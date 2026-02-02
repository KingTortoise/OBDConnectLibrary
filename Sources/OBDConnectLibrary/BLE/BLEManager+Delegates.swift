//
//  BLEManager+Delegates.swift
//  OBDConnectLibrary
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//
//  对应 Android: BleManage.kt (GATT 回调部分)
//

import Foundation
import CoreBluetooth

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    
    /// 蓝牙状态变化回调
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logD("\(TAG): centralManagerDidUpdateState: \(central.state.rawValue)")
        
        switch central.state {
        case .poweredOff:
            let wasConnected = currentConnectState == .connected
            currentConnectState = .disconnected
            
            DispatchQueue.main.async { [weak self] in
                self?.onBluetoothStateDisconnect?()
            }
            closeGatt()
            
        case .poweredOn:
            logD("\(TAG): Bluetooth is powered on")
            
        case .unauthorized:
            logE("\(TAG): Bluetooth unauthorized")
            
        case .unsupported:
            logE("\(TAG): Bluetooth unsupported")
            
        default:
            break
        }
    }
    
    /// 发现外设回调
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // iOS CoreBluetooth 在 RSSI 无效时返回 127，需要过滤
        // 对应 Android 中使用 -100 作为已配对但未扫描设备的默认 RSSI
        let rssiValue = RSSI.intValue == 127 ? -100 : RSSI.intValue
        let deviceWithRssi = BLEDeviceWithRssi(peripheral: peripheral, rssi: rssiValue)
        
        scanLock.lock()
        scanResultCache[peripheral.identifier] = advertisementData
        
        if let existingDevice = scannedDevicesWithRssi.first(where: { $0.peripheral.identifier == peripheral.identifier }) {
            if existingDevice.rssi != RSSI.intValue {
                scannedDevicesWithRssi.remove(existingDevice)
                scannedDevicesWithRssi.insert(deviceWithRssi)
            }
        } else {
            scannedDevicesWithRssi.insert(deviceWithRssi)
        }
        
        let currentDevices = scannedDevicesWithRssi
        scanLock.unlock()
        
        DispatchQueue.main.async { [weak self] in
            self?.onDeviceFound?(currentDevices)
        }
    }
    
    /// 连接成功回调
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logD("\(TAG): didConnect - \(peripheral.name ?? "Unknown")")
        currentConnectState = .connected
        addressForAccepted = addressForRequested
        peripheral.discoverServices(nil)
    }
    
    /// 连接失败回调
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logE("\(TAG): didFailToConnect - \(error?.localizedDescription ?? "Unknown error")")
        
        let wasConnected = currentConnectState == .connected
        currentConnectState = .disconnected
        
        let callback = connectionCompletion
        connectionCompletion = nil
        
        DispatchQueue.main.async { [weak self] in
            callback?(.failure(.connectionFailed(underlyingError: error)))
            if wasConnected { self?.onDeviceDisconnect?() }
        }
        
        closeGatt()
    }
    
    /// 断开连接回调
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logD("\(TAG): didDisconnectPeripheral - \(peripheral.name ?? "Unknown"), error: \(error?.localizedDescription ?? "none")")
        
        let wasConnected = currentConnectState == .connected
        currentConnectState = .disconnected
        
        if let callback = connectionCompletion {
            connectionCompletion = nil
            DispatchQueue.main.async {
                callback(.failure(.connectionFailed(underlyingError: error)))
            }
        }
        
        if wasConnected {
            DispatchQueue.main.async { [weak self] in
                self?.onDeviceDisconnect?()
            }
        }
        
        closeGatt()
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    
    /// 发现服务回调
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            logE("\(TAG): didDiscoverServices failed: \(error.localizedDescription)")
            currentConnectState = .disconnected
            
            let callback = connectionCompletion
            connectionCompletion = nil
            
            DispatchQueue.main.async { [weak self] in
                callback?(.failure(.connectionFailed(underlyingError: error)))
                self?.onDeviceDisconnect?()
            }
            closeGatt()
            return
        }
        
        logD("\(TAG): didDiscoverServices - found \(peripheral.services?.count ?? 0) services")
        
        peripheral.services?.forEach { service in
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    /// 发现特征值回调
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            logE("\(TAG): didDiscoverCharacteristics failed: \(error.localizedDescription)")
            return
        }
        
        logD("\(TAG): didDiscoverCharacteristics for service \(service.uuid) - found \(service.characteristics?.count ?? 0) characteristics")
        
        parseAllUUIDs(peripheral: peripheral)
        
        if readWriteCharacteristic != nil && mtu > 0 {
            logD("\(TAG): Service discovery completed, characteristic found")
            
            let callback = connectionCompletion
            connectionCompletion = nil
            
            startRssiMonitoring()
            
            DispatchQueue.main.async {
                callback?(.success(true))
            }
        }
    }
    
    /// 特征值读取回调
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid.uuidString
        
        if let completion = characteristicReadCompletions[uuid] {
            characteristicReadCompletions.removeValue(forKey: uuid)
            if error != nil {
                completion(nil)
            } else {
                completion(characteristic.value)
            }
            return
        }
        
        guard let value = characteristic.value, !value.isEmpty else { return }
        
        logD("\(TAG): onCharChange: \(String(data: value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? HexDump.toHexString(value))")
        
        if characteristic.uuid == notifyUUID {
            readQueueLock.lock()
            readQueueBuffer.append(contentsOf: value)
            logD("\(TAG): Added \(value.count) bytes to read queue (queue size now: \(readQueueBuffer.count))")
            readQueueLock.unlock()
        }
    }
    
    /// 特征值写入回调
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logE("\(TAG): didWriteValueFor failed: \(error.localizedDescription)")
            
            writeQueueLock.lock()
            writeQueueBuffer.removeAll()
            writeQueueLock.unlock()
            
            sendDataLock.lock()
            currentSendData = nil
            sendDataLock.unlock()
            
            let callback = writeCompletion
            writeCompletion = nil
            callback?(.failure(.sendFailed(underlyingError: error)))
            return
        }
        
        sendDataLock.lock()
        let actualData = currentSendData
        currentSendData = nil
        sendDataLock.unlock()
        
        if let data = actualData {
            logD("\(TAG): onCharWrite >>> \(peripheral.name ?? "Unknown") write \(characteristic.uuid) -> \(HexDump.toHexString(data))")
            
            writeQueueLock.lock()
            if data.count != writeQueueBuffer.count {
                logE("\(TAG): onCharWrite: data length mismatch, actual=\(data.count), queue=\(writeQueueBuffer.count)")
                writeQueueBuffer.removeAll()
                writeQueueLock.unlock()
                
                let callback = writeCompletion
                writeCompletion = nil
                callback?(.success(true))
                return
            }
            
            for (index, byte) in data.enumerated() {
                if index < writeQueueBuffer.count && byte != writeQueueBuffer[index] {
                    logE("\(TAG): onCharWrite DATA **ERROR** | index=\(index), actual=\(byte), queue=\(writeQueueBuffer[index])")
                }
            }
            writeQueueBuffer.removeAll()
            writeQueueLock.unlock()
        }
        
        let callback = writeCompletion
        writeCompletion = nil
        callback?(.success(true))
    }
    
    /// RSSI 读取回调
    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        isRssiReading = false
        
        if error == nil {
            DispatchQueue.main.async { [weak self] in
                self?.onHandleRssiUpdate?(RSSI.intValue)
            }
        }
    }
    
    /// 通知状态变更回调
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logE("\(TAG): didUpdateNotificationStateFor failed: \(error.localizedDescription)")
            return
        }
        
        let state = characteristic.isNotifying ? "enabled" : "disabled"
        logD("\(TAG): Notification \(state) for \(characteristic.uuid)")
    }
}
