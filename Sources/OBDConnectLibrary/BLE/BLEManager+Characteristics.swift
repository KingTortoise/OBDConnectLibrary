//
//  BLEManager+Characteristics.swift
//  OBDConnectLibrary
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//
//  对应 Android: BleManage.kt (特征值解析、设备信息读取部分)
//

import Foundation
import CoreBluetooth

// MARK: - Parse Characteristics

extension BLEManager {
    
    /// 解析 BLE 设备的所有服务、特征值的 UUID
    ///
    /// 优先级：
    /// 1. 分离的通知和写入特征值（不同 UUID）
    /// 2. 同时支持通知和写入的单一特征值
    /// 3. 仅通知或仅写入的特征值（不完整配置）
    internal func parseAllUUIDs(peripheral: CBPeripheral) {
        // 重置特征值引用
        readWriteCharacteristic = nil
        var notifyCharacteristic: CBCharacteristic?
        var writeCharacteristic: CBCharacteristic?
        var combinedCharacteristic: CBCharacteristic?
        
        // 1. 遍历所有服务和特征值，收集可用特征值
        peripheral.services?.forEach { service in
            service.characteristics?.forEach { characteristic in
                let properties = characteristic.properties
                logD("\(TAG): Checking characteristic: \(characteristic.uuid), properties: \(properties.rawValue)")
                
                // 检查特征值支持的操作
                let isNotifySupported = properties.contains(.notify) || properties.contains(.indicate)
                let isWriteSupported = properties.contains(.write) || properties.contains(.writeWithoutResponse)
                
                // 记录同时支持通知和写入的特征值（作为备选）
                if isNotifySupported && isWriteSupported {
                    logD("\(TAG): Found combined characteristic (notify+write): \(characteristic.uuid)")
                    combinedCharacteristic = characteristic
                }
                
                // 记录单独的通知特征值
                if isNotifySupported && !isWriteSupported && notifyCharacteristic == nil {
                    notifyCharacteristic = characteristic
                    logD("\(TAG): Found notify-only characteristic: \(characteristic.uuid)")
                }
                
                // 记录单独的写入特征值
                if isWriteSupported && !isNotifySupported && writeCharacteristic == nil {
                    writeCharacteristic = characteristic
                    logD("\(TAG): Found write-only characteristic: \(characteristic.uuid)")
                }
            }
        }
        
        // 2. 优先使用分离的通知和写入特征值（不同 UUID）
        if let notify = notifyCharacteristic, let write = writeCharacteristic {
            logD("\(TAG): Using separate characteristics - Notify: \(notify.uuid), Write: \(write.uuid)")
            
            notifyUUID = notify.uuid
            writeUUID = write.uuid
            
            // 开启通知
            enableCharacteristicNotification(peripheral: peripheral, characteristic: notify)
            
            // 设置写入特征值作为主要写入引用
            readWriteCharacteristic = write
            return
        }
        
        // 3. 若没有分离的特征值，再使用同时支持通知和写入的单一特征值
        if let combined = combinedCharacteristic {
            logD("\(TAG): Using combined characteristic: \(combined.uuid)")
            
            notifyUUID = combined.uuid
            writeUUID = combined.uuid
            
            // 开启通知
            enableCharacteristicNotification(peripheral: peripheral, characteristic: combined)
            
            // 设置为主要引用
            readWriteCharacteristic = combined
            return
        }
        
        // 4. 最后尝试使用仅通知或仅写入的特征值
        logW("\(TAG): No ideal characteristic configuration found")
        if let notify = notifyCharacteristic {
            notifyUUID = notify.uuid
            enableCharacteristicNotification(peripheral: peripheral, characteristic: notify)
            readWriteCharacteristic = notify
            logW("\(TAG): Fallback to notify-only characteristic: \(notify.uuid)")
        } else if let write = writeCharacteristic {
            writeUUID = write.uuid
            readWriteCharacteristic = write
            logW("\(TAG): Fallback to write-only characteristic: \(write.uuid)")
        } else {
            logE("\(TAG): No usable characteristics found!")
        }
    }
    
    /// 开启特征值的通知/指示功能
    ///
    /// - Parameters:
    ///   - peripheral: 蓝牙外设
    ///   - characteristic: 目标特征值
    /// - Returns: 是否成功开启通知
    @discardableResult
    private func enableCharacteristicNotification(peripheral: CBPeripheral, characteristic: CBCharacteristic) -> Bool {
        // 调用系统 API 开启通知
        peripheral.setNotifyValue(true, for: characteristic)
        
        // 确定订阅类型
        let subscriptionType: String
        if characteristic.properties.contains(.notify) {
            subscriptionType = "NOTIFY"
        } else {
            subscriptionType = "INDICATE"
        }
        
        // 添加到订阅缓存
        subscriptionCaches.append(SubscriptionCache(characteristic: characteristic, subscriptionType: subscriptionType))
        
        logD("\(TAG): Notification is enabled successfully (Characteristic UUID: \(characteristic.uuid))")
        return true
    }
}

// MARK: - Device Info

extension BLEManager {
    
    /// 获取 BLE 设备信息
    ///
    /// - Parameter completion: 完成回调，返回设备信息
    public func getBLEDeviceInfo(completion: @escaping @Sendable (BLEDeviceInfo) -> Void) {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else {
                completion(BLEDeviceInfo(broadcastData: nil, deviceInfo: nil, serviceInfo: []))
                return
            }
            
            // 解析广播数据
            if self.broadcastData == nil, let address = self.addressForRequested {
                self.scanLock.lock()
                if let advertisementData = self.scanResultCache[address] {
                    self.parseScanRecord(advertisementData)
                }
                self.scanLock.unlock()
            }
            
            // 读取设备信息服务
            if self.deviceInfo == nil, let peripheral = self.connectedPeripheral {
                if let deviceInfoService = peripheral.services?.first(where: { $0.uuid == self.DEVICE_INFO_SERVICE_UUID }) {
                    self.readDeviceInfoFeatures(peripheral: peripheral, service: deviceInfoService) { [weak self] in
                        guard let self = self else { return }
                        self.buildServiceList()
                        let info = BLEDeviceInfo(
                            broadcastData: self.broadcastData,
                            deviceInfo: self.deviceInfo,
                            serviceInfo: self.serviceList
                        )
                        DispatchQueue.main.async {
                            completion(info)
                        }
                    }
                    return
                }
            }
            
            self.buildServiceList()
            let info = BLEDeviceInfo(
                broadcastData: self.broadcastData,
                deviceInfo: self.deviceInfo,
                serviceInfo: self.serviceList
            )
            DispatchQueue.main.async {
                completion(info)
            }
        }
    }
    
    /// 解析 BLE 广播数据
    private func parseScanRecord(_ advertisementData: [String: Any]) {
        let deviceName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown"
        let txPowerLevel = advertisementData[CBAdvertisementDataTxPowerLevelKey] as? Int
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        
        var manufacturerData: [Int: Data] = [:]
        if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfgData.count >= 2 {
            let companyId = Int(mfgData[0]) | (Int(mfgData[1]) << 8)
            manufacturerData[companyId] = mfgData.subdata(in: 2..<mfgData.count)
        }
        
        broadcastData = BroadcastData(
            rawData: nil,
            deviceName: deviceName,
            txPowerLevel: txPowerLevel,
            serviceUUIDs: serviceUUIDs,
            manufacturerData: manufacturerData,
            flags: nil
        )
    }
    
    /// 读取设备信息服务中的所有特征
    private func readDeviceInfoFeatures(peripheral: CBPeripheral, service: CBService, completion: @escaping () -> Void) {
        let characteristicUUIDs = [
            MANUFACTURER_NAME_UUID,
            MODEL_NUMBER_UUID,
            SERIAL_NUMBER_UUID,
            HARDWARE_REVISION_UUID,
            FIRMWARE_REVISION_UUID,
            SOFTWARE_REVISION_UUID,
            SYSTEM_UUID,
            IEEE_UUID,
            PNP_UUID
        ]
        
        var results: [CBUUID: String?] = [:]
        let group = DispatchGroup()
        
        for uuid in characteristicUUIDs {
            if let characteristic = service.characteristics?.first(where: { $0.uuid == uuid }) {
                group.enter()
                readCharacteristic(peripheral: peripheral, characteristic: characteristic) { data in
                    if let data = data {
                        if uuid == self.SYSTEM_UUID || uuid == self.IEEE_UUID || uuid == self.PNP_UUID {
                            results[uuid] = data.map { String(format: "%02X", $0) }.joined(separator: ":")
                        } else {
                            results[uuid] = String(data: data, encoding: .utf8)
                        }
                    }
                    group.leave()
                }
            }
        }
        
        group.notify(queue: .global()) { [weak self] in
            guard let self = self else {
                completion()
                return
            }
            
            self.deviceInfo = DeviceInfo(
                manufacturerName: results[self.MANUFACTURER_NAME_UUID] ?? nil,
                modelNumber: results[self.MODEL_NUMBER_UUID] ?? nil,
                serialNumber: results[self.SERIAL_NUMBER_UUID] ?? nil,
                hardwareRevision: results[self.HARDWARE_REVISION_UUID] ?? nil,
                firmwareRevision: results[self.FIRMWARE_REVISION_UUID] ?? nil,
                softwareRevision: results[self.SOFTWARE_REVISION_UUID] ?? nil,
                systemId: results[self.SYSTEM_UUID] ?? nil,
                ieeeId: results[self.IEEE_UUID] ?? nil,
                pnpId: results[self.PNP_UUID] ?? nil
            )
            completion()
        }
    }
    
    /// 读取单个特征值
    private func readCharacteristic(peripheral: CBPeripheral, characteristic: CBCharacteristic, completion: @escaping (Data?) -> Void) {
        let uuid = characteristic.uuid.uuidString
        characteristicReadCompletions[uuid] = completion
        peripheral.readValue(for: characteristic)
        
        // 超时处理
        DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) { [weak self] in
            if let pendingCompletion = self?.characteristicReadCompletions[uuid] {
                self?.characteristicReadCompletions.removeValue(forKey: uuid)
                pendingCompletion(nil)
            }
        }
    }
    
    /// 构建服务列表
    private func buildServiceList() {
        serviceList.removeAll()
        
        guard let peripheral = connectedPeripheral else { return }
        
        peripheral.services?.forEach { service in
            let hasMultiPropertyCharacteristic = service.characteristics?.contains { characteristic in
                countProperties(characteristic.properties) > 1
            } ?? false
            
            if hasMultiPropertyCharacteristic {
                serviceList.append(mapServiceToDto(service))
            }
        }
    }
    
    /// 将服务转换为数据传输对象
    private func mapServiceToDto(_ service: CBService) -> BLEServiceDto {
        let characteristics = service.characteristics?.map { characteristic -> BLECharacteristicDto in
            let propertyStatus = checkEachPropertyStatus(characteristic: characteristic)
            return BLECharacteristicDto(
                characteristicUUID: characteristic.uuid.uuidString,
                properties: mapProperties(characteristic.properties),
                value: characteristic.value?.map { String(format: "%02X", $0) }.joined(separator: ":"),
                propertyStatus: propertyStatus
            )
        } ?? []
        
        return BLEServiceDto(serviceUUID: service.uuid.uuidString, characteristics: characteristics)
    }
    
    /// 检查特征的每个属性是否被订阅/活跃
    private func checkEachPropertyStatus(characteristic: CBCharacteristic) -> [String: Bool] {
        var propertyStatus: [String: Bool] = [:]
        
        // 1. 检查 READ 属性
        if characteristic.properties.contains(.read) {
            propertyStatus["READ"] = true
        }
        
        // 2. NOTIFY 属性
        if characteristic.properties.contains(.notify) {
            let isSubscribed = subscriptionCaches.contains { cache in
                cache.characteristic.uuid == characteristic.uuid &&
                cache.subscriptionType == "NOTIFY"
            }
            propertyStatus["NOTIFY"] = isSubscribed
        }
        
        // 3. INDICATE 属性
        if characteristic.properties.contains(.indicate) {
            let isSubscribed = subscriptionCaches.contains { cache in
                cache.characteristic.uuid == characteristic.uuid &&
                cache.subscriptionType == "INDICATE"
            }
            propertyStatus["INDICATE"] = isSubscribed
        }
        
        // 4. WRITE 属性
        if characteristic.properties.contains(.write) {
            let isActive = readWriteCharacteristic?.uuid == characteristic.uuid &&
                           writeType == .withResponse
            propertyStatus["WRITE"] = isActive
        }
        
        // 5. WRITE_WITHOUT_RESPONSE 属性
        if characteristic.properties.contains(.writeWithoutResponse) {
            let isActive = readWriteCharacteristic?.uuid == characteristic.uuid &&
                           writeType == .withoutResponse
            propertyStatus["WRITE_WITHOUT_RESPONSE"] = isActive
        }
        
        return propertyStatus
    }
    
    /// 转换特征属性为可读字符串
    private func mapProperties(_ properties: CBCharacteristicProperties) -> [String] {
        var result: [String] = []
        if properties.contains(.read) {
            result.append(CharacteristicProperty.read.displayName)
        }
        if properties.contains(.write) {
            result.append(CharacteristicProperty.write.displayName)
        }
        if properties.contains(.notify) {
            result.append(CharacteristicProperty.notify.displayName)
        }
        if properties.contains(.indicate) {
            result.append(CharacteristicProperty.indicate.displayName)
        }
        if properties.contains(.writeWithoutResponse) {
            result.append(CharacteristicProperty.writeWithoutResponse.displayName)
        }
        return result
    }
    
    /// 计算特征属性的数量
    private func countProperties(_ properties: CBCharacteristicProperties) -> Int {
        var count = 0
        if properties.contains(.read) { count += 1 }
        if properties.contains(.write) { count += 1 }
        if properties.contains(.notify) { count += 1 }
        if properties.contains(.indicate) { count += 1 }
        if properties.contains(.writeWithoutResponse) { count += 1 }
        return count
    }
}
