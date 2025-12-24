//
//  IPortManage.swift
//  OBDUpdater
//
//  Created by 金文武 on 2025/6/30.
//

import Foundation
import CoreBluetooth

// 端口管理协议
public protocol IPortManage {
    // 设备断开回调
    var onDeviceDisconnect: (() -> Void)? { get set }
    
    func open(context: Any, name: String, peripheral: CBPeripheral?, completion: @escaping (Result<Void, ConnectError>) -> Void)
    func write(data: Data, timeout: TimeInterval) -> Result<Void, ConnectError>
    func read(timeout: TimeInterval, completion: @escaping (Result<Data?, ConnectError>) -> Void)
    func close()
    func startScan(completion: @escaping (Bool) -> Void)
    func stopScan()
    func setScanResultCallback(_ callback: @escaping ([Any]) -> Void)
    func receiveDataFlow(callback: @escaping (Data) -> Void, onFinish: @escaping () -> Void)
    func reconnect(completion: @escaping (Result<Void, ConnectError>) -> Void)
    func getBleDeviceInfo(completion: @escaping (BleDeviceInfo?) -> Void)
    
    // BLE 写入信息变更回调
    func onChangeBleWriteInfo(characteristicUuid: String, propertyName: String, isActive: Bool)
    
    // BLE 描述符信息变更回调
    func onChangeBleDescriptorInfo(characteristicUuid: String, propertyName: String, isActive: Bool)
}
