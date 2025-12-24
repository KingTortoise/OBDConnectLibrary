//
//  BLEManage.swift
//  OBDUpdater
//
//  Created by 金文武 on 2025/7/1.
//

import Foundation
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
    // 客户端配置描述符 UUID（CCCD）
    private let UUID_CCCD = CBUUID(string: "00002902-0000-1000-8000-00805f9b34fb")
     
    // MTU 相关属性
    private var currentMTU: Int = 20 // 默认 MTU 值（BLE 默认是 20 字节）
    private var isMTURequested: Bool = false
    
    private let syncQueue = DispatchQueue(label: "com.bleManage.syncQueue", qos: .userInitiated)
    
    // 当前接收数据流的任务（使用 DispatchWorkItem 替代 Task）
    private var currentReceiveWorkItem: DispatchWorkItem?
    
    // 扫描结果回调（替代 AsyncStream）
    private var scanResultCallback: (([BLEScannedDeviceInfo]) -> Void)?
    private var sendCount = 1
    
    // 设备断开回调
    var onDeviceDisconnect: (() -> Void)?
    
    // 蓝牙状态断开回调
    var onBluetoothDisconnect: (() -> Void)?
    
    // 当前连接设备 RSSI 实时回调（读取到最新 RSSI 时回调一次）
    var onHandleRssiUpdate: ((Int) -> Void)?
    
    // RSSI 定时读取相关属性
    private var rssiReadTimer: Timer?
    private let RSSI_READ_INTERVAL: TimeInterval = 3.0 // RSSI 读取间隔（秒），降低频率避免影响发送/接收
    private let rssiReadQueue = DispatchQueue(label: "com.bleManage.rssiReadQueue", qos: .utility) // RSSI 读取专用队列
    private var isRssiReading = false // RSSI 读取状态标志，防止重复读取
    
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
    
    func waitForBluetoothPoweredOn(timeout: TimeInterval = 5.0, completion: @escaping (Bool) -> Void) {
        wait(unit: { [weak self] in
            self?.centralManager.state == .poweredOn
        }, timeout: timeout, completion: completion)
    }
    
    func waitForSearchPeripheral(timeout: TimeInterval = 5.0, completion: @escaping (Bool) -> Void) {
        wait(unit: { [weak self] () -> Bool in
            return self?.syncQueue.sync {
                self?.connectedPeripheral != nil
            } ?? false
        }, timeout: timeout, completion: completion)
    }
    
    func waitForConnectState(timeout: TimeInterval = 5.0, completion: @escaping (Bool) -> Void) {
        wait(unit: { [weak self] in
            return self?.syncQueue.sync {
                self?.connectedPeripheral?.state == .connected
            } ?? false
        }, timeout: timeout, completion: completion)
    }
    
    func waitForReadWrite(timeout: TimeInterval = 5.0, completion: @escaping (Bool) -> Void) {
        wait(unit: { [weak self] in
            return self?.syncQueue.sync {
                self?.characteristicForReadWrite != nil
            } ?? false
        }, timeout: timeout, completion: completion)
    }
    
    func waitForReadData(timeout: TimeInterval = 5.0, completion: @escaping (Bool) -> Void) {
        wait(unit: { [weak self] in
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
        }, timeout: timeout, completion: completion)
    }
    
    func waitForActualPeripheralConnection(peripheral: CBPeripheral, timeout: TimeInterval = 5.0, completion: @escaping (Bool) -> Void) {
        wait(unit: { [weak self] in
            guard let self = self else { return false }
            let isConnected = self.syncQueue.sync {
                let state = peripheral.state
                if state != .connected {
                }
                return state == .connected
            }
            return isConnected
        }, timeout: timeout, completion: completion)
    }
    
    func open(peripheral: CBPeripheral?, completion: @escaping (Result<Void, ConnectError>) -> Void) {
        let connectState = syncQueue.sync { state }
        if connectState == .connected {
            completion(.success(()))
            return
        }
        if connectState == .connecting {
            completion(.failure(.connecting))
            return
        }
        
        guard let peripheral = peripheral else {
            completion(.failure(.invalidData))
            return
        }
        
        waitForBluetoothPoweredOn { [weak self] success in
            guard let self = self else {
                completion(.failure(.connectionFailed(NSError(domain: "BLEManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"]))))
                return
            }
            
            guard success else {
                self.syncQueue.sync {
                    self.state = .disconnected
                }
                completion(.failure(.btUnEnable))
                return
            }
            
            self.syncQueue.sync {
                self.state = .connecting
                self.connectedPeripheral = peripheral
                self.targetPeripheral = peripheral // 保存目标设备用于重连
                self.centralManager.connect(peripheral, options: nil)
            }
            
            self.waitForConnectState { [weak self] success in
                guard let self = self else {
                    completion(.failure(.connectionFailed(NSError(domain: "BLEManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"]))))
                    return
                }
                
                guard success else {
                    self.syncQueue.sync {
                        // 连接失败时直接清理状态，不调用cancelPeripheralConnection避免触发断开回调
                        self.connectedPeripheral = nil
                        self.state = .disconnected
                    }
                    completion(.failure(.connectionFailed(NSError(domain: "BLEManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No status change notification received."]))))
                    return
                }
                
                self.waitForReadWrite { [weak self] success in
                    guard let self = self else {
                        completion(.failure(.connectionFailed(NSError(domain: "BLEManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"]))))
                        return
                    }
                    
                    guard success else {
                        self.syncQueue.sync {
                            // 连接失败时直接清理状态，不调用cancelPeripheralConnection避免触发断开回调
                            self.connectedPeripheral = nil
                            self.characteristicForReadWrite = nil
                            self.state = .disconnected
                        }
                        completion(.failure(.connectionFailed(NSError(domain: "BLEManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No characteristics found."]))))
                        return
                    }
                    
                    // 关键修复：验证 peripheral 实际连接状态
                    self.waitForActualPeripheralConnection(peripheral: peripheral, timeout: 5.0) { [weak self] success in
                        guard let self = self else {
                            completion(.failure(.connectionFailed(NSError(domain: "BLEManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"]))))
                            return
                        }
                        
                        guard success else {
                            self.syncQueue.sync {
                                self.connectedPeripheral = nil
                                self.characteristicForReadWrite = nil
                                self.state = .disconnected
                            }
                            completion(.failure(.connectionFailed(NSError(domain: "BLEManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Peripheral did not reach connected state"]))))
                            return
                        }
                        
                        // 获取并保存 MTU 值
                        self.updateMTUValue()
                        
                        self.syncQueue.sync {
                            self.state = .connected
                            self.targetPeripheral = peripheral // 连接成功时更新目标设备
                        }
                        
                        // 启动 RSSI 定时读取
                        self.startRssiReading()
                        
                        // 异步获取设备信息（不阻塞连接成功返回）
                        DispatchQueue.global(qos: .background).async { [weak self] in
                            guard let self = self else { return }
                            self.getBleDeviceInfo { _ in
                                // 设备信息获取完成，不需要处理结果
                            }
                        }
                        
                        completion(.success(()))
                    }
                }
            }
        }
    }
    
    // 更新 MTU 值
    private func updateMTUValue() {
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
            print("aaaaa-send\(Int64(Date().timeIntervalSince1970 * 1_000_000))")
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
    
    
    func read(timeout: TimeInterval, completion: @escaping (Result<Data, ConnectError>) -> Void) {
        let (currentState, characteristic) = syncQueue.sync {
            (state, characteristicForReadWrite)
        }
        guard currentState == .connected, centralManager.state == CBManagerState.poweredOn, characteristic != nil else {
            clenReceiveInfo()
            completion(.failure(.notConnected))
            return
        }
        waitForReadData(timeout: timeout) { [weak self] success in
            guard let self = self else {
                completion(.failure(.connectionFailed(NSError(domain: "BLEManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"]))))
                return
            }
            guard success else {
                self.clenReceiveInfo()
                completion(.failure(.receiveTimeout))
                return
            }
            completion(.success(self.dataForRead))
        }
    }
    
    // 数据流读取方法（使用回调替代 AsyncStream）
    func receiveDataFlow(callback: @escaping (Data) -> Void, onFinish: @escaping () -> Void) {
        // 取消之前的任务
        currentReceiveWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else {
                onFinish()
                return
            }
            
            let currentState = self.syncQueue.sync {
                return self.state
            }
            
            if currentState != .connected {
                onFinish()
                return
            }
            
            let pollingQueue = DispatchQueue(label: "com.bleManage.receivePolling", qos: .userInitiated)
            var isCancelled = false
            
            func pollData() {
                guard !isCancelled else {
                    self.syncQueue.async {
                        self.readDataQueue.removeAll()
                    }
                    onFinish()
                    return
                }
                
                let (hasData, batch) = self.syncQueue.sync {
                    let data = self.readDataQueue
                    let hasData = !data.isEmpty
                    if hasData {
                        self.readDataQueue.removeAll()
                    }
                    return (hasData, data)
                }
                
                if hasData {
                    sendCount += 1
                    print("aaaaa-receiveSendData\(Int64(Date().timeIntervalSince1970 * 1_000_000))")
                    callback(batch)
                }
                
                // 继续轮询（0.1ms 延迟）
                pollingQueue.asyncAfter(deadline: .now() + 0.0001) {
                    pollData()
                }
            }
            
            pollData()
            
            // 保存 workItem 以便后续可以取消
            self.currentReceiveWorkItem = DispatchWorkItem {
                isCancelled = true
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
        currentReceiveWorkItem = workItem
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
            self.currentReceiveWorkItem?.cancel()
            self.currentReceiveWorkItem = nil
            
            // 停止 RSSI 定时读取
            self.stopRssiReading()
            
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
    func startScan(completion: @escaping (Bool) -> Void) {
        // 等待蓝牙状态就绪
        waitForBluetoothPoweredOn { [weak self] success in
            guard let self = self else {
                completion(false)
                return
            }
            
            guard success else {
                completion(false)
                return
            }
            
            // 清空之前的设备列表
            self.syncQueue.sync {
                self.discoveredDevices.removeAll()
            }
            
            // 开始扫描BLE设备
            self.syncQueue.sync {
                // 停止之前的扫描
                self.centralManager.stopScan()
                // 开始新的扫描 - 扫描所有外设
                // 扫描所有外设，允许重复发现以获取更多设备
                self.centralManager.scanForPeripherals(withServices: nil, options: [
                    CBCentralManagerScanOptionAllowDuplicatesKey: true
                ])
            }
            
            completion(true)
        }
    }
    
    // 设置扫描结果回调（替代 AsyncStream）
    func setScanResultCallback(_ callback: @escaping ([BLEScannedDeviceInfo]) -> Void) {
        syncQueue.sync {
            self.scanResultCallback = callback
        }
    }
    
    // 停止扫描BLE设备
    func stopScan() {
        syncQueue.sync {
            self.centralManager.stopScan()
            self.scanResultCallback = nil
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
            
            // 只有在需要更新时才调用回调
            if shouldUpdate {
                if let callback = self.scanResultCallback {
                    DispatchQueue.main.async {
                        callback(self.discoveredDevices)
                    }
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
            self.currentReceiveWorkItem?.cancel()
            self.currentReceiveWorkItem = nil
            self.state = .disconnected
            self.subscriptionCaches.removeAll()
            
            // 停止 RSSI 定时读取
            self.stopRssiReading()
            
            // 触发设备断开回调
            DispatchQueue.main.async {
                self.onDeviceDisconnect?()
            }
        }
    }
    
    // 主动读取当前连接设备的 RSSI
    // 注意：此方法只是触发一次读取，真正的 RSSI 数值会在 didReadRSSI 回调中通过 onHandleRssiUpdate 返回
    func readCurrentRssi() {
        // 使用独立的 RSSI 读取队列，避免与发送/接收操作冲突
        rssiReadQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 防止重复读取（如果上一次读取还未完成，跳过本次读取）
            guard !self.isRssiReading else {
                return
            }
            
            // 检查连接状态（使用 syncQueue 同步访问 connectedPeripheral）
            let peripheral = self.syncQueue.sync { self.connectedPeripheral }
            guard let peripheral = peripheral, peripheral.state == .connected else {
                return
            }
            
            // 设置读取标志
            self.isRssiReading = true
            
            // 触发系统去读取当前 RSSI，读取结果会异步回调到 didReadRSSI
            // 注意：readRSSI() 必须在主线程或蓝牙队列中调用
            DispatchQueue.main.async {
                peripheral.readRSSI()
            }
        }
    }
    
    /// 启动 RSSI 定时读取（连接成功后自动调用）
    private func startRssiReading() {
        stopRssiReading() // 先停止之前的定时器
        
        // 在主线程创建定时器（Timer 需要在主线程创建）
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // 创建定时器，每隔 RSSI_READ_INTERVAL 秒读取一次 RSSI
            self.rssiReadTimer = Timer.scheduledTimer(withTimeInterval: self.RSSI_READ_INTERVAL, repeats: true) { [weak self] _ in
                self?.readCurrentRssi()
            }
            
            // 立即读取一次 RSSI
            self.readCurrentRssi()
        }
    }
    
    /// 停止 RSSI 定时读取（断开连接时自动调用）
    private func stopRssiReading() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.rssiReadTimer?.invalidate()
            self.rssiReadTimer = nil
        }
        // 重置读取标志
        isRssiReading = false
    }
    
    /// 设置 RSSI 更新回调（与 Android 版本一致）
    /// - Parameter callback: RSSI 更新时的回调函数，参数为 RSSI 值（Int）
    func setOnBleRssiUpdate(_ callback: @escaping (Int) -> Void) {
        self.onHandleRssiUpdate = callback
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
    
    // 读取 RSSI 完成后的回调
    // 每次调用 readRSSI() 后，系统会异步回调到这里
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: (any Error)?) {
        // 重置读取标志
        isRssiReading = false
        
        if let _ = error {
            return
        }
        
        // 将读取到的 RSSI 通过外部回调抛出，方便上层实时展示信号强度
        let rssiValue = RSSI.intValue
        DispatchQueue.main.async { [weak self] in
            self?.onHandleRssiUpdate?(rssiValue)
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
            
            // 确保是当前连接的外设
            guard self.connectedPeripheral == peripheral else {
                return
            }
            
            // 根据订阅缓存判断是否是已订阅的通知特征值（实时反映订阅状态，这是主要判断逻辑）
            let isSubscribedNotifyCharacteristic = self.subscriptionCaches.contains { cache in
                cache.characteristic.uuid == characteristic.uuid &&
                cache.characteristic.service?.uuid == characteristic.service?.uuid &&
                (cache.subscriptionType == "NOTIFY" || cache.subscriptionType == "INDICATE")
            }
            
            if isSubscribedNotifyCharacteristic {
                // 该特征值已订阅通知，处理接收到的数据
                if let value = characteristic.value {
                    self.dataForRead.append(value)
                    print("aaaaa-receive\(Int64(Date().timeIntervalSince1970 * 1_000_000))")
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
    func reconnect(completion: @escaping (Result<Void, ConnectError>) -> Void) {
        // 检查是否已连接或正在重连
        let currentState = syncQueue.sync { state }
        
        if currentState == .connected {
            completion(.success(()))
            return
        }
        if currentState == .connecting {
            completion(.failure(.connecting))
            return
        }
        
        // 检查蓝牙是否可用
        waitForBluetoothPoweredOn { [weak self] success in
            guard let self = self else {
                completion(.failure(.connectionFailed(NSError(domain: "BLEManage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"]))))
                return
            }
            
            guard success else {
                completion(.failure(.btUnEnable))
                return
            }
            
            // 检查是否有目标设备
            guard let targetPeripheral = self.syncQueue.sync(execute: { self.targetPeripheral }) else {
                completion(.failure(.connectionFailed(NSError(domain: "BLEManage", code: -1, userInfo: [NSLocalizedDescriptionKey: "No target device for reconnection"]))))
                return
            }
            
            self.subscriptionCaches.removeAll()
            // 执行带重试的重连逻辑
            self.performReconnect(peripheral: targetPeripheral, timeout: 30.0, completion: completion)
        }
    }
    
    /// 带重试机制的重连实现
    private func performReconnect(peripheral: CBPeripheral, timeout: TimeInterval, completion: @escaping (Result<Void, ConnectError>) -> Void) {
        // 重置重连次数（避免累计旧次数）
        reconnectAttempts = 0
        
        func attemptReconnect() {
            guard reconnectAttempts < MAX_RECONNECT_ATTEMPTS else {
                reconnectAttempts = 0
                syncQueue.sync {
                    self.state = .disconnected
                }
                completion(.failure(.connectionFailed(NSError(domain: "BLEManage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Max reconnection attempts reached"]))))
                return
            }
            
            reconnectAttempts += 1
            let currentAttempt = reconnectAttempts
            
            // 执行单次重连
            self.open(peripheral: peripheral) { [weak self] result in
                guard let self = self else {
                    completion(.failure(.connectionFailed(NSError(domain: "BLEManage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"]))))
                    return
                }
                
                if case .success = result {
                    // 重连成功：验证连接状态是否真正可用
                    self.validateConnection(peripheral: peripheral) { [weak self] isValid in
                        guard let self = self else {
                            completion(.failure(.connectionFailed(NSError(domain: "BLEManage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"]))))
                            return
                        }
                        
                        if isValid {
                            self.reconnectAttempts = 0
                            completion(.success(()))
                        } else {
                            // 如果验证失败，确保状态为 disconnected
                            self.syncQueue.sync {
                                self.state = .disconnected
                            }
                            completion(.failure(.connectionFailed(NSError(domain: "BLEManage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Connection validation failed"]))))
                        }
                    }
                } else {
                    // 重连失败：延迟后继续重连（指数退避）
                    let delayMillis = self.INITIAL_RECONNECT_DELAY * pow(2.0, Double(currentAttempt - 1)) // 1s→2s→4s...
                    DispatchQueue.global().asyncAfter(deadline: .now() + delayMillis) {
                        attemptReconnect()
                    }
                }
            }
        }
        
        attemptReconnect()
    }
    
    /// 验证连接状态是否真正可用
    private func validateConnection(peripheral: CBPeripheral, completion: @escaping (Bool) -> Void) {
        // 检查 peripheral 状态
        guard peripheral.state == .connected else {
            completion(false)
            return
        }
        
        // 检查特征值是否可用
        let characteristic = syncQueue.sync { characteristicForReadWrite }
        guard characteristic != nil else {
            completion(false)
            return
        }
        
        // 检查 BLE 管理器状态
        let managerState = syncQueue.sync { state }
        guard managerState == .connected else {
            completion(false)
            return
        }
        completion(true)
    }
    
    // MARK: - Device Info Collection
    
    /// 获取 BLE 设备信息（按照 Kotlin 逻辑实现）
    func getBleDeviceInfo(completion: @escaping (BleDeviceInfo) -> Void) {
        // 1. 收集广播数据
        if broadcastData == nil {
            collectBroadcastData { [weak self] in
                guard let self = self else { return }
                // 2. 收集设备信息服务
                if self.deviceInfo == nil {
                    self.collectDeviceInfoService { [weak self] in
                        guard let self = self else { return }
                        // 3. 收集服务特征值信息
                        self.collectServiceCharacteristics { [weak self] in
                            guard let self = self else { return }
                            let result = BleDeviceInfo(
                                broadcastData: self.broadcastData,
                                deviceInfo: self.deviceInfo,
                                serviceInfo: self.serviceList
                            )
                            completion(result)
                        }
                    }
                } else {
                    // 3. 收集服务特征值信息
                    self.collectServiceCharacteristics { [weak self] in
                        guard let self = self else { return }
                        let result = BleDeviceInfo(
                            broadcastData: self.broadcastData,
                            deviceInfo: self.deviceInfo,
                            serviceInfo: self.serviceList
                        )
                        completion(result)
                    }
                }
            }
        } else {
            // 2. 收集设备信息服务
            if deviceInfo == nil {
                collectDeviceInfoService { [weak self] in
                    guard let self = self else { return }
                    // 3. 收集服务特征值信息
                    self.collectServiceCharacteristics { [weak self] in
                        guard let self = self else { return }
                        let result = BleDeviceInfo(
                            broadcastData: self.broadcastData,
                            deviceInfo: self.deviceInfo,
                            serviceInfo: self.serviceList
                        )
                        completion(result)
                    }
                }
            } else {
                // 3. 收集服务特征值信息
                collectServiceCharacteristics { [weak self] in
                    guard let self = self else { return }
                    let result = BleDeviceInfo(
                        broadcastData: self.broadcastData,
                        deviceInfo: self.deviceInfo,
                        serviceInfo: self.serviceList
                    )
                    completion(result)
                }
            }
        }
    }
    
    /// 收集广播数据
    private func collectBroadcastData(completion: @escaping () -> Void) {
        
        // 从扫描结果中获取目标设备的广播数据
        let targetDevice = syncQueue.sync { targetPeripheral }
        guard let peripheral = targetDevice else {
            completion()
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
        
        completion()
    }
    
    /// 收集设备信息服务
    private func collectDeviceInfoService(completion: @escaping () -> Void) {
        
        guard let peripheral = syncQueue.sync(execute: { connectedPeripheral }) else {
            completion()
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
            let characteristics = deviceInfoService.characteristics ?? []
            var remainingCharacteristics = characteristics.filter { char in
                [MANUFACTURER_NAME_UUID, MODEL_NUMBER_UUID, SERIAL_NUMBER_UUID, HARDWARE_REVISION_UUID,
                 FIRMWARE_REVISION_UUID, SOFTWARE_REVISION_UUID, SYSTEM_UUID, IEEE_UUID, PnP_UUID].contains(char.uuid)
            }
            
            func readNextCharacteristic() {
                guard let characteristic = remainingCharacteristics.first else {
                    // 所有特征值读取完成
                    // 确保至少有一些基本信息
                    if manufacturerName == nil {
                        manufacturerName = "Unknown Manufacturer"
                    }
                    
                    self.deviceInfo = BleDeviceInfoDetails(
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
                    completion()
                    return
                }
                
                remainingCharacteristics.removeFirst()
                
                self.readCharacteristic(peripheral, characteristic) { [weak self] value in
                    guard let self = self else {
                        completion()
                        return
                    }
                    
                    // 根据特征值UUID设置对应的值
                    switch characteristic.uuid {
                    case self.MANUFACTURER_NAME_UUID:
                        manufacturerName = value ?? ""
                    case self.MODEL_NUMBER_UUID:
                        modelNumber = value
                    case self.SERIAL_NUMBER_UUID:
                        serialNumber = value
                    case self.HARDWARE_REVISION_UUID:
                        hardwareRevision = value
                    case self.FIRMWARE_REVISION_UUID:
                        firmwareRevision = value
                    case self.SOFTWARE_REVISION_UUID:
                        softwareRevision = value
                    case self.SYSTEM_UUID:
                        systemId = value
                    case self.IEEE_UUID:
                        ieeeId = value
                    case self.PnP_UUID:
                        pnpId = value
                    default:
                        break
                    }
                    
                    // 继续读取下一个特征值
                    readNextCharacteristic()
                }
            }
            
            readNextCharacteristic()
        } else {
            // 如果没有标准设备信息服务，提供一些基本信息
            if manufacturerName == nil {
                manufacturerName = "Unknown Manufacturer"
            }
            modelNumber = peripheral.name ?? "Unknown Model"
            serialNumber = "UUID: \(peripheral.identifier.uuidString)"
            
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
            completion()
        }
    }
    
    /// 收集服务特征值信息
    private func collectServiceCharacteristics(completion: @escaping () -> Void) {
        
        guard let peripheral = syncQueue.sync(execute: { connectedPeripheral }) else {
            completion()
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
        
        completion()
    }
    
    /// 读取单个特征值
    private func readCharacteristic(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic?, completion: @escaping (String?) -> Void) {
        guard let characteristic = characteristic else {
            completion(nil)
            return
        }
        
        // 检查特征值是否支持读取
        guard characteristic.properties.contains(.read) else {
            completion(nil)
            return
        }
        
        // 如果特征值已经有缓存的值，直接使用
        if let value = characteristic.value, !value.isEmpty {
            let result = parseCharacteristicValue(value, for: characteristic.uuid)
            completion(result)
            return
        }
        
        // 使用 peripheral.readValue 进行异步读取
        peripheral.readValue(for: characteristic)
        
        // 等待读取完成（延迟后检查值）
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }
            
            if let value = characteristic.value, !value.isEmpty {
                let result = self.parseCharacteristicValue(value, for: characteristic.uuid)
                completion(result)
            } else {
                // 如果0.5秒后还没有值，再等1.5秒
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self = self else {
                        completion(nil)
                        return
                    }
                    
                    if let value = characteristic.value, !value.isEmpty {
                        let result = self.parseCharacteristicValue(value, for: characteristic.uuid)
                        completion(result)
                    } else {
                        completion(nil)
                    }
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
    
    /// 检查特征的每个属性状态（确保线程安全）
    private func checkEachPropertyStatus(_ characteristic: CBCharacteristic, notifyChar: CBCharacteristic? = nil, writeChar: CBCharacteristic? = nil) -> [String: Bool] {
        return syncQueue.sync {
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
                // 检查是否当前活跃的写入特征值，并且 writeType 为 withResponse
                let isWriteActive = (writeUUID == characteristic.uuid) &&
                (writeType == .withResponse) // WRITE_TYPE_DEFAULT
                propertyStatus["WRITE"] = isWriteActive
            }
            
            // WRITE_WITHOUT_RESPONSE 属性 - 如果支持无响应写入，检查是否当前活跃
            if characteristic.properties.contains(.writeWithoutResponse) {
                // 检查是否当前活跃的写入特征值，并且 writeType 为 withoutResponse
                let isWriteNoRespActive = (writeUUID == characteristic.uuid) &&
                (writeType == .withoutResponse) // WRITE_TYPE_NO_RESPONSE
                propertyStatus["WRITE_WITHOUT_RESPONSE"] = isWriteNoRespActive
            }
            
            return propertyStatus
        }
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
    ///   - characteristicUuid: 特征值 UUID 字符串
    ///   - propertyName: 属性名称 (NOTIFY, INDICATE)
    ///   - isActive: 是否激活
    func onChangeBleDescriptorInfo(characteristicUuid: String, propertyName: String, isActive: Bool) {
        // 确保在连接状态下才处理
        guard let peripheral = syncQueue.sync(execute: { connectedPeripheral }), peripheral.state == .connected else {
            return
        }
        
        // 查找对应的特征值
        guard let characteristic = findCharacteristicByUuid(characteristicUuid) else {
            return
        }
        
        // 根据属性名称处理不同的订阅类型
        switch propertyName {
        case "NOTIFY":
            // 先同步更新缓存（与 Android 版本一致，立即更新缓存）
            updateSubscriptionCache(characteristic: characteristic, subscriptionType: "NOTIFY", isActive: isActive)
            // 然后执行异步的订阅操作
            handleNotifyPropertyChange(characteristic: characteristic, isActive: isActive)
            
        case "INDICATE":
            // 先同步更新缓存（与 Android 版本一致，立即更新缓存）
            updateSubscriptionCache(characteristic: characteristic, subscriptionType: "INDICATE", isActive: isActive)
            // 然后执行异步的订阅操作
            handleIndicatePropertyChange(characteristic: characteristic, isActive: isActive)
            
        default:
            break
        }
        
        // 更新 notifyUUID（确保切换订阅状态时 notifyUUID 正确更新）
        syncQueue.sync {
            if isActive {
                // 开启订阅时，如果该特征值是当前读写特征值，更新 notifyUUID
                if characteristic == characteristicForReadWrite {
                    notifyUUID = characteristic.uuid
                }
            } else {
                // 关闭订阅时，如果该特征值是当前的 notifyUUID，清空 notifyUUID
                if notifyUUID == characteristic.uuid {
                    notifyUUID = nil
                }
            }
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
        // 注意：缓存更新已在 onChangeBleDescriptorInfo 中完成，这里只执行实际的订阅操作
        performNotificationSubscription(characteristic: characteristic, isActive: isActive)
    }
    
    /// 处理 INDICATE 属性变更
    private func handleIndicatePropertyChange(characteristic: CBCharacteristic, isActive: Bool) {
        // 注意：缓存更新已在 onChangeBleDescriptorInfo 中完成，这里只执行实际的订阅操作
        performNotificationSubscription(characteristic: characteristic, isActive: isActive)
    }
    
    /// 更新订阅缓存（确保线程安全）
    /// - Parameters:
    ///   - characteristic: 特征值对象
    ///   - subscriptionType: 订阅类型（"NOTIFY" 或 "INDICATE"）
    ///   - isActive: 是否激活
    private func updateSubscriptionCache(characteristic: CBCharacteristic, subscriptionType: String, isActive: Bool) {
        syncQueue.sync {
            let charUuid = characteristic.uuid.uuidString
            let serviceUuid = characteristic.service?.uuid.uuidString ?? ""
            
            if isActive {
                // 先移除可能存在的旧缓存（相同特征值但不同订阅类型）
                let beforeCount = subscriptionCaches.count
                subscriptionCaches.removeAll { existingCache in
                    existingCache.characteristic.uuid.uuidString == charUuid &&
                    existingCache.characteristic.service?.uuid.uuidString == serviceUuid
                }
                
                // 添加新缓存
                let cache = SubscriptionCache(characteristic: characteristic, subscriptionType: subscriptionType)
                subscriptionCaches.append(cache)
                
                print("✅ [缓存更新] 开启订阅: \(charUuid) - \(subscriptionType), 移除 \(beforeCount - subscriptionCaches.count + 1) 个旧缓存，当前缓存数: \(subscriptionCaches.count)")
            } else {
                // 移除特定特征值和订阅类型的缓存（与 Android 版本一致：移除所有匹配 UUID 的缓存）
                let beforeCount = subscriptionCaches.count
                subscriptionCaches.removeAll { existingCache in
                    existingCache.characteristic.uuid.uuidString == charUuid &&
                    existingCache.characteristic.service?.uuid.uuidString == serviceUuid &&
                    existingCache.subscriptionType == subscriptionType
                }
                
                print("✅ [缓存更新] 关闭订阅: \(charUuid) - \(subscriptionType), 移除 \(beforeCount - subscriptionCaches.count) 个缓存，当前缓存数: \(subscriptionCaches.count)")
            }
        }
    }
    
    /// 执行通知订阅操作
    /// 注意：在 iOS 中，CCCD 必须通过 setNotifyValue 来配置，不能直接写入描述符
    private func performNotificationSubscription(characteristic: CBCharacteristic, isActive: Bool) {
        guard let peripheral = syncQueue.sync(execute: { connectedPeripheral }) else {
            return
        }
        
        // 在 iOS 中，setNotifyValue 会自动处理 CCCD 的写入，不需要也不能手动写入描述符
        peripheral.setNotifyValue(isActive, for: characteristic)
    }
    
    /// 处理通知状态更新回调（当 setNotifyValue 完成时调用）
    /// 这个回调用于确保缓存状态与实际 BLE 状态一致
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let charUuid = characteristic.uuid.uuidString
        let subscriptionType = characteristic.properties.contains(.notify) ? "NOTIFY" : "INDICATE"
        
        syncQueue.sync {
            if let error = error {
                // 如果操作失败，需要回滚缓存（因为我们在 onChangeBleDescriptorInfo 中已经更新了缓存）
                print("❌ [通知状态更新失败] \(charUuid) - \(subscriptionType): \(error.localizedDescription)")
                
                // 检查当前缓存状态，如果与实际状态不一致，需要修正
                let hasCache = subscriptionCaches.contains { cache in
                    cache.characteristic.uuid.uuidString == charUuid &&
                    cache.characteristic.service?.uuid.uuidString == characteristic.service?.uuid.uuidString &&
                    cache.subscriptionType == subscriptionType
                }
                
                // 如果实际状态是启用的，但缓存中没有，说明操作失败，需要回滚
                if characteristic.isNotifying && !hasCache {
                    // 操作失败，但实际状态是启用的，说明之前的状态是启用的，不需要回滚
                    print("⚠️ [通知状态回调] 操作失败但实际状态仍为启用，保持当前状态")
                } else if !characteristic.isNotifying && hasCache {
                    // 操作失败，但实际状态是禁用的，说明操作可能部分成功，移除缓存
                    subscriptionCaches.removeAll { cache in
                        cache.characteristic.uuid.uuidString == charUuid &&
                        cache.characteristic.service?.uuid.uuidString == characteristic.service?.uuid.uuidString &&
                        cache.subscriptionType == subscriptionType
                    }
                    print("⚠️ [通知状态回调] 操作失败但实际状态为禁用，移除缓存")
                }
                return
            }
            
            // 操作成功，根据实际状态同步缓存
            let isNotifying = characteristic.isNotifying
            let hasCache = subscriptionCaches.contains { cache in
                cache.characteristic.uuid.uuidString == charUuid &&
                cache.characteristic.service?.uuid.uuidString == characteristic.service?.uuid.uuidString &&
                cache.subscriptionType == subscriptionType
            }
            
            if isNotifying && !hasCache {
                // 实际状态是启用，但缓存中没有，添加缓存
                let cache = SubscriptionCache(characteristic: characteristic, subscriptionType: subscriptionType)
                subscriptionCaches.append(cache)
                print("✅ [通知状态回调] 操作成功，添加缓存: \(charUuid) - \(subscriptionType)")
            } else if !isNotifying && hasCache {
                // 实际状态是禁用，但缓存中有，移除缓存
                subscriptionCaches.removeAll { cache in
                    cache.characteristic.uuid.uuidString == charUuid &&
                    cache.characteristic.service?.uuid.uuidString == characteristic.service?.uuid.uuidString &&
                    cache.subscriptionType == subscriptionType
                }
                print("✅ [通知状态回调] 操作成功，移除缓存: \(charUuid) - \(subscriptionType)")
            } else {
                // 状态一致，无需更新
                print("✅ [通知状态回调] 状态一致: \(charUuid) - \(subscriptionType) = \(isNotifying)")
            }
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
