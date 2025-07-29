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
public enum ConnectType: Int {
    case WIFI = 0
    case BT = 1
    case BLE = 2
}

public struct VlContext {
    public var type: Int
    public var name: String?
    public var isOpen: Bool
    public var port: IPortManage?
}

@available(macOS 10.15, *)
public class ConnectManager: @unchecked Sendable {
    
    // 单例实例（全局唯一）
    public static let shared = ConnectManager()
    
    // 全局连接上下文
    public var globalContext: VlContext?
        
    // 主协程作用域
    private var mainScope: AnyCancellable?
    
    public init() {}
    
    // 初始化管理器
    public func initManager(type: Int, context: Any) async throws -> Bool {
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
            throw NSError(domain: "ConnectManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid type."])
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
    public func connect(name: String, context: Any) async -> Result<Void, ConnectError> {
        guard let port = globalContext?.port else {
            return .failure(.connectionFailed(NSError(domain: "ConnectManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Port is nil"])))
        }
        
        let connectSuccess = await port.open(context: context, name: name)
        switch connectSuccess {
        case .success():
            globalContext?.isOpen = true
            return .success(())
            
        case .failure(let error):
            globalContext?.isOpen = false
            return .failure(error)
        }
    }
    
    // 写入数据
    public func write(data: Data, timeout: TimeInterval) async -> Result<Void, ConnectError> {
        guard let port = globalContext?.port else {
            return .failure(.sendFailed(NSError(domain: "ConnectManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Port is nil"])))
        }
        
        return  await port.write(data: data, timeout: timeout)
    }
    
    // 接收响应
    public func read(timeout: TimeInterval) async -> Result<String?, ConnectError>{
        let readSuccess = await globalContext?.port?.read(timeout: timeout)
        switch readSuccess {
        case .success(let data):
            if data != nil {
                let result = String(data: data!, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                    .replacingOccurrences(of: ">", with: "")
                guard let result = result else { return .success(nil) }
                return result.isEmpty  ? .success(nil) : .success(result)
            } else {
                return .success(nil)
            }
        case .failure(let error):
            return .failure(error)
        case .none:
            return .success(nil)
        }
    }
    
    // 关闭连接
    public func close() {
        globalContext?.port?.close()
        globalContext = nil
    }
}
