//
//  BluetoothManage.swift
//  OBDUpdater
//
//  Created by myrc on 2025/7/1.
//

import ExternalAccessory

class BluetoothManage: NSObject, StreamDelegate,@unchecked Sendable {
    private var mName: [String] = []
    private var state: State = .disconnected
    private var accessoryManager: EAAccessoryManager!
    private var connectedAccessory: EAAccessory?
    private var mSession: EASession?
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var receiveBuffer = Data()
    
    // 专用后台线程和 RunLoop（用于驱动 Stream 事件）
    private var streamThread: Thread!
    private var streamRunLoop: RunLoop!
    // 线程安全队列（用于同步共享资源访问）
    private let syncQueue = DispatchQueue(label: "TCP.SyncQueue")
    
    override init() {
        super.init()
        accessoryManager = EAAccessoryManager.shared()
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
   
    
    func open(name: String) async -> Result<Void, ConnectError> {
        let connectState = syncQueue.sync { state }
        if connectState == .connected {
            return .success(())
        }
        if connectState == .connecting {
            return .failure(.connecting)
        }
        mName = name.components(separatedBy: ":").filter{ !$0.isEmpty }
        guard !mName.isEmpty else {
            return .failure(.invalidData)
        }
        var connectProtocolString = ""
        for eaAccessory in accessoryManager.connectedAccessories {
            for protocolString in eaAccessory.protocolStrings {
                if mName.contains(where: { protocolString.hasPrefix($0) == true }) {
                    connectedAccessory = eaAccessory
                    connectProtocolString = protocolString
                    break;
                }
            }
        }
        guard connectedAccessory != nil, connectProtocolString != ""  else {
            return .failure(.noCompatibleDevices)
        }
        // 等待线程的RunLoop准备就绪
        guard await waitForStreamThreadReady() else {
            return .failure(.connectionFailed(NSError(domain: "BluetoothManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Thread init failed."])))
        }
        
        syncQueue.sync {
            self.state = .connecting
        }
        mSession = EASession.init(accessory: connectedAccessory!, forProtocol: connectProtocolString)
        if let session = mSession {
            inputStream = session.inputStream
            outputStream = session.outputStream
            guard let inputStream = inputStream, let outputStream = outputStream else {
                return .failure(.connectionFailed(NSError(domain: "BluetoothManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Stream init failed."])))
            }
            inputStream.delegate = self
            inputStream.schedule(in: self.streamRunLoop, forMode: .default)
            inputStream.open()
            
            outputStream.delegate = self
            outputStream.schedule(in: self.streamRunLoop, forMode: .default)
            outputStream.open()
            return .success(())
        } else {
            return .failure(.connectionFailed(NSError(domain: "BluetoothManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "EASession init failed."])))
        }
    }
    
    func write(data: Data, timeout: TimeInterval) async -> Result<Void, ConnectError> {
        let currentState = syncQueue.sync {state}
        guard currentState == .connected, let outputStream = outputStream, outputStream.hasSpaceAvailable, isOpened() else {
            return .failure(.notConnected)
        }
        let totalLength = data.count
        guard totalLength > 0 else {
            // 空数据视为发送成功
            return .success(())
        }
        let startTime = CFAbsoluteTimeGetCurrent()
        var result:Result<Void, ConnectError> = .success(())
        var bytesSent = 0
        
        while bytesSent < totalLength  {
            let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
            if elapsedTime >= timeout {
                result =  .failure(.sendTimeout)
                break
            }
            let remainingLength = totalLength - bytesSent
            let buffer = data.subdata(in: bytesSent..<totalLength)
            let bytesWritten = buffer.withUnsafeBytes { bufferPtr in
                outputStream.write(bufferPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), maxLength: remainingLength)
            }
            if bytesWritten > 0 {
                bytesSent += bytesWritten
                if bytesSent == totalLength {
                    result =  .success(())
                    break
                }
            } else if bytesWritten < 0 {
                result = .failure(.sendFailed(outputStream.streamError))
                break
            }
        }
        return result
    }
    
    func waitForReadData(timeout: TimeInterval = 10.0) async -> Bool {
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
    
    func read(timeout: TimeInterval) async -> Result<Data, ConnectError> {
        let currentState = syncQueue.sync {state}
        guard currentState == .connected, let inputStream = inputStream, isOpened() else {
            clenReceiveInfo()
            return .failure(.notConnected)
        }
        
        guard await waitForReadData() else {
            clenReceiveInfo()
            return .failure(.receiveTimeout)
        }
        let result = syncQueue.sync {receiveBuffer}
        return .success(result)
    }
    
    func clenReceiveInfo() {
        syncQueue.async { [weak self] in
            guard let self = self else {return}
            self.receiveBuffer.removeAll()
        }
    }
    
    func isOpened() -> Bool {
        return mSession != nil
    }
    
    func close() {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            // 清理
            self.inputStream?.delegate = nil
            self.outputStream?.delegate = nil
            self.inputStream?.close()
            self.inputStream?.remove(from: self.streamRunLoop!, forMode: .default)
            self.inputStream = nil
            self.outputStream?.close()
            self.outputStream?.remove(from: self.streamRunLoop!, forMode: .default)
            self.outputStream = nil
            
            self.mSession = nil
            self.connectedAccessory = nil
            
            self.receiveBuffer.removeAll()
            self.state = .disconnected
        }
    }
    
    private func checkForReceivedData(input: InputStream) {
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        
        while input.hasBytesAvailable {
            let bytesRead = input.read(&buffer, maxLength: bufferSize)
            if bytesRead > 0 {
                let receivedData = Data(bytes: buffer, count: bytesRead)
                syncQueue.async { [weak self] in
                    self?.receiveBuffer.append(receivedData)
                }
            }
        }
    }
    
    /// MARK: - StreamDelegate（处理流事件）
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
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
        case .errorOccurred, .endEncountered:
            syncQueue.async { [weak self] in
                self?.state = .disconnected
            }
        default:
            break
        }
        
    }
}
