//
//  TCPPortManage.swift
//  OBDConnectLibrary
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//
//  对应 Android: TcpPortManage.kt
//

import Foundation

// MARK: - TCPPortManage

/// TCP 端口管理类
///
/// 实现 PortManageProtocol 协议，封装 TCPManager 的功能。
///
/// - Note: 对应 Kotlin 的 `class TcpPortManage`
public class TCPPortManage: PortManageProtocol {
    
    // MARK: - Private Properties
    
    private let tcpManager: TCPManager
    
    // MARK: - PortManageProtocol Callbacks
    
    /// 设备断开连接时的回调
    public var onDeviceDisconnect: (() -> Void)? {
        get { return tcpManager.onDeviceDisconnect }
        set { tcpManager.onDeviceDisconnect = newValue }
    }
    
    /// 蓝牙状态变化导致断开的回调（TCP 不使用）
    public var onBluetoothStateDisconnect: (() -> Void)? {
        get { return tcpManager.onBluetoothStateDisconnect }
        set { tcpManager.onBluetoothStateDisconnect = newValue }
    }
    
    /// RSSI 更新回调（TCP 不支持）
    public var onRssiUpdate: ((Int) -> Void)? {
        get { return nil }
        set { }
    }
    
    /// 发现新设备时的回调（TCP 不支持扫描）
    public var onDeviceFound: ((Set<DiscoveredDevice>) -> Void)? {
        get { return nil }
        set { }
    }
    
    /// 接收到数据时的回调
    public var onDataReceived: ((Data) -> Void)? {
        get { return tcpManager.onDataReceived }
        set { tcpManager.onDataReceived = newValue }
    }
    
    // MARK: - Initialization
    
    /// 初始化 TCP 端口管理器
    public init() {
        self.tcpManager = TCPManager()
    }
    
    // MARK: - PortManageProtocol Implementation
    
    /// 开始扫描（TCP 不支持，直接返回成功）
    public func startScan(completion: @escaping (Result<Void, ConnectError>) -> Void) {
        // TCP 不支持扫描，直接返回成功
        completion(.success(()))
    }
    
    /// 停止扫描（TCP 不支持，空实现）
    public func stopScan() {
        // TCP 不支持扫描
    }
    
    /// 连接设备
    ///
    /// - Parameters:
    ///   - name: 连接地址，格式为 "ip:port:timeout"
    ///   - completion: 完成回调
    public func connect(name: String, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        tcpManager.openChannel(name: name, completion: completion)
    }
    
    /// 重新连接
    public func reconnect(completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        tcpManager.reconnect(completion: completion)
    }
    
    /// 关闭连接
    public func close() {
        tcpManager.disconnect()
    }
    
    /// 发送数据
    public func write(data: Data, timeout: TimeInterval, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        tcpManager.sendData(data, timeout: timeout, completion: completion)
    }
    
    // MARK: - TCP Specific Methods
    
    /// 开始接收数据监听
    public func startReceiveDataMonitoring() {
        tcpManager.startReceiveDataMonitoring()
    }
    
    /// 停止接收数据监听
    public func stopReceiveDataMonitoring() {
        tcpManager.stopReceiveDataMonitoring()
    }
}
