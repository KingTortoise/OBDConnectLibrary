//
//  BluetoothPortManage.swift
//  OBDUpdater
//
//  Created by 金文武 on 2025/6/30.
//

import Foundation
import CoreBluetooth

class BluetoothPortManage: IPortManage, @unchecked Sendable {
    
    private let bluetoothManage: BluetoothManage!
    
    // 实现协议中的设备断开回调属性
    var onDeviceDisconnect: (() -> Void)? {
        get {
            return bluetoothManage.onDeviceDisconnect
        }
        set {
            bluetoothManage.onDeviceDisconnect = newValue
        }
    }

    init() {
        bluetoothManage = BluetoothManage()
    }
    
    func open(context: Any, name: String, peripheral: CBPeripheral?, completion: @escaping (Result<Void, ConnectError>) -> Void) {
        bluetoothManage.open(name: name, completion: completion)
    }
    
    func write(data: Data, timeout: TimeInterval) -> Result<Void, ConnectError> {
        return  bluetoothManage.write(data: data, timeout: timeout)
    }
    
    // 获取数据流（使用回调替代AsyncStream以支持iOS 12.0）
    func receiveDataFlow(callback: @escaping (Data) -> Void, onFinish: @escaping () -> Void) {
        // 蓝牙暂时不支持数据流，直接调用onFinish
        onFinish()
    }
    
    func read(timeout: TimeInterval, completion: @escaping (Result<Data?, ConnectError>) -> Void) {
        bluetoothManage.read(timeout: timeout) { [weak self] result in
            guard let self = self else {
                completion(.failure(.connectionFailed(NSError(domain: "BluetoothPortManage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"]))))
                return
            }
            switch result {
            case .success(let data):
                self.bluetoothManage.clenReceiveInfo()
                completion(.success(data))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    func close() {
        bluetoothManage.close()
    }
    
    func startScan(completion: @escaping (Bool) -> Void) {
        bluetoothManage.startScan(completion: completion)
    }
    
    // 停止扫描（蓝牙不需要停止扫描）
    func stopScan() {
        print("Bluetooth scan - no need to stop")
    }
    
    // 设置扫描结果回调（替代AsyncStream以支持iOS 12.0）
    func setScanResultCallback(_ callback: @escaping ([Any]) -> Void) {
        // 对于 External Accessory 框架，我们返回已连接的设备
        // 虽然不能主动扫描，但可以提供已连接设备
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                callback([])
                return
            }
            let connectedAccessories = self.bluetoothManage.getConnectedAccessories()
            callback(connectedAccessories)
        }
    }
    
    func reconnect(completion: @escaping (Result<Void, ConnectError>) -> Void) {
        // BluetoothPortManage 暂不支持重连，返回失败
        completion(.failure(.connectionFailed(NSError(domain: "BluetoothPortManage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Reconnect not supported for Bluetooth"]))))
    }
    
    func getBleDeviceInfo(completion: @escaping (BleDeviceInfo?) -> Void) {
        // 蓝牙连接不支持 BLE 设备信息
        completion(nil)
    }
    
    // MARK: - BLE 信息变更回调实现（蓝牙不支持，提供空实现）
    
    func onChangeBleWriteInfo(characteristicUuid: String, propertyName: String, isActive: Bool) {
        print("⚠️ 蓝牙连接不支持 BLE 写入信息变更")
    }
    
    func onChangeBleDescriptorInfo(characteristicUuid: String, propertyName: String, isActive: Bool) {
        print("⚠️ 蓝牙连接不支持 BLE 描述符信息变更")
    }
    
}
