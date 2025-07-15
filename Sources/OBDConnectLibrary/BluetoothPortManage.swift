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
    
    func open(context: Any, name: String) async -> Bool {
        let connectResult = await bluetoothManage.open(name: name)
        switch connectResult {
        case .success:
            return true
        case .failure(_):
            return false
        }
    }
    
    func write(data: Data, timeout: TimeInterval) async -> Bool {
        let writeResult = await bluetoothManage.write(data: data, timeout: timeout)
        switch writeResult {
        case .success:
            return true
        case .failure(_):
            return false
        }
    }
    
    func read(timeout: TimeInterval) async -> Data? {
        let readResult = await bluetoothManage.read(timeout: timeout)
        switch readResult {
        case .success(let data):
            bluetoothManage.clenReceiveInfo()
            return data
        case .failure(_):
            return nil
        }
    }
    
    func close() {
        bluetoothManage.close()
    }
    
}
