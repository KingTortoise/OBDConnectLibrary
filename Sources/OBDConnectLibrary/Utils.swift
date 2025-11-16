//
//  Utils.swift
//  OBDUpdater
//
//  Created by 金文武 on 2025/7/3.
//
import Foundation
// MARK: - 通用等待工具
/// 通用等待函数：循环检查条件，直到满足或超时
/// - Parameters:
///     - condition: 等待的条件
///     - timeout: 超时时间
///     - interval: 检查间隔（默认0.1秒）
///     - Returns: 是否在超时前满足条件
func wait(unit condition: @escaping () -> Bool, timeout: TimeInterval, interval: TimeInterval = 0.1) async -> Bool {
    let startTime = Date()
    while true {
        if condition() {
            return true // 条件满足， 返回成功
        }
        // 检查超时
        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed >= timeout {
            return false // 超时，返回失败
        }
        // 等待间隔后重试（非阻塞）
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
}
