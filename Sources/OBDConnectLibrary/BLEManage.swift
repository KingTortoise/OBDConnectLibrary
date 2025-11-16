//
//  BLEManage.swift
//  OBDUpdater
//
//  Created by 金文武 on 2025/7/1.
//

import SwiftUI
@preconcurrency
import CoreBluetooth

// 扫描设备信息结构体，包含 peripheral 和 RSSI
struct BLEScannedDeviceInfo {
    let peripheral: CBPeripheral
    let rssi: Int
    let lastUpdateTime: Date
    let updateCount: Int
    let advertisementData: [String: Any]?
    let serviceUuids: [String]
    let manufacturerData: [String: Data]
    let txPowerLevel: Int?
    
    init(peripheral: CBPeripheral, rssi: Int, lastUpdateTime: Date, updateCount: Int, advertisementData: [String: Any]? = nil) {
        self.peripheral = peripheral
        self.rssi = rssi
        self.lastUpdateTime = lastUpdateTime
        self.updateCount = updateCount
        self.advertisementData = advertisementData
        
        // 从广播数据中提取信息
        var serviceUuids: [String] = []
        var manufacturerData: [String: Data] = [:]
        var txPowerLevel: Int? = nil
        
        if let adData = advertisementData {
            // 提取服务 UUIDs
            if let services = adData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
                serviceUuids = services.map { $0.uuidString }
            }
            
            // 提取制造商数据
            if let mfgData = adData[CBAdvertisementDataManufacturerDataKey] as? Data {
                manufacturerData["Manufacturer"] = mfgData
            }
        
            
            // 提取发射功率级别
            if let txPower = adData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber {
                txPowerLevel = txPower.intValue
            }
        }
        
        self.serviceUuids = serviceUuids
        self.manufacturerData = manufacturerData
        self.txPowerLevel = txPowerLevel
    }
}

final class BLEManage: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate,@unchecked Sendable {
    
    // 蓝牙中央管理器
    private var centralManager: CBCentralManager!
    // 当前连接的外设
    private var connectedPeripheral: CBPeripheral?
    // 所有发现的外设信息（包含RSSI）
    private var discoveredDevices: [BLEScannedDeviceInfo] = []
    
    private var characteristicForReadWrite: CBCharacteristic?
    private var state: State = .disconnected
    private var dataForRead = Data()
    private var readDataQueue = Data()
    
    // 智能特征值选择相关属性
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var combinedCharacteristic: CBCharacteristic?
    private var notifyUUID: CBUUID?
    private var writeUUID: CBUUID?
    private var writeType: CBCharacteristicWriteType = CBCharacteristicWriteType.withoutResponse // 0 = WRITE_TYPE_DEFAULT, 1 = WRITE_TYPE_NO_RESPONSE
    
    // 订阅状态缓存
    private var subscriptionCaches: [SubscriptionCache] = []
    
    // 订阅缓存结构体
    private struct SubscriptionCache: Equatable {
        let characteristic: CBCharacteristic
        let subscriptionType: String // "NOTIFY" 或 "INDICATE"
        
        static func == (lhs: SubscriptionCache, rhs: SubscriptionCache) -> Bool {
            return lhs.characteristic.uuid.uuidString == rhs.characteristic.uuid.uuidString &&
                   lhs.characteristic.service?.uuid.uuidString == rhs.characteristic.service?.uuid.uuidString &&
                   lhs.subscriptionType == rhs.subscriptionType
        }
    }
    
    // 设备信息收集相关属性
    private var broadcastData: BroadcastData?
    private var deviceInfo: BleDeviceInfoDetails?
    private var serviceList: [BleServiceDto] = []
    
    // 设备信息服务 UUID（标准 UUID）
    private let DEVICE_INFO_SERVICE_UUID = CBUUID(string: "0000180a-0000-1000-8000-00805f9b34fb")
    private let MANUFACTURER_NAME_UUID = CBUUID(string: "00002a29-0000-1000-8000-00805f9b34fb")
    private let MODEL_NUMBER_UUID = CBUUID(string: "00002a24-0000-1000-8000-00805f9b34fb")
    private let SERIAL_NUMBER_UUID = CBUUID(string: "00002a25-0000-1000-8000-00805f9b34fb")
    private let HARDWARE_REVISION_UUID = CBUUID(string: "00002a27-0000-1000-8000-00805f9b34fb")
    private let FIRMWARE_REVISION_UUID = CBUUID(string: "00002a26-0000-1000-8000-00805f9b34fb")
    private let SOFTWARE_REVISION_UUID = CBUUID(string: "00002a28-0000-1000-8000-00805f9b34fb")
    private let SYSTEM_UUID = CBUUID(string: "00002A23-0000-1000-8000-00805F9B34FB")
    private let IEEE_UUID = CBUUID(string: "00002A2A-0000-1000-8000-00805F9B34FB")
    private let PnP_UUID = CBUUID(string: "00002A50-0000-1000-8000-00805F9B34FB")
     
    // MTU 相关属性
    private var currentMTU: Int = 20 // 默认 MTU 值（BLE 默认是 20 字节）
    private var isMTURequested: Bool = false
    
    private let syncQueue = DispatchQueue(label: "com.bleManage.syncQueue", qos: .userInitiated)
    
    // 当前接收数据流的任务
    @available(iOS 13.0, *)
    private var currentReceiveTask: Task<Void, Never>?
    
    // 扫描结果数据流
    @available(iOS 13.0, *)
    private var scanResultContinuation: AsyncStream<[BLEScannedDeviceInfo]>.Continuation?
    @available(iOS 13.0, *)
    private var scanResultStream: AsyncStream<[BLEScannedDeviceInfo]>?
    private var sendCount = 1
    
    // 设备断开回调
    var onDeviceDisconnect: (() -> Void)?
    
    // 蓝牙状态断开回调
    var onBluetoothDisconnect: (() -> Void)?
    
    // 重连相关属性
    private var reconnectAttempts: Int = 0
    private var targetPeripheral: CBPeripheral? = nil // 保存目标设备，用于重连
    private let MAX_RECONNECT_ATTEMPTS = 1
    private let INITIAL_RECONNECT_DELAY: TimeInterval = 1.0 // 1秒
    
    override init() {
        super.init()
        // 初始化中央管理器
        let bluetoothQueue = DispatchQueue(label: "com.bleManage.bluetoothQueue")
        centralManager = CBCentralManager(delegate: self, queue: bluetoothQueue)
    }
    
    func waitForBluetoothPoweredOn(timeout: TimeInterval = 5.0) async -> Bool {
        await wait(unit: { [weak self] in
            self?.centralManager.state == .poweredOn
        }, timeout: timeout)
    }
    
    func waitForSearchPeripheral(timeout: TimeInterval = 5.0) async -> Bool {
        await wait(unit: { [weak self] () -> Bool in
            return self?.syncQueue.sync {
                self?.connectedPeripheral != nil
            } ?? false
        }, timeout: timeout)
    }
    
    func waitForConnectState(timeout: TimeInterval = 5.0) async -> Bool {
        await wait(unit: { [weak self] in
            return self?.syncQueue.sync {
                self?.connectedPeripheral?.state == .connected
            } ?? false
        }, timeout: timeout)
    }
    
    func waitForReadWrite(timeout: TimeInterval = 5.0) async -> Bool {
        await wait(unit: { [weak self] in
            return self?.syncQueue.sync {
                self?.characteristicForReadWrite != nil
            } ?? false
        }, timeout: timeout)
    }
    
    func waitForReadData(timeout: TimeInterval = 5.0) async -> Bool {
        await wait(unit: { [weak self] in
            guard let self = self else { return false }
            return self.syncQueue.sync {
                if self.dataForRead.count > 0 {
                    if let endData = self.dataForRead.last {
                        let endChar = Unicode.Scalar(endData)
                        return endChar == ">"
                    } else {
                        return false
                    }
                } else {
                    return false
                }
            }
        }, timeout: timeout)
    }
    
    func waitForActualPeripheralConnection(peripheral: CBPeripheral, timeout: TimeInterval = 5.0) async -> Bool {
        let result = await wait(unit: { [weak self] in
            guard let self = self else { return false }
            let isConnected = self.syncQueue.sync {
                let state = peripheral.state
                if state != .connected {
                }
                return state == .connected
            }
            return isConnected
        }, timeout: timeout)
        return result
    }
    
    func open(peripheral: CBPeripheral?) async -> Result<Void, ConnectError> {
        let connectState = syncQueue.sync { state }
        if connectState == .connected {
            return .success(())
        }
        if connectState == .connecting {
            return .failure(.connecting)
        }
        
        guard let peripheral = peripheral else {
            return .failure(.invalidData)
        }
        
        guard await waitForBluetoothPoweredOn() else {
            syncQueue.sync {
                self.state = .disconnected
            }
            return .failure(.btUnEnable)
        }
        
        syncQueue.sync {
            self.state = .connecting
            self.connectedPeripheral = peripheral
            self.targetPeripheral = peripheral // 保存目标设备用于重连
            self.centralManager.connect(peripheral, options: nil)
        }
        
        guard await waitForConnectState() else {
            syncQueue.sync {
                // 连接失败时直接清理状态，不调用cancelPeripheralConnection避免触发断开回调
                self.connectedPeripheral = nil
                self.state = .disconnected
            }
            return .failure(.connectionFailed(NSError(domain: "BLEManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No status change notification received."])))
        }
        guard await waitForReadWrite() else {
            syncQueue.sync {
                // 连接失败时直接清理状态，不调用cancelPeripheralConnection避免触发断开回调
                self.connectedPeripheral = nil
                self.characteristicForReadWrite = nil
                self.state = .disconnected
            }
            return .failure(.connectionFailed(NSError(domain: "BLEManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No characteristics found."])))
        }
        
        // 关键修复：验证 peripheral 实际连接状态
        let peripheralConnected = await waitForActualPeripheralConnection(peripheral: peripheral, timeout: 5.0)
        guard peripheralConnected else {
            syncQueue.sync {
                self.connectedPeripheral = nil
                self.characteristicForReadWrite = nil
                self.state = .disconnected
            }
            return .failure(.connectionFailed(NSError(domain: "BLEManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Peripheral did not reach connected state"])))
        }
        
        // 获取并保存 MTU 值
        await updateMTUValue()
        
        syncQueue.sync {
            self.state = .connected
            self.targetPeripheral = peripheral // 连接成功时更新目标设备
        }
        // 异步获取设备信息（不阻塞连接成功返回）
        Task {
            await getBleDeviceInfo()
        }
               
        return .success(())
    }
    
    // 更新 MTU 值
    private func updateMTUValue() async {
        guard let peripheral = connectedPeripheral else { return }
        
        // 获取当前连接的 MTU 值
        let mtuValue = peripheral.maximumWriteValueLength(for: .withoutResponse)
        
        syncQueue.sync {
            self.currentMTU = mtuValue
            self.isMTURequested = true
        }
        
    }
    
    // 获取当前 MTU 值
    func getCurrentMTU() -> Int {
        return syncQueue.sync {
            return self.currentMTU
        }
    }
    
    // 将数据分块
    private func chunkData(_ data: Data, chunkSize: Int) -> [Data] {
        var chunks: [Data] = []
        var offset = 0
        
        while offset < data.count {
            let endIndex = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: offset..<endIndex)
            chunks.append(chunk)
            offset = endIndex
        }
        
        return chunks
    }
    
    func write(data: Data, timeout: TimeInterval) -> Result<Void, ConnectError> {
        // 状态检查
        let (currentState, characteristic, mtu, peripheral) = syncQueue.sync {
            (state, characteristicForReadWrite, currentMTU, connectedPeripheral)
        }
        
        // 增强状态检查：检查 BLE 状态、连接状态和 peripheral 状态
        guard currentState == .connected, 
              centralManager.state == CBManagerState.poweredOn, 
              characteristic != nil,
              let peripheral = peripheral else {
            return .failure(.notConnected)
        }
        
        // 检查 peripheral 状态，如果未连接则更新内部状态
        if peripheral.state != .connected {
            
            // 如果 peripheral 状态不是 connected，说明连接已断开
            // 更新内部状态为 disconnected
            syncQueue.sync {
                self.state = .disconnected
                self.connectedPeripheral = nil
                self.characteristicForReadWrite = nil
            }
            
            return .failure(.notConnected)
        }
        
        guard !data.isEmpty else {
            // 空数据视为发送成功
            return .success(())
        }
        
        // 检查数据长度是否超过 MTU
        if data.count <= mtu {
            // 数据长度在 MTU 范围内，直接发送
            peripheral.writeValue(data, for: characteristic!, type: writeType)
            return .success(())
        } else {
            // 数据长度超过 MTU，需要分段发送
            let result = sendDataInChunks(data, mtu: mtu)
            return result
        }
    }
    
    // 分段发送数据
    private func sendDataInChunks(_ data: Data, mtu: Int)  -> Result<Void, ConnectError> {
        let (peripheral, characteristic) = syncQueue.sync { (connectedPeripheral, characteristicForReadWrite) }
        guard let peripheral = peripheral, let characteristic = characteristic else {
            return .failure(.notConnected)
        }
        
        let chunks = chunkData(data, chunkSize: mtu)
        for (index, chunk) in chunks.enumerated() {
            peripheral.writeValue(chunk, for: characteristic, type: writeType)
            
            // 在包之间添加小延迟，避免发送过快
            if index < chunks.count - 1 {
                Thread.sleep(forTimeInterval: 0.001) // 1ms 延迟
            }
        }
        
        return .success(())
    }
    
    
    func read(timeout: TimeInterval) async -> Result<Data, ConnectError> {
        let (currentState, characteristic) = syncQueue.sync {
            (state, characteristicForReadWrite)
        }
        guard currentState == .connected, centralManager.state == CBManagerState.poweredOn, characteristic != nil else {
            clenReceiveInfo()
            return .failure(.notConnected)
        }
        guard await waitForReadData() else {
            clenReceiveInfo()
            return .failure(.receiveTimeout)
        }
        return .success(self.dataForRead)
    }
    
    // 数据流读取方法
    @available(iOS 13.0, *)
    func receiveDataFlow() -> AsyncStream<Data> {
        // 取消之前的任务
        currentReceiveTask?.cancel()
        
        return AsyncStream<Data> { continuation in
            let task = Task { [weak self] in
                guard let self = self else {
                    continuation.finish()
                    return
                }
                
                let currentState = await withCheckedContinuation { (cont: CheckedContinuation<State, Never>) in
                    self.syncQueue.async {
                        cont.resume(returning: self.state)
                    }
                }
                
                if currentState != .connected {
                    continuation.finish()
                    return
                }
                
                do {
                    while true {
                        // 检查任务是否被取消
                        if Task.isCancelled {
                            break
                        }
                        
                        // 原子操作：检查并获取数据
                        let (hasData, batch) = await withCheckedContinuation { (cont: CheckedContinuation<(Bool, Data), Never>) in
                            self.syncQueue.async {
                                let data = self.readDataQueue
                                let hasData = !data.isEmpty
                                if hasData {
                                    self.readDataQueue.removeAll()
                                }
                                cont.resume(returning: (hasData, data))
                            }
                        }
                        
                        if hasData {
                            sendCount += 1
                            continuation.yield(batch)
                        } else {
                            // 队列无数据：短暂延迟避免忙等待
                            try await Task.sleep(nanoseconds: 100_000) // 0.1ms
                        }
                    }
                } catch {
                }
                
                // 清理资源
                self.syncQueue.async {
                    self.readDataQueue.removeAll()
                }
                continuation.finish()
            }
            
            // 设置当前任务以便后续可以取消
            self.currentReceiveTask = task
        }
    }
    
    func clenReceiveInfo() {
        syncQueue.async { [weak self] in
            guard let self = self else {return}
            self.dataForRead.removeAll()
            self.readDataQueue.removeAll()
        }
    }
    
    func close() {
        syncQueue.async { [weak self] in
            guard let self = self else {return}
            
            // 取消接收任务
            self.currentReceiveTask?.cancel()
            self.currentReceiveTask = nil
            
            if let manage = self.centralManager, let connected = self.connectedPeripheral {
                manage.cancelPeripheralConnection(connected)
            }
            self.centralManager = nil
            self.connectedPeripheral = nil
            self.targetPeripheral = nil // 清理目标设备
            self.characteristicForReadWrite = nil
            self.dataForRead = Data()
            self.state = .disconnected
            // 重置 MTU 状态
            self.currentMTU = 20
            self.isMTURequested = false
        }
    }
    
    // 开始扫描BLE设备
    func startScan() async -> Bool {
        // 等待蓝牙状态就绪
        guard await waitForBluetoothPoweredOn() else {
            return false
        }
        
        // 创建扫描结果数据流
        if #available(iOS 13.0, *) {
            scanResultStream = AsyncStream<[BLEScannedDeviceInfo]> { continuation in
                scanResultContinuation = continuation
            }
        }
        
        // 清空之前的设备列表
        syncQueue.sync {
            self.discoveredDevices.removeAll()
        }
        
        // 开始扫描BLE设备
        syncQueue.sync {
            // 停止之前的扫描
            self.centralManager.stopScan()
            // 开始新的扫描 - 扫描所有外设
            // 扫描所有外设，允许重复发现以获取更多设备
            self.centralManager.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: true
            ])
        }
        
        return true
    }
    
    // 获取扫描结果数据流
    @available(iOS 13.0, *)
    func getScanResultStream() -> AsyncStream<[BLEScannedDeviceInfo]>? {
        return scanResultStream
    }
    
    // 停止扫描BLE设备
    func stopScan() {
        syncQueue.sync {
            self.centralManager.stopScan()
        }
        
        // 结束数据流
        if #available(iOS 13.0, *) {
            scanResultContinuation?.finish()
            scanResultContinuation = nil
            scanResultStream = nil
        }
        
    }
    
    /// ##CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let currentState = central.state
        
        // 当蓝牙状态变为非 poweredOn 时，触发蓝牙断开回调
        if currentState != .poweredOn {
            // 更新内部状态为 disconnected
            syncQueue.sync {
                self.state = .disconnected
                self.connectedPeripheral = nil
                self.characteristicForReadWrite = nil
            }
            
            DispatchQueue.main.async {
                self.onBluetoothDisconnect?()
            }
        } else {
            // 蓝牙重新开启时，如果之前有连接，需要重新连接
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        syncQueue.async { [weak self] in
            guard let self = self else {return}
            
            let rssiValue = RSSI.intValue
            let currentTime = Date()
            var shouldUpdate = false
            
            // 检查是否已存在该设备，如果存在则更新RSSI，否则添加新设备
            if let existingIndex = self.discoveredDevices.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
                let existingDevice = self.discoveredDevices[existingIndex]
                let timeSinceLastUpdate = currentTime.timeIntervalSince(existingDevice.lastUpdateTime)
                let rssiDifference = abs(existingDevice.rssi - rssiValue)
                
                // 智能更新策略：
                // 1. 如果RSSI变化很大（>10dBm），立即更新
                // 2. 如果RSSI变化中等（5-10dBm），且距离上次更新超过1秒，则更新
                // 3. 如果RSSI变化较小（<5dBm），且距离上次更新超过3秒，则更新
                // 4. 对于更新频率过高的设备，增加时间间隔
                let shouldUpdateRSSI: Bool
                if rssiDifference >= 10 {
                    shouldUpdateRSSI = true
                } else if rssiDifference >= 5 && timeSinceLastUpdate >= 1.0 {
                    shouldUpdateRSSI = true
                } else if rssiDifference >= 2 && timeSinceLastUpdate >= 3.0 {
                    shouldUpdateRSSI = true
                } else if timeSinceLastUpdate >= 5.0 {
                    // 即使RSSI变化很小，超过5秒也要更新一次
                    shouldUpdateRSSI = true
                } else {
                    shouldUpdateRSSI = false
                }
                
                if shouldUpdateRSSI {
                    let newDeviceInfo = BLEScannedDeviceInfo(
                        peripheral: peripheral,
                        rssi: rssiValue,
                        lastUpdateTime: currentTime,
                        updateCount: existingDevice.updateCount + 1,
                        advertisementData: advertisementData
                    )
                    self.discoveredDevices[existingIndex] = newDeviceInfo
                    shouldUpdate = true
                }
            } else {
                // 添加新设备
                let newDeviceInfo = BLEScannedDeviceInfo(
                    peripheral: peripheral,
                    rssi: rssiValue,
                    lastUpdateTime: currentTime,
                    updateCount: 1,
                    advertisementData: advertisementData
                )
                self.discoveredDevices.append(newDeviceInfo)
                shouldUpdate = true
            }
            
            // 只有在需要更新时才发送数据流
            if shouldUpdate {
                if #available(iOS 13.0, *) {
                    self.scanResultContinuation?.yield(self.discoveredDevices)
                }
            }
        }
    }
    
    /// ##CBPeripheralDelegate
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        syncQueue.async {
            peripheral.delegate = self
            // 发现所有服务，包括设备信息服务
            peripheral.discoverServices(nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        // 设备断开时主动取消接收任务
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            self.currentReceiveTask?.cancel()
            self.currentReceiveTask = nil
            self.state = .disconnected
            
            // 触发设备断开回调
            DispatchQueue.main.async {
                self.onDeviceDisconnect?()
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        syncQueue.async {
            if let services = peripheral.services {
                for service in services {
                    // 发现所有特征值，不限制特定 UUID
                    peripheral.discoverCharacteristics(nil, for: service)
                }
            }
        }
    }
    
    /// 获取服务名称（用于调试）
    private func getServiceName(for uuid: CBUUID) -> String {
        switch uuid.uuidString.uppercased() {
        case "0000180A-0000-1000-8000-00805F9B34FB":
            return "Device Information Service"
        case "0000180F-0000-1000-8000-00805F9B34FB":
            return "Battery Service"
        case "0000180D-0000-1000-8000-00805F9B34FB":
            return "Heart Rate Service"
        case "00001812-0000-1000-8000-00805F9B34FB":
            return "Human Interface Device"
        default:
            return "Unknown Service"
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        if error != nil {
            return
        }
        
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            
            if let characteristics = service.characteristics {
                // 解析所有特征值，按 Kotlin 逻辑进行智能选择
                self.parseAllCharacteristics(characteristics)
            }
        }
    }
    
    /// 获取特征值名称（用于调试）
    private func getCharacteristicName(for uuid: CBUUID) -> String {
        switch uuid.uuidString.uppercased() {
        case "00002A29-0000-1000-8000-00805F9B34FB":
            return "Manufacturer Name String"
        case "00002A24-0000-1000-8000-00805F9B34FB":
            return "Model Number String"
        case "00002A25-0000-1000-8000-00805F9B34FB":
            return "Serial Number String"
        case "00002A27-0000-1000-8000-00805F9B34FB":
            return "Hardware Revision String"
        case "00002A26-0000-1000-8000-00805F9B34FB":
            return "Firmware Revision String"
        case "00002A28-0000-1000-8000-00805F9B34FB":
            return "Software Revision String"
        case "00002A23-0000-1000-8000-00805F9B34FB":
            return "System ID"
        case "00002A2A-0000-1000-8000-00805F9B34FB":
            return "IEEE 11073-20601 Regulatory Certification Data List"
        case "00002A50-0000-1000-8000-00805F9B34FB":
            return "PnP ID"
        default:
            return "Unknown Characteristic"
        }
    }
    
    /// 解析所有特征值，按智能策略选择最佳配置
    private func parseAllCharacteristics(_ characteristics: [CBCharacteristic]) {
        // 保存之前的专门特征值引用
        let previousNotifyCharacteristic = notifyCharacteristic
        let previousWriteCharacteristic = writeCharacteristic
        
        // 重置特征值引用
        characteristicForReadWrite = nil
        notifyCharacteristic = nil
        writeCharacteristic = nil
        combinedCharacteristic = nil
        
        
        // 1. 遍历所有特征值，收集可用特征值
        for characteristic in characteristics {
            let properties = characteristic.properties
            
            // 检查特征值支持的操作
            let isNotifySupported = properties.contains(.notify) || properties.contains(.indicate)
            let isWriteSupported = properties.contains(.write) || properties.contains(.writeWithoutResponse)
            
            
            // 记录同时支持通知和写入的特征值（最佳选择）
            if isNotifySupported && isWriteSupported {
                combinedCharacteristic = characteristic
            }
            // 记录单独的通知特征值
            else if isNotifySupported && !isWriteSupported && notifyCharacteristic == nil {
                notifyCharacteristic = characteristic
            }
            // 记录单独的写入特征值
            else if isWriteSupported && !isNotifySupported && writeCharacteristic == nil {
                writeCharacteristic = characteristic
            }
        }
        
        // 2. 如果没有找到新的专门特征值，保留之前的
        if notifyCharacteristic == nil && previousNotifyCharacteristic != nil {
            notifyCharacteristic = previousNotifyCharacteristic
        }
        if writeCharacteristic == nil && previousWriteCharacteristic != nil {
            writeCharacteristic = previousWriteCharacteristic
        }
        
        // 3. 按优先级选择特征值配置
        selectOptimalCharacteristicConfiguration()
    }
    
    /// 按优先级选择最佳特征值配置
    private func selectOptimalCharacteristicConfiguration() {
        // 第一优先级：分离式特征值（不同 UUID 进行通知和写入）
        if let notify = notifyCharacteristic, let write = writeCharacteristic {
            
            notifyUUID = notify.uuid
            writeUUID = write.uuid
            
            // 开启通知
            enableCharacteristicNotification(notify)
            
            // 设置写入特征值作为主要引用
            characteristicForReadWrite = write
            return
        }
        
        // 第二优先级：组合式特征值（同一 UUID 进行通知和写入）
        if let combined = combinedCharacteristic {
            
            notifyUUID = combined.uuid
            writeUUID = combined.uuid
            
            // 开启通知
            enableCharacteristicNotification(combined)
            
            // 设置为主要引用
            characteristicForReadWrite = combined
            return
        }
        
        
        if let notify = notifyCharacteristic {
            notifyUUID = notify.uuid
            enableCharacteristicNotification(notify)
            characteristicForReadWrite = notify
        } else if let write = writeCharacteristic {
            writeUUID = write.uuid
            
            characteristicForReadWrite = write
        }
    }
    
    /// 开启特征值的通知功能
    private func enableCharacteristicNotification(_ characteristic: CBCharacteristic) {
        guard let peripheral = connectedPeripheral else {
            return
        }
        
        peripheral.setNotifyValue(true, for: characteristic)
        
        // 添加到订阅缓存
        let subscriptionType = characteristic.properties.contains(.notify) ? "NOTIFY" : "INDICATE"
        let cache = SubscriptionCache(characteristic: characteristic, subscriptionType: subscriptionType)
        subscriptionCaches.append(cache)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error = error {
            return;
        }
        
        syncQueue.async {[weak self] in
            guard let self = self else {
                return
            }
            
            // 智能特征值匹配：支持通知的特征值
            let isNotifyCharacteristic = (self.notifyUUID != nil && characteristic.uuid == self.notifyUUID) ||
                                        (self.combinedCharacteristic != nil && characteristic.uuid == self.combinedCharacteristic!.uuid)
            
            if isNotifyCharacteristic && self.connectedPeripheral == peripheral {
                if let value = characteristic.value {
                    self.dataForRead.append(value)
                    self.readDataQueue.append(value)
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error = error {
            return;
        }
    }
    
    // 获取蓝牙状态的描述信息
    private func getBluetoothStateDescription(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: return "Unknown"
        case .resetting: return "Resetting"
        case .unsupported: return "Unsupported"
        case .unauthorized: return "Unauthorized"
        case .poweredOff: return "Powered Off"
        case .poweredOn: return "Powered On"
        @unknown default: return "Unknown"
        }
    }
    
    // MARK: - Reconnect Implementation
    
    /// 重连方法
    func reconnect() async -> Result<Void, ConnectError> {
        
        // 检查是否已连接或正在重连
        let currentState = syncQueue.sync { state }
        
        if currentState == .connected {
            return .success(())
        }
        if currentState == .connecting {
            return .failure(.connecting)
        }
        
        // 检查蓝牙是否可用
        guard await waitForBluetoothPoweredOn() else {
            return .failure(.btUnEnable)
        }
        
        // 检查是否有目标设备
        guard let targetPeripheral = syncQueue.sync(execute: { self.targetPeripheral }) else {
            return .failure(.connectionFailed(NSError(domain: "BLEManage", code: -1, userInfo: [NSLocalizedDescriptionKey: "No target device for reconnection"])))
        }
        
        // 执行带重试的重连逻辑
        return await performReconnect(peripheral: targetPeripheral, timeout: 30.0)
    }
    
    /// 带重试机制的重连实现
    private func performReconnect(peripheral: CBPeripheral, timeout: TimeInterval) async -> Result<Void, ConnectError> {
        // 重置重连次数（避免累计旧次数）
        reconnectAttempts = 0
        
        while reconnectAttempts < MAX_RECONNECT_ATTEMPTS {
            reconnectAttempts += 1
            let currentAttempt = reconnectAttempts
            
            
            // 执行单次重连
            let result = await open(peripheral: peripheral)
            if case .success = result {
                
                // 重连成功：验证连接状态是否真正可用
                let connectionValid = await validateConnection(peripheral: peripheral)
                if connectionValid {
                    reconnectAttempts = 0
                    return .success(())
                } else {
                    // 如果验证失败，确保状态为 disconnected
                    syncQueue.sync {
                        self.state = .disconnected
                    }
                    return .failure(.connectionFailed(NSError(domain: "BLEManage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Connection validation failed"])))
                }
            } else {
                
                // 重连失败：检查是否达到最大次数
                if reconnectAttempts >= MAX_RECONNECT_ATTEMPTS {
                    reconnectAttempts = 0
                    syncQueue.sync {
                        self.state = .disconnected
                    }
                    return .failure(.connectionFailed(NSError(domain: "BLEManage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Max reconnection attempts reached"])))
                }
                
                // 未达最大次数：延迟后继续重连（指数退避）
                let delayMillis = INITIAL_RECONNECT_DELAY * pow(2.0, Double(currentAttempt - 1)) // 1s→2s→4s...
                try? await Task.sleep(nanoseconds: UInt64(delayMillis * 1_000_000_000))
            }
        }
        
        // 理论上不会走到这里，保险起见返回失败
        return .failure(.connectionFailed(NSError(domain: "BLEManage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error in reconnection"])))
    }
    
    /// 验证连接状态是否真正可用
    private func validateConnection(peripheral: CBPeripheral) async -> Bool {
        // 检查 peripheral 状态
        guard peripheral.state == .connected else {
            return false
        }
        
        // 检查特征值是否可用
        let characteristic = syncQueue.sync { characteristicForReadWrite }
        guard characteristic != nil else {
            return false
        }
        
        // 检查 BLE 管理器状态
        let managerState = syncQueue.sync { state }
        guard managerState == .connected else {
            return false
        }
        return true
    }
    
    // MARK: - Device Info Collection
    
    /// 获取 BLE 设备信息（按照 Kotlin 逻辑实现）
    func getBleDeviceInfo() async -> BleDeviceInfo {
        
        // 1. 收集广播数据
        if broadcastData == nil {
            await collectBroadcastData()
        }
        
        // 2. 收集设备信息服务
        if deviceInfo == nil {
            await collectDeviceInfoService()
        }
        
        // 3. 收集服务特征值信息
        await collectServiceCharacteristics()
        
        return BleDeviceInfo(
            broadcastData: broadcastData,
            deviceInfo: deviceInfo,
            serviceInfo: serviceList
        )
    }
    
    /// 收集广播数据
    private func collectBroadcastData() async {
        
        // 从扫描结果中获取目标设备的广播数据
        let targetDevice = syncQueue.sync { targetPeripheral }
        guard let peripheral = targetDevice else {
            return
        }
        
        // 从已发现的设备中查找匹配的扫描数据
        let discoveredDevices = syncQueue.sync { self.discoveredDevices }
        let matchingDevice = discoveredDevices.first { $0.peripheral.identifier == peripheral.identifier }
        
        var deviceName = peripheral.name ?? "Unknown"
        var txPowerLevel = -1
        var serviceUuids: [String] = []
        var manufacturerData: [String: Data] = [:]
        var isConnect: Bool = false
        
        if let device = matchingDevice {
            // 从扫描数据中提取信息
            deviceName = peripheral.name ?? "Unknown"
            txPowerLevel = device.txPowerLevel ?? device.rssi // 优先使用广播中的功率级别，否则使用 RSSI
            
            // 使用从广播数据中提取的信息
            serviceUuids = device.serviceUuids
            manufacturerData = device.manufacturerData
            isConnect = device.advertisementData != nil
            
        }
        
        broadcastData = BroadcastData(
            deviceName: deviceName,
            txPowerLevel: txPowerLevel,
            serviceUuids: serviceUuids,
            manufacturerData: manufacturerData,
            isConnect: isConnect
        )
        
    }
    
    /// 收集设备信息服务
    private func collectDeviceInfoService() async {
        
        guard let peripheral = syncQueue.sync(execute: { connectedPeripheral }) else {
            return
        }
        
        // 首先尝试从广播数据中获取基本信息
        let discoveredDevices = syncQueue.sync { self.discoveredDevices }
        
        var manufacturerName: String? = nil
        var modelNumber: String? = nil
        var serialNumber: String? = nil
        var hardwareRevision: String? = nil
        var firmwareRevision: String? = nil
        var softwareRevision: String? = nil
        var systemId: String? = nil
        var ieeeId: String? = nil
        var pnpId: String? = nil
    
        
        // 尝试从标准设备信息服务获取详细信息
        if let deviceInfoService = peripheral.services?.first(where: { $0.uuid == DEVICE_INFO_SERVICE_UUID }) {
            
            // 串行读取所有设备信息特征值
            manufacturerName = await readCharacteristic(peripheral, deviceInfoService.characteristics?.first(where: { $0.uuid == MANUFACTURER_NAME_UUID })) ?? ""
            modelNumber = await readCharacteristic(peripheral, deviceInfoService.characteristics?.first(where: { $0.uuid == MODEL_NUMBER_UUID }))
            serialNumber = await readCharacteristic(peripheral, deviceInfoService.characteristics?.first(where: { $0.uuid == SERIAL_NUMBER_UUID }))
            hardwareRevision = await readCharacteristic(peripheral, deviceInfoService.characteristics?.first(where: { $0.uuid == HARDWARE_REVISION_UUID }))
            firmwareRevision = await readCharacteristic(peripheral, deviceInfoService.characteristics?.first(where: { $0.uuid == FIRMWARE_REVISION_UUID }))
            softwareRevision = await readCharacteristic(peripheral, deviceInfoService.characteristics?.first(where: { $0.uuid == SOFTWARE_REVISION_UUID }))
            systemId = await readCharacteristic(peripheral, deviceInfoService.characteristics?.first(where: { $0.uuid == SYSTEM_UUID }))
            ieeeId = await readCharacteristic(peripheral, deviceInfoService.characteristics?.first(where: { $0.uuid == IEEE_UUID }))
            pnpId = await readCharacteristic(peripheral, deviceInfoService.characteristics?.first(where: { $0.uuid == PnP_UUID }))
        } else {
            
            // 如果没有标准设备信息服务，提供一些基本信息
            if manufacturerName == nil {
                manufacturerName = "Unknown Manufacturer"
            }
            modelNumber = peripheral.name ?? "Unknown Model"
            serialNumber = "UUID: \(peripheral.identifier.uuidString)"
        }
        
        // 确保至少有一些基本信息
        if manufacturerName == nil {
            manufacturerName = "Unknown Manufacturer"
        }
        
        deviceInfo = BleDeviceInfoDetails(
            manufacturerName: manufacturerName,
            modelNumber: modelNumber,
            serialNumber: serialNumber,
            hardwareRevision: hardwareRevision,
            firmwareRevision: firmwareRevision,
            softwareRevision: softwareRevision,
            systemId: systemId,
            ieeeId: ieeeId,
            pnpId: pnpId
        )
        
    }
    
    /// 收集服务特征值信息
    private func collectServiceCharacteristics() async {
        
        guard let peripheral = syncQueue.sync(execute: { connectedPeripheral }) else {
            return
        }
        
        serviceList.removeAll()
        
        guard let services = peripheral.services else {
            return
        }
        
        // 保存当前的特征值引用，避免在收集过程中被重置
        let currentNotifyCharacteristic = syncQueue.sync { notifyCharacteristic }
        let currentWriteCharacteristic = syncQueue.sync { writeCharacteristic }
        
        for service in services {
            // 只收集多属性特征值的服务
            let hasMultiPropertyCharacteristic = service.characteristics?.contains { characteristic in
                countProperties(characteristic.properties) > 1
            } ?? false
            
            if hasMultiPropertyCharacteristic {
                let serviceDto = mapServiceToDto(service, notifyChar: currentNotifyCharacteristic, writeChar: currentWriteCharacteristic)
                serviceList.append(serviceDto)
            }
        }
        
    }
    
    /// 读取单个特征值
    private func readCharacteristic(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic?) async -> String? {
        guard let characteristic = characteristic else { 
            return nil 
        }
        
        
        // 检查特征值是否支持读取
        guard characteristic.properties.contains(.read) else {
            return nil
        }
        
        // 如果特征值已经有缓存的值，直接使用
        if let value = characteristic.value, !value.isEmpty {
            let result = parseCharacteristicValue(value, for: characteristic.uuid)
            return result
        }
        
        // 尝试读取特征值
        return await withCheckedContinuation { continuation in
            // 设置一个超时机制
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2秒超时
                continuation.resume(returning: nil)
            }
            
            // 使用 peripheral.readValue 进行异步读取
            peripheral.readValue(for: characteristic)
            
            // 等待一小段时间让读取完成
            Task {
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
                timeoutTask.cancel()
                
                if let value = characteristic.value, !value.isEmpty {
                    let result = parseCharacteristicValue(value, for: characteristic.uuid)
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    /// 解析特征值数据
    private func parseCharacteristicValue(_ data: Data, for uuid: CBUUID) -> String {
        // 根据特征值类型选择解析方式
        switch uuid {
        case SYSTEM_UUID, IEEE_UUID, PnP_UUID:
            // 二进制特征值，转换为十六进制
            return data.map { String(format: "%02X", $0) }.joined(separator: ":")
        default:
            // 字符串特征值，使用 UTF-8 解析
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
    
    /// 将服务转换为数据传输对象
    private func mapServiceToDto(_ service: CBService, notifyChar: CBCharacteristic? = nil, writeChar: CBCharacteristic? = nil) -> BleServiceDto {
        let characteristics: [BleCharacteristicDto] = service.characteristics?.map { characteristic in
            let propertyStatus = checkEachPropertyStatus(characteristic, notifyChar: notifyChar, writeChar: writeChar)
            return BleCharacteristicDto(
                characteristicUuid: characteristic.uuid.uuidString,
                properties: mapProperties(characteristic.properties),
                value: characteristic.value?.map { String(format: "%02X", $0) }.joined(separator: ":") ?? "",
                propertyStatus: propertyStatus
            )
        } ?? []
        
        return BleServiceDto(
            serviceUuid: service.uuid.uuidString,
            characteristics: characteristics
        )
    }
    
    /// 检查特征的每个属性状态
    private func checkEachPropertyStatus(_ characteristic: CBCharacteristic, notifyChar: CBCharacteristic? = nil, writeChar: CBCharacteristic? = nil) -> [String: Bool] {
        var propertyStatus: [String: Bool] = [:]
        
        // 只添加支持的属性到 propertyStatus 中
        
        // READ 属性 - 如果支持读取，则添加到状态中
        if characteristic.properties.contains(.read) {
            propertyStatus["READ"] = true
        }
        
        // NOTIFY 属性 - 如果支持通知，检查是否已订阅
        if characteristic.properties.contains(.notify) {
            // 检查订阅缓存中是否有该特征值的 NOTIFY 订阅
            let isNotifySubscribed: Bool = subscriptionCaches.contains { cache in
                cache.characteristic.service?.uuid.uuidString == characteristic.service?.uuid.uuidString &&
                cache.characteristic.uuid.uuidString == characteristic.uuid.uuidString &&
                cache.subscriptionType == "NOTIFY"
            }
            propertyStatus["NOTIFY"] = isNotifySubscribed
        }
        
        // INDICATE 属性 - 如果支持指示，检查是否已订阅
        if characteristic.properties.contains(.indicate) {
            // 检查订阅缓存中是否有该特征值的 INDICATE 订阅
            let isIndicateSubscribed: Bool = subscriptionCaches.contains { cache in
                cache.characteristic.service?.uuid.uuidString == characteristic.service?.uuid.uuidString &&
                cache.characteristic.uuid.uuidString == characteristic.uuid.uuidString &&
                cache.subscriptionType == "INDICATE"
            }
            propertyStatus["INDICATE"] = isIndicateSubscribed
        }
        
        // WRITE 属性 - 如果支持写入，检查是否当前活跃
        if characteristic.properties.contains(.write) {
            // 检查是否当前活跃的写入特征值，或者是专门的写入特征值，并且 writeType 为 DEFAULT
            let isWriteActive = (writeUUID == characteristic.uuid) &&
            (writeType == .withResponse) // WRITE_TYPE_DEFAULT
            propertyStatus["WRITE"] = isWriteActive
        }
        
        // WRITE_WITHOUT_RESPONSE 属性 - 如果支持无响应写入，检查是否当前活跃
        if characteristic.properties.contains(.writeWithoutResponse) {
            // 检查是否当前活跃的写入特征值，或者是专门的写入特征值，并且 writeType 为 NO_RESPONSE
            let isWriteNoRespActive = (writeUUID == characteristic.uuid) &&
            (writeType == .withoutResponse) // WRITE_TYPE_NO_RESPONSE
            propertyStatus["WRITE_WITHOUT_RESPONSE"] = isWriteNoRespActive
        }
        
        
        return propertyStatus
    }
    
    /// 转换特征属性为可读字符串
    private func mapProperties(_ properties: CBCharacteristicProperties) -> [String] {
        var result: [String] = []
        
        if properties.contains(.read) {
            result.append("READ")
        }
        if properties.contains(.write) {
            result.append("WRITE")
        }
        if properties.contains(.notify) {
            result.append("NOTIFY")
        }
        if properties.contains(.indicate) {
            result.append("INDICATE")
        }
        if properties.contains(.writeWithoutResponse) {
            result.append("WRITE_WITHOUT_RESPONSE")
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
    
    // MARK: - BLE 信息变更回调实现
    
    /// 处理 BLE 写入信息变更
    /// - Parameters:
    ///   - characteristicUuid: 特征值 UUID
    ///   - propertyName: 属性名称 (WRITE, WRITE_WITHOUT_RESPONSE)
    ///   - isActive: 是否激活
    func onChangeBleWriteInfo(characteristicUuid: String, propertyName: String, isActive: Bool) {
        
        // 确保在连接状态下才处理
        guard let peripheral = connectedPeripheral, peripheral.state == .connected else {
            return
        }
        
        // 查找对应的特征值
        guard let characteristic = findCharacteristicByUuid(characteristicUuid) else {
            return
        }
        
        // 根据属性名称处理不同的写入类型
        switch propertyName {
        case "WRITE":
            writeType = .withResponse
        case "WRITE_WITHOUT_RESPONSE":
            writeType = .withoutResponse
        default:
            break
        }
        if isActive {
            characteristicForReadWrite = characteristic
            writeUUID = characteristic.uuid
        } else {
            characteristicForReadWrite = nil
            writeUUID = nil
        }
    }
    
    /// 处理 BLE 描述符信息变更
    /// - Parameters:
    ///   - characteristicUuid: 特征值 UUID
    ///   - propertyName: 属性名称 (NOTIFY, INDICATE)
    ///   - isActive: 是否激活
    func onChangeBleDescriptorInfo(characteristicUuid: String, propertyName: String, isActive: Bool) {
        
        // 确保在连接状态下才处理
        guard let peripheral = connectedPeripheral, peripheral.state == .connected else {
            return
        }
        
        // 查找对应的特征值
        guard let characteristic = findCharacteristicByUuid(characteristicUuid) else {
            return
        }
        
        
        // 根据属性名称处理不同的订阅类型
        switch propertyName {
        case "NOTIFY":
            handleNotifyPropertyChange(characteristic: characteristic, isActive: isActive)
        case "INDICATE":
            handleIndicatePropertyChange(characteristic: characteristic, isActive: isActive)
        default:
            break
        }
        
        if characteristic == characteristicForReadWrite {
            notifyUUID = characteristic.uuid
        }
        
    }
    
    // MARK: - 私有辅助方法
    
    /// 根据 UUID 查找特征值
    private func findCharacteristicByUuid(_ uuidString: String) -> CBCharacteristic? {
        guard let peripheral = connectedPeripheral else { return nil }
        
        guard let services = peripheral.services else { return nil }
        
        for service in services {
            guard let characteristics = service.characteristics else { continue }
            
            for characteristic in characteristics {
                if characteristic.uuid.uuidString.lowercased() == uuidString.lowercased() {
                    return characteristic
                }
            }
        }
        
        return nil
    }

    
    /// 处理 NOTIFY 属性变更
    private func handleNotifyPropertyChange(characteristic: CBCharacteristic, isActive: Bool) {
        
        // 更新订阅缓存
        updateSubscriptionCache(characteristic: characteristic, subscriptionType: "NOTIFY", isActive: isActive)
        
        // 执行实际的订阅/取消订阅操作
        Task {
            await performNotificationSubscription(characteristic: characteristic, isActive: isActive)
        }
    }
    
    /// 处理 INDICATE 属性变更
    private func handleIndicatePropertyChange(characteristic: CBCharacteristic, isActive: Bool) {
        
        // 更新订阅缓存
        updateSubscriptionCache(characteristic: characteristic, subscriptionType: "INDICATE", isActive: isActive)
        
        // 执行实际的订阅/取消订阅操作
        Task {
            await performNotificationSubscription(characteristic: characteristic, isActive: isActive)
        }
    }
    
    /// 更新订阅缓存
    private func updateSubscriptionCache(characteristic: CBCharacteristic, subscriptionType: String, isActive: Bool) {
        let cache = SubscriptionCache(characteristic: characteristic, subscriptionType: subscriptionType)
        
        if isActive {
            // 先移除可能存在的旧缓存（相同特征值但不同订阅类型）
            subscriptionCaches.removeAll { existingCache in
                existingCache.characteristic.uuid == characteristic.uuid &&
                existingCache.characteristic.service?.uuid == characteristic.service?.uuid
            }
            
            // 添加新缓存
            subscriptionCaches.append(cache)
        } else {
            // 移除特定特征值和订阅类型的缓存
            if let index = subscriptionCaches.firstIndex(of: cache) {
                subscriptionCaches.remove(at: index)
            }
        }
    }
    
    /// 执行通知订阅操作
    private func performNotificationSubscription(characteristic: CBCharacteristic, isActive: Bool) async {
        guard let peripheral = connectedPeripheral else {
            return
        }
        
        do {
            if isActive {
                // 启用通知
                peripheral.setNotifyValue(true, for: characteristic)
            } else {
                // 禁用通知
                peripheral.setNotifyValue(false, for: characteristic)
            }
        } catch {
        }
    }
}

// MARK: - Data Structures

/// BLE 设备信息
public struct BleDeviceInfo {
    public let broadcastData: BroadcastData?
    public let deviceInfo: BleDeviceInfoDetails?
    public let serviceInfo: [BleServiceDto]
    
    public init(broadcastData: BroadcastData?, deviceInfo: BleDeviceInfoDetails?, serviceInfo: [BleServiceDto]) {
        self.broadcastData = broadcastData
        self.deviceInfo = deviceInfo
        self.serviceInfo = serviceInfo
    }
}

/// 广播数据
public struct BroadcastData {
    public let deviceName: String
    public let txPowerLevel: Int
    public let serviceUuids: [String]
    public let manufacturerData: [String: Data]
    public let isConnect: Bool
    
    public init(deviceName: String, txPowerLevel: Int, serviceUuids: [String], manufacturerData: [String: Data], isConnect: Bool = false) {
        self.deviceName = deviceName
        self.txPowerLevel = txPowerLevel
        self.serviceUuids = serviceUuids
        self.manufacturerData = manufacturerData
        self.isConnect = isConnect
    }
}

/// 设备信息服务中的详细信息
public struct BleDeviceInfoDetails {
    public let manufacturerName: String?
    public let modelNumber: String?
    public let serialNumber: String?
    public let hardwareRevision: String?
    public let firmwareRevision: String?
    public let softwareRevision: String?
    public let systemId: String?
    public let ieeeId: String?
    public let pnpId: String?
    
    public init(manufacturerName: String?, modelNumber: String?, serialNumber: String?, hardwareRevision: String?, firmwareRevision: String?, softwareRevision: String?, systemId: String?, ieeeId: String?, pnpId: String?) {
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

/// 服务信息
public struct BleServiceDto {
    public let serviceUuid: String
    public let characteristics: [BleCharacteristicDto]
    
    public init(serviceUuid: String, characteristics: [BleCharacteristicDto]) {
        self.serviceUuid = serviceUuid
        self.characteristics = characteristics
    }
}

/// 特征信息
public struct BleCharacteristicDto {
    public let characteristicUuid: String
    public let properties: [String]
    public let value: String
    public let propertyStatus: [String: Bool]
    
    public init(characteristicUuid: String, properties: [String], value: String, propertyStatus: [String: Bool]) {
        self.characteristicUuid = characteristicUuid
        self.properties = properties
        self.value = value
        self.propertyStatus = propertyStatus
    }
}
