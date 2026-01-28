//
//  ConnectErrorTests.swift
//  OBDConnectLibraryTests
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//

import XCTest
@testable import OBDConnectLibrary

/// ConnectError 单元测试
final class ConnectErrorTests: XCTestCase {
    
    // MARK: - Error Description Tests
    
    /// 测试蓝牙不可用错误
    func testBluetoothUnavailable() {
        let error = ConnectError.bluetoothUnavailable
        XCTAssertNotNil(error.errorDescription, "Should have error description")
        XCTAssertTrue(error.errorDescription?.contains("Bluetooth") ?? false)
    }
    
    /// 测试正在连接错误
    func testConnecting() {
        let error = ConnectError.connecting
        XCTAssertNotNil(error.errorDescription)
    }
    
    /// 测试未连接错误
    func testNotConnected() {
        let error = ConnectError.notConnected
        XCTAssertNotNil(error.errorDescription)
    }
    
    /// 测试连接超时错误
    func testConnectionTimeout() {
        let error = ConnectError.connectionTimeout
        XCTAssertNotNil(error.errorDescription)
    }
    
    /// 测试发送超时错误
    func testSendTimeout() {
        let error = ConnectError.sendTimeout
        XCTAssertNotNil(error.errorDescription)
    }
    
    /// 测试接收超时错误
    func testReceiveTimeout() {
        let error = ConnectError.receiveTimeout
        XCTAssertNotNil(error.errorDescription)
    }
    
    /// 测试无效名称错误
    func testInvalidName() {
        let error = ConnectError.invalidName
        XCTAssertNotNil(error.errorDescription)
    }
    
    /// 测试连接失败错误（带底层错误）
    func testConnectionFailedWithUnderlyingError() {
        let underlyingError = NSError(domain: "Test", code: 123, userInfo: [NSLocalizedDescriptionKey: "Test error"])
        let error = ConnectError.connectionFailed(underlyingError: underlyingError)
        
        XCTAssertNotNil(error.errorDescription)
        // errorDescription 使用 localizedDescription，应该包含 "Test error"
        XCTAssertTrue(error.errorDescription?.contains("Test error") ?? false)
    }
    
    /// 测试连接失败错误（无底层错误）
    func testConnectionFailedWithoutUnderlyingError() {
        let error = ConnectError.connectionFailed(underlyingError: nil)
        XCTAssertNotNil(error.errorDescription)
    }
    
    /// 测试发送失败错误
    func testSendFailed() {
        let underlyingError = NSError(domain: "Test", code: 456, userInfo: nil)
        let error = ConnectError.sendFailed(underlyingError: underlyingError)
        
        XCTAssertNotNil(error.errorDescription)
    }
    
    // MARK: - Error Equality Tests
    
    /// 测试错误比较
    func testErrorEquality() {
        let error1 = ConnectError.bluetoothUnavailable
        let error2 = ConnectError.bluetoothUnavailable
        let error3 = ConnectError.connecting
        
        // 简单错误应该相等
        XCTAssertEqual(error1.errorDescription, error2.errorDescription)
        XCTAssertNotEqual(error1.errorDescription, error3.errorDescription)
    }
}
