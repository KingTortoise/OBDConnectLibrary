//
//  BLEPortManage.swift
//  OBDUpdater
//
//  Created by myrc on 2025/7/1.
//

import Foundation
import CoreBluetooth

class BLEPortManage: IPortManage {
    private let bleManage: BLEManage!
    
    // 实现协议中的设备断开回调属性
    var onDeviceDisconnect: (() -> Void)? {
        get {
            return bleManage.onDeviceDisconnect
        }
        set {
            bleManage.onDeviceDisconnect = newValue
        }
    }
    
    // 蓝牙状态断开回调属性
    var onBluetoothDisconnect: (() -> Void)? {
        get {
            return bleManage.onBluetoothDisconnect
        }
        set {
            bleManage.onBluetoothDisconnect = newValue
        }
    }
    
    init() {
        bleManage = BLEManage()
    }
    
    func open(context: Any, name: String, peripheral: CBPeripheral?) async -> Result<Void, ConnectError> {
        // BLE 连接只使用 peripheral 对象，忽略 name 参数
        return await bleManage.open(peripheral: peripheral)
    }
    
    func write(data: Data, timeout: TimeInterval) -> Result<Void, ConnectError> {
        return  bleManage.write(data: data, timeout: timeout)
    }
    
    // 获取数据流
    @available(iOS 13.0, *)
    func receiveDataFlow() -> AsyncStream<Data> {
        return bleManage.receiveDataFlow()
    }
    
    func read(timeout: TimeInterval) async -> Result<Data?, ConnectError> {
        let readResult = await bleManage.read(timeout: timeout)
        switch readResult {
        case .success(let data):
            bleManage.clenReceiveInfo()
            return .success(data)
        case .failure(let error):
            return .failure(error)
        }
    }
    
    func close() {
        bleManage.close()
    }
    
    func startScan() async -> Bool {
        return await bleManage.startScan()
    }
    
    // 停止扫描
    func stopScan() {
        bleManage.stopScan()
    }
    
    // 获取扫描结果数据流
    @available(iOS 13.0, *)
    func getScanResultStream() -> AsyncStream<[Any]>? {
        guard let stream = bleManage.getScanResultStream() else { return nil }
        
        return AsyncStream<[Any]> { continuation in
            Task {
                for await deviceInfos in stream {
                    // 将 BLEScannedDeviceInfo 转换为包含RSSI信息的字典
                    let devices: [Any] = deviceInfos.map { deviceInfo in
                        return [
                            "peripheral": deviceInfo.peripheral,
                            "rssi": deviceInfo.rssi
                        ]
                    }
                    continuation.yield(devices)
                }
                continuation.finish()
            }
        }
    }
    
    func reconnect() async -> Result<Void, ConnectError> {
        // BLEPortManage 使用 BLEManage 的重连实现
        return await bleManage.reconnect()
    }
    
    func getBleDeviceInfo() async -> BleDeviceInfo? {
        // 只有 BLE 连接才支持获取设备信息
        return await bleManage.getBleDeviceInfo()
    }
    
    // MARK: - BLE 信息变更回调实现
    
    func onChangeBleWriteInfo(characteristicUuid: String, propertyName: String, isActive: Bool) {
        // 将调用转发给 BLEManage
        bleManage.onChangeBleWriteInfo(characteristicUuid: characteristicUuid, propertyName: propertyName, isActive: isActive)
    }
    
    func onChangeBleDescriptorInfo(characteristicUuid: String, propertyName: String, isActive: Bool) {
        // 将调用转发给 BLEManage
        bleManage.onChangeBleDescriptorInfo(characteristicUuid: characteristicUuid, propertyName: propertyName, isActive: isActive)
    }
}
