//
//  Error.swift
//  OBDUpdater
//
//  Created by myrc on 2025/7/2.
//

import Foundation

enum ConnectError: Error, LocalizedError {
    case invalidName
    case connectionTimeout
    case connecting
    case btUnEnable
    case noCompatibleDevices
    case sendTimeout
    case receiveTimeout
    case connectionFailed(Error?)
    case sendFailed(Error?)
    case receiveFailed(Error?)
    case invalidData
    case notConnected
    case unknown
    
    var errorDescription: String? {
        switch self {
        case .invalidName: return "参数错误"
        case .connectionTimeout: return "连接超时"
        case .connecting: return "正在连接中"
        case .btUnEnable: return "蓝牙当前不可用"
        case .noCompatibleDevices: return "无符合条件的设备"
        case .sendTimeout: return "发送超时"
        case .receiveTimeout: return "接收超时"
        case .connectionFailed(let error): return "连接失败: \(error?.localizedDescription ?? "未知错误")"
        case .sendFailed(let error): return "发送失败: \(error?.localizedDescription ?? "未知错误")"
        case .receiveFailed(let error): return "接收失败: \(error?.localizedDescription ?? "未知错误")"
        case .invalidData: return "无效数据"
        case .notConnected: return "未连接到设备"
        case .unknown: return "未知错误"
        }
    }
}

enum State {
    case disconnected
    case connecting
    case connected
}
