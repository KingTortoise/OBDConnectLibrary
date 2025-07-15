//
//  TcpPortManage.swift
//  OBDUpdater
//
//  Created by 金文武 on 2025/6/30.
//

import Foundation

class TcpPortManage: IPortManage {
    private let tcpManage: TcpManage!

    init() {
        tcpManage = TcpManage()
    }
    
    func open(context: Any, name: String) async -> Bool {
        let connectResult = await tcpManage.openChannel(name: name, timeout: 5.0) // 10秒连接超时
        switch connectResult {
        case .success:
            return true
        case .failure(_):
            return false
        }
    }
    
    func write(data: Data, timeout: TimeInterval) async -> Bool {
        let writeResult = await tcpManage.write(data: data, timeout: timeout)
        switch writeResult {
        case .success:
            return true
        case .failure(_):
            return false
        }
    }
    
    func read(timeout: TimeInterval) async -> Data? {
        let readResult = await tcpManage.read(timeout: timeout)
        switch readResult {
        case .success(let data):
            tcpManage.clenReceiveInfo()
            return data
        case .failure(_):
            return nil
        }
    }
    
    func close() {
        tcpManage.close()
    }
    
}
