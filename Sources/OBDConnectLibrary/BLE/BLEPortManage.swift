//
//  BLEPortManage.swift
//  OBDConnectLibrary
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//
//  对应 Android: BlePortManage.kt
//

import Foundation
import CoreBluetooth

// MARK: - BLEPortManage

/// BLE 端口管理类
///
/// 实现 PortManageProtocol 协议，封装 BLEManager 的功能。
///
/// - Note: 对应 Kotlin 的 `class BlePortManage`
public class BLEPortManage: PortManageProtocol {
    
    // MARK: - Private Properties
    
    private let bleManager: BLEManager
    
    // MARK: - PortManageProtocol Callbacks
    
    /// 设备断开连接时的回调
    public var onDeviceDisconnect: (() -> Void)? {
        get { return bleManager.onDeviceDisconnect }
        set { bleManager.onDeviceDisconnect = newValue }
    }
    
    /// 蓝牙状态变化导致断开的回调
    public var onBluetoothStateDisconnect: (() -> Void)? {
        get { return bleManager.onBluetoothStateDisconnect }
        set { bleManager.onBluetoothStateDisconnect = newValue }
    }
    
    /// RSSI 更新回调
    public var onRssiUpdate: ((Int) -> Void)? {
        get { return bleManager.onHandleRssiUpdate }
        set { bleManager.onHandleRssiUpdate = newValue }
    }
    
    /// 发现新设备时的回调
    /// 转换 BLEDeviceWithRssi 到 DiscoveredDevice
    public var onDeviceFound: ((Set<DiscoveredDevice>) -> Void)? {
        get { return nil }
        set {
            bleManager.onDeviceFound = { devices in
                guard let callback = newValue else { return }
                let discoveredDevices = Set(devices.map { device in
                    DiscoveredDevice(
                        identifier: device.peripheral.identifier.uuidString,
                        name: device.name,
                        rssi: device.rssi
                    )
                })
                callback(discoveredDevices)
            }
        }
    }
    
    /// 接收到数据时的回调
    public var onDataReceived: ((Data) -> Void)? {
        get { return bleManager.onDataReceived }
        set { bleManager.onDataReceived = newValue }
    }
    
    // MARK: - Initialization
    
    /// 初始化 BLE 端口管理器
    public init() {
        self.bleManager = BLEManager()
    }
    
    // MARK: - PortManageProtocol Implementation
    
    /// 开始扫描 BLE 设备
    public func startScan(completion: @escaping (Result<Void, ConnectError>) -> Void) {
        bleManager.startScan(completion: completion)
    }
    
    /// 停止扫描
    public func stopScan() {
        bleManager.stopScan()
    }
    
    /// 连接设备
    public func connect(name: String, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        bleManager.connectDevice(identifier: name, timeout: 30.0, completion: completion)
    }
    
    /// 重新连接
    public func reconnect(completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        bleManager.reconnect(completion: completion)
    }
    
    /// 关闭连接
    public func close() {
        bleManager.closeChannel()
    }
    
    /// 发送数据
    public func write(data: Data, timeout: TimeInterval, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        bleManager.sendData(data, timeout: timeout, completion: completion)
    }
    
    // MARK: - BLE Specific Methods
    
    /// 开始接收数据监听
    public func startReceiveDataMonitoring() {
        bleManager.startReceiveDataMonitoring()
    }
    
    /// 获取 BLE 设备信息
    public func getBLEDeviceInfo(completion: @escaping @Sendable (BLEDeviceInfo) -> Void) {
        bleManager.getBLEDeviceInfo(completion: completion)
    }
    
    /// 切换写入特征值配置
    public func onChangeBLEWriteInfo(uuid: String, typeName: String, status: Bool) {
        bleManager.onChangeBLEWriteInfo(uuid: uuid, typeName: typeName, status: status)
    }
    
    /// 切换通知/指示订阅配置
    public func onChangeBLEDescriptorInfo(uuid: String, typeName: String, status: Bool) {
        bleManager.onChangeBLEDescriptorInfo(uuid: uuid, typeName: typeName, status: status)
    }
    
    /// 释放资源
    public func release() {
        bleManager.release()
    }
}
