//
//  CharacteristicProperty.swift
//  OBDConnectLibrary
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//
//  对应 Android: CharacteristicProperty.kt
//

import Foundation
import CoreBluetooth

// MARK: - CharacteristicProperty

/// BLE 特征属性枚举类
///
/// 定义了常见的特征属性，可被外部类直接引用和使用。
///
/// - Note: 对应 Kotlin 的 `enum class CharacteristicProperty`
public enum CharacteristicProperty: Int, CaseIterable {
    
    /// 读属性：对应 PROPERTY_READ (0x02)
    case read = 0x02
    
    /// 写属性：对应 PROPERTY_WRITE (0x08)
    case write = 0x08
    
    /// 通知属性：对应 PROPERTY_NOTIFY (0x10)
    case notify = 0x10
    
    /// 指示属性：对应 PROPERTY_INDICATE (0x20)
    case indicate = 0x20
    
    /// 无响应写属性：对应 PROPERTY_WRITE_NO_RESPONSE (0x04)
    case writeWithoutResponse = 0x04
    
    // MARK: - Display Name
    
    /// 属性的显示名称（与传统字符串标识保持一致）
    public var displayName: String {
        switch self {
        case .read:
            return "READ"
        case .write:
            return "WRITE"
        case .notify:
            return "NOTIFY"
        case .indicate:
            return "INDICATE"
        case .writeWithoutResponse:
            return "WRITE_WITHOUT_RESPONSE"
        }
    }
    
    // MARK: - CoreBluetooth Mapping
    
    /// 对应的 CoreBluetooth 属性值
    public var cbCharacteristicProperties: CBCharacteristicProperties {
        switch self {
        case .read:
            return .read
        case .write:
            return .write
        case .notify:
            return .notify
        case .indicate:
            return .indicate
        case .writeWithoutResponse:
            return .writeWithoutResponse
        }
    }
    
    // MARK: - Static Methods
    
    /// 根据属性值获取对应的枚举列表
    ///
    /// 供外部类快速转换属性值为枚举集合。
    ///
    /// - Parameter properties: CBCharacteristicProperties 属性值
    /// - Returns: 包含所有匹配属性的枚举列表
    public static func fromPropertyValue(_ properties: CBCharacteristicProperties) -> [CharacteristicProperty] {
        return allCases.filter { property in
            // 通过位运算判断当前属性是否包含在目标属性值中
            properties.contains(property.cbCharacteristicProperties)
        }
    }
    
    /// 根据显示名称获取对应的枚举实例
    ///
    /// 供外部类通过字符串标识查找枚举（如从缓存中读取字符串后转换）。
    ///
    /// - Parameter name: 属性显示名称
    /// - Returns: 对应的枚举实例，未找到返回 nil
    public static func fromDisplayName(_ name: String) -> CharacteristicProperty? {
        return allCases.first { $0.displayName == name }
    }
    
    /// 将枚举列表转换为显示名称列表
    ///
    /// 供外部类需要展示属性名称时使用。
    ///
    /// - Parameter properties: 枚举列表
    /// - Returns: 显示名称列表
    public static func toDisplayNames(_ properties: [CharacteristicProperty]) -> [String] {
        return properties.map { $0.displayName }
    }
}
