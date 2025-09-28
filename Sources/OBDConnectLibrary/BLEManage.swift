//
//  BLEManage.swift
//  OBDUpdater
//
//  Created by 金文武 on 2025/7/1.
//

import SwiftUI
@preconcurrency
import CoreBluetooth


struct UUIDs {
    static let readWriteService = "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"
    static let readWrite = "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F"
}
//fileprivate let ISSC_READ_WRITE_SERVICE_UUID = CBUUID(string: "18F0")
//fileprivate let ISSC_READ_WRITE_CHARACTERISTIC_UUIT = CBUUID(string: "2AF0")

// 设备信息结构体，包含 peripheral 和 RSSI
struct BLEDeviceInfo {
    let peripheral: CBPeripheral
    let rssi: Int
    let lastUpdateTime: Date
    let updateCount: Int
}

final class BLEManage: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate,@unchecked Sendable {
    
    // 蓝牙中央管理器
    private var centralManager: CBCentralManager!
    // 当前连接的外设
    private var connectedPeripheral: CBPeripheral?
    // 所有发现的外设信息（包含RSSI）
    private var discoveredDevices: [BLEDeviceInfo] = []
    
    private var characteristicForReadWrite: CBCharacteristic?
    private var state: State = .disconnected
    private var dataForRead = Data()
    private var readDataQueue = Data()
    
    // MTU 相关属性
    private var currentMTU: Int = 20 // 默认 MTU 值（BLE 默认是 20 字节）
    private var isMTURequested: Bool = false
    
    private let syncQueue = DispatchQueue(label: "com.bleManage.syncQueue")
    
    // 当前接收数据流的任务
    @available(iOS 13.0, *)
    private var currentReceiveTask: Task<Void, Never>?
    
    // 扫描结果数据流
    @available(iOS 13.0, *)
    private var scanResultContinuation: AsyncStream<[BLEDeviceInfo]>.Continuation?
    @available(iOS 13.0, *)
    private var scanResultStream: AsyncStream<[BLEDeviceInfo]>?
    
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
        print("⏱️ BLE 开始等待peripheral状态变为connected，当前状态: \(peripheral.state.rawValue)")
        let result = await wait(unit: { [weak self] in
            guard let self = self else { return false }
            let isConnected = self.syncQueue.sync {
                let state = peripheral.state
                if state != .connected {
                    print("⏱️ BLE 等待中，peripheral状态: \(state.rawValue)")
                }
                return state == .connected
            }
            return isConnected
        }, timeout: timeout)
        print("⏱️ BLE peripheral状态等待结果: \(result)")
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
        print("⏱️ BLE 开始验证peripheral连接状态，当前状态: \(peripheral.state.rawValue)")
        let peripheralConnected = await waitForActualPeripheralConnection(peripheral: peripheral, timeout: 5.0)
        guard peripheralConnected else {
            print("⏱️ BLE peripheral连接验证失败，当前状态: \(peripheral.state.rawValue)")
            syncQueue.sync {
                self.connectedPeripheral = nil
                self.characteristicForReadWrite = nil
                self.state = .disconnected
            }
            return .failure(.connectionFailed(NSError(domain: "BLEManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Peripheral did not reach connected state"])))
        }
        print("⏱️ BLE peripheral连接验证成功，状态: \(peripheral.state.rawValue)")
        
        // 获取并保存 MTU 值
        await updateMTUValue()
        
        syncQueue.sync {
            self.state = .connected
            self.targetPeripheral = peripheral // 连接成功时更新目标设备
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
        
        print("BLE MTU 协商完成，当前 MTU 值: \(mtuValue) 字节")
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
    
    func write(data: Data, timeout: TimeInterval) async -> Result<Void, ConnectError> {
        let (currentState, characteristic, mtu, peripheral) = syncQueue.sync {
            (state, characteristicForReadWrite, currentMTU, connectedPeripheral)
        }
        
        // 增强状态检查：检查 BLE 状态、连接状态和 peripheral 状态
        guard currentState == .connected, 
              centralManager.state == CBManagerState.poweredOn, 
              characteristic != nil,
              let peripheral = peripheral else {
            print("⏱️ BLE 写入失败: 基础状态检查失败 - state: \(currentState), centralManager状态: \(centralManager.state.rawValue), peripheral: \(peripheral != nil)")
            return .failure(.notConnected)
        }
        
        // 检查 peripheral 状态，如果未连接则更新内部状态
        if peripheral.state != .connected {
            print("⏱️ BLE 写入失败: peripheral状态未连接 - 当前状态: \(peripheral.state.rawValue)")
            
            // 如果 peripheral 状态不是 connected，说明连接已断开
            // 更新内部状态为 disconnected
            syncQueue.sync {
                self.state = .disconnected
                self.connectedPeripheral = nil
                self.characteristicForReadWrite = nil
            }
            
            print("⏱️ BLE 检测到连接断开，更新内部状态为 disconnected")
            return .failure(.notConnected)
        }
        guard !data.isEmpty else {
            // 空数据视为发送成功
            return .success(())
        }
        
        // 检查数据长度是否超过 MTU
        if data.count <= mtu {
            // 数据长度在 MTU 范围内，直接发送
            peripheral.writeValue(data, for: characteristic!, type: CBCharacteristicWriteType.withoutResponse)
            let currentTime = CFAbsoluteTimeGetCurrent()
            let date = Date(timeIntervalSince1970: currentTime)
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let timeString = formatter.string(from: date)
            print("⏱️ BLE 写入成功: \(data.count) 字节 - 时间: \(timeString)")
            return .success(())
        } else {
            // 数据长度超过 MTU，需要分段发送
            return await sendDataInChunks(data, mtu: mtu)
        }
    }
    
    // 分段发送数据
    private func sendDataInChunks(_ data: Data, mtu: Int) async -> Result<Void, ConnectError> {
        let (peripheral, characteristic) = syncQueue.sync { (connectedPeripheral, characteristicForReadWrite) }
        guard let peripheral = peripheral, let characteristic = characteristic else {
            return .failure(.notConnected)
        }
        
        let chunks = chunkData(data, chunkSize: mtu)
        for (index, chunk) in chunks.enumerated() {
            peripheral.writeValue(chunk, for: characteristic, type: CBCharacteristicWriteType.withoutResponse)
            
            // 在包之间添加小延迟，避免发送过快
            if index < chunks.count - 1 {
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms 延迟
            }
        }
        
        let currentTime = CFAbsoluteTimeGetCurrent()
        let date = Date(timeIntervalSince1970: currentTime)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: date)
        print("⏱️ BLE 分段写入成功: \(data.count) 字节，\(chunks.count) 包 - 时间: \(timeString)")
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
                    print("receiveDataFlow: not connected")
                    continuation.finish()
                    return
                }
                
                do {
                    while true {
                        // 检查任务是否被取消
                        if Task.isCancelled {
                            print("receiveDataFlow: task cancelled")
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
                            print("⏱️ BLE receiveDataFlow: 向数据流发送数据, 大小: \(batch.count) 字节")
                            continuation.yield(batch)
                        } else {
                            // 队列无数据：短暂延迟避免忙等待
                            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                        }
                    }
                } catch {
                    print("Error in receiveDataFlow: \(error.localizedDescription)")
                }
                
                // 清理资源
                self.syncQueue.async {
                    self.readDataQueue.removeAll()
                }
                print("receiveDataFlow stopped, buffers cleared")
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
            print("⏱️ BLE 连接关闭，已取消接收任务")
        }
    }
    
    // 开始扫描BLE设备
    func startScan() async -> Bool {
        // 等待蓝牙状态就绪
        guard await waitForBluetoothPoweredOn() else {
            let currentState = centralManager.state
            let stateDescription = getBluetoothStateDescription(currentState)
            print("Bluetooth is not powered on after waiting, current state: \(stateDescription) (\(currentState.rawValue))")
            return false
        }
        
        // 创建扫描结果数据流
        if #available(iOS 13.0, *) {
            scanResultStream = AsyncStream<[BLEDeviceInfo]> { continuation in
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
        
        print("Started BLE scanning for all peripherals")
        return true
    }
    
    // 获取扫描结果数据流
    @available(iOS 13.0, *)
    func getScanResultStream() -> AsyncStream<[BLEDeviceInfo]>? {
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
        
        print("Stopped BLE scanning")
    }
    
    /// ##CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let currentState = central.state
        print("蓝牙状态变化: \(getBluetoothStateDescription(currentState))")
        
        // 当蓝牙状态变为非 poweredOn 时，触发蓝牙断开回调
        if currentState != .poweredOn {
            // 更新内部状态为 disconnected
            syncQueue.sync {
                self.state = .disconnected
                self.connectedPeripheral = nil
                self.characteristicForReadWrite = nil
            }
            print("⏱️ BLE 蓝牙状态变化，更新内部状态为 disconnected")
            
            DispatchQueue.main.async {
                self.onBluetoothDisconnect?()
            }
        } else {
            // 蓝牙重新开启时，如果之前有连接，需要重新连接
            print("⏱️ BLE 蓝牙重新开启，检查是否需要重连")
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
                    let newDeviceInfo = BLEDeviceInfo(
                        peripheral: peripheral,
                        rssi: rssiValue,
                        lastUpdateTime: currentTime,
                        updateCount: existingDevice.updateCount + 1
                    )
                    self.discoveredDevices[existingIndex] = newDeviceInfo
                    shouldUpdate = true
                    print("Updated BLE device RSSI: \(peripheral.name ?? "Unknown") - \(peripheral.identifier) - RSSI: \(rssiValue) (变化: \(rssiDifference)dBm, 更新次数: \(newDeviceInfo.updateCount))")
                }
            } else {
                // 添加新设备
                let newDeviceInfo = BLEDeviceInfo(
                    peripheral: peripheral,
                    rssi: rssiValue,
                    lastUpdateTime: currentTime,
                    updateCount: 1
                )
                self.discoveredDevices.append(newDeviceInfo)
                shouldUpdate = true
                print("Discovered BLE device: \(peripheral.name ?? "Unknown") - \(peripheral.identifier) - RSSI: \(rssiValue)")
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
            peripheral.discoverServices([CBUUID(string: UUIDs.readWriteService)])
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        NSLog("%@\n", "didDisconnectPeripheral");
        if let error = error {
            NSLog("Error: %@\n", error.localizedDescription);
        }
        
        // 设备断开时主动取消接收任务
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            self.currentReceiveTask?.cancel()
            self.currentReceiveTask = nil
            self.state = .disconnected
            print("⏱️ BLE 设备断开，已取消接收任务")
            
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
                    if service.uuid == CBUUID(string: UUIDs.readWriteService) {
                        peripheral.discoverCharacteristics([CBUUID(string: UUIDs.readWrite)], for: service)
                    }
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        NSLog("%@\n", "didDiscoverCharacteristicsForService");
        if let error = error {
            NSLog("Error: %@\n", error.localizedDescription);
            return;
        }
        syncQueue.async { [weak self] in
            guard let self = self else {return}
            if let characteristics = service.characteristics {
                for characteristic in characteristics {
                    if characteristic.uuid == CBUUID(string: UUIDs.readWrite) {
                        self.characteristicForReadWrite = characteristic
                        self.connectedPeripheral?.setNotifyValue(true, for: characteristic)
                    }
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        let receiveStartTime = CFAbsoluteTimeGetCurrent()
        NSLog("%@\n", "didUpdateValueForCharacteristic");
        if let error = error {
            NSLog("Error: %@\n", error.localizedDescription);
            return;
        }
        syncQueue.async {[weak self] in
            guard let self = self else {
                return
            }
            if characteristic.service?.uuid == CBUUID(string: UUIDs.readWriteService) {
                if characteristic.uuid == CBUUID(string: UUIDs.readWrite) {
                    if connectedPeripheral == peripheral {
                        if let value = characteristic.value {
                            self.dataForRead.append(value)
                            self.readDataQueue.append(value)
                            let currentTime = CFAbsoluteTimeGetCurrent()
                            let date = Date(timeIntervalSince1970: currentTime)
                            let formatter = DateFormatter()
                            formatter.dateFormat = "HH:mm:ss.SSS"
                            let timeString = formatter.string(from: date)
                            print("⏱️ BLE 接收数据: \(value.count) 字节 - 时间: \(timeString)")
                            print("⏱️ BLE readDataQueue 当前大小: \(self.readDataQueue.count) 字节")
                        }
                    }
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        NSLog("%@\n", "didWriteValueForCharacteristic");
        if let error = error {
            NSLog("Error: %@\n", error.localizedDescription);
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
        print("🔄 BLE 开始重连流程...")
        
        // 检查是否已连接或正在重连
        let currentState = syncQueue.sync { state }
        print("🔄 BLE 重连前状态检查: \(currentState)")
        
        if currentState == .connected {
            print("🔄 BLE 已连接，无需重连")
            return .success(())
        }
        if currentState == .connecting {
            print("🔄 BLE 正在连接中，无法重连")
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
        print("⏱️ BLE 重连使用targetPeripheral: \(targetPeripheral.identifier), 当前状态: \(targetPeripheral.state.rawValue)")
        
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
            
            print("BLE重连尝试 \(currentAttempt)/\(MAX_RECONNECT_ATTEMPTS)")
            
            // 执行单次重连
            let result = await open(peripheral: peripheral)
            if case .success = result {
                print("BLE open方法成功，开始验证连接状态...")
                
                // 检查 open 方法后的实际状态
                let currentState = syncQueue.sync { state }
                print("⏱️ BLE 重连后状态检查: manager状态=\(currentState), peripheral状态=\(peripheral.state.rawValue)")
                
                // 重连成功：验证连接状态是否真正可用
                let connectionValid = await validateConnection(peripheral: peripheral)
                if connectionValid {
                    reconnectAttempts = 0
                    print("BLE重连成功，连接状态验证通过")
                    return .success(())
                } else {
                    print("BLE重连失败：连接状态验证失败")
                    // 如果验证失败，确保状态为 disconnected
                    syncQueue.sync {
                        self.state = .disconnected
                    }
                    return .failure(.connectionFailed(NSError(domain: "BLEManage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Connection validation failed"])))
                }
            } else {
                print("BLE重连失败，尝试 \(currentAttempt)/\(MAX_RECONNECT_ATTEMPTS)")
                
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
                print("BLE重连延迟 \(delayMillis) 秒后重试")
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
            print("⏱️ BLE 连接验证失败: peripheral状态为 \(peripheral.state.rawValue)")
            return false
        }
        
        // 检查特征值是否可用
        let characteristic = syncQueue.sync { characteristicForReadWrite }
        guard characteristic != nil else {
            print("⏱️ BLE 连接验证失败: 特征值不可用")
            return false
        }
        
        // 检查 BLE 管理器状态
        let managerState = syncQueue.sync { state }
        guard managerState == .connected else {
            print("⏱️ BLE 连接验证失败: 管理器状态为 \(managerState)")
            return false
        }
        
        print("⏱️ BLE 连接验证通过: peripheral=\(peripheral.state.rawValue), characteristic=\(characteristic != nil), manager=\(managerState)")
        return true
    }
}
