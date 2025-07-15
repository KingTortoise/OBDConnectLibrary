//
//  TcpManage.swift
//  OBDUpdater
//
//  Created by myrc on 2025/7/2.
//

import Foundation
import SwiftUI

class TcpManage: NSObject, StreamDelegate, @unchecked Sendable {
    
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var state: State = .disconnected
    private var receiveBuffer = Data()
    // 专用后台线程和 RunLoop（用于驱动 Stream 事件）
    private var streamThread: Thread!
    private var streamRunLoop: RunLoop!
    // 线程安全队列（用于同步共享资源访问）
    private let syncQueue = DispatchQueue(label: "TCP.SyncQueue")
    
    override init() {
        super.init()
        setupStreamThread()
    }
    
    // 初始化后台线程和 RunLoop
    private func setupStreamThread() {
        streamThread = Thread { [weak self] in
            guard let self = self else { return }
            // 保存当前线程的 RunLoop
            self.streamRunLoop = RunLoop.current
            // 给 RunLoop 添加一个空的端口，避免立即退出
            let port = Port()
            self.streamRunLoop.add(port, forMode: .default)
            // 启动 RunLoop（永久循环，直到线程被取消）
            while !self.streamThread.isCancelled {
                self.streamRunLoop.run(until: Date().addingTimeInterval(0.1))
            }
        }
        streamThread.name = "TCP.StreamThread"
        streamThread.start()
    }
    
    func waitForInputStream(timeout: TimeInterval = 5.0)  async -> Bool  {
        await wait(unit: { [weak self] () -> Bool in
            return self?.syncQueue.sync {
                self?.state == .connected
            } ?? false
        }, timeout: timeout)
    }
    
    // 等待后台线程和 RunLoop 准备就绪
    private func waitForStreamThreadReady(timeout: TimeInterval = 2.0) async -> Bool {
        await wait(unit: { [weak self] in
            guard let self = self else { return false }
            if self.streamThread?.isExecuting == true {
                return true
            } else {
                return false
            }
        }, timeout: timeout)
    }
    
    func waitForReadData(timeout: TimeInterval = 5.0) async -> Bool {
        await wait(unit: { [weak self] in
            guard let self = self else { return false }
            return self.syncQueue.sync {
                if self.receiveBuffer.count > 0 {
                    if let endData = self.receiveBuffer.last {
                        let endChar = Unicode.Scalar(endData)
                        return endChar == ">"
                    } else {
                        return false
                    }
                } else {
                    return false
                }
            }
        }, timeout: timeout)
    }
    
    func openChannel(name: String, timeout: TimeInterval) async -> Result<Void, ConnectError> {
        // 先在syncQueue中检查状态（避免并发修改）
        let currentState = syncQueue.sync { state }
        // 检查当前状态
        guard currentState == .disconnected else {
            return .failure(.connectionFailed(nil))
        }
        
        let info = name.components(separatedBy: ":")
        guard info.count >= 2 else {
            return .failure(.invalidName)
        }
        
        let host = info[0] as CFString
        if let port = UInt32(info[1]) {
            // 等待线程的RunLoop准备就绪
            guard await waitForStreamThreadReady() else {
                return .failure(.connectionFailed(nil))
            }
            self.syncQueue.sync { self.state = .connecting }
            var readStream: Unmanaged<CFReadStream>?
            var writeStream: Unmanaged<CFWriteStream>?
            CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault, host, port, &readStream, &writeStream)
            guard let input = readStream?.takeRetainedValue(), let output = writeStream?.takeRetainedValue()  else {
                self.syncQueue.sync { self.state = .disconnected }
                return .failure(.connectionFailed(nil))
                
                                    
            }
            self.inputStream = input
            self.outputStream = output
            self.inputStream?.delegate = self
            self.outputStream?.delegate = self
            self.inputStream?.schedule(in: self.streamRunLoop, forMode: .default)
            self.outputStream?.schedule(in: self.streamRunLoop, forMode: .default)
            
            self.inputStream?.open()
            self.outputStream?.open()
            let connectSuccess = await waitForInputStream(timeout: timeout)
            return connectSuccess ?  .success(()) :  .failure(.connectionFailed(nil))
        } else {
            return .failure(.invalidName)
        }           
    }
    
    func write(data: Data, timeout: TimeInterval) async -> Result<Void, ConnectError> {
        let (currentState, output) = syncQueue.sync { (state, outputStream) }
        guard currentState == .connected, let output = output else {
            return .failure(.notConnected)
        }
        let totalLength = data.count
        guard totalLength > 0 else {
            // 空数据视为发送成功
            return .success(())
        }
        var bytesSent = 0
        let startTime = CFAbsoluteTimeGetCurrent()
        var result:Result<Void, ConnectError> = .success(())
        
        while bytesSent < totalLength  {
            let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
            if elapsedTime >= timeout {
                result =  .failure(.sendTimeout)
                break
            }
            let remainingLength = totalLength - bytesSent
            let buffer = data.subdata(in: bytesSent..<totalLength)
            let bytesWritten = buffer.withUnsafeBytes { bufferPtr in
                output.write(bufferPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), maxLength: remainingLength)
            }
            if bytesWritten > 0 {
                bytesSent += bytesWritten
                if bytesSent == totalLength {
                    result =  .success(())
                    break
                }
            } else if bytesWritten < 0 {
                result = .failure(.sendFailed(output.streamError))
                break
            }
        }
        return result
    }
    
    // 接收数据
    func read(timeout: TimeInterval) async -> Result<Data, ConnectError> {
        let currentState = syncQueue.sync { state }
        guard currentState == .connected else {
            return .failure(.notConnected)
        }
        guard await waitForReadData() else {
            clenReceiveInfo()
            return .failure(.receiveTimeout)
        }
        return .success(self.receiveBuffer)
    }
    
    func clenReceiveInfo() {
        syncQueue.async { [weak self] in
            guard let self = self else {return}
            self.receiveBuffer.removeAll()
        }
    }
    
    private func checkForReceivedData(input: InputStream) {
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        
        while input.hasBytesAvailable {
            let bytesRead = input.read(&buffer, maxLength: bufferSize)
            if bytesRead > 0 {
                receiveBuffer.append(buffer, count: bytesRead)
            }
        }
    }
    
    func close(){
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 关闭流
            self.inputStream?.close()
            self.outputStream?.close()
            // 从RunLoop移除
            self.inputStream?.remove(from: self.streamRunLoop!, forMode: .default)
            self.outputStream?.remove(from: self.streamRunLoop!, forMode: .default)
            // 清理
            self.inputStream?.delegate = nil
            self.outputStream?.delegate = nil
            self.inputStream = nil
            self.outputStream = nil
            self.receiveBuffer.removeAll()
            self.state = .disconnected
        }
    }
    
    // 析构时清理资源
    deinit {
        streamThread?.cancel()
        close()
    }
        
    
    /// ##StreamDelegate
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            switch eventCode {
            case .openCompleted:
                // 连接成功（两个流都打开才算完成）
                if aStream is InputStream, self.inputStream?.streamStatus == .open, self.outputStream?.streamStatus == .open {
                    self.state = .connected
                }
                                
            case .hasBytesAvailable:
                //  读取数据并处理
                if let input = aStream as? InputStream {
                    self.checkForReceivedData(input: input)
                }
            case .errorOccurred:
                self.state = .disconnected
            case .endEncountered:
                self.state = .disconnected
            default:
                break
            }
        }
        
    }
}
