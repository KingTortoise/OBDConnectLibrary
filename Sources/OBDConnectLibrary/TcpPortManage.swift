//
//  TcpPortManage.swift
//  OBDUpdater
//
//  Created by 金文武 on 2025/6/30.
//

import Foundation
import CoreBluetooth

class TcpPortManage: IPortManage {
    private let tcpManage: TcpManage!
    
    // 实现协议中的设备断开回调属性
    var onDeviceDisconnect: (() -> Void)? {
        get {
            return tcpManage.onDeviceDisconnect
        }
        set {
            tcpManage.onDeviceDisconnect = newValue
        }
    }

    init() {
        tcpManage = TcpManage()
    }
    
    func open(context: Any, name: String, peripheral: CBPeripheral?, completion: @escaping (Result<Void, ConnectError>) -> Void) {
        tcpManage.openChannel(name: name, timeout: 5.0, completion: completion) // 5秒连接超时
    }
    
    func write(data: Data, timeout: TimeInterval)  -> Result<Void, ConnectError> {
        return  tcpManage.write(data: data, timeout: timeout)
    }
    
    // 获取数据流（使用回调替代AsyncStream以支持iOS 12.0）
    func receiveDataFlow(callback: @escaping (Data) -> Void, onFinish: @escaping () -> Void) {
        // TCP/WiFi 暂时不支持数据流，直接调用onFinish
        onFinish()
    }
    
    func read(timeout: TimeInterval, completion: @escaping (Result<Data?, ConnectError>) -> Void) {
        tcpManage.read(timeout: timeout) { [weak self] result in
            guard let self = self else {
                completion(.failure(.connectionFailed(NSError(domain: "TcpPortManage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"]))))
                return
            }
            switch result {
            case .success(let data):
                self.tcpManage.clenReceiveInfo()
                completion(.success(data))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    func close() {
        tcpManage.close()
    }
    
    func startScan(completion: @escaping (Bool) -> Void) {
        // TCP/WiFi 扫描逻辑
        // WiFi 连接通常不需要扫描，因为需要手动输入 IP 地址
        // 这里可以返回一些预定义的网络地址或空数组
        print("TCP/WiFi scan - no actual scanning needed")
        completion(true)
    }
    
    // 停止扫描（TCP/WiFi 不需要停止扫描）
    func stopScan() {
        print("TCP/WiFi scan - no need to stop")
    }
    
    
    
    // 设置扫描结果回调（替代AsyncStream以支持iOS 12.0）
    func setScanResultCallback(_ callback: @escaping ([Any]) -> Void) {
        // 对于 TCP/WiFi 连接，不需要扫描设备
        // 但为了保持 API 一致性，返回空数组
        DispatchQueue.main.async {
            callback([])
        }
    }
    
    func reconnect(completion: @escaping (Result<Void, ConnectError>) -> Void) {
        // TcpPortManage 暂不支持重连，返回失败
        completion(.failure(.connectionFailed(NSError(domain: "TcpPortManage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Reconnect not supported for TCP"]))))
    }
    
    func getBleDeviceInfo(completion: @escaping (BleDeviceInfo?) -> Void) {
        // TCP/WiFi 连接不支持 BLE 设备信息
        completion(nil)
    }
    
    // MARK: - BLE 信息变更回调实现（TCP不支持，提供空实现）
    
    func onChangeBleWriteInfo(characteristicUuid: String, propertyName: String, isActive: Bool) {
        print("⚠️ TCP连接不支持 BLE 写入信息变更")
    }
    
    func onChangeBleDescriptorInfo(characteristicUuid: String, propertyName: String, isActive: Bool) {
        print("⚠️ TCP连接不支持 BLE 描述符信息变更")
    }
    
}
