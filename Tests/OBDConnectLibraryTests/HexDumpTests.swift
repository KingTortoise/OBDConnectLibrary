//
//  HexDumpTests.swift
//  OBDConnectLibraryTests
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//

import XCTest
@testable import OBDConnectLibrary

/// HexDump 单元测试
final class HexDumpTests: XCTestCase {
    
    // MARK: - toHexString Tests
    
    /// 测试空数据
    func testEmptyData() {
        let data = Data()
        let result = HexDump.toHexString(data)
        XCTAssertEqual(result, "", "Empty data should return empty string")
    }
    
    /// 测试单字节数据
    func testSingleByte() {
        let data = Data([0x0A])
        let result = HexDump.toHexString(data)
        XCTAssertEqual(result, "0A", "Single byte should be formatted correctly")
    }
    
    /// 测试多字节数据
    func testMultipleBytes() {
        let data = Data([0x01, 0x02, 0x0A, 0xFF])
        let result = HexDump.toHexString(data)
        XCTAssertEqual(result, "01 02 0A FF", "Multiple bytes should be space-separated")
    }
    
    /// 测试整数转换
    func testIntegerConversion() {
        let result = HexDump.toHexString(255)
        XCTAssertTrue(result.contains("FF"), "Should contain FF for value 255")
    }
    
    // MARK: - fromHexString Tests
    
    /// 测试从十六进制字符串转换
    func testFromHexStringBasic() {
        let result = HexDump.fromHexString("010203")
        XCTAssertEqual(result, Data([0x01, 0x02, 0x03]))
    }
    
    /// 测试带空格的十六进制字符串
    func testFromHexStringWithSpaces() {
        let result = HexDump.fromHexString("01 02 03")
        XCTAssertEqual(result, Data([0x01, 0x02, 0x03]))
    }
    
    /// 测试大小写混合
    func testFromHexStringMixedCase() {
        let result = HexDump.fromHexString("aB cD eF")
        XCTAssertEqual(result, Data([0xAB, 0xCD, 0xEF]))
    }
    
    /// 测试空字符串
    func testFromHexStringEmpty() {
        let result = HexDump.fromHexString("")
        XCTAssertEqual(result, Data())
    }
    
    /// 测试无效字符串
    func testFromHexStringInvalid() {
        let result = HexDump.fromHexString("GH")
        // 无效字符应返回 nil
        XCTAssertNil(result)
    }
    
    /// 测试奇数长度字符串
    func testFromHexStringOddLength() {
        let result = HexDump.fromHexString("123")
        // 奇数长度应返回 nil
        XCTAssertNil(result)
    }
    
    // MARK: - toByte Tests
    
    /// 测试字符转数值
    func testToByteValidChars() {
        XCTAssertEqual(HexDump.toByte("0"), 0)
        XCTAssertEqual(HexDump.toByte("9"), 9)
        XCTAssertEqual(HexDump.toByte("A"), 10)
        XCTAssertEqual(HexDump.toByte("F"), 15)
        XCTAssertEqual(HexDump.toByte("a"), 10)
        XCTAssertEqual(HexDump.toByte("f"), 15)
    }
    
    /// 测试无效字符
    func testToByteInvalidChars() {
        XCTAssertNil(HexDump.toByte("G"))
        XCTAssertNil(HexDump.toByte("Z"))
        XCTAssertNil(HexDump.toByte(" "))
    }
    
    // MARK: - toByteArray Tests
    
    /// 测试整数转 Data
    func testToByteArrayInt() {
        let data = HexDump.toByteArray(0x12345678)
        XCTAssertEqual(data.count, 4)
        XCTAssertEqual(data[0], 0x12)
        XCTAssertEqual(data[1], 0x34)
        XCTAssertEqual(data[2], 0x56)
        XCTAssertEqual(data[3], 0x78)
    }
    
    // MARK: - dumpHexString Tests
    
    /// 测试格式化输出
    func testDumpHexString() {
        let data = "Hello".data(using: .utf8)!
        let result = HexDump.dumpHexString(data)
        
        XCTAssertTrue(result.contains("48"), "Should contain hex for 'H'")
        XCTAssertTrue(result.contains("65"), "Should contain hex for 'e'")
        XCTAssertTrue(result.contains("Hello") || result.contains("ello"), "Should contain ASCII representation")
    }
}
