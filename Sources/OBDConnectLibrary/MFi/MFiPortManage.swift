//
//  MFiPortManage.swift
//  OBDConnectLibrary
//
//  MFi 端口管理类
//  对应 Android: ClassicPortManage.kt
//
//  实现 PortManageProtocol 协议，封装 MFiManager 的功能
//

import Foundation

// MARK: - MFiPortManage

/// MFi 端口管理类
///
/// 实现 PortManageProtocol 协议，封装 MFiManager 的功能。
/// 对应 Kotlin 的 `ClassicPortManage`
public class MFiPortManage: PortManageProtocol {
    
    // MARK: - Private Properties
    
    private let mfiManager: MFiManager
    
    /// MFi 协议字符串
    /// - Note: 需要在调用 connect 前设置，或通过 connect 参数传入
    public var protocolString: String?
    
    // MARK: - PortManageProtocol Callbacks
    
    /// 设备断开连接时的回调
    public var onDeviceDisconnect: (() -> Void)? {
        get { return mfiManager.onDeviceDisconnect }
        set { mfiManager.onDeviceDisconnect = newValue }
    }
    
    /// 蓝牙状态变化导致断开的回调
    public var onBluetoothStateDisconnect: (() -> Void)? {
        get { return mfiManager.onBluetoothStateDisconnect }
        set { mfiManager.onBluetoothStateDisconnect = newValue }
    }
    
    /// RSSI 更新回调
    /// - Note: MFi 设备不支持 RSSI，此回调不会被触发
    public var onRssiUpdate: ((Int) -> Void)?
    
    /// 发现新设备时的回调
    public var onDeviceFound: ((Set<DiscoveredDevice>) -> Void)? {
        get { return mfiManager.onDeviceFound }
        set { mfiManager.onDeviceFound = newValue }
    }
    
    /// 接收到数据时的回调
    public var onDataReceived: ((Data) -> Void)? {
        get { return mfiManager.onDataReceived }
        set { mfiManager.onDataReceived = newValue }
    }
    
    // MARK: - Initialization
    
    /// 初始化 MFi 端口管理器
    ///
    /// - Parameter protocolString: 可选的 MFi 协议字符串，也可以稍后设置
    public init(protocolString: String? = nil) {
        self.mfiManager = MFiManager()
        self.protocolString = protocolString
    }
    
    // MARK: - PortManageProtocol Implementation
    
    /// 开始扫描 MFi 设备
    ///
    /// - Note: MFi 设备需要先在系统蓝牙设置中配对，此方法返回已配对的 MFi 设备
    public func startScan(completion: @escaping (Result<Void, ConnectError>) -> Void) {
        mfiManager.startScan(completion: completion)
    }
    
    /// 停止扫描
    public func stopScan() {
        mfiManager.stopScan()
    }
    
    /// 连接设备
    ///
    /// - Parameters:
    ///   - name: 设备标识符（serialNumber）
    ///   - completion: 完成回调
    public func connect(name: String, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        // 如果设置了协议字符串，使用完整连接方法
        if let proto = protocolString {
            mfiManager.connect(serialNumber: name, protocolString: proto, completion: completion)
        } else {
            // 否则使用简化版（自动选择第一个协议）
            mfiManager.connect(identifier: name, completion: completion)
        }
    }
    
    /// 使用指定协议字符串连接
    ///
    /// - Parameters:
    ///   - serialNumber: 设备序列号
    ///   - protocolString: MFi 协议字符串
    ///   - completion: 完成回调
    public func connect(serialNumber: String, protocolString: String, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        self.protocolString = protocolString
        mfiManager.connect(serialNumber: serialNumber, protocolString: protocolString, completion: completion)
    }
    
    /// 重新连接
    public func reconnect(completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        mfiManager.reconnect(completion: completion)
    }
    
    /// 关闭连接
    public func close() {
        mfiManager.disconnect()
    }
    
    /// 发送数据
    public func write(data: Data, timeout: TimeInterval, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        mfiManager.sendData(data, timeout: timeout, completion: completion)
    }
    
    // MARK: - MFi Specific Methods
    
    /// 获取当前已连接的 MFi 配件列表
    ///
    /// - Returns: EAAccessory 数组
    public func getConnectedAccessories() -> [Any] {
        return mfiManager.getConnectedAccessories()
    }
    
    /// 释放资源
    public func release() {
        mfiManager.destroy()
    }
    
    /// 当前连接状态
    public var connectionState: MFiConnectionState {
        return mfiManager.connectionState
    }
}
