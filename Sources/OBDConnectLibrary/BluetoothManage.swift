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
            inputStream.schedule(in: self.streamRunLoop, forMode: .common)
            inputStream.open()
            
            outputStream.schedule(in: self.streamRunLoop, forMode: .common)
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
        var totalLength = data.count
        guard totalLength > 0 else {
            // 空数据视为发送成功
            return .success(())
        }
        var i = 0
        var buffer = [UInt8](data)
        let startTime = CFAbsoluteTimeGetCurrent()
        var result:Result<Void, ConnectError> = .success(())
        
        while totalLength > 0 {
            let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
            if elapsedTime >= timeout {
                result = .failure(.sendTimeout)
                break
            }
            let bytesWritten = outputStream.write(&buffer[i], maxLength: totalLength)
            if bytesWritten < 0 {
                result = .failure(.sendFailed(outputStream.streamError))
                break;
            }
            totalLength -= bytesWritten
            i += bytesWritten
            
            if totalLength <= 0 {
                result = .success(())
            }
        }
        return result
    }
    
    func read(timeout: TimeInterval) async -> Result<Data, ConnectError> {
        let currentState = syncQueue.sync {state}
        guard currentState == .connected, let inputStream = inputStream, isOpened() else {
            clenReceiveInfo()
            return .failure(.notConnected)
        }
     
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let startTime = CFAbsoluteTimeGetCurrent()
        var result:Result<Data, ConnectError> = .success(Data())
        var receiveStatus = true
        while receiveStatus {
            let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
            if elapsedTime >= timeout {
                result = .failure(.sendTimeout)
                receiveStatus = false
                clenReceiveInfo()
                break
            }
            let count = inputStream.read(&buffer, maxLength: bufferSize)
            if count > 0 {
                self.receiveBuffer.append(buffer, count: count)
            }
            if self.receiveBuffer.count > 0 {
                if let endData = self.receiveBuffer.last {
                    let endChar = Unicode.Scalar(endData)
                    if endChar == ">" {
                        result = .success(self.receiveBuffer)
                        receiveStatus = false
                    }
                }
            }
        }
        return result
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
            self.inputStream?.close()
            self.inputStream?.remove(from: self.streamRunLoop!, forMode: .common)
            self.inputStream = nil
            self.outputStream?.close()
            self.outputStream?.remove(from: self.streamRunLoop!, forMode: .common)
            self.outputStream = nil
            
            self.mSession = nil
            self.connectedAccessory = nil
            
            self.receiveBuffer.removeAll()
            self.state = .disconnected
        }
    }
}
