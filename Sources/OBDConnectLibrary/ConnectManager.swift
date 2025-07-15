//
//  ConnectManager.swift
//  OBDUpdater
//
//  Created by 金文武 on 2025/6/30.
//

import Foundation
import CoreBluetooth
import Combine

// 连接类型枚举
enum ConnectType: Int {
    case WIFI = 0
    case BT = 1
    case BLE = 2
}

struct VlContext {
    var type: Int
    var name: String?
    var isOpen: Bool
    var port: IPortManage?
}

@available(macOS 10.15, *)
class ConnectManager {
    // 全局连接上下文
    var globalContext: VlContext?
        
    // 主协程作用域
    private var mainScope: AnyCancellable?
    
    // 初始化管理器
    func initManager(type: Int, context: Any) async throws -> Bool {
        if let globalContext = globalContext {
            if globalContext.type == type && globalContext.isOpen {
                return true
            } else {
                close()
            }
        }
        let manager: IPortManage?
        switch type {
        case ConnectType.BT.rawValue:
            manager = BluetoothPortManage()
        case ConnectType.BLE.rawValue:
            manager = BLEPortManage()
        case ConnectType.WIFI.rawValue:
            manager = TcpPortManage()
        default:
            manager = nil
        }
        
        guard let manager = manager else {
            throw NSError(domain: "ConnectManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported connection type"])
        }
        let context = VlContext(
            type: type,
            name: nil,
            isOpen: false,
            port: manager
                    
        )
        self.globalContext = context
        return true
    }
    
    // 连接
    func connect(name: String, context: Any) async throws -> Bool {
        guard let port = globalContext?.port else {
            throw NSError(domain: "ConnectManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Port is nil"])
        }
        
        let result = await port.open(context: context, name: name)
        globalContext?.isOpen = result
        return result
    }
    
    // 写入数据
    func write(data: Data, timeout: TimeInterval) async throws -> Bool {
        guard let port = globalContext?.port else {
            throw NSError(domain: "ConnectManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Port is nil"])
        }
        
        return  await port.write(data: data, timeout: timeout)
    }
    
    // 接收响应
    func read(timeout: TimeInterval) async throws -> String? {
        // 从异步读取获取数据，添加超时处理
        guard let data = await globalContext?.port?.read(timeout: timeout) else {
            return nil
        }
        
        // 转换数据为字符串并处理
        guard let result = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: ">", with: "")else {
            return nil
        }
        
        return result.isEmpty ? nil : result
    }
    
    // 关闭连接
    func close() {
        globalContext?.port?.close()
        globalContext = nil
    }
}
