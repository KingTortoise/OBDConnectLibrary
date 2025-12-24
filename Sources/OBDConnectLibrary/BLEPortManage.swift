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
    
    // 当前连接设备 RSSI 实时回调属性
    // 外部通过 ConnectManager 或直接通过 BLEPortManage 设置，用于实时获取信号强度
    var onHandleRssiUpdate: ((Int) -> Void)? {
        get {
            return bleManage.onHandleRssiUpdate
        }
        set {
            bleManage.onHandleRssiUpdate = newValue
        }
    }
    
    init() {
        bleManage = BLEManage()
    }
    
    func open(context: Any, name: String, peripheral: CBPeripheral?, completion: @escaping (Result<Void, ConnectError>) -> Void) {
        // BLE 连接只使用 peripheral 对象，忽略 name 参数
        bleManage.open(peripheral: peripheral, completion: completion)
    }
    
    func write(data: Data, timeout: TimeInterval) -> Result<Void, ConnectError> {
        return  bleManage.write(data: data, timeout: timeout)
    }
    
    // 获取数据流（使用回调替代AsyncStream以支持iOS 12.0）
    func receiveDataFlow(callback: @escaping (Data) -> Void, onFinish: @escaping () -> Void) {
        bleManage.receiveDataFlow(callback: callback, onFinish: onFinish)
    }
    
    func read(timeout: TimeInterval, completion: @escaping (Result<Data?, ConnectError>) -> Void) {
        bleManage.read(timeout: timeout) { [weak self] result in
            guard let self = self else {
                completion(.failure(.connectionFailed(NSError(domain: "BLEPortManage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"]))))
                return
            }
            switch result {
            case .success(let data):
                self.bleManage.clenReceiveInfo()
                completion(.success(data))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    func close() {
        bleManage.close()
    }
    
    // 触发一次当前连接设备 RSSI 读取
    // 读取结果会通过 onHandleRssiUpdate 回调异步返回
    func readCurrentRssi() {
        bleManage.readCurrentRssi()
    }
    
    func startScan(completion: @escaping (Bool) -> Void) {
        bleManage.startScan(completion: completion)
    }
    
    // 停止扫描
    func stopScan() {
        bleManage.stopScan()
    }
    
    // 设置扫描结果回调（替代AsyncStream以支持iOS 12.0）
    func setScanResultCallback(_ callback: @escaping ([Any]) -> Void) {
        bleManage.setScanResultCallback { deviceInfos in
            // 将 BLEScannedDeviceInfo 转换为包含RSSI信息的字典
            let devices: [Any] = deviceInfos.map { deviceInfo in
                return [
                    "peripheral": deviceInfo.peripheral,
                    "rssi": deviceInfo.rssi
                ]
            }
            callback(devices)
        }
    }
    
    func reconnect(completion: @escaping (Result<Void, ConnectError>) -> Void) {
        // BLEPortManage 使用 BLEManage 的重连实现
        bleManage.reconnect(completion: completion)
    }
    
    func getBleDeviceInfo(completion: @escaping (BleDeviceInfo?) -> Void) {
        // 只有 BLE 连接才支持获取设备信息
        bleManage.getBleDeviceInfo { deviceInfo in
            completion(deviceInfo)
        }
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
