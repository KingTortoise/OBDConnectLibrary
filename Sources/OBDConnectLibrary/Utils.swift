//
//  Utils.swift
//  OBDUpdater
//
//  Created by 金文武 on 2025/7/3.
//
import Foundation
// MARK: - 通用等待工具
/// 通用等待函数：循环检查条件，直到满足或超时（使用回调替代async/await以支持iOS 12.0）
/// - Parameters:
///     - condition: 等待的条件
///     - timeout: 超时时间
///     - interval: 检查间隔（默认0.1秒）
///     - completion: 完成回调，返回是否在超时前满足条件
func wait(unit condition: @escaping () -> Bool, timeout: TimeInterval, interval: TimeInterval = 0.1, completion: @escaping (Bool) -> Void) {
    let startTime = Date()
    let queue = DispatchQueue(label: "com.obdconnect.wait", qos: .userInitiated)
    
    func checkCondition() {
        queue.async {
            if condition() {
                completion(true) // 条件满足，返回成功
                return
            }
            
            // 检查超时
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed >= timeout {
                completion(false) // 超时，返回失败
                return
            }
            
            // 等待间隔后重试
            queue.asyncAfter(deadline: .now() + interval) {
                checkCondition()
            }
        }
    }
    
    checkCondition()
}
