//
//  BLEManager+Connection.swift
//  OBDConnectLibrary
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//
//  对应 Android: BleManage.kt (RSSI监控、断开、重连部分)
//

import Foundation
import CoreBluetooth

// MARK: - RSSI Monitoring

extension BLEManager {
    
    /// 启动 RSSI 信号强度实时监控
    internal func startRssiMonitoring(interval: TimeInterval = 2.0) {
        stopRssiMonitoring()
        
        DispatchQueue.main.async { [weak self] in
            self?.rssiTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.readRssiWithStatusTracking()
            }
        }
    }
    
    /// 带状态跟踪的 RSSI 读取
    private func readRssiWithStatusTracking() {
        guard isConnected else { return }
        
        if isDataSending {
            logD("\(TAG): Data sending in progress, canceling RSSI read")
            return
        }
        
        if isRssiReading {
            if let startTime = rssiReadStartTime,
               Date().timeIntervalSince(startTime) > RSSI_READ_TIMEOUT {
                logW("\(TAG): RSSI read wait timeout, resetting status")
                isRssiReading = false
            } else {
                return
            }
        }
        
        isRssiReading = true
        rssiReadStartTime = Date()
        connectedPeripheral?.readRSSI()
        logD("\(TAG): RSSI read request sent")
    }
    
    /// 等待 RSSI 读取完成
    internal func waitForRssiReadComplete(completion: @escaping () -> Void) {
        if !isRssiReading {
            logD("\(TAG): RSSI read not in progress, proceeding with send")
            completion()
            return
        }
        
        logD("\(TAG): Waiting for RSSI read to complete before sending data...")
        let waitStart = Date()
        
        func checkRssi() {
            if !self.isRssiReading {
                let waitTime = Date().timeIntervalSince(waitStart) * 1000
                logD("\(self.TAG): RSSI read completed, waited \(Int(waitTime))ms")
                completion()
            } else if Date().timeIntervalSince(waitStart) > self.RSSI_READ_TIMEOUT {
                logW("\(self.TAG): RSSI read timeout, proceeding with send")
                self.isRssiReading = false
                completion()
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
                    checkRssi()
                }
            }
        }
        
        DispatchQueue.global().async {
            checkRssi()
        }
    }
    
    /// 停止 RSSI 监控
    internal func stopRssiMonitoring() {
        DispatchQueue.main.async { [weak self] in
            self?.rssiTimer?.invalidate()
            self?.rssiTimer = nil
        }
        isRssiReading = false
        isDataSending = false
        
        writingLock.lock()
        isWriting = false
        writingLock.unlock()
    }
}

// MARK: - Disconnect Methods

extension BLEManager {
    
    /// 断开 GATT 连接
    private func disconnectGatt() {
        guard let peripheral = connectedPeripheral else {
            logW("\(TAG): disconnect - peripheral not initialized")
            currentConnectState = .disconnected
            return
        }
        
        stopRssiMonitoring()
        centralManager?.cancelPeripheralConnection(peripheral)
        
        writeQueueLock.lock()
        writeQueueBuffer.removeAll()
        writeQueueLock.unlock()
    }
    
    /// 关闭 GATT 连接并释放资源
    internal func closeGatt() {
        closingLock.lock()
        if isClosing {
            closingLock.unlock()
            logD("\(TAG): close() already in progress, skipping")
            return
        }
        isClosing = true
        closingLock.unlock()
        
        defer {
            closingLock.lock()
            isClosing = false
            closingLock.unlock()
        }
        
        guard let peripheral = connectedPeripheral else { return }
        
        stopRssiMonitoring()
        centralManager?.cancelPeripheralConnection(peripheral)
        connectedPeripheral = nil
        readWriteCharacteristic = nil
        writeUUID = nil
        mtu = 185
    }
    
    /// 关闭连接通道
    @discardableResult
    public func closeChannel() -> Bool {
        closeGatt()
        currentConnectState = .disconnected
        return true
    }
    
    /// 释放所有资源
    public func release() {
        closeChannel()
        stopRssiMonitoring()
        characteristicReadCompletions.removeAll()
    }
}

// MARK: - Reconnect

extension BLEManager {
    
    /// 重新连接上次连接的设备
    public func reconnect(completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        if currentConnectState == .connected {
            completion(.success(true))
            return
        }
        if currentConnectState == .connecting {
            completion(.failure(.connecting))
            return
        }
        
        if !initBluetooth() {
            currentConnectState = .disconnected
            completion(.failure(.bluetoothUnavailable))
            return
        }
        
        if !isEnabled {
            currentConnectState = .disconnected
            completion(.failure(.connectionFailed(underlyingError: NSError(domain: "BLE", code: -1, userInfo: [NSLocalizedDescriptionKey: "Bluetooth off"]))))
            return
        }
        
        guard let address = addressForRequested else {
            currentConnectState = .disconnected
            completion(.failure(.connectionFailed(underlyingError: NSError(domain: "BLE", code: -1, userInfo: [NSLocalizedDescriptionKey: "No target address for reconnection"]))))
            return
        }
        
        connectDevice(identifier: address.uuidString, timeout: 30.0, completion: completion)
    }
}
