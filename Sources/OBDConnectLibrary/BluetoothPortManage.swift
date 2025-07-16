//
//  BluetoothPortManage.swift
//  OBDUpdater
//
//  Created by 金文武 on 2025/6/30.
//

import Foundation

class BluetoothPortManage: IPortManage {
    
    private let bluetoothManage: BluetoothManage!

    init() {
        bluetoothManage = BluetoothManage()
    }
    
    func open(context: Any, name: String) async -> Result<Void, ConnectError> {
        return await bluetoothManage.open(name: name)
    }
    
    func write(data: Data, timeout: TimeInterval) async -> Result<Void, ConnectError> {
        return await bluetoothManage.write(data: data, timeout: timeout)
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
    
}
