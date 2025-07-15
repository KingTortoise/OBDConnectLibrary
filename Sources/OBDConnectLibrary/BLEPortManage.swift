//
//  BLEPortManage.swift
//  OBDUpdater
//
//  Created by myrc on 2025/7/1.
//

import Foundation

class BLEPortManage: IPortManage {
    private let bleManage: BLEManage!

    init() {
        bleManage = BLEManage()
    }
    
    func open(context: Any, name: String) async -> Bool {
        let connectResult = await bleManage.open(name: name)
        switch connectResult {
        case .success:
            return true
        case .failure(let error):
            return false
        }
    }
    
    func write(data: Data, timeout: TimeInterval) async -> Bool {
        let writeResult = await bleManage.write(data: data, timeout: timeout)
        switch writeResult {
        case .success:
            return true
        case .failure(_):
            return false
        }
    }
    
    func read(timeout: TimeInterval) async -> Data? {
        let readResult = await bleManage.read(timeout: timeout)
        switch readResult {
        case .success(let data):
            bleManage.clenReceiveInfo()
            return data
        case .failure(_):
            return nil
        }
    }
    
    func close() {
        bleManage.close()
    }
    
}
