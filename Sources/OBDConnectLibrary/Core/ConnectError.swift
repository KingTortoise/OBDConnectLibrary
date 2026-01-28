//
//  ConnectError.swift
//  OBDConnectLibrary
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//
//  对应 Android: ErrorCode.kt
//

import Foundation

// MARK: - ConnectError

/// 连接库错误类型
///
/// 定义了蓝牙/TCP 连接过程中可能发生的各类错误。
/// 每种错误都有对应的本地化描述信息。
///
/// - Note: 对应 Kotlin 的 `sealed class ConnectError`
public enum ConnectError: LocalizedError {
    
    /// 蓝牙不可用（未开启或设备不支持）
    case bluetoothUnavailable
    
    /// 无效的输入参数（如设备名称为空）
    case invalidName
    
    /// 连接超时
    case connectionTimeout
    
    /// 正在连接中（重复连接时抛出）
    case connecting
    
    /// 未找到匹配的设备
    case noCompatibleDevices
    
    /// 发送数据超时
    case sendTimeout
    
    /// 接收数据超时
    case receiveTimeout
    
    /// 扫描失败
    /// - Parameter underlyingError: 底层错误信息
    case scanFailed(underlyingError: Error?)
    
    /// 连接失败
    /// - Parameter underlyingError: 底层错误信息
    case connectionFailed(underlyingError: Error?)
    
    /// 发送失败
    /// - Parameter underlyingError: 底层错误信息
    case sendFailed(underlyingError: Error?)
    
    /// 接收失败
    /// - Parameter underlyingError: 底层错误信息
    case receiveFailed(underlyingError: Error?)
    
    /// 无效数据
    case invalidData
    
    /// 未连接到设备
    case notConnected
    
    /// 未知错误
    case unknown
    
    // MARK: - LocalizedError
    
    /// 错误描述（用于用户展示）
    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            return "Bluetooth is currently unavailable"
        case .invalidName:
            return "Invalid input parameter"
        case .connectionTimeout:
            return "Connection timeout"
        case .connecting:
            return "Connecting"
        case .noCompatibleDevices:
            return "No matching devices"
        case .sendTimeout:
            return "Send timeout"
        case .receiveTimeout:
            return "Receive timeout"
        case .scanFailed(let error):
            return "Scan failed: \(error?.localizedDescription ?? "unknown error")"
        case .connectionFailed(let error):
            return "Connection failed: \(error?.localizedDescription ?? "unknown error")"
        case .sendFailed(let error):
            return "Send failed: \(error?.localizedDescription ?? "unknown error")"
        case .receiveFailed(let error):
            return "Receive failed: \(error?.localizedDescription ?? "unknown error")"
        case .invalidData:
            return "Invalid Data"
        case .notConnected:
            return "Not connected to device"
        case .unknown:
            return "Unknown error"
        }
    }
}

// MARK: - ConnectState

/// 连接状态枚举
///
/// 表示当前连接的状态，用于状态机管理。
///
/// - Note: 对应 Kotlin 的 `enum class State`
public enum ConnectState {
    
    /// 已断开连接
    case disconnected
    
    /// 正在连接中
    case connecting
    
    /// 已连接
    case connected
}
