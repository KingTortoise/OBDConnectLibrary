//
//  IPortManage.swift
//  OBDUpdater
//
//  Created by 金文武 on 2025/6/30.
//

import Foundation

// 端口管理协议
public protocol IPortManage {
    func open(context: Any, name: String) async -> Result<Void, ConnectError>
    func write(data: Data, timeout: TimeInterval) async -> Result<Void, ConnectError>
    func read(timeout: TimeInterval) async -> Result<Data?, ConnectError>
    func close()
}
