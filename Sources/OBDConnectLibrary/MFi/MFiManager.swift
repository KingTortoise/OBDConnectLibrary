//
//  MFiManager.swift
//  OBDConnectLibrary
//
//  MFi (External Accessory) 连接管理器
//  对应 Android: ClassicManager.kt (SPP)
//
//  使用 ExternalAccessory.framework 实现 MFi 认证的经典蓝牙连接
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
    
    /// 连接状态
    private(set) var connectionState: MFiConnectionState = .disconnected
    
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
    
    /// 数据接收工作队列
    private let workQueue = DispatchQueue(label: "com.obdconnect.mfi.work", qos: .userInitiated)
    
    /// 流处理运行循环
    private var streamThread: Thread?
    
    /// 是否应该停止流处理
    private var shouldStopStreaming = false
    
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
            closeSession()
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
        guard connectionState != .connected else {
            completion(.success(true))
            return
        }
        
        guard connectionState != .connecting else {
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
            
            guard let session = EASession(accessory: targetAccessory, forProtocol: protocolString) else {
                DispatchQueue.main.async {
                    self.connectionState = .disconnected
                    completion(.failure(.connectionFailed(underlyingError: NSError(
                        domain: "MFiManager",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create session"]
                    ))))
                }
                return
            }
            
            self.session = session
            self.connectedAccessory = targetAccessory
            self.inputStream = session.inputStream
            self.outputStream = session.outputStream
            
            // 配置流
            self.setupStreams()
            
            DispatchQueue.main.async {
                self.connectionState = .connected
                completion(.success(true))
            }
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
        guard connectionState != .connected else {
            completion(.success(true))
            return
        }
        
        guard connectionState != .connecting else {
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
            
            // 清理
            input.close()
            output.close()
            input.remove(from: runLoop, forMode: .default)
            output.remove(from: runLoop, forMode: .default)
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
        
        guard let output = outputStream else {
            completion(.failure(.sendFailed(underlyingError: NSError(
                domain: "MFiManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Output stream not available"]
            ))))
            return
        }
        
        workQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.isWaitingResponse = true
            self.lastReceiveTime = Date()
            
            data.withUnsafeBytes { buffer in
                guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    DispatchQueue.main.async {
                        completion(.failure(.sendFailed(underlyingError: NSError(
                            domain: "MFiManager",
                            code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "Invalid data buffer"]
                        ))))
                    }
                    return
                }
                
                var bytesWritten = 0
                var totalBytes = data.count
                
                while bytesWritten < totalBytes {
                    let written = output.write(pointer.advanced(by: bytesWritten), maxLength: totalBytes - bytesWritten)
                    
                    if written < 0 {
                        DispatchQueue.main.async {
                            completion(.failure(.sendFailed(underlyingError: output.streamError ?? NSError(
                                domain: "MFiManager",
                                code: -3,
                                userInfo: [NSLocalizedDescriptionKey: "Write failed"]
                            ))))
                        }
                        return
                    }
                    
                    bytesWritten += written
                }
            }
            
            DispatchQueue.main.async {
                completion(.success(true))
            }
        }
    }
    
    // MARK: - Disconnect
    
    /// 断开连接
    public func disconnect() {
        closeSession()
        connectionState = .disconnected
    }
    
    private func closeSession() {
        shouldStopStreaming = true
        
        inputStream?.delegate = nil
        outputStream?.delegate = nil
        
        // 必须在释放 session 之前显式关闭流！
        // 否则 EASession dealloc 时发现流仍然开着，
        // 会报 "unable to close session" 错误，
        // 导致后续新建 EASession 返回 nil，连接失败。
        inputStream?.close()
        outputStream?.close()
        
        inputStream = nil
        outputStream = nil
        session = nil
        connectedAccessory = nil
        
        // 等待线程结束
        streamThread?.cancel()
        streamThread = nil
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
        switch eventCode {
        case .hasBytesAvailable:
            guard let input = aStream as? InputStream else { return }
            readAvailableBytes(from: input)
            
        case .hasSpaceAvailable:
            // 可以写入数据
            break
            
        case .errorOccurred:
            logD("\(TAG): Stream error: \(aStream.streamError?.localizedDescription ?? "unknown")")
            DispatchQueue.main.async { [weak self] in
                self?.connectionState = .disconnected
                self?.onDeviceDisconnect?()
            }
            
        case .endEncountered:
            logD("\(TAG): Stream ended")
            DispatchQueue.main.async { [weak self] in
                self?.connectionState = .disconnected
                self?.onDeviceDisconnect?()
            }
            
        default:
            break
        }
    }
    
    private func readAvailableBytes(from stream: InputStream) {
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: bufferSize)
            
            if bytesRead > 0 {
                let data = Data(bytes: buffer, count: bytesRead)
                
                isWaitingResponse = false
                lastReceiveTime = Date()
                
                // 通知接收到数据
                DispatchQueue.main.async { [weak self] in
                    self?.onDataReceived?(data)
                }
            } else if bytesRead < 0 {
                logD("\(TAG): Read error: \(stream.streamError?.localizedDescription ?? "unknown")")
                break
            }
        }
    }
}
