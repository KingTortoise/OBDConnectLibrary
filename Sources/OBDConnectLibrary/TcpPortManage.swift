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
    
    func open(context: Any, name: String) async -> Result<Void, ConnectError> {
        return await tcpManage.openChannel(name: name, timeout: 5.0) // 10秒连接超时
    }
    
    func write(data: Data, timeout: TimeInterval) async -> Result<Void, ConnectError> {
        return await tcpManage.write(data: data, timeout: timeout)
    }
    
    func read(timeout: TimeInterval) async -> Result<Data?, ConnectError> {
        let readResult = await tcpManage.read(timeout: timeout)
        switch readResult {
        case .success(let data):
            tcpManage.clenReceiveInfo()
            return .success(data)
        case .failure(let error):
            return .failure(error)
        }
    }
    
    func close() {
        tcpManage.close()
    }
    
}
