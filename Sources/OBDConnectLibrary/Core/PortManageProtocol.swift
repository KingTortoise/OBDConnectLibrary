//
//  PortManageProtocol.swift
//  OBDConnectLibrary
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//
//  对应 Android: IPortManage.kt
//

import Foundation

// MARK: - DiscoveredDevice

/// 扫描发现的设备信息
///
/// 包含设备标识符、名称和信号强度。
/// 使用 `Hashable` 以支持 Set 集合操作。
public struct DiscoveredDevice: Hashable {
    
    /// 设备唯一标识符
    ///
    /// - Note: 在 iOS 上为 `CBPeripheral.identifier` (UUID)，
    ///         不同于 Android 的 MAC 地址。
    public let identifier: String
    
    /// 设备名称
    ///
    /// 可能为 nil，取决于设备广播数据。
    public let name: String?
    
    /// 信号强度 (RSSI)
    ///
    /// 单位为 dBm，值越大信号越强。
    public var rssi: Int
    
    /// 初始化 DiscoveredDevice
    ///
    /// - Parameters:
    ///   - identifier: 设备唯一标识符
    ///   - name: 设备名称（可选）
    ///   - rssi: 信号强度
    public init(identifier: String, name: String?, rssi: Int) {
        self.identifier = identifier
        self.name = name
        self.rssi = rssi
    }
    
    // MARK: - Hashable
    
    /// 仅使用 identifier 进行哈希和比较
    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
    
    public static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        return lhs.identifier == rhs.identifier
    }
}

// MARK: - PortManageProtocol

/// 端口管理协议
///
/// 定义了蓝牙/TCP 连接管理器需要实现的核心接口。
/// 支持扫描、连接、数据收发等操作。
///
/// - Note: 对应 Kotlin 的 `interface IPortManage`
/// - Important: 所有异步操作使用闭包回调（兼容 iOS 12）
public protocol PortManageProtocol: AnyObject {
    
    // MARK: - Callbacks (事件回调)
    
    /// 设备断开连接时的回调
    ///
    /// 当已连接的设备断开时触发。
    var onDeviceDisconnect: (() -> Void)? { get set }
    
    /// 蓝牙状态变化导致断开的回调
    ///
    /// 当系统蓝牙被关闭时触发。
    var onBluetoothStateDisconnect: (() -> Void)? { get set }
    
    /// RSSI 更新回调
    ///
    /// 定期返回当前连接设备的信号强度。
    /// - Parameter rssi: 信号强度值 (dBm)
    var onRssiUpdate: ((Int) -> Void)? { get set }
    
    /// 发现新设备时的回调
    ///
    /// 每次扫描到新设备或设备信息更新时触发。
    /// - Parameter devices: 当前已发现的所有设备集合
    var onDeviceFound: ((Set<DiscoveredDevice>) -> Void)? { get set }
    
    /// 接收到数据时的回调
    ///
    /// 当从已连接设备接收到数据时触发。
    /// - Parameter data: 接收到的原始数据
    var onDataReceived: ((Data) -> Void)? { get set }
    
    // MARK: - Scanning (扫描)
    
    /// 开始扫描设备
    ///
    /// 扫描结果通过 `onDeviceFound` 回调返回。
    ///
    /// - Parameter completion: 完成回调
    ///   - success: 扫描是否成功启动
    ///   - error: 失败时的错误信息
    func startScan(completion: @escaping (Result<Void, ConnectError>) -> Void)
    
    /// 停止扫描设备
    ///
    /// 停止正在进行的设备扫描。此方法为同步操作。
    func stopScan()
    
    // MARK: - Connection (连接)
    
    /// 连接到指定设备
    ///
    /// 使用设备名称或标识符进行连接。
    ///
    /// - Parameters:
    ///   - name: 设备名称或标识符
    ///   - completion: 完成回调
    ///     - success: 连接是否成功
    ///     - error: 失败时的错误信息
    func connect(name: String, completion: @escaping (Result<Bool, ConnectError>) -> Void)
    
    /// 重新连接到上次连接的设备
    ///
    /// - Parameter completion: 完成回调
    ///   - success: 重连是否成功
    ///   - error: 失败时的错误信息
    func reconnect(completion: @escaping (Result<Bool, ConnectError>) -> Void)
    
    /// 关闭连接并释放资源
    ///
    /// 断开当前连接并清理所有相关资源。
    func close()
    
    // MARK: - Data Transfer (数据传输)
    
    /// 发送数据到已连接设备
    ///
    /// - Parameters:
    ///   - data: 要发送的数据
    ///   - timeout: 超时时间（秒）
    ///   - completion: 完成回调
    ///     - success: 发送是否成功
    ///     - error: 失败时的错误信息
    func write(data: Data, timeout: TimeInterval, completion: @escaping (Result<Bool, ConnectError>) -> Void)
}

// MARK: - Default Implementations

/// 协议默认实现
///
/// 为可选回调提供空实现，简化实现类的代码。
public extension PortManageProtocol {
    
    /// 默认回调为 nil
    var onDeviceDisconnect: (() -> Void)? {
        get { return nil }
        set { }
    }
    
    var onBluetoothStateDisconnect: (() -> Void)? {
        get { return nil }
        set { }
    }
    
    var onRssiUpdate: ((Int) -> Void)? {
        get { return nil }
        set { }
    }
}
