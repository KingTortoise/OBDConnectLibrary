//
//  BluetoothPortManage.swift
//  OBDUpdater
//
//  Created by 金文武 on 2025/6/30.
//

import Foundation
import CoreBluetooth

class BluetoothPortManage: IPortManage {
    
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
    
    func open(context: Any, name: String, peripheral: CBPeripheral?) async -> Result<Void, ConnectError> {
        return await bluetoothManage.open(name: name)
    }
    
    func write(data: Data, timeout: TimeInterval) async -> Result<Void, ConnectError> {
        return await bluetoothManage.write(data: data, timeout: timeout)
    }
    
    // 获取数据流
    @available(iOS 13.0, *)
    func receiveDataFlow() -> AsyncStream<Data> {
        // 蓝牙暂时不支持数据流，返回空流
        return AsyncStream<Data> { continuation in
            continuation.finish()
        }
    }
    
    func read(timeout: TimeInterval) async -> Result<Data?, ConnectError> {
        let readResult = await bluetoothManage.read(timeout: timeout)
        switch readResult {
        case .success(let data):
            bluetoothManage.clenReceiveInfo()
            return .success(data)
        case .failure(let error):
            return .failure(error)
        }
    }
    
    func close() {
        bluetoothManage.close()
    }
    
    func startScan() async -> Bool {
        return await bluetoothManage.startScan()
    }
    
    // 停止扫描（蓝牙不需要停止扫描）
    func stopScan() {
        print("Bluetooth scan - no need to stop")
    }
    
    // 获取扫描结果数据流（蓝牙返回已连接的设备）
    @available(iOS 13.0, *)
    func getScanResultStream() -> AsyncStream<[Any]>? {
        // 对于 External Accessory 框架，我们返回已连接的设备
        // 虽然不能主动扫描，但可以提供已连接设备的数据流
        return AsyncStream<[Any]> { continuation in
            Task {
                // 立即返回已连接的设备
                let connectedAccessories = bluetoothManage.getConnectedAccessories()
                continuation.yield(connectedAccessories)
                
                // 对于蓝牙，我们不需要持续监听，因为 External Accessory 框架
                // 不支持主动扫描新设备，只能获取已连接的设备
                continuation.finish()
            }
        }
    }
    
    func reconnect() async -> Result<Void, ConnectError> {
        // BluetoothPortManage 暂不支持重连，返回失败
        return .failure(.connectionFailed(NSError(domain: "BluetoothPortManage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Reconnect not supported for Bluetooth"])))
    }
    
}
