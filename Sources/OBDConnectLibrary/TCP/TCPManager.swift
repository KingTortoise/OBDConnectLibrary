//
//  TCPManager.swift
//  OBDConnectLibrary
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//
//  对应 Android: TcpManager.kt
//
//  职责：
//  - TCP/IP 连接管理
//  - 数据发送与接收
//  - 断线检测与重连
//

import Foundation

// MARK: - TCPManager

/// TCP 连接管理类
///
/// 使用 BSD Socket API 实现 TCP 连接，兼容 iOS 12+。
/// 
/// - Note: 对应 Kotlin 的 `class TcpManager`
public class TCPManager: @unchecked Sendable {
    
    // ==================================================================================
    // MARK: - 1. 常量定义
    // ==================================================================================
    
    private let TAG = "TCPManager"
    
    /// 最大重连次数（0 表示不自动重连）
    private let MAX_RECONNECT_ATTEMPTS = 0
    /// 初始重连间隔（秒）
    private let INITIAL_RECONNECT_DELAY: TimeInterval = 1.0
    /// 连接状态检查间隔（秒）
    private let CONNECTION_CHECK_INTERVAL: TimeInterval = 5.0
    /// 数据接收超时时间（秒）
    private let RECEIVE_TIMEOUT: TimeInterval = 20.0
    
    // ==================================================================================
    // MARK: - 2. 连接核心组件
    // ==================================================================================
    
    /// 输入流
    private var inputStream: InputStream?
    /// 输出流
    private var outputStream: OutputStream?
    /// 接收数据的后台线程
    private var receiveThread: Thread?
    /// 是否应该停止接收
    private var shouldStopReceiving = false
    
    // ==================================================================================
    // MARK: - 3. 连接状态管理
    // ==================================================================================
    
    /// 当前连接状态
    private var currentConnectState: ConnectState = .disconnected {
        didSet {
            logD("\(TAG): State changed from \(oldValue) to \(currentConnectState)")
        }
    }
    
    /// 是否已连接
    public var isConnected: Bool {
        return currentConnectState == .connected
    }
    
    /// 连接地址 (格式: ip:port:timeout)
    private var connectAddress: String?
    /// 连接 IP
    private var connectIp: String?
    /// 连接端口
    private var connectPort: Int?
    
    // ==================================================================================
    // MARK: - 4. 重连与超时控制
    // ==================================================================================
    
    /// 当前重连次数
    private var reconnectAttempts = 0
    /// 上次检查连接的时间
    private var lastCheckTime: Date = Date()
    /// 上次接收到数据的时间
    private var lastReceiveTime: Date = Date()
    /// 写入是否成功
    private var isWriteSuccess = false
    /// 是否正在等待设备返回数据
    private var isWaitingResponse = false
    /// 重连回调
    private var reconnectCompletion: ((Result<Bool, ConnectError>) -> Void)?
    /// 重连地址
    private var reconnectAddress: String?
    /// 连接回调
    private var openChannelCompletion: ((Result<Bool, ConnectError>) -> Void)?
    /// 发送数据回调
    private var sendDataCompletion: ((Result<Bool, ConnectError>) -> Void)?
    
    // ==================================================================================
    // MARK: - 5. 线程安全锁
    // ==================================================================================
    
    private let stateLock = NSLock()
    private let streamLock = NSLock()
    
    // ==================================================================================
    // MARK: - 6. 回调函数
    // ==================================================================================
    
    /// 设备断开连接回调
    public var onDeviceDisconnect: (() -> Void)?
    
    /// 蓝牙状态变化导致断开的回调（TCP 不使用，但保持接口一致）
    public var onBluetoothStateDisconnect: (() -> Void)?
    
    /// 接收到数据时的回调
    public var onDataReceived: ((Data) -> Void)?
    
    // ==================================================================================
    // MARK: - 7. 初始化
    // ==================================================================================
    
    public init() {}
    
    // ==================================================================================
    // MARK: - 8. 连接方法
    // ==================================================================================
    
    /// 打开 TCP 连接通道
    ///
    /// - Parameters:
    ///   - name: 连接地址，格式为 "ip:port:timeout"
    ///   - completion: 完成回调
    ///
    /// - Note: 对应 Kotlin 的 `openChannel(name: String)`
    public func openChannel(name: String, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        stateLock.lock()
        if currentConnectState == .connected {
            stateLock.unlock()
            completion(.success(true))
            return
        }
        if currentConnectState == .connecting {
            stateLock.unlock()
            completion(.failure(.connecting))
            return
        }
        currentConnectState = .connecting
        stateLock.unlock()
        
        // 解析连接地址
        let info = name.split(separator: ":").map { String($0) }
        if info.count < 3 {
            stateLock.lock()
            currentConnectState = .disconnected
            stateLock.unlock()
            completion(.failure(.invalidName))
            return
        }
        
        guard let port = Int(info[1]), let timeout = Int(info[2]) else {
            stateLock.lock()
            currentConnectState = .disconnected
            stateLock.unlock()
            completion(.failure(.invalidName))
            return
        }
        
        connectAddress = name
        connectIp = info[0]
        connectPort = port
        openChannelCompletion = completion
        
        let host = info[0]
        
        // 在后台线程创建连接
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            self.createConnection(host: host, port: port, timeout: timeout) { [weak self] result in
                guard let self = self else { return }
                let callback = self.openChannelCompletion
                self.openChannelCompletion = nil
                
                switch result {
                case .success:
                    self.stateLock.lock()
                    self.currentConnectState = .connected
                    self.stateLock.unlock()
                    logD("\(self.TAG): Connected to \(host):\(port)")
                    callback?(.success(true))
                    
                case .failure(let error):
                    self.stateLock.lock()
                    self.currentConnectState = .disconnected
                    self.stateLock.unlock()
                    logE("\(self.TAG): Connection failed: \(error.localizedDescription)")
                    callback?(.failure(error))
                }
            }
        }
    }
    
    /// 创建 TCP 连接
    private func createConnection(host: String, port: Int, timeout: Int, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        
        // 使用 CFStream 创建 TCP 连接
        CFStreamCreatePairWithSocketToHost(
            kCFAllocatorDefault,
            host as CFString,
            UInt32(port),
            &readStream,
            &writeStream
        )
        
        guard let inputCFStream = readStream?.takeRetainedValue(),
              let outputCFStream = writeStream?.takeRetainedValue() else {
            completion(.failure(.connectionFailed(underlyingError: NSError(domain: "TCP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create streams"]))))
            return
        }
        
        let input = inputCFStream as InputStream
        let output = outputCFStream as OutputStream
        
        // 设置超时（通过 RunLoop 控制）
        let timeoutSeconds = TimeInterval(timeout) / 1000.0
        
        // 打开流
        input.open()
        output.open()
        
        // 等待连接建立
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeoutSeconds {
            let inputStatus = input.streamStatus
            let outputStatus = output.streamStatus
            
            if inputStatus == .open && outputStatus == .open {
                // 连接成功
                streamLock.lock()
                self.inputStream = input
                self.outputStream = output
                streamLock.unlock()
                completion(.success(true))
                return
            }
            
            if inputStatus == .error || outputStatus == .error {
                // 连接失败
                let error = input.streamError ?? output.streamError
                input.close()
                output.close()
                completion(.failure(.connectionFailed(underlyingError: error)))
                return
            }
            
            // 等待 10ms 再检查
            Thread.sleep(forTimeInterval: 0.01)
        }
        
        // 超时
        input.close()
        output.close()
        completion(.failure(.connectionTimeout))
    }
    
    // ==================================================================================
    // MARK: - 9. 断开方法
    // ==================================================================================
    
    /// 断开 TCP 连接
    ///
    /// - Note: 对应 Kotlin 的 `disconnect()`
    public func disconnect() {
        shouldStopReceiving = true
        receiveThread?.cancel()
        receiveThread = nil
        
        streamLock.lock()
        inputStream?.close()
        outputStream?.close()
        inputStream = nil
        outputStream = nil
        streamLock.unlock()
        
        stateLock.lock()
        currentConnectState = .disconnected
        stateLock.unlock()
        
        logD("\(TAG): Disconnected")
    }
    
    /// 验证连接是否有效
    private func isConnectionValid() -> Bool {
        streamLock.lock()
        defer { streamLock.unlock() }
        
        guard let input = inputStream, let output = outputStream else {
            return false
        }
        
        let inputStatus = input.streamStatus
        let outputStatus = output.streamStatus
        
        return inputStatus == .open && outputStatus == .open
    }
    
    /// 验证 IP 是否可用并触发断开回调
    private func verifyIpIsAvailable() {
        if !isConnectionValid() {
            stateLock.lock()
            currentConnectState = .disconnected
            stateLock.unlock()
            
            isWriteSuccess = false
            DispatchQueue.main.async { [weak self] in
                self?.onDeviceDisconnect?()
            }
        }
    }
    
    // ==================================================================================
    // MARK: - 10. 重连方法
    // ==================================================================================
    
    /// 重新连接到上次的地址
    ///
    /// - Note: 对应 Kotlin 的 `reconnect()`
    public func reconnect(completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        if currentConnectState == .connected {
            completion(.success(true))
            return
        }
        if currentConnectState == .connecting {
            completion(.failure(.connecting))
            return
        }
        
        guard let address = connectAddress else {
            completion(.failure(.connectionFailed(underlyingError: NSError(domain: "TCP", code: -1, userInfo: [NSLocalizedDescriptionKey: "No target address for reconnection"]))))
            return
        }
        
        performReconnect(address: address, completion: completion)
    }
    
    /// 带重试机制的重连实现
    private func performReconnect(address: String, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        reconnectAttempts = 0
        reconnectCompletion = completion
        reconnectAddress = address
        attemptReconnectInternal()
    }
    
    /// 内部重连尝试
    private func attemptReconnectInternal() {
        guard let address = reconnectAddress, let completion = reconnectCompletion else { return }
        
        if reconnectAttempts >= MAX_RECONNECT_ATTEMPTS {
            reconnectAttempts = 0
            stateLock.lock()
            currentConnectState = .disconnected
            stateLock.unlock()
            reconnectCompletion = nil
            reconnectAddress = nil
            completion(.failure(.connectionFailed(underlyingError: NSError(domain: "TCP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Max reconnection attempts reached"]))))
            return
        }
        
        reconnectAttempts += 1
        let currentAttempt = reconnectAttempts
        
        openChannel(name: address) { [weak self] result in
            guard let self = self else { return }
            guard let storedCompletion = self.reconnectCompletion else { return }
            
            switch result {
            case .success:
                self.reconnectAttempts = 0
                self.reconnectCompletion = nil
                self.reconnectAddress = nil
                storedCompletion(.success(true))
                
            case .failure:
                if self.reconnectAttempts >= self.MAX_RECONNECT_ATTEMPTS {
                    self.reconnectAttempts = 0
                    self.reconnectCompletion = nil
                    self.reconnectAddress = nil
                    storedCompletion(.failure(.connectionFailed(underlyingError: NSError(domain: "TCP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Max reconnection attempts reached"]))))
                } else {
                    // 指数退避
                    let delay = self.INITIAL_RECONNECT_DELAY * pow(2.0, Double(currentAttempt - 1))
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.attemptReconnectInternal()
                    }
                }
            }
        }
    }
    
    // ==================================================================================
    // MARK: - 11. 写入方法
    // ==================================================================================
    
    /// 发送数据
    ///
    /// - Parameters:
    ///   - data: 要发送的数据
    ///   - timeout: 超时时间（秒）
    ///   - completion: 完成回调
    ///
    /// - Note: 对应 Kotlin 的 `sendData(data: ByteArray, timeout: Long)`
    public func sendData(_ data: Data, timeout: TimeInterval, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        guard currentConnectState == .connected else {
            logW("\(TAG): Not connected, cannot send data")
            completion(.failure(.notConnected))
            return
        }
        
        sendDataCompletion = completion
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            self.streamLock.lock()
            guard let output = self.outputStream else {
                self.streamLock.unlock()
                let callback = self.sendDataCompletion
                self.sendDataCompletion = nil
                callback?(.failure(.notConnected))
                return
            }
            self.streamLock.unlock()
            
            let startTime = Date()
            var bytesWritten = 0
            let totalBytes = data.count
            
            while bytesWritten < totalBytes {
                if Date().timeIntervalSince(startTime) > timeout {
                    logE("\(self.TAG): Send timeout")
                    self.verifyIpIsAvailable()
                    let callback = self.sendDataCompletion
                    self.sendDataCompletion = nil
                    callback?(.failure(.sendTimeout))
                    return
                }
                
                let remainingData = data.subdata(in: bytesWritten..<totalBytes)
                let written = remainingData.withUnsafeBytes { buffer -> Int in
                    guard let baseAddress = buffer.baseAddress else { return -1 }
                    return output.write(baseAddress.assumingMemoryBound(to: UInt8.self), maxLength: remainingData.count)
                }
                
                if written < 0 {
                    logE("\(self.TAG): Send data failed: \(output.streamError?.localizedDescription ?? "Unknown error")")
                    self.verifyIpIsAvailable()
                    let callback = self.sendDataCompletion
                    self.sendDataCompletion = nil
                    callback?(.failure(.sendFailed(underlyingError: output.streamError)))
                    return
                }
                
                bytesWritten += written
            }
            
            // 标记发送成功，等待响应
            self.isWaitingResponse = true
            self.isWriteSuccess = true
            
            logD("\(self.TAG): Sent \(totalBytes) bytes")
            let callback = self.sendDataCompletion
            self.sendDataCompletion = nil
            callback?(.success(true))
        }
    }
    
    // ==================================================================================
    // MARK: - 12. 读取方法
    // ==================================================================================
    
    /// 开始接收数据监听
    ///
    /// 数据通过 `onDataReceived` 回调返回。
    ///
    /// - Note: 对应 Kotlin 的 `receiveDataFlow()`
    public func startReceiveDataMonitoring() {
        guard currentConnectState == .connected else {
            logW("\(TAG): Not connected, cannot receive data")
            return
        }
        
        shouldStopReceiving = false
        lastCheckTime = Date()
        lastReceiveTime = Date()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            while !self.shouldStopReceiving && self.currentConnectState == .connected {
                self.streamLock.lock()
                guard let input = self.inputStream else {
                    self.streamLock.unlock()
                    break
                }
                self.streamLock.unlock()
                
                if input.hasBytesAvailable {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    let bytesRead = input.read(&buffer, maxLength: buffer.count)
                    
                    if bytesRead > 0 {
                        // 成功读取数据
                        self.lastReceiveTime = Date()
                        self.isWaitingResponse = false
                        
                        let data = Data(buffer[0..<bytesRead])
                        self.onDataReceived?(data)
                    } else if bytesRead < 0 {
                        // 连接异常
                        logE("\(self.TAG): Connection closed by peer (read returns -1)")
                        break
                    }
                } else if self.isWriteSuccess {
                    // 无数据：检查连接状态
                    let currentTime = Date()
                    if currentTime.timeIntervalSince(self.lastCheckTime) >= self.CONNECTION_CHECK_INTERVAL {
                        self.verifyIpIsAvailable()
                        if !self.isConnectionValid() {
                            break
                        }
                        self.lastCheckTime = currentTime
                    }
                    
                    // 接收超时检测
                    if self.isWaitingResponse && currentTime.timeIntervalSince(self.lastReceiveTime) > self.RECEIVE_TIMEOUT {
                        self.isWaitingResponse = false
                        logE("\(self.TAG): Receive timeout: no data received within \(self.RECEIVE_TIMEOUT)s")
                    }
                    
                    // 无数据时短暂延迟
                    Thread.sleep(forTimeInterval: 0.01)
                } else {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            
            // 异常退出时验证连接
            if self.currentConnectState == .connected {
                self.verifyIpIsAvailable()
            }
        }
    }
    
    /// 停止接收数据
    public func stopReceiveDataMonitoring() {
        shouldStopReceiving = true
    }
}
