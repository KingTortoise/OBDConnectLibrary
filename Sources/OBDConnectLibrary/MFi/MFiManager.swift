//
//  MFiManager.swift
//  OBDConnectLibrary
//
//  MFi (External Accessory) 连接管理器
//  对应 Android: ClassicManager.kt (SPP)
//
//  使用 ExternalAccessory.framework 实现 MFi 认证的经典蓝牙连接
//
//  线程模型：
//  - 主线程：EAAccessory 通知、connectionState 变化、回调分发
//  - workQueue：连接/重连操作、数据准备
//  - MFiStreamThread：流事件处理、流读写
//  - 所有流操作（open/read/write/close）必须在 MFiStreamThread 上执行
//

import Foundation
import ExternalAccessory

// MARK: - MFiConnectionState

/// MFi 连接状态
public enum MFiConnectionState {
    case disconnected
    case connecting
    case connected
}

// MARK: - MFiManager

/// MFi 连接管理器
///
/// 使用 ExternalAccessory 框架管理 MFi 认证的经典蓝牙设备连接。
/// 对应 Android 的 `ClassicManager` (SPP 连接)。
///
/// - Important: 需要在 Info.plist 中配置 `UISupportedExternalAccessoryProtocols`
public class MFiManager: NSObject {
    
    // MARK: - Constants
    
    private let TAG = "MFiManager"
    private let RECEIVE_TIMEOUT: TimeInterval = 10.0
    
    // MARK: - Properties
    
    /// 连接状态 - 使用 stateLock 保护
    private var _connectionState: MFiConnectionState = .disconnected
    private let stateLock = NSLock()
    
    private(set) var connectionState: MFiConnectionState {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _connectionState
        }
        set {
            stateLock.lock()
            _connectionState = newValue
            stateLock.unlock()
        }
    }
    
    /// 已连接的配件
    private var connectedAccessory: EAAccessory?
    
    /// 会话
    private var session: EASession?
    
    /// 输入流
    private var inputStream: InputStream?
    
    /// 输出流
    private var outputStream: OutputStream?
    
    /// 目标协议字符串
    private var targetProtocolString: String?
    
    /// 上次连接的配件 Serial Number (用于重连)
    private var lastConnectedSerialNumber: String?
    
    /// 接收数据缓冲区
    private var receiveBuffer = Data()
    
    /// 是否正在等待响应
    private var isWaitingResponse = false
    
    /// 上次接收数据时间
    private var lastReceiveTime: Date = Date()
    
    /// 流状态锁 - 保护流相关属性的线程安全访问
    private let streamLock = NSLock()
    
    /// 数据接收工作队列
    private let workQueue = DispatchQueue(label: "com.obdconnect.mfi.work", qos: .userInitiated)
    
    /// 流处理运行循环
    private var streamThread: Thread?
    
    /// 是否应该停止流处理
    private var shouldStopStreaming = false
    
    /// 流线程的 CFRunLoop 引用（用于从外部唤醒 RunLoop）
    private var streamRunLoop: CFRunLoop?
    
    /// 流线程清理完成信号量
    private var cleanupSemaphore: DispatchSemaphore?
    
    /// 是否正在关闭 session（重入保护）
    private var isClosingSession = false
    
    // MARK: - Callbacks
    
    /// 设备断开连接回调
    public var onDeviceDisconnect: (() -> Void)?
    
    /// 蓝牙状态变化导致断开的回调
    public var onBluetoothStateDisconnect: (() -> Void)?
    
    /// 发现设备回调
    public var onDeviceFound: ((Set<DiscoveredDevice>) -> Void)?
    
    /// 接收到数据回调
    public var onDataReceived: ((Data) -> Void)?
    
    // MARK: - Initialization
    
    public override init() {
        super.init()
        setupNotifications()
    }
    
    deinit {
        destroy()
    }
    
    // MARK: - Notification Setup
    
    private func setupNotifications() {
        // 监听配件连接
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessoryDidConnect(_:)),
            name: .EAAccessoryDidConnect,
            object: nil
        )
        
        // 监听配件断开
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessoryDidDisconnect(_:)),
            name: .EAAccessoryDidDisconnect,
            object: nil
        )
        
        // 开始接收通知
        EAAccessoryManager.shared().registerForLocalNotifications()
    }
    
    @objc private func accessoryDidConnect(_ notification: Notification) {
        logD("\(TAG): Accessory connected")
        // 如果正在等待连接，检查是否是目标设备
        refreshConnectedDevices()
    }
    
    @objc private func accessoryDidDisconnect(_ notification: Notification) {
        guard let accessory = notification.userInfo?[EAAccessoryKey] as? EAAccessory else {
            return
        }
        
        logD("\(TAG): Accessory disconnected: \(accessory.name)")
        
        // 检查是否是当前连接的设备
        if accessory.serialNumber == connectedAccessory?.serialNumber {
            connectionState = .disconnected
            
            // 异步关闭 session，避免阻塞主线程
            // closeSession 内部使用 semaphore 等待流线程清理，
            // 如果在主线程同步调用可能导致 UI 卡顿
            workQueue.async { [weak self] in
                self?.closeSession()
            }
            
            onDeviceDisconnect?()
        }
        
        // 刷新设备列表
        refreshConnectedDevices()
    }
    
    // MARK: - Device Discovery
    
    /// 获取当前已连接的 MFi 设备列表
    ///
    /// - Note: MFi 设备需要先在系统蓝牙设置中配对
    public func getConnectedAccessories() -> [EAAccessory] {
        return EAAccessoryManager.shared().connectedAccessories
    }
    
    /// 刷新并通知已连接的设备
    private func refreshConnectedDevices() {
        let accessories = getConnectedAccessories()
        
        // 转换为 DiscoveredDevice
        let devices = Set(accessories.map { accessory in
            DiscoveredDevice(
                identifier: accessory.serialNumber,
                name: accessory.name.isEmpty ? "MFi Device" : accessory.name,
                rssi: 0  // MFi 设备没有 RSSI 信息
            )
        })
        
        onDeviceFound?(devices)
    }
    
    /// 开始扫描（返回已配对的 MFi 设备）
    ///
    /// - Parameter completion: 完成回调
    public func startScan(completion: @escaping (Result<Void, ConnectError>) -> Void) {
        // MFi 设备不需要主动扫描，直接返回已连接的配件
        refreshConnectedDevices()
        completion(.success(()))
    }
    
    /// 停止扫描
    public func stopScan() {
        // MFi 没有主动扫描过程
    }
    
    // MARK: - Connection
    
    /// 连接到指定设备
    ///
    /// - Parameters:
    ///   - serialNumber: 设备序列号
    ///   - protocolString: MFi 协议字符串
    ///   - timeout: 超时时间（秒）
    ///   - completion: 完成回调
    public func connect(
        serialNumber: String,
        protocolString: String,
        timeout: TimeInterval = 30.0,
        completion: @escaping (Result<Bool, ConnectError>) -> Void
    ) {
        // 检查当前状态
        let currentState = connectionState
        guard currentState != .connected else {
            completion(.success(true))
            return
        }
        
        guard currentState != .connecting else {
            completion(.failure(.connecting))
            return
        }
        
        connectionState = .connecting
        targetProtocolString = protocolString
        lastConnectedSerialNumber = serialNumber
        
        // 查找目标配件
        let accessories = getConnectedAccessories()
        guard let targetAccessory = accessories.first(where: { $0.serialNumber == serialNumber }) else {
            connectionState = .disconnected
            completion(.failure(.connectionFailed(underlyingError: NSError(
                domain: "MFiManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Device not found: \(serialNumber)"]
            ))))
            return
        }
        
        // 检查协议支持
        guard targetAccessory.protocolStrings.contains(protocolString) else {
            connectionState = .disconnected
            completion(.failure(.connectionFailed(underlyingError: NSError(
                domain: "MFiManager",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Protocol not supported: \(protocolString)"]
            ))))
            return
        }
        
        // 打开会话
        workQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 如果有旧 session，先清理
            if self.session != nil {
                self.closeSession()
            }
            
            guard let session = EASession(accessory: targetAccessory, forProtocol: protocolString) else {
                self.connectionState = .disconnected
                completion(.failure(.connectionFailed(underlyingError: NSError(
                    domain: "MFiManager",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create session"]
                ))))
                return
            }
            
            self.session = session
            self.connectedAccessory = targetAccessory
            self.inputStream = session.inputStream
            self.outputStream = session.outputStream
            
            // 配置流
            self.setupStreams()
            
            self.connectionState = .connected
            completion(.success(true))
        }
    }
    
    /// 使用设备标识符连接（简化版，使用默认协议）
    ///
    /// - Parameters:
    ///   - identifier: 设备标识符（serialNumber）
    ///   - completion: 完成回调
    public func connect(identifier: String, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        // 查找设备并获取其支持的第一个协议
        let accessories = getConnectedAccessories()
        guard let accessory = accessories.first(where: { $0.serialNumber == identifier }),
              let protocolString = accessory.protocolStrings.first else {
            completion(.failure(.connectionFailed(underlyingError: NSError(
                domain: "MFiManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Device not found or no protocol available"]
            ))))
            return
        }
        
        connect(serialNumber: identifier, protocolString: protocolString, completion: completion)
    }
    
    /// 重新连接到上次连接的设备
    public func reconnect(completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        let currentState = connectionState
        guard currentState != .connected else {
            completion(.success(true))
            return
        }
        
        guard currentState != .connecting else {
            completion(.failure(.connecting))
            return
        }
        
        guard let serialNumber = lastConnectedSerialNumber,
              let protocolString = targetProtocolString else {
            completion(.failure(.connectionFailed(underlyingError: NSError(
                domain: "MFiManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No previous connection to reconnect"]
            ))))
            return
        }
        
        connect(serialNumber: serialNumber, protocolString: protocolString, completion: completion)
    }
    
    // MARK: - Stream Setup
    
    private func setupStreams() {
        guard let input = inputStream, let output = outputStream else { return }
        
        shouldStopStreaming = false
        
        // 创建专用线程处理流
        streamThread = Thread { [weak self] in
            guard let self = self else { return }
            
            let runLoop = RunLoop.current
            
            // 保存 CFRunLoop 引用，以便 closeSession 可以唤醒它
            self.streamRunLoop = CFRunLoopGetCurrent()
            
            input.delegate = self
            output.delegate = self
            
            input.schedule(in: runLoop, forMode: .default)
            output.schedule(in: runLoop, forMode: .default)
            
            input.open()
            output.open()
            
            // 运行循环
            while !self.shouldStopStreaming && runLoop.run(mode: .default, before: .distantFuture) {
                // 继续运行
            }
            
            // ===== 清理 - 全部在流线程上执行，避免线程竞争 =====
            // ExternalAccessory 框架在处理流事件时会访问流/session 对象，
            // 如果从外部线程关闭流会导致 SIGSEGV。
            // 所以所有流的 close/remove/nil 操作必须在这里完成。
            input.delegate = nil
            output.delegate = nil
            input.close()
            output.close()
            input.remove(from: runLoop, forMode: .default)
            output.remove(from: runLoop, forMode: .default)
            
            // 安全清理引用
            self.streamLock.lock()
            self.inputStream = nil
            self.outputStream = nil
            self.session = nil
            self.streamRunLoop = nil
            self.streamLock.unlock()
            
            // 通知 closeSession 清理完成
            self.cleanupSemaphore?.signal()
        }
        
        streamThread?.name = "MFiStreamThread"
        streamThread?.start()
    }
    
    // MARK: - Data Transfer
    
    /// 发送数据
    ///
    /// - Parameters:
    ///   - data: 要发送的数据
    ///   - timeout: 超时时间
    ///   - completion: 完成回调
    public func sendData(_ data: Data, timeout: TimeInterval, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        guard connectionState == .connected else {
            completion(.failure(.notConnected))
            return
        }
        
        guard !shouldStopStreaming else {
            completion(.failure(.notConnected))
            return
        }
        
        guard let rl = streamRunLoop else {
            completion(.failure(.sendFailed(underlyingError: NSError(
                domain: "MFiManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Stream not available"]
            ))))
            return
        }
        
        // 将写操作调度到流线程上执行
        // 流（InputStream/OutputStream）的所有操作必须在其被调度的 RunLoop 线程上进行，
        // 否则会导致线程竞争和 SIGSEGV
        let writeBlock: @convention(block) () -> Void = { [weak self] in
            guard let self = self else { return }
            
            // 在流线程上再次检查状态
            guard !self.shouldStopStreaming else {
                completion(.failure(.notConnected))
                return
            }
            
            guard let output = self.outputStream else {
                completion(.failure(.sendFailed(underlyingError: NSError(
                    domain: "MFiManager",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Output stream not available"]
                ))))
                return
            }
            
            self.isWaitingResponse = true
            self.lastReceiveTime = Date()
            
            data.withUnsafeBytes { buffer in
                guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    completion(.failure(.sendFailed(underlyingError: NSError(
                        domain: "MFiManager",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid data buffer"]
                    ))))
                    return
                }
                
                var bytesWritten = 0
                let totalBytes = data.count
                
                while bytesWritten < totalBytes {
                    // 发送前检查是否已停止
                    guard !self.shouldStopStreaming else {
                        completion(.failure(.notConnected))
                        return
                    }
                    
                    let written = output.write(pointer.advanced(by: bytesWritten), maxLength: totalBytes - bytesWritten)
                    
                    if written < 0 {
                        completion(.failure(.sendFailed(underlyingError: output.streamError ?? NSError(
                            domain: "MFiManager",
                            code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "Write failed"]
                        ))))
                        return
                    }
                    
                    bytesWritten += written
                }
            }
            
            completion(.success(true))
        }
        
        // 使用 CFRunLoopPerformBlock 在流线程的 RunLoop 上执行写操作
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue, writeBlock)
        CFRunLoopWakeUp(rl)
    }
    
    // MARK: - Disconnect
    
    /// 断开连接
    public func disconnect() {
        connectionState = .disconnected
        closeSession()
    }
    
    private func closeSession() {
        // 重入保护：防止 closeSession 被并发重复调用
        streamLock.lock()
        guard !isClosingSession else {
            streamLock.unlock()
            return
        }
        isClosingSession = true
        streamLock.unlock()
        
        defer {
            streamLock.lock()
            isClosingSession = false
            streamLock.unlock()
        }
        
        // 1. 标记停止
        shouldStopStreaming = true
        
        // 2. 准备等待清理完成
        let semaphore = DispatchSemaphore(value: 0)
        cleanupSemaphore = semaphore
        
        // 3. 唤醒流线程的 RunLoop，让它退出循环并执行清理
        if let rl = streamRunLoop {
            CFRunLoopStop(rl)
        }
        
        // 4. 等待流线程完成清理（最多 3 秒）
        // 流的 close/remove/nil 全部由流线程自己完成，避免线程竞争
        if streamThread != nil {
            _ = semaphore.wait(timeout: .now() + 3.0)
        }
        
        // 5. 清理线程引用
        cleanupSemaphore = nil
        streamThread = nil
        connectedAccessory = nil
    }
    
    /// 销毁管理器
    public func destroy() {
        NotificationCenter.default.removeObserver(self)
        EAAccessoryManager.shared().unregisterForLocalNotifications()
        disconnect()
    }
    
    // MARK: - Logging
    
    private func logD(_ message: String) {
        #if DEBUG
        print("[DEBUG] \(message)")
        #endif
    }
}

// MARK: - StreamDelegate

extension MFiManager: StreamDelegate {
    
    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        // Guard: if streaming has stopped, ignore all events
        guard !shouldStopStreaming else { return }
        
        switch eventCode {
        case .hasBytesAvailable:
            guard let input = aStream as? InputStream else { return }
            readAvailableBytes(from: input)
            
        case .hasSpaceAvailable:
            // 可以写入数据
            break
            
        case .errorOccurred:
            guard !shouldStopStreaming else { return }
            logD("\(TAG): Stream error: \(aStream.streamError?.localizedDescription ?? "unknown")")
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.connectionState != .disconnected else { return }
                self.connectionState = .disconnected
                self.onDeviceDisconnect?()
            }
            
        case .endEncountered:
            guard !shouldStopStreaming else { return }
            logD("\(TAG): Stream ended")
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.connectionState != .disconnected else { return }
                self.connectionState = .disconnected
                self.onDeviceDisconnect?()
            }
            
        default:
            break
        }
    }
    
    private func readAvailableBytes(from stream: InputStream) {
        // Guard: if streaming has stopped, don't read
        guard !shouldStopStreaming else { return }
        
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        
        while stream.hasBytesAvailable && !shouldStopStreaming {
            let bytesRead = stream.read(&buffer, maxLength: bufferSize)
            
            if bytesRead > 0 {
                let data = Data(bytes: buffer, count: bytesRead)
                
                isWaitingResponse = false
                lastReceiveTime = Date()
                
                // 通知接收到数据
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, !self.shouldStopStreaming else { return }
                    self.onDataReceived?(data)
                }
            } else if bytesRead < 0 {
                logD("\(TAG): Read error: \(stream.streamError?.localizedDescription ?? "unknown")")
                break
            }
        }
    }
}
