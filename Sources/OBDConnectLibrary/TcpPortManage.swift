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
    
    func open(context: Any, name: String, peripheral: CBPeripheral?) async -> Result<Void, ConnectError> {
        return await tcpManage.openChannel(name: name, timeout: 5.0) // 10秒连接超时
    }
    
    func write(data: Data, timeout: TimeInterval) async -> Result<Void, ConnectError> {
        return await tcpManage.write(data: data, timeout: timeout)
    }
    
    // 获取数据流
    @available(iOS 13.0, *)
    func receiveDataFlow() -> AsyncStream<Data> {
        // TCP/WiFi 暂时不支持数据流，返回空流
        return AsyncStream<Data> { continuation in
            continuation.finish()
        }
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
    
    func startScan() async -> Bool {
        // TCP/WiFi 扫描逻辑
        // WiFi 连接通常不需要扫描，因为需要手动输入 IP 地址
        // 这里可以返回一些预定义的网络地址或空数组
        print("TCP/WiFi scan - no actual scanning needed")
        return true
    }
    
    // 停止扫描（TCP/WiFi 不需要停止扫描）
    func stopScan() {
        print("TCP/WiFi scan - no need to stop")
    }
    
    
    
    // 获取扫描结果数据流（TCP/WiFi 返回空数组）
    @available(iOS 13.0, *)
    func getScanResultStream() -> AsyncStream<[Any]>? {
        // 对于 TCP/WiFi 连接，不需要扫描设备
        // 但为了保持 API 一致性，返回一个空的数据流
        return AsyncStream<[Any]> { continuation in
            Task {
                // 返回空数组，表示没有可扫描的设备
                continuation.yield([])
                continuation.finish()
            }
        }
    }
    
    func reconnect() async -> Result<Void, ConnectError> {
        // TcpPortManage 暂不支持重连，返回失败
        return .failure(.connectionFailed(NSError(domain: "TcpPortManage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Reconnect not supported for TCP"])))
    }
    
}
