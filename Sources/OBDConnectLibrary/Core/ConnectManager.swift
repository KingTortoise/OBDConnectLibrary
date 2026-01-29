//
//  ConnectManager.swift
//  OBDConnectLibrary
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//
//  对应 Android: ConnectManager.kt
//
//  职责：
//  - 统一管理 BLE 和 TCP 连接
//  - 提供单例访问入口
//  - 屏蔽底层连接类型差异
//

import Foundation

// MARK: - ConnectType

/// 连接类型
///
/// - Note: 对应 Kotlin 的 `enum class ConnectType`
public enum ConnectType: Int {
    /// WiFi/TCP 连接
    case wifi = 0
    /// 经典蓝牙 MFi (External Accessory)
    case bt = 1
    /// BLE 蓝牙低功耗
    case ble = 2
}

// MARK: - VLContext

/// 连接上下文
///
/// - Note: 对应 Kotlin 的 `data class VlContext`
public class VLContext {
    /// 连接类型
    public var type: ConnectType
    /// 设备名称/地址
    public var name: String?
    /// 是否已连接
    public var isOpen: Bool
    /// 端口管理器
    public var port: PortManageProtocol?
    
    public init(type: ConnectType, name: String? = nil, isOpen: Bool = false, port: PortManageProtocol? = nil) {
        self.type = type
        self.name = name
        self.isOpen = isOpen
        self.port = port
    }
}

// MARK: - ConnectManager

/// 连接管理器单例
///
/// 提供统一的 BLE 和 TCP 连接管理接口。
///
/// 使用示例:
/// ```swift
/// // 初始化 BLE 连接
/// ConnectManager.shared.initManager(type: .ble)
///
/// // 开始扫描
/// ConnectManager.shared.startScan { result in
///     switch result {
///     case .success:
///         print("Scan started")
///     case .failure(let error):
///         print("Scan failed: \(error)")
///     }
/// }
///
/// // 连接设备
/// ConnectManager.shared.connect(name: deviceId) { result in
///     // ...
/// }
/// ```
///
/// - Note: 对应 Kotlin 的 `object ConnectManager`
public class ConnectManager: @unchecked Sendable {
    
    // MARK: - Singleton
    
    /// 单例实例
    public static let shared = ConnectManager()
    
    private init() {}
    
    // MARK: - Properties
    
    /// 全局连接上下文
    public private(set) var globalContext: VLContext?
    
    // MARK: - Callbacks
    
    /// 设备断开连接回调
    public var onDeviceDisconnect: (() -> Void)? {
        didSet {
            globalContext?.port?.onDeviceDisconnect = onDeviceDisconnect
        }
    }
    
    /// 蓝牙状态变化导致断开的回调
    public var onBluetoothDisconnect: (() -> Void)? {
        didSet {
            globalContext?.port?.onBluetoothStateDisconnect = onBluetoothDisconnect
        }
    }
    
    /// RSSI 更新回调
    public var onHandleRssiUpdate: ((Int) -> Void)? {
        didSet {
            globalContext?.port?.onRssiUpdate = onHandleRssiUpdate
        }
    }
    
    /// 发现新设备回调
    public var onDeviceFound: ((Set<DiscoveredDevice>) -> Void)? {
        didSet {
            globalContext?.port?.onDeviceFound = onDeviceFound
        }
    }
    
    /// 接收到数据回调
    public var onDataReceived: ((Data) -> Void)? {
        didSet {
            globalContext?.port?.onDataReceived = onDataReceived
        }
    }
    
    // MARK: - Init Manager
    
    /// 初始化管理器
    ///
    /// - Parameter type: 连接类型
    /// - Returns: 连接上下文，如果类型不支持则返回 nil
    ///
    /// - Note: 对应 Kotlin 的 `initManager(type: Int, context: Context)`
    @discardableResult
    public func initManager(type: ConnectType) -> VLContext? {
        // 如果已有相同类型且已打开的连接，直接返回
        if let context = globalContext {
            if context.type == type && context.isOpen {
                return context
            } else {
                close()
            }
        }
        
        // 根据类型创建端口管理器
        let manager: PortManageProtocol?
        switch type {
        case .bt:
            // MFi 经典蓝牙 (External Accessory)
            manager = MFiPortManage()
        case .ble:
            manager = BLEPortManage()
        case .wifi:
            manager = TCPPortManage()
        }
        
        guard let port = manager else {
            return nil
        }
        
        // 创建上下文
        let context = VLContext(type: type, name: nil, isOpen: false, port: port)
        globalContext = context
        
        // 同步回调
        port.onDeviceDisconnect = onDeviceDisconnect
        port.onBluetoothStateDisconnect = onBluetoothDisconnect
        port.onRssiUpdate = onHandleRssiUpdate
        port.onDeviceFound = onDeviceFound
        port.onDataReceived = onDataReceived
        
        return context
    }
    
    // MARK: - Scan Methods
    
    /// 开始扫描设备
    ///
    /// - Parameter completion: 完成回调
    ///
    /// - Note: 对应 Kotlin 的 `startScan()`
    public func startScan(completion: @escaping (Result<Void, ConnectError>) -> Void) {
        guard let port = globalContext?.port else {
            completion(.failure(.connectionFailed(underlyingError: NSError(domain: "ConnectManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "port is null."]))))
            return
        }
        port.startScan(completion: completion)
    }
    
    /// 停止扫描
    ///
    /// - Note: 对应 Kotlin 的 `stopScan()`
    public func stopScan() {
        globalContext?.port?.stopScan()
    }
    
    // MARK: - Connection Methods
    
    /// 连接设备
    ///
    /// - Parameters:
    ///   - name: 设备标识符（BLE: UUID, TCP: ip:port:timeout）
    ///   - completion: 完成回调
    ///
    /// - Note: 对应 Kotlin 的 `connect(name: String, context: Context)`
    public func connect(name: String, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        guard let port = globalContext?.port else {
            completion(.failure(.connectionFailed(underlyingError: NSError(domain: "ConnectManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "port is null."]))))
            return
        }
        
        globalContext?.name = name
        port.connect(name: name) { [weak self] result in
            switch result {
            case .success(let success):
                self?.globalContext?.isOpen = success
                completion(.success(success))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    /// 重新连接
    ///
    /// - Parameter completion: 完成回调
    ///
    /// - Note: 对应 Kotlin 的 `reconnect()`
    public func reconnect(completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        guard let port = globalContext?.port else {
            completion(.failure(.connectionFailed(underlyingError: NSError(domain: "ConnectManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "port is null."]))))
            return
        }
        
        port.reconnect { [weak self] result in
            if case .success(let success) = result {
                self?.globalContext?.isOpen = success
            }
            completion(result)
        }
    }
    
    /// 关闭连接
    ///
    /// - Note: 对应 Kotlin 的 `close()`
    public func close() {
        globalContext?.port?.close()
        globalContext?.isOpen = false
    }
    
    // MARK: - Data Transfer Methods
    
    /// 发送数据
    ///
    /// - Parameters:
    ///   - data: 要发送的数据
    ///   - timeout: 超时时间（秒）
    ///   - completion: 完成回调
    ///
    /// - Note: 对应 Kotlin 的 `write(data: ByteArray, timeout: Long)`
    public func write(data: Data, timeout: TimeInterval, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        guard let port = globalContext?.port else {
            completion(.failure(.sendFailed(underlyingError: NSError(domain: "ConnectManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "port is null."]))))
            return
        }
        port.write(data: data, timeout: timeout, completion: completion)
    }
    
    // MARK: - BLE Specific Methods
    
    /// 获取 BLE 设备信息
    ///
    /// 仅对 BLE 连接类型有效。
    ///
    /// - Parameter completion: 完成回调，返回设备信息
    ///
    /// - Note: 对应 Kotlin 的 `getBleDeviceInfo()`
    public func getBleDeviceInfo(completion: @escaping @Sendable (BLEDeviceInfo?) -> Void) {
        guard globalContext?.type == .ble,
              let blePort = globalContext?.port as? BLEPortManage else {
            completion(nil)
            return
        }
        blePort.getBLEDeviceInfo { info in
            completion(info)
        }
    }
    
    /// 更改 BLE 写入配置
    ///
    /// - Parameters:
    ///   - uuid: 特征 UUID
    ///   - typeName: 写入类型名称
    ///   - status: 是否启用
    ///
    /// - Note: 对应 Kotlin 的 `onChangeBleWriteInfo(uuid, typeName, status)`
    public func onChangeBleWriteInfo(uuid: String, typeName: String, status: Bool) {
        guard globalContext?.type == .ble,
              let blePort = globalContext?.port as? BLEPortManage else {
            return
        }
        blePort.onChangeBLEWriteInfo(uuid: uuid, typeName: typeName, status: status)
    }
    
    /// 更改 BLE 描述符配置
    ///
    /// - Parameters:
    ///   - uuid: 特征 UUID
    ///   - typeName: 描述符类型名称
    ///   - status: 是否启用
    ///
    /// - Note: 对应 Kotlin 的 `onChangeBleDescriptorInfo(uuid, typeName, status)`
    public func onChangeBleDescriptorInfo(uuid: String, typeName: String, status: Bool) {
        guard globalContext?.type == .ble,
              let blePort = globalContext?.port as? BLEPortManage else {
            return
        }
        blePort.onChangeBLEDescriptorInfo(uuid: uuid, typeName: typeName, status: status)
    }
    
    // MARK: - TCP Specific Methods
    
    /// 开始 TCP 数据接收监听
    ///
    /// 仅对 TCP 连接类型有效。
    public func startTCPReceiveMonitoring() {
        guard globalContext?.type == .wifi,
              let tcpPort = globalContext?.port as? TCPPortManage else {
            return
        }
        tcpPort.startReceiveDataMonitoring()
    }
    
    /// 停止 TCP 数据接收监听
    public func stopTCPReceiveMonitoring() {
        guard globalContext?.type == .wifi,
              let tcpPort = globalContext?.port as? TCPPortManage else {
            return
        }
        tcpPort.stopReceiveDataMonitoring()
    }
    
    // MARK: - Utility Methods
    
    /// 当前连接类型
    public var currentType: ConnectType? {
        return globalContext?.type
    }
    
    /// 是否已连接
    public var isConnected: Bool {
        return globalContext?.isOpen ?? false
    }
    
    /// 当前设备名称/地址
    public var currentDeviceName: String? {
        return globalContext?.name
    }
}
