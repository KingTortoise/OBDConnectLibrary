//
//  IPortManage.swift
//  OBDUpdater
//
//  Created by 金文武 on 2025/6/30.
//

import Foundation

// 端口管理协议
protocol IPortManage {
    func open(context: Any, name: String) async -> Bool
    func write(data: Data, timeout: TimeInterval) async -> Bool
    func read(timeout: TimeInterval) async -> Data?
    func close()
}
