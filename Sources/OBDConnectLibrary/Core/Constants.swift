//
//  Constants.swift
//  OBDConnectLibrary
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//
//  对应 Android: LocalUUID.kt
//

import Foundation

// MARK: - OBDConstants

/// OBD 连接库常量定义
///
/// 包含 BLE 服务和特征值的 UUID 常量。
/// 这些 UUID 用于识别和通信 OBD 设备。
///
/// - Note: 对应 Kotlin 的 `object LocalUUID`
public struct OBDConstants {
    
    // MARK: - BLE UUIDs
    
    /// BLE 服务 UUID（用于读写通信）
    ///
    /// 此 UUID 用于发现 OBD 设备提供的主要通信服务。
    public static let bleServiceReadWriteUUID: String = "e7810a71-73ae-499d-8c15-faa9aef0c3f2"
    
    /// BLE 特征值 UUID（用于读写通信）
    ///
    /// 此 UUID 用于在已连接的 BLE 服务中进行数据读写。
    public static let bleCharacteristicReadWriteUUID: String = "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"
    
    /// 经典蓝牙 SDP UUID
    ///
    /// 用于经典蓝牙（SPP）串口通信的标准 UUID。
    /// - Warning: iOS 不直接支持经典蓝牙，此常量仅供参考。
    public static let classicBluetoothSDPUUID: String = "00001101-0000-1000-8000-00805F9B34FB"
    
    // MARK: - Timeouts
    
    /// 默认连接超时时间（秒）
    public static let defaultConnectionTimeout: TimeInterval = 10.0
    
    /// 默认扫描超时时间（秒）
    public static let defaultScanTimeout: TimeInterval = 30.0
    
    /// 默认数据发送超时时间（秒）
    public static let defaultSendTimeout: TimeInterval = 5.0
    
    /// 默认数据接收超时时间（秒）
    public static let defaultReceiveTimeout: TimeInterval = 5.0
    
    // MARK: - RSSI
    
    /// RSSI 监控间隔（毫秒）
    public static let rssiMonitoringInterval: TimeInterval = 2.0
}
