//
//  BLEManager.swift
//  OBDConnectLibrary
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//
//  对应 Android: BleManage.kt
//
//  职责：
//  - 扫描 BLE 设备（包含 RSSI 信息）
//  - 连接/断开/重连设备
//  - 数据分片发送与接收
//  - 特征值通知订阅管理
//  - 设备信息读取
//  - 实时 RSSI 监控
//

import Foundation
import CoreBluetooth

// MARK: - BLEManager

/// BLE 蓝牙管理类
///
/// - Note: 对应 Kotlin 的 `class BleManage`
public class BLEManager: NSObject, @unchecked Sendable {
    
    // ==================================================================================
    // MARK: - 1. 常量定义
    // ==================================================================================
    
    internal let TAG = "BLEManager"
    
    /// RSSI 读取超时时间（秒）
    internal let RSSI_READ_TIMEOUT: TimeInterval = 3.0
    /// 数据接收超时时间（秒）
    internal let RECEIVE_TIMEOUT: TimeInterval = 10.0
    
    /// 将 CoreBluetooth 错误转换为用户友好的提示信息
    internal func getErrorMessage(_ error: Error?) -> String {
        guard let error = error else { return "Unknown error" }
        let nsError = error as NSError
        switch nsError.code {
        case 0: return "Success"
        case 6: return "Read not permitted"
        case 7: return "Write not permitted"
        case 14: return "Encryption required"
        case 15: return "Authentication required"
        default: return "Connection error: \(error.localizedDescription)"
        }
    }
    
    // ==================================================================================
    // MARK: - 2. 蓝牙核心组件
    // ==================================================================================
    
    internal var centralManager: CBCentralManager!
    internal var connectedPeripheral: CBPeripheral?
    
    // ==================================================================================
    // MARK: - 3. 连接状态管理
    // ==================================================================================
    
    internal var addressForRequested: UUID?
    internal var addressForAccepted: UUID?
    internal var currentConnectState: ConnectState = .disconnected {
        didSet { logD("\(TAG): State changed from \(oldValue) to \(currentConnectState)") }
    }
    internal var isConnected: Bool { return currentConnectState == .connected }
    
    // ==================================================================================
    // MARK: - 4. 设备列表与扫描状态
    // ==================================================================================
    
    internal var scannedDevicesWithRssi: Set<BLEDeviceWithRssi> = []
    internal let scanLock = NSLock()
    internal var scanResultCache: [UUID: [String: Any]] = [:]
    internal var isScanning = false
    
    // ==================================================================================
    // MARK: - 5. 数据缓冲与并发控制
    // ==================================================================================
    
    internal var readQueueBuffer: [UInt8] = []
    internal let readQueueLock = NSLock()
    internal var writeQueueBuffer: [UInt8] = []
    internal let writeQueueLock = NSLock()
    internal var currentSendData: Data?
    internal let sendDataLock = NSLock()
    internal var isWriting = false
    internal let writingLock = NSLock()
    internal var connectionCompletion: ((Result<Bool, ConnectError>) -> Void)?
    internal var writeCompletion: ((Result<Bool, ConnectError>) -> Void)?
    internal var characteristicReadCompletions: [String: (Data?) -> Void] = [:]
    internal var isClosing = false
    internal let closingLock = NSLock()
    
    // ==================================================================================
    // MARK: - 6. 特征值配置
    // ==================================================================================
    
    internal var readWriteCharacteristic: CBCharacteristic?
    internal var writeType: CBCharacteristicWriteType = .withResponse
    internal var mtu: Int = 185
    internal var notifyUUID: CBUUID?
    internal var writeUUID: CBUUID?
    internal var subscriptionCaches: [SubscriptionCache] = []
    
    internal let DEVICE_INFO_SERVICE_UUID = CBUUID(string: "180A")
    internal let MANUFACTURER_NAME_UUID = CBUUID(string: "2A29")
    internal let MODEL_NUMBER_UUID = CBUUID(string: "2A24")
    internal let SERIAL_NUMBER_UUID = CBUUID(string: "2A25")
    internal let HARDWARE_REVISION_UUID = CBUUID(string: "2A27")
    internal let FIRMWARE_REVISION_UUID = CBUUID(string: "2A26")
    internal let SOFTWARE_REVISION_UUID = CBUUID(string: "2A28")
    internal let SYSTEM_UUID = CBUUID(string: "2A23")
    internal let IEEE_UUID = CBUUID(string: "2A2A")
    internal let PNP_UUID = CBUUID(string: "2A50")
    internal let UUID_CCCD = CBUUID(string: "2902")
    
    // ==================================================================================
    // MARK: - 7. 设备信息缓存
    // ==================================================================================
    
    internal var broadcastData: BroadcastData?
    internal var deviceInfo: DeviceInfo?
    internal var serviceList: [BLEServiceDto] = []
    
    // ==================================================================================
    // MARK: - 8. RSSI 监控状态
    // ==================================================================================
    
    internal var rssiTimer: Timer?
    internal var isRssiReading = false
    internal var isDataSending = false
    internal var isWaitingResponse = false
    internal var rssiReadStartTime: Date?
    
    // ==================================================================================
    // MARK: - 9. 回调函数
    // ==================================================================================
    
    public var onDeviceDisconnect: (() -> Void)?
    public var onBluetoothStateDisconnect: (() -> Void)?
    public var onHandleRssiUpdate: ((Int) -> Void)?
    public var onDeviceFound: ((Set<BLEDeviceWithRssi>) -> Void)?
    public var onDataReceived: ((Data) -> Void)?
    
    // ==================================================================================
    // MARK: - 10. 初始化方法
    // ==================================================================================
    
    public override init() {
        super.init()
    }
    
    internal func initBluetooth() -> Bool {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.global(qos: .userInitiated))
        }
        return true
    }
    
    internal var isEnabled: Bool {
        guard let manager = centralManager else {
            logE("\(TAG): CBCentralManager not initialized")
            return false
        }
        return manager.state == .poweredOn
    }
    
    // ==================================================================================
    // MARK: - 11. 扫描方法
    // ==================================================================================
    
    public func startScan(completion: @escaping (Result<Void, ConnectError>) -> Void) {
        if !initBluetooth() {
            completion(.failure(.bluetoothUnavailable))
            return
        }
        
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            
            if !self.isEnabled {
                DispatchQueue.main.async {
                    completion(.failure(.connectionFailed(underlyingError: NSError(domain: "BLE", code: -1, userInfo: [NSLocalizedDescriptionKey: "Bluetooth off"]))))
                }
                return
            }
            
            if self.isScanning { self.stopScan() }
            
            self.scanLock.lock()
            self.scannedDevicesWithRssi.removeAll()
            self.scanResultCache.removeAll()
            self.scanLock.unlock()
            
            self.isScanning = true
            self.centralManager.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: true
            ])
            
            logD("\(self.TAG): Scan started")
            DispatchQueue.main.async { completion(.success(())) }
        }
    }
    
    public func stopScan() {
        if isScanning {
            centralManager?.stopScan()
            isScanning = false
            logD("\(TAG): Scan stopped")
        }
    }
    
    // ==================================================================================
    // MARK: - 12. 连接方法
    // ==================================================================================
    
    public func connectDevice(identifier: String, timeout: TimeInterval, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        if currentConnectState == .connected {
            completion(.success(true))
            return
        }
        if currentConnectState == .connecting {
            completion(.failure(.connecting))
            return
        }
        
        stopScan()
        readWriteCharacteristic = nil
        addressForAccepted = nil
        
        guard let uuid = UUID(uuidString: identifier) else {
            currentConnectState = .disconnected
            completion(.failure(.connectionFailed(underlyingError: NSError(domain: "BLE", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid identifier"]))))
            return
        }
        
        addressForRequested = uuid
        
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        guard let peripheral = peripherals.first else {
            scanLock.lock()
            let cachedDevice = scannedDevicesWithRssi.first { $0.peripheral.identifier == uuid }
            scanLock.unlock()
            
            if let device = cachedDevice {
                connectToPeripheral(device.peripheral, timeout: timeout, completion: completion)
            } else {
                currentConnectState = .disconnected
                completion(.failure(.connectionFailed(underlyingError: NSError(domain: "BLE", code: -1, userInfo: [NSLocalizedDescriptionKey: "Can not get remote device"]))))
            }
            return
        }
        
        connectToPeripheral(peripheral, timeout: timeout, completion: completion)
    }
    
    internal func connectToPeripheral(_ peripheral: CBPeripheral, timeout: TimeInterval, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        currentConnectState = .connecting
        connectedPeripheral = peripheral
        peripheral.delegate = self
        connectionCompletion = completion
        
        centralManager.connect(peripheral, options: nil)
        logD("\(TAG): Trying to create a new connection to \(peripheral.name ?? "Unknown")")
        
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self else { return }
            if self.currentConnectState == .connecting {
                logE("\(self.TAG): Connection timeout after \(timeout)s")
                self.closeChannel()
                let callback = self.connectionCompletion
                self.connectionCompletion = nil
                DispatchQueue.main.async { callback?(.failure(.connectionTimeout)) }
            }
        }
    }
}
