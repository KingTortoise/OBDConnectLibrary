//
//  LogUtil.swift
//  OBDConnectLibrary
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//
//  对应 Android: LogUtil.kt
//

import Foundation

// MARK: - LogLevel

/// 日志级别枚举
public enum LogLevel: Int, Comparable {
    case verbose = 0
    case debug = 1
    case info = 2
    case warning = 3
    case error = 4
    case none = 5
    
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

// MARK: - LogUtil

/// 日志工具类
///
/// 提供统一的日志输出接口，支持不同级别的日志和可选的文件写入功能。
///
/// - Note: 对应 Kotlin 的 `object LogUtil`
public final class LogUtil: @unchecked Sendable {
    
    // MARK: - Singleton
    
    /// 共享实例
    public static let shared = LogUtil()
    
    // MARK: - Properties
    
    /// 默认日志标签
    public var defaultTag: String = "OBDConnect"
    
    /// 是否显示日志（全局开关）
    public var showLog: Bool = true
    
    /// 当前日志级别（低于此级别的日志不会输出）
    public var logLevel: LogLevel = .debug
    
    /// 是否写入文件
    public var writeToFile: Bool = false
    
    /// 日志文件路径
    public var logFilePath: String = ""
    
    /// 日期格式化器
    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    
    // MARK: - Private Init
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// 输出 Verbose 级别日志
    ///
    /// - Parameters:
    ///   - message: 日志内容
    ///   - tag: 日志标签（可选，默认使用 defaultTag）
    public func v(_ message: String, tag: String? = nil) {
        log(level: .verbose, message: message, tag: tag)
    }
    
    /// 输出 Debug 级别日志
    ///
    /// - Parameters:
    ///   - message: 日志内容
    ///   - tag: 日志标签（可选，默认使用 defaultTag）
    public func d(_ message: String, tag: String? = nil) {
        log(level: .debug, message: message, tag: tag)
    }
    
    /// 输出 Info 级别日志
    ///
    /// - Parameters:
    ///   - message: 日志内容
    ///   - tag: 日志标签（可选，默认使用 defaultTag）
    public func i(_ message: String, tag: String? = nil) {
        log(level: .info, message: message, tag: tag)
    }
    
    /// 输出 Warning 级别日志
    ///
    /// - Parameters:
    ///   - message: 日志内容
    ///   - tag: 日志标签（可选，默认使用 defaultTag）
    public func w(_ message: String, tag: String? = nil) {
        log(level: .warning, message: message, tag: tag)
    }
    
    /// 输出 Error 级别日志
    ///
    /// - Parameters:
    ///   - message: 日志内容
    ///   - tag: 日志标签（可选，默认使用 defaultTag）
    public func e(_ message: String, tag: String? = nil) {
        log(level: .error, message: message, tag: tag)
    }
    
    // MARK: - Private Methods
    
    /// 统一日志输出方法
    ///
    /// - Parameters:
    ///   - level: 日志级别
    ///   - message: 日志内容
    ///   - tag: 日志标签
    private func log(level: LogLevel, message: String, tag: String?) {
        // 检查是否启用日志
        guard showLog else { return }
        
        // 检查日志级别
        guard level >= logLevel else { return }
        
        let tagString = tag ?? defaultTag
        let timestamp = dateFormatter.string(from: Date())
        let levelPrefix = levelPrefix(for: level)
        
        let fullMessage = "[\(timestamp)][\(levelPrefix)][\(tagString)] \(message)"
        
        if writeToFile && !logFilePath.isEmpty {
            writeLogToFile(fullMessage)
        } else {
            print(fullMessage)
        }
    }
    
    /// 获取日志级别前缀
    ///
    /// - Parameter level: 日志级别
    /// - Returns: 级别对应的前缀字符串
    private func levelPrefix(for level: LogLevel) -> String {
        switch level {
        case .verbose:
            return "V"
        case .debug:
            return "D"
        case .info:
            return "I"
        case .warning:
            return "W"
        case .error:
            return "E"
        case .none:
            return "-"
        }
    }
    
    /// 将日志写入文件
    ///
    /// - Parameter message: 要写入的日志内容
    private func writeLogToFile(_ message: String) {
        guard !logFilePath.isEmpty else { return }
        
        let fileURL = URL(fileURLWithPath: logFilePath)
        let logMessage = message + "\n"
        
        // 确保目录存在
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("LogUtil: Failed to create log directory: \(error)")
                return
            }
        }
        
        // 追加写入
        if FileManager.default.fileExists(atPath: logFilePath) {
            do {
                let fileHandle = try FileHandle(forWritingTo: fileURL)
                fileHandle.seekToEndOfFile()
                if let data = logMessage.data(using: .utf8) {
                    fileHandle.write(data)
                }
                fileHandle.closeFile()
            } catch {
                print("LogUtil: Failed to write log: \(error)")
            }
        } else {
            // 创建新文件
            do {
                try logMessage.write(toFile: logFilePath, atomically: true, encoding: .utf8)
            } catch {
                print("LogUtil: Failed to create log file: \(error)")
            }
        }
    }
}

// MARK: - Convenience Functions

/// 便捷日志函数（全局访问）
///
/// - Parameters:
///   - message: 日志内容
///   - tag: 日志标签（可选）
public func logV(_ message: String, tag: String? = nil) {
    LogUtil.shared.v(message, tag: tag)
}

public func logD(_ message: String, tag: String? = nil) {
    LogUtil.shared.d(message, tag: tag)
}

public func logI(_ message: String, tag: String? = nil) {
    LogUtil.shared.i(message, tag: tag)
}

public func logW(_ message: String, tag: String? = nil) {
    LogUtil.shared.w(message, tag: tag)
}

public func logE(_ message: String, tag: String? = nil) {
    LogUtil.shared.e(message, tag: tag)
}
