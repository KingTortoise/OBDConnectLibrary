//
//  BLEManager+DataTransfer.swift
//  OBDConnectLibrary
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//
//  对应 Android: BleManage.kt (数据发送与接收部分)
//

import Foundation
import CoreBluetooth

// MARK: - Send Data

extension BLEManager {
    
    /// 发送数据到 BLE 设备
    ///
    /// 数据发送流程：
    /// 1. 检查连接状态和 MTU 有效性
    /// 2. 等待正在进行的 RSSI 读取完成
    /// 3. 根据 MTU 大小将数据分片
    /// 4. 逐片发送，等待每片的写入回调确认
    ///
    /// - Parameters:
    ///   - data: 要发送的数据
    ///   - timeout: 超时时间（秒）
    ///   - completion: 完成回调
    public func sendData(_ data: Data?, timeout: TimeInterval, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        guard isConnected else {
            logE("\(TAG): sendData: not connected")
            completion(.failure(.notConnected))
            return
        }
        
        guard let originalData = data, !originalData.isEmpty else {
            logE("\(TAG): sendData: input data is null or empty")
            completion(.failure(.invalidData))
            return
        }
        
        // 标记当前处于发送阶段
        isDataSending = true
        isWaitingResponse = true
        
        // MTU 有效性校验
        if mtu <= 3 {
            let errorMsg = "Invalid MTU: \(mtu) (must >3)"
            logE("\(TAG): sendData: \(errorMsg)")
            isWaitingResponse = false
            isDataSending = false
            completion(.failure(.sendFailed(underlyingError: NSError(domain: "BLE", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg]))))
            return
        }
        
        let block = mtu - 3 // 单次写入最大字节（MTU-3 为协议头预留）
        let len = originalData.count
        let totalBlocks = (len + block - 1) / block // 计算总分片数
        
        logD("\(TAG): sendData: total len=\(len), block=\(block), total blocks=\(totalBlocks)")
        
        // 等待 RSSI 读取完成后发送
        waitForRssiReadComplete { [weak self] in
            self?.sendDataInternal(originalData, block: block, totalBlocks: totalBlocks, timeout: timeout, completion: completion)
        }
    }
    
    /// 内部发送逻辑
    private func sendDataInternal(_ originalData: Data, block: Int, totalBlocks: Int, timeout: TimeInterval, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        let len = originalData.count
        
        // 如果数据小于一个分片，直接发送
        if totalBlocks <= 1 {
            writeData(originalData, timeout: timeout, forceDefaultWrite: false) { [weak self] result in
                self?.isDataSending = false
                completion(result)
            }
            return
        }
        
        // 分片发送
        var currentBlock = 0
        
        func sendNextBlock() {
            guard currentBlock < totalBlocks else {
                logD("\(self.TAG): sendData: all blocks success")
                self.isDataSending = false
                completion(.success(true))
                return
            }
            
            let start = currentBlock * block
            let end = min((currentBlock + 1) * block, len)
            let currentData = originalData.subdata(in: start..<end)
            let isLastBlock = (currentBlock == totalBlocks - 1)
            
            self.writeData(currentData, timeout: timeout, forceDefaultWrite: isLastBlock) { [weak self] result in
                guard let self = self else { return }
                
                if case .failure(let error) = result {
                    logE("\(self.TAG): Block \(currentBlock) send failed: \(error.localizedDescription)")
                    self.isWaitingResponse = false
                    self.isDataSending = false
                    completion(result)
                    return
                }
                
                // 如果通知和写入用的是同一个 UUID，需要等待响应
                if self.notifyUUID == self.writeUUID {
                    self.waitForBlockResponse(timeout: self.RECEIVE_TIMEOUT) { responseResult in
                        if case .failure = responseResult {
                            logE("\(self.TAG): Block \(currentBlock) wait for response failed")
                            self.isWaitingResponse = false
                            self.isDataSending = false
                            completion(responseResult)
                            return
                        }
                        
                        currentBlock += 1
                        sendNextBlock()
                    }
                } else {
                    currentBlock += 1
                    sendNextBlock()
                }
            }
        }
        
        sendNextBlock()
    }
    
    /// 分片数据写入
    private func writeData(_ dataArray: Data, timeout: TimeInterval, forceDefaultWrite: Bool, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        guard let characteristic = readWriteCharacteristic else {
            let errorMsg = "GattCharacteristic is null."
            logE("\(TAG): writeData: \(errorMsg)")
            completion(.failure(.sendFailed(underlyingError: NSError(domain: "BLE", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg]))))
            return
        }
        
        // 并发控制
        writingLock.lock()
        if isWriting {
            writingLock.unlock()
            logE("\(TAG): writeData: concurrent write detected")
            completion(.failure(.sendFailed(underlyingError: NSError(domain: "BLE", code: -1, userInfo: [NSLocalizedDescriptionKey: "Concurrent write not allowed"]))))
            return
        }
        isWriting = true
        writingLock.unlock()
        
        // 清空并填充写入队列
        writeQueueLock.lock()
        writeQueueBuffer.removeAll()
        writeQueueBuffer.append(contentsOf: dataArray)
        writeQueueLock.unlock()
        
        logD("\(TAG): writeData: put data to queue, size=\(dataArray.count), data=\(HexDump.toHexString(dataArray))")
        
        // 确定写入类型
        let currentWriteType: CBCharacteristicWriteType = forceDefaultWrite ? .withResponse : writeType
        
        // 保存当前发送数据
        sendDataLock.lock()
        currentSendData = dataArray
        sendDataLock.unlock()
        
        // 保存完成回调
        writeCompletion = { [weak self] result in
            self?.writingLock.lock()
            self?.isWriting = false
            self?.writingLock.unlock()
            completion(result)
        }
        
        // 执行写入
        connectedPeripheral?.writeValue(dataArray, for: characteristic, type: currentWriteType)
        
        // 对于无响应写入，需要手动完成
        if currentWriteType == .withoutResponse {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                
                self.writeQueueLock.lock()
                self.writeQueueBuffer.removeAll()
                self.writeQueueLock.unlock()
                
                self.sendDataLock.lock()
                self.currentSendData = nil
                self.sendDataLock.unlock()
                
                let callback = self.writeCompletion
                self.writeCompletion = nil
                callback?(.success(true))
            }
        }
    }
    
    /// 等待设备响应
    /// 
    /// 当 notifyUUID == writeUUID 时，需要等待设备响应后再发送下一片数据。
    /// 通过检查 isWaitingResponse 标志来判断是否收到响应（在 didUpdateValueFor 中被置为 false）。
    private func waitForBlockResponse(timeout: TimeInterval, completion: @escaping (Result<Bool, ConnectError>) -> Void) {
        let startTime = Date()
        var hasCompleted = false
        
        func checkResponse() {
            if hasCompleted { return }
            
            // 检查是否已收到响应（isWaitingResponse 在 didUpdateValueFor 中被置为 false）
            if !self.isWaitingResponse {
                hasCompleted = true
                completion(.success(true))
                return
            }
            
            // 超时检测
            if Date().timeIntervalSince(startTime) > timeout {
                hasCompleted = true
                logE("\(self.TAG): waitForBlockResponse timeout after \(timeout)s")
                completion(.failure(.receiveTimeout))
                return
            }
            
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
                checkResponse()
            }
        }
        
        DispatchQueue.global().async {
            checkResponse()
        }
    }
}

