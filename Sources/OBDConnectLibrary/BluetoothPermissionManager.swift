//
//  BluetoothPermissionManager.swift
//  OBDUpdater
//
//  Created by 金文武 on 2025/6/29.
//

import Foundation
import CoreBluetooth
import ExternalAccessory

/// 蓝牙权限类型
public enum BluetoothPermissionType {
    case ble                // 低功耗蓝牙
    case classic            // 传统蓝牙
}

/// 蓝牙权限状态
public enum BluetoothPermissionStatus {
    case authorized         // 已授权
    case denied             // 已拒绝
    case restricted         // 受限制
    case notDetermined      // 未决定
    case unsupported        // 不支持
    case poweredOff         // 蓝牙已关闭
    case resetting          // 去设置重置
}

/// 权限变更回调
public typealias BluetoothPermissionCallback = (CBManagerState) -> Void

/// 蓝牙权限管理类
@objcMembers
public class BluetoothPermissionManager: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    public static let shared = BluetoothPermissionManager()
    public var centralManager: CBCentralManager?
    public var permissonCallback: BluetoothPermissionCallback?
    
    public override init() {
        super.init()
        setupManagers()
    }
    
    public func setupManagers() {
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }
    
    public func checkAndRequestPermission(callback: @escaping BluetoothPermissionCallback){
        let status = checkPermission()
        switch status {
        case .unknown:
            // iOS 12: 状态未知，等待 centralManagerDidUpdateState 回调
            // iOS 13+: 等待权限弹窗或状态更新
            permissonCallback = callback
            triggerPermissionRequest()
        case .unauthorized:
            // iOS 12: 没有权限弹窗，直接返回状态让调用方处理（显示 Alert 引导用户去设置）
            // iOS 13+: 用户拒绝了权限，直接返回状态
            callback(status)
        default:
            callback(status)
        }
    }
    
    
    public func checkPermission() -> CBManagerState {
        /// 从 iOS 13 开始，传统蓝牙和 BLE 的权限状态统一通过CBManager.authorization获取
        if #available(iOS 13.1, *) {
            if let central = centralManager {
                return central.state
            } else {
                return .unknown
            }
        } else {
            /// iOS 12及以下：BLE 权限不需要用户授权，但需要检查 CBCentralManager 的实际状态
            /// 在 iOS 12 上，CBCentralManager.state 可以反映蓝牙的实际状态：
            /// - .poweredOn: 蓝牙已开启且可用
            /// - .poweredOff: 蓝牙已关闭
            /// - .unauthorized: 用户拒绝了权限（虽然 iOS 12 没有 BLE 权限弹窗，但可能通过其他方式拒绝）
            /// - .unsupported: 设备不支持蓝牙
            /// - .unknown: 状态未知，需要等待初始化完成
            /// - .resetting: 蓝牙正在重置
            if let central = centralManager {
                return central.state
            } else {
                // 如果 centralManager 未初始化，先初始化它
                setupManagers()
                return .unknown
            }
        }
    }
    
    public func triggerPermissionRequest() {
        // 初始化或重新初始化 CBCentralManager 触发权限请求
        // iOS 13+: 会触发权限弹窗
        // iOS 12: 不会触发权限弹窗，但会初始化 CBCentralManager 并等待状态更新
        if centralManager == nil {
            setupManagers()
        } else {
            // 如果已经初始化，重新初始化以触发状态更新
            centralManager = nil
            setupManagers()
        }
    }
    
    public func notifyCallbacks(status: CBManagerState) {
        DispatchQueue.main.async {
            if let callback = self.permissonCallback {
                callback(status)
            }
        }
    }

    @objc public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let status = checkPermission()
        notifyCallbacks(status: status)
    }
}
