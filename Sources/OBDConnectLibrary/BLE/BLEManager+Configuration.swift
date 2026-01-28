//
//  BLEManager+Configuration.swift
//  OBDConnectLibrary
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//
//  对应 Android: BleManage.kt (配置变更方法部分)
//

import Foundation
import CoreBluetooth

// MARK: - Configuration Changes

extension BLEManager {
    
    /// 切换写入特征值配置
    ///
    /// 当用户在 UI 上选择不同的写入特征值时调用。
    /// 更新 writeType 和 readWriteCharacteristic。
    ///
    /// - Parameters:
    ///   - uuid: 特征值 UUID 字符串
    ///   - typeName: 写入类型名称（"WRITE" 或 "WRITE_WITHOUT_RESPONSE"）
    ///   - status: true=启用该特征值, false=禁用
    public func onChangeBLEWriteInfo(uuid: String, typeName: String, status: Bool) {
        // 确定写入类型
        switch typeName {
        case CharacteristicProperty.write.displayName:
            writeType = .withResponse
        case CharacteristicProperty.writeWithoutResponse.displayName:
            writeType = .withoutResponse
        default:
            break
        }
        
        guard let peripheral = connectedPeripheral else { return }
        
        if status {
            // 查找该特征
            var foundCharacteristic: CBCharacteristic?
            peripheral.services?.forEach { service in
                if let char = service.characteristics?.first(where: { $0.uuid.uuidString == uuid }) {
                    foundCharacteristic = char
                }
            }
            
            if let characteristic = foundCharacteristic {
                readWriteCharacteristic = characteristic
                writeUUID = characteristic.uuid
                
                // 在同一 Service 下查找已订阅的 Notify/Indicate 特征值
                if let writeService = peripheral.services?.first(where: { service in
                    service.characteristics?.contains(where: { $0.uuid == characteristic.uuid }) ?? false
                }) {
                    let matchingNotifyInCache = subscriptionCaches.first { cache in
                        writeService.characteristics?.contains(where: { $0.uuid == cache.characteristic.uuid }) ?? false
                    }
                    if let matchingCache = matchingNotifyInCache {
                        notifyUUID = matchingCache.characteristic.uuid
                        logD("\(TAG): onChangeBLEWriteInfo: found notify in same service, set notifyUUID to \(notifyUUID?.uuidString ?? "nil")")
                    }
                }
            }
        } else {
            readWriteCharacteristic = nil
            writeUUID = nil
        }
    }
    
    /// 切换通知/指示订阅配置
    ///
    /// 当用户在 UI 上选择开启或关闭特征值通知时调用。
    ///
    /// - Parameters:
    ///   - uuid: 特征值 UUID 字符串
    ///   - typeName: 订阅类型（"NOTIFY" 或 "INDICATE"）
    ///   - status: true=开启订阅, false=取消订阅
    public func onChangeBLEDescriptorInfo(uuid: String, typeName: String, status: Bool) {
        guard let peripheral = connectedPeripheral else {
            logW("\(TAG): onChangeBLEDescriptorInfo: peripheral is null")
            return
        }
        
        if status {
            // 查找该特征
            var foundCharacteristic: CBCharacteristic?
            peripheral.services?.forEach { service in
                if let char = service.characteristics?.first(where: { $0.uuid.uuidString == uuid }) {
                    foundCharacteristic = char
                }
            }
            
            guard let characteristic = foundCharacteristic else {
                logE("\(TAG): onChangeBLEDescriptorInfo: characteristic not found for uuid \(uuid)")
                return
            }
            
            // 开启通知
            peripheral.setNotifyValue(true, for: characteristic)
            
            // 更新 notifyUUID（如果当前写入特征值匹配）
            if characteristic.uuid == readWriteCharacteristic?.uuid {
                notifyUUID = characteristic.uuid
            }
            
            // 更新订阅缓存
            subscriptionCaches.removeAll { $0.characteristic.uuid.uuidString == uuid }
            subscriptionCaches.append(SubscriptionCache(characteristic: characteristic, subscriptionType: typeName))
            
            logD("\(TAG): onChangeBLEDescriptorInfo: enabled \(typeName) for \(uuid)")
        } else {
            clearExistingSubscription(uuid: uuid)
        }
    }
    
    /// 清除现有订阅
    ///
    /// 取消指定特征值的通知/指示订阅。
    ///
    /// - Parameter uuid: 要取消订阅的特征值 UUID 字符串
    private func clearExistingSubscription(uuid: String) {
        guard let peripheral = connectedPeripheral else {
            logW("\(TAG): clearExistingSubscription: peripheral is null")
            return
        }
        
        // 查找该特征
        var foundCharacteristic: CBCharacteristic?
        peripheral.services?.forEach { service in
            if let char = service.characteristics?.first(where: { $0.uuid.uuidString == uuid }) {
                foundCharacteristic = char
            }
        }
        
        guard let characteristic = foundCharacteristic else { return }
        
        // 关闭通知
        peripheral.setNotifyValue(false, for: characteristic)
        
        // 从订阅缓存中移除
        subscriptionCaches.removeAll { $0.characteristic.uuid.uuidString == uuid }
        notifyUUID = nil
        
        logD("\(TAG): clearExistingSubscription: disabled notifications for \(uuid)")
    }
}
