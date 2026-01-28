//
//  HexDump.swift
//  OBDConnectLibrary
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//
//  对应 Android: HexDump.kt
//

import Foundation

// MARK: - HexDump

/// 十六进制数据转换工具
///
/// 提供 Data/ByteArray 与十六进制字符串之间的转换功能。
/// 主要用于调试日志和数据展示。
///
/// - Note: 对应 Kotlin 的 `object HexDump`
public struct HexDump {
    
    /// 十六进制字符表
    private static let hexDigits: [Character] = [
        "0", "1", "2", "3", "4", "5", "6", "7",
        "8", "9", "A", "B", "C", "D", "E", "F"
    ]
    
    // MARK: - Public Methods
    
    /// 将 Data 转换为十六进制字符串（带格式化）
    ///
    /// 输出格式示例：
    /// ```
    /// 0x00000000 48 65 6C 6C 6F Hello
    /// ```
    ///
    /// - Parameter data: 要转换的数据
    /// - Returns: 格式化的十六进制字符串
    public static func dumpHexString(_ data: Data) -> String {
        return dumpHexString(data, offset: 0, length: data.count)
    }
    
    /// 将 Data 的指定范围转换为十六进制字符串（带格式化）
    ///
    /// - Parameters:
    ///   - data: 要转换的数据
    ///   - offset: 起始偏移量
    ///   - length: 要转换的长度
    /// - Returns: 格式化的十六进制字符串
    public static func dumpHexString(_ data: Data, offset: Int, length: Int) -> String {
        var result = ""
        var line: [UInt8] = Array(repeating: 0, count: 16)
        var lineIndex = 0
        
        result.append("\n0x")
        result.append(toHexString(offset))
        
        let bytes = [UInt8](data)
        let endIndex = min(offset + length, bytes.count)
        
        for i in offset..<endIndex {
            if lineIndex == 16 {
                result.append(" ")
                
                for j in 0..<16 {
                    if line[j] > 0x20 && line[j] < 0x7E {
                        result.append(Character(UnicodeScalar(line[j])))
                    } else {
                        result.append(".")
                    }
                }
                
                result.append("\n0x")
                result.append(toHexString(i))
                lineIndex = 0
            }
            
            let b = bytes[i]
            result.append(" ")
            result.append(hexDigits[Int((b >> 4) & 0x0F)])
            result.append(hexDigits[Int(b & 0x0F)])
            
            line[lineIndex] = b
            lineIndex += 1
        }
        
        // 处理最后一行不满 16 字节的情况
        if lineIndex != 16 {
            var count = (16 - lineIndex) * 3
            count += 1
            for _ in 0..<count {
                result.append(" ")
            }
            
            for i in 0..<lineIndex {
                if line[i] > 0x20 && line[i] < 0x7E {
                    result.append(Character(UnicodeScalar(line[i])))
                } else {
                    result.append(".")
                }
            }
        }
        
        return result
    }
    
    /// 将单个字节转换为十六进制字符串
    ///
    /// - Parameter byte: 要转换的字节
    /// - Returns: 两位十六进制字符串（如 "0A"）
    public static func toHexString(_ byte: UInt8) -> String {
        return toHexString(Data([byte]))
    }
    
    /// 将 Data 转换为十六进制字符串（简单格式）
    ///
    /// 输出格式示例：`48 65 6C 6C 6F`
    ///
    /// - Parameter data: 要转换的数据
    /// - Returns: 空格分隔的十六进制字符串
    public static func toHexString(_ data: Data) -> String {
        var result = ""
        for byte in data {
            let value = Int(byte)
            result.append(hexDigits[value >> 4])
            result.append(hexDigits[value & 0x0F])
            result.append(" ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
    
    /// 将整数转换为十六进制字符串
    ///
    /// - Parameter value: 要转换的整数
    /// - Returns: 八位十六进制字符串（如 "0000000A"）
    public static func toHexString(_ value: Int) -> String {
        return toHexString(toByteArray(value))
    }
    
    /// 将单个字节转换为 Data
    ///
    /// - Parameter byte: 要转换的字节
    /// - Returns: 包含单个字节的 Data
    public static func toByteArray(_ byte: UInt8) -> Data {
        return Data([byte])
    }
    
    /// 将整数转换为 Data（大端序）
    ///
    /// - Parameter value: 要转换的整数
    /// - Returns: 4 字节的 Data（大端序）
    public static func toByteArray(_ value: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes[3] = UInt8(value & 0xFF)
        bytes[2] = UInt8((value >> 8) & 0xFF)
        bytes[1] = UInt8((value >> 16) & 0xFF)
        bytes[0] = UInt8((value >> 24) & 0xFF)
        return Data(bytes)
    }
    
    /// 将十六进制字符转换为数值
    ///
    /// - Parameter char: 十六进制字符（0-9, A-F, a-f）
    /// - Returns: 对应的数值（0-15），无效字符返回 nil
    public static func toByte(_ char: Character) -> Int? {
        guard let ascii = char.asciiValue else { return nil }
        
        switch char {
        case "0"..."9":
            return Int(ascii) - Int(Character("0").asciiValue!)
        case "A"..."F":
            return Int(ascii) - Int(Character("A").asciiValue!) + 10
        case "a"..."f":
            return Int(ascii) - Int(Character("a").asciiValue!) + 10
        default:
            return nil
        }
    }
    
    /// 将十六进制字符串转换为 Data
    ///
    /// 支持带空格或不带空格的格式。
    ///
    /// - Parameter hexString: 十六进制字符串（如 "48656C6C6F" 或 "48 65 6C 6C 6F"）
    /// - Returns: 转换后的 Data，格式错误时返回 nil
    public static func fromHexString(_ hexString: String) -> Data? {
        // 移除空格
        let cleanedHex = hexString.replacingOccurrences(of: " ", with: "")
        
        // 确保是偶数长度
        guard cleanedHex.count % 2 == 0 else { return nil }
        
        var data = Data()
        var index = cleanedHex.startIndex
        
        while index < cleanedHex.endIndex {
            let nextIndex = cleanedHex.index(index, offsetBy: 2)
            let byteString = String(cleanedHex[index..<nextIndex])
            
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            
            index = nextIndex
        }
        
        return data
    }
}
