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

public class ConnectManager: @unchecked Sendable {
    
    // 单例实例（全局唯一）
    public static let shared = ConnectManager()
    
    // 全局连接上下文
    public var globalContext: VlContext?
    
    public init() {}
    
    // 初始化管理器（使用回调替代async/await以支持iOS 12.0）
    public func initManager(type: Int, context: Any, completion: @escaping (Result<Bool, Error>) -> Void) {
        if let globalContext = globalContext {
            if globalContext.type == type && globalContext.isOpen {
                completion(.success(true))
                return
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
            completion(.failure(NSError(domain: "ConnectManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid type."])))
            return
        }
        let context = VlContext(
            type: type,
            name: nil,
            isOpen: false,
            port: manager
                    
        )
        self.globalContext = context
        completion(.success(true))
    }
    
    // 连接（使用回调替代async/await以支持iOS 12.0）
    public func connect(name: String, peripheral: CBPeripheral?, context: Any, completion: @escaping (Result<Void, ConnectError>) -> Void) {
        guard let port = globalContext?.port else {
            completion(.failure(.connectionFailed(NSError(domain: "ConnectManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Port is nil"]))))
            return
        }
        
        port.open(context: context, name: name, peripheral: peripheral) { [weak self] result in
            guard let self = self else {
                completion(.failure(.connectionFailed(NSError(domain: "ConnectManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"]))))
                return
            }
            switch result {
            case .success():
                self.globalContext?.isOpen = true
                completion(.success(()))
                
            case .failure(let error):
                self.globalContext?.isOpen = false
                completion(.failure(error))
            }
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
    
    // 获取数据流（使用回调替代AsyncStream以支持iOS 12.0）
    public func receiveDataFlow(callback: @escaping (Data) -> Void, onFinish: @escaping () -> Void) {
        guard let port = globalContext?.port else {
            onFinish()
            return
        }
        port.receiveDataFlow(callback: callback, onFinish: onFinish)
    }
    
    // 接收响应（使用回调替代async/await以支持iOS 12.0）
    public func read(timeout: TimeInterval, completion: @escaping (Result<String?, ConnectError>) -> Void) {
        guard let port = globalContext?.port else {
            completion(.success(nil))
            return
        }
        
        port.read(timeout: timeout) { result in
            switch result {
            case .success(let data):
                if let data = data {
                    let result = String(data: data, encoding: .utf8)
                    guard let result = result else {
                        completion(.success(nil))
                        return
                    }
                    completion(.success(result.isEmpty ? nil : result))
                } else {
                    completion(.success(nil))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    // 开始扫描设备（使用回调替代async/await以支持iOS 12.0）
    public func startScan(completion: @escaping (Bool) -> Void) {
        guard let port = globalContext?.port else {
            completion(false)
            return
        }
        
        port.startScan(completion: completion)
    }
    
    // 停止扫描设备
    public func stopScan() {
        globalContext?.port?.stopScan()
    }
    
    
    // 设置扫描结果回调（替代AsyncStream以支持iOS 12.0）
    public func setScanResultCallback(_ callback: @escaping ([Any]) -> Void) {
        globalContext?.port?.setScanResultCallback(callback)
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
    
    // 设置 BLE 设备 RSSI 更新回调
    // 只有当前端口为 BLEPortManage 时才生效，其他连接类型会被忽略
    public func setOnBleRssiUpdate(_ callback: @escaping (Int) -> Void) {
        if let blePortManage = globalContext?.port as? BLEPortManage {
            blePortManage.onHandleRssiUpdate = callback
        }
    }
    
    // 触发一次当前 BLE 连接的 RSSI 读取
    // 读取结果会通过 setOnBleRssiUpdate 设置的回调异步返回
    public func readCurrentBleRssi() {
        if let blePortManage = globalContext?.port as? BLEPortManage {
            blePortManage.readCurrentRssi()
        }
    }
    
    // 重连方法（使用回调替代async/await以支持iOS 12.0）
    public func reconnect(completion: @escaping (Result<Void, ConnectError>) -> Void) {
        guard let port = globalContext?.port else {
            completion(.failure(.connectionFailed(NSError(domain: "ConnectManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Port is nil"]))))
            return
        }
        
        port.reconnect { [weak self] result in
            guard let self = self else {
                completion(.failure(.connectionFailed(NSError(domain: "ConnectManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"]))))
                return
            }
            switch result {
            case .success():
                self.globalContext?.isOpen = true
                completion(.success(()))
            case .failure(let error):
                self.globalContext?.isOpen = false
                completion(.failure(error))
            }
        }
    }
    
    // 获取 BLE 设备信息（使用回调替代async/await以支持iOS 12.0）
    public func getBleDeviceInfo(completion: @escaping (BleDeviceInfo?) -> Void) {
        guard let port = globalContext?.port else {
            completion(nil)
            return
        }
        
        port.getBleDeviceInfo(completion: completion)
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
