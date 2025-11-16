//
//  ConnectManager.swift
//  OBDUpdater
//
//  Created by 金文武 on 2025/6/30.
//

import Foundation
import CoreBluetooth

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
    public func connect(name: String, peripheral: CBPeripheral?, context: Any) async -> Result<Void, ConnectError> {
        guard let port = globalContext?.port else {
            return .failure(.connectionFailed(NSError(domain: "ConnectManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Port is nil"])))
        }
        
        let connectSuccess = await port.open(context: context, name: name, peripheral: peripheral)
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
    @inlinable
    public func write(data: Data, timeout: TimeInterval) -> Result<Void, ConnectError> {
        // 检查端口状态
        guard let port = globalContext?.port else {
            return .failure(.sendFailed(NSError(domain: "ConnectManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Port is nil"])))
        }
        
        return port.write(data: data, timeout: timeout)
    }
    
    // 获取数据流
    @available(iOS 13.0, *)
    public func receiveDataFlow() -> AsyncStream<Data> {
        
        guard let port = globalContext?.port else {
            return AsyncStream<Data> { continuation in
                continuation.finish()
            }
        }
        let stream = port.receiveDataFlow()
        
        return AsyncStream<Data> { continuation in
            Task {
                for await data in stream {
                    continuation.yield(data)
                }
                continuation.finish()
            }
        }
    }
    
    // 接收响应
    public func read(timeout: TimeInterval) async -> Result<String?, ConnectError>{
        let readSuccess = await globalContext?.port?.read(timeout: timeout)
        switch readSuccess {
        case .success(let data):
            if data != nil {
                let result = String(data: data!, encoding: .utf8)
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
    
    // 开始扫描设备
    public func startScan() async -> Bool {
        guard let port = globalContext?.port else {
            return false
        }
        
        return await port.startScan()
    }
    
    // 停止扫描设备
    public func stopScan() {
        globalContext?.port?.stopScan()
    }
    
    
    // 获取扫描结果数据流
    @available(iOS 13.0, *)
    public func getScanResultStream() -> AsyncStream<[Any]>? {
        return globalContext?.port?.getScanResultStream()
    }
    
    // 设置设备断开回调
    public func setOnDeviceDisconnect(_ callback: @escaping () -> Void) {
        globalContext?.port?.onDeviceDisconnect = callback
    }
    
    // 设置蓝牙状态断开回调
    public func setOnBluetoothDisconnect(_ callback: @escaping () -> Void) {
        if let blePortManage = globalContext?.port as? BLEPortManage {
            blePortManage.onBluetoothDisconnect = callback
        }
    }
    
    // 重连方法
    public func reconnect() async -> Result<Void, ConnectError> {
        guard let port = globalContext?.port else {
            return .failure(.connectionFailed(NSError(domain: "ConnectManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Port is nil"])))
        }
        
        let reconnectResult = await port.reconnect()
        switch reconnectResult {
        case .success():
            globalContext?.isOpen = true
            return .success(())
        case .failure(let error):
            globalContext?.isOpen = false
            return .failure(error)
        }
    }
    
    // 获取 BLE 设备信息
    public func getBleDeviceInfo() async -> BleDeviceInfo? {
        guard let port = globalContext?.port else {
            return nil
        }
        
        return await port.getBleDeviceInfo()
    }
    
    // 更改 BLE 写入信息
    public func onChangeBleWriteInfo(characteristicUuid: String, propertyName: String, isActive: Bool) {
        // 调用端口管理器的实现
        globalContext?.port?.onChangeBleWriteInfo(characteristicUuid: characteristicUuid, propertyName: propertyName, isActive: isActive)
    }
    
    // 更改 BLE 描述符信息
    public func onChangeBleDescriptorInfo(characteristicUuid: String, propertyName: String, isActive: Bool) {
        // 调用端口管理器的实现
        globalContext?.port?.onChangeBleDescriptorInfo(characteristicUuid: characteristicUuid, propertyName: propertyName, isActive: isActive)
    }
    
    // 关闭连接
    public func close() {
        globalContext?.port?.close()
        globalContext = nil
    }
}
