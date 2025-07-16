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
    
    func open(context: Any, name: String) async -> Result<Void, ConnectError> {
        return await bleManage.open(name: name)
    }
    
    func write(data: Data, timeout: TimeInterval) async -> Result<Void, ConnectError> {
        return await bleManage.write(data: data, timeout: timeout)
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
    
}
