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
    
    func open(context: Any, name: String, peripheral: CBPeripheral?) async -> Result<Void, ConnectError>
    func write(data: Data, timeout: TimeInterval) async -> Result<Void, ConnectError>
    func read(timeout: TimeInterval) async -> Result<Data?, ConnectError>
    func close()
    func startScan() async -> Bool
    func stopScan()
    @available(iOS 13.0, *)
    func getScanResultStream() -> AsyncStream<[Any]>?
    @available(iOS 13.0, *)
    func receiveDataFlow() -> AsyncStream<Data>
    func reconnect() async -> Result<Void, ConnectError>
}
