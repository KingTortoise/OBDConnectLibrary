//
//  BLEModels.swift
//  OBDConnectLibrary
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//
//  对应 Android: BleModels.kt + BluetoothDeviceWithRssi.kt
//

import Foundation
import CoreBluetooth

// MARK: - BLEDeviceWithRssi

/// 包含蓝牙设备和信号强度信息的数据类
///
/// - Note: 对应 Kotlin 的 `data class BluetoothDeviceWithRssi`
public struct BLEDeviceWithRssi: Hashable, Comparable {
    
    /// 蓝牙外设对象
    public let peripheral: CBPeripheral
    
    /// 信号强度 (RSSI)
    public var rssi: Int
    
    /// 设备名称（便捷访问）
    public var name: String? {
        return peripheral.name
    }
    
    /// 设备标识符（便捷访问）
    public var identifier: UUID {
        return peripheral.identifier
    }
    
    /// 初始化
    ///
    /// - Parameters:
    ///   - peripheral: CBPeripheral 对象
    ///   - rssi: 信号强度
    public init(peripheral: CBPeripheral, rssi: Int) {
        self.peripheral = peripheral
        self.rssi = rssi
    }
    
    // MARK: - Hashable
    
    /// 仅使用 identifier 进行哈希
    public func hash(into hasher: inout Hasher) {
        hasher.combine(peripheral.identifier)
    }
    
    public static func == (lhs: BLEDeviceWithRssi, rhs: BLEDeviceWithRssi) -> Bool {
        return lhs.peripheral.identifier == rhs.peripheral.identifier
    }
    
    // MARK: - Comparable
    
    /// 按信号强度降序排列（信号越强排在前面）
    public static func < (lhs: BLEDeviceWithRssi, rhs: BLEDeviceWithRssi) -> Bool {
        return rhs.rssi < lhs.rssi
    }
}

// MARK: - BLEDeviceInfo

/// BLE 设备完整信息
///
/// - Note: 对应 Kotlin 的 `data class BleDeviceInfo`
public struct BLEDeviceInfo: Sendable {
    
    /// 广播数据（可能为 nil）
    public let broadcastData: BroadcastData?
    
    /// 设备信息服务数据（可能为 nil）
    public let deviceInfo: DeviceInfo?
    
    /// 服务和特征值列表
    public let serviceInfo: [BLEServiceDto]
    
    /// 初始化
    ///
    /// - Parameters:
    ///   - broadcastData: 广播数据
    ///   - deviceInfo: 设备信息
    ///   - serviceInfo: 服务列表
    public init(broadcastData: BroadcastData?, deviceInfo: DeviceInfo?, serviceInfo: [BLEServiceDto]) {
        self.broadcastData = broadcastData
        self.deviceInfo = deviceInfo
        self.serviceInfo = serviceInfo
    }
}

// MARK: - BroadcastData

/// BLE 广播数据
///
/// - Note: 对应 Kotlin 的 `data class BroadcastData`
public struct BroadcastData: Equatable, @unchecked Sendable {
    
    /// 原始广播字节数组
    public let rawData: Data?
    
    /// 设备名称
    public let deviceName: String
    
    /// 发射功率等级
    public let txPowerLevel: Int?
    
    /// 广播的服务 UUID 列表
    public let serviceUUIDs: [CBUUID]
    
    /// 厂商自定义数据
    /// - Note: iOS 使用 Dictionary 替代 Android 的 SparseArray
    public let manufacturerData: [Int: Data]
    
    /// 广播标志位
    public let flags: Int?
    
    /// 初始化
    ///
    /// - Parameters:
    ///   - rawData: 原始广播数据
    ///   - deviceName: 设备名称
    ///   - txPowerLevel: 发射功率
    ///   - serviceUUIDs: 服务 UUID 列表
    ///   - manufacturerData: 厂商数据
    ///   - flags: 广播标志位
    public init(
        rawData: Data?,
        deviceName: String,
        txPowerLevel: Int?,
        serviceUUIDs: [CBUUID],
        manufacturerData: [Int: Data],
        flags: Int?
    ) {
        self.rawData = rawData
        self.deviceName = deviceName
        self.txPowerLevel = txPowerLevel
        self.serviceUUIDs = serviceUUIDs
        self.manufacturerData = manufacturerData
        self.flags = flags
    }
    
    // MARK: - Equatable
    
    public static func == (lhs: BroadcastData, rhs: BroadcastData) -> Bool {
        return lhs.rawData == rhs.rawData &&
               lhs.deviceName == rhs.deviceName &&
               lhs.txPowerLevel == rhs.txPowerLevel &&
               lhs.serviceUUIDs == rhs.serviceUUIDs &&
               lhs.flags == rhs.flags
    }
}

// MARK: - DeviceInfo

/// BLE 设备信息服务数据（0x180A）
///
/// - Note: 对应 Kotlin 的 `data class DeviceInfo`
public struct DeviceInfo: Sendable {
    
    /// 制造商名称
    public let manufacturerName: String?
    
    /// 型号
    public let modelNumber: String?
    
    /// 序列号
    public let serialNumber: String?
    
    /// 硬件版本
    public let hardwareRevision: String?
    
    /// 固件版本
    public let firmwareRevision: String?
    
    /// 软件版本
    public let softwareRevision: String?
    
    /// 系统 ID
    public let systemId: String?
    
    /// IEEE 认证 ID
    public let ieeeId: String?
    
    /// PnP ID
    public let pnpId: String?
    
    /// 初始化
    ///
    /// - Parameters:
    ///   - manufacturerName: 制造商名称
    ///   - modelNumber: 型号
    ///   - serialNumber: 序列号
    ///   - hardwareRevision: 硬件版本
    ///   - firmwareRevision: 固件版本
    ///   - softwareRevision: 软件版本
    ///   - systemId: 系统 ID
    ///   - ieeeId: IEEE ID
    ///   - pnpId: PnP ID
    public init(
        manufacturerName: String?,
        modelNumber: String?,
        serialNumber: String?,
        hardwareRevision: String?,
        firmwareRevision: String?,
        softwareRevision: String?,
        systemId: String?,
        ieeeId: String?,
        pnpId: String?
    ) {
        self.manufacturerName = manufacturerName
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.hardwareRevision = hardwareRevision
        self.firmwareRevision = firmwareRevision
        self.softwareRevision = softwareRevision
        self.systemId = systemId
        self.ieeeId = ieeeId
        self.pnpId = pnpId
    }
}

// MARK: - BLEServiceDto

/// BLE 服务 DTO
///
/// - Note: 对应 Kotlin 的 `data class BleServiceDto`
public struct BLEServiceDto: Sendable {
    
    /// 服务 UUID
    public let serviceUUID: String
    
    /// 该服务下的特征值列表
    public let characteristics: [BLECharacteristicDto]
    
    /// 初始化
    ///
    /// - Parameters:
    ///   - serviceUUID: 服务 UUID
    ///   - characteristics: 特征值列表
    public init(serviceUUID: String, characteristics: [BLECharacteristicDto]) {
        self.serviceUUID = serviceUUID
        self.characteristics = characteristics
    }
}

// MARK: - BLECharacteristicDto

/// BLE 特征值 DTO
///
/// - Note: 对应 Kotlin 的 `data class BleCharacteristicDto`
public struct BLECharacteristicDto: Sendable {
    
    /// 特征值 UUID
    public let characteristicUUID: String
    
    /// 支持的属性列表（如 "READ", "WRITE", "NOTIFY"）
    public let properties: [String]
    
    /// 当前值（十六进制字符串）
    public let value: String?
    
    /// 各属性的启用状态
    public let propertyStatus: [String: Bool]
    
    /// 初始化
    ///
    /// - Parameters:
    ///   - characteristicUUID: 特征值 UUID
    ///   - properties: 属性列表
    ///   - value: 当前值
    ///   - propertyStatus: 属性状态
    public init(
        characteristicUUID: String,
        properties: [String],
        value: String?,
        propertyStatus: [String: Bool]
    ) {
        self.characteristicUUID = characteristicUUID
        self.properties = properties
        self.value = value
        self.propertyStatus = propertyStatus
    }
}

// MARK: - SubscriptionCache

/// 订阅状态缓存
///
/// - Note: 对应 Kotlin 的 `data class SubscriptionCache`
internal struct SubscriptionCache {
    
    /// 已订阅的特征值对象
    let characteristic: CBCharacteristic
    
    /// 订阅类型（"NOTIFY" 或 "INDICATE"）
    let subscriptionType: String
    
    /// 初始化
    ///
    /// - Parameters:
    ///   - characteristic: 特征值对象
    ///   - subscriptionType: 订阅类型
    init(characteristic: CBCharacteristic, subscriptionType: String) {
        self.characteristic = characteristic
        self.subscriptionType = subscriptionType
    }
}
