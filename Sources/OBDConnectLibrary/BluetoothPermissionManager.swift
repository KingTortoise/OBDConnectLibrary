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
public class BluetoothPermissionManager: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    static let shared = BluetoothPermissionManager()
    private var centralManager: CBCentralManager?
    private var permissonCallback: BluetoothPermissionCallback?
    
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
        case .unauthorized, .unknown:
            permissonCallback = callback
            triggerPermissionRequest()
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
            /// iOS 12及以下 BLE 默认返回 .allowedAlways
            /// 所以这里只需要判断 传统蓝牙权限
            let accessoryManager = EAAccessoryManager.shared()
            let connectedAccessories = accessoryManager.connectedAccessories
            // 已有连接，说明已授权
            if !connectedAccessories.isEmpty {
                return .poweredOn
            }
            return .unauthorized
        }
    }
    
    public func triggerPermissionRequest() {
        // 初始化或重新初始化 CBCentralManager 触发权限请求
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: .main)
        }
    }
    
    public func notifyCallbacks(status: CBManagerState) {
        DispatchQueue.main.async {
            if let callback = self.permissonCallback {
                callback(status)
            }
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let status = checkPermission()
        notifyCallbacks(status: status)
    }
}
