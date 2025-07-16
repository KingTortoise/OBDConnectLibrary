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
fileprivate let ISSC_READ_WRITE_SERVICE_UUID = CBUUID(string: "18F0")
fileprivate let ISSC_READ_WRITE_CHARACTERISTIC_UUIT = CBUUID(string: "2AF0")

final class BLEManage: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate,@unchecked Sendable {
    
    private var mName: [String] = []
    // 蓝牙中央管理器
    private var centralManager: CBCentralManager!
    // 当前连接的外设
    private var connectedPeripheral: CBPeripheral?
    
    private var characteristicForReadWrite: CBCharacteristic?
    private var state: State = .disconnected
    private var dataForRead = Data()
    
    private let syncQueue = DispatchQueue(label: "com.bleManage.syncQueue")
    
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
    
    func open(name: String) async -> Result<Void, ConnectError> {
        let connectState = syncQueue.sync { state }
        if connectState == .connected {
            return .success(())
        }
        if connectState == .connecting {
            return .failure(.connecting)
        }
        mName = name.components(separatedBy: ":").filter{ !$0.isEmpty }
        guard !mName.isEmpty else {
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
            // 蓝牙已开启，继续操作
            // 开始扫描特定服务的外设
            self.centralManager.scanForPeripherals(withServices: [ISSC_READ_WRITE_SERVICE_UUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            
        }
        guard await waitForSearchPeripheral() else {
            // 停止扫描
            syncQueue.sync {
                self.centralManager.stopScan()
                self.state = .disconnected
            }
            return .failure(.noCompatibleDevices)
        }
        
        syncQueue.sync {
            self.centralManager.stopScan()
            self.centralManager.connect(connectedPeripheral!, options: nil)
        }
        
        guard await waitForConnectState() else {
            syncQueue.sync {
                self.centralManager.cancelPeripheralConnection(self.connectedPeripheral!)
                self.connectedPeripheral = nil
                self.state = .disconnected
            }
            return .failure(.connectionFailed(NSError(domain: "BLEManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No status change notification received."])))
        }
        guard await waitForReadWrite() else {
            syncQueue.sync {
                self.centralManager.cancelPeripheralConnection(self.connectedPeripheral!)
                self.connectedPeripheral = nil
                self.characteristicForReadWrite = nil
                self.state = .disconnected
            }
            return .failure(.connectionFailed(NSError(domain: "BLEManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No characteristics found."])))
        }
        syncQueue.sync {
            self.state = .connected
        }
        return .success(())
    }
    
    func write(data: Data, timeout: TimeInterval) async -> Result<Void, ConnectError> {
        let (currentState, characteristic) = syncQueue.sync {
            (state, characteristicForReadWrite)
        }
        guard currentState == .connected, centralManager.state == CBManagerState.poweredOn, characteristic != nil else {
            return .failure(.notConnected)
        }
        guard !data.isEmpty else {
            // 空数据视为发送成功
            return .success(())
        }
        connectedPeripheral?.writeValue(data, for: self.characteristicForReadWrite!, type: CBCharacteristicWriteType.withoutResponse)
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
    
    func clenReceiveInfo() {
        syncQueue.async { [weak self] in
            guard let self = self else {return}
            self.dataForRead.removeAll()
        }
    }
    
    func close() {
        syncQueue.async { [weak self] in
            guard let self = self else {return}
            if let manage = self.centralManager, let connected = self.connectedPeripheral {
                manage.cancelPeripheralConnection(connected)
            }
            self.centralManager = nil
            self.connectedPeripheral = nil
            self.characteristicForReadWrite = nil
            self.dataForRead = Data()
        }
    }
    
    /// ##CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        syncQueue.async { [weak self] in
            guard let self = self else {return}
            if let name = peripheral.name, self.mName.contains(where: { name.hasPrefix($0) == true }) {
                self.connectedPeripheral = peripheral
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
            return;
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
}
