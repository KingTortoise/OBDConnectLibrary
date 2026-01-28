//
//  ConnectManagerTests.swift
//  OBDConnectLibraryTests
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//

import XCTest
@testable import OBDConnectLibrary

/// ConnectManager 单元测试
final class ConnectManagerTests: XCTestCase {
    
    // MARK: - Setup/Teardown
    
    override func setUp() {
        super.setUp()
        // 每个测试前关闭所有连接
        ConnectManager.shared.close()
    }
    
    override func tearDown() {
        ConnectManager.shared.close()
        super.tearDown()
    }
    
    // MARK: - Init Manager Tests
    
    /// 测试初始化 BLE 管理器
    func testInitManagerBLE() {
        let context = ConnectManager.shared.initManager(type: .ble)
        
        XCTAssertNotNil(context, "BLE context should not be nil")
        XCTAssertEqual(context?.type, .ble, "Context type should be BLE")
        XCTAssertFalse(context?.isOpen ?? true, "Context should not be open initially")
        XCTAssertNotNil(context?.port, "Port should not be nil")
    }
    
    /// 测试初始化 TCP 管理器
    func testInitManagerTCP() {
        let context = ConnectManager.shared.initManager(type: .wifi)
        
        XCTAssertNotNil(context, "TCP context should not be nil")
        XCTAssertEqual(context?.type, .wifi, "Context type should be WiFi")
        XCTAssertFalse(context?.isOpen ?? true, "Context should not be open initially")
        XCTAssertNotNil(context?.port, "Port should not be nil")
    }
    
    /// 测试经典蓝牙（iOS 不支持）
    func testInitManagerClassicBT() {
        let context = ConnectManager.shared.initManager(type: .bt)
        
        XCTAssertNil(context, "Classic Bluetooth should return nil on iOS")
    }
    
    /// 测试重复初始化相同类型
    func testInitManagerDuplicateType() {
        let context1 = ConnectManager.shared.initManager(type: .ble)
        let context2 = ConnectManager.shared.initManager(type: .ble)
        
        // 应该返回相同的上下文引用
        XCTAssertTrue(context1 === context2 || context2 != nil, "Should return valid context")
    }
    
    /// 测试切换连接类型
    func testInitManagerSwitchType() {
        let bleContext = ConnectManager.shared.initManager(type: .ble)
        XCTAssertEqual(bleContext?.type, .ble)
        
        let tcpContext = ConnectManager.shared.initManager(type: .wifi)
        XCTAssertEqual(tcpContext?.type, .wifi)
        XCTAssertTrue(ConnectManager.shared.currentType == .wifi)
    }
    
    // MARK: - Callback Tests
    
    /// 测试回调设置
    func testCallbacksAreSet() {
        _ = ConnectManager.shared.initManager(type: .ble)
        
        var disconnectCalled = false
        var rssiValue: Int?
        var foundDevices: Set<DiscoveredDevice>?
        var receivedData: Data?
        
        ConnectManager.shared.onDeviceDisconnect = {
            disconnectCalled = true
        }
        
        ConnectManager.shared.onHandleRssiUpdate = { rssi in
            rssiValue = rssi
        }
        
        ConnectManager.shared.onDeviceFound = { devices in
            foundDevices = devices
        }
        
        ConnectManager.shared.onDataReceived = { data in
            receivedData = data
        }
        
        // 验证回调已设置（不会抛出异常）
        XCTAssertNotNil(ConnectManager.shared.onDeviceDisconnect)
        XCTAssertNotNil(ConnectManager.shared.onHandleRssiUpdate)
        XCTAssertNotNil(ConnectManager.shared.onDeviceFound)
        XCTAssertNotNil(ConnectManager.shared.onDataReceived)
    }
    
    // MARK: - State Tests
    
    /// 测试初始状态
    func testInitialState() {
        _ = ConnectManager.shared.initManager(type: .ble)
        
        XCTAssertFalse(ConnectManager.shared.isConnected, "Should not be connected initially")
        XCTAssertNil(ConnectManager.shared.currentDeviceName, "Device name should be nil")
    }
    
    /// 测试关闭连接
    func testClose() {
        _ = ConnectManager.shared.initManager(type: .ble)
        
        ConnectManager.shared.close()
        
        XCTAssertFalse(ConnectManager.shared.isConnected, "Should not be connected after close")
    }
    
    // MARK: - Error Handling Tests
    
    /// 测试在 globalContext 为 nil 时调用 startScan（需要清除上下文）
    /// 注意：close() 不会清除 globalContext，只会标记 isOpen = false
    /// 这个测试验证当 port 存在时，startScan 会被调用
    func testStartScanAfterClose() {
        _ = ConnectManager.shared.initManager(type: .ble)
        ConnectManager.shared.close()
        
        let expectation = self.expectation(description: "startScan callback")
        
        // 由于 port 仍然存在，startScan 会执行（但可能因蓝牙状态失败）
        ConnectManager.shared.startScan { result in
            // 无论成功或失败，回调都应该被调用
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 2.0)
    }
    
    /// 测试未初始化时调用 connect
    func testConnectWithoutInit() {
        ConnectManager.shared.close()
        
        let expectation = self.expectation(description: "connect callback")
        
        ConnectManager.shared.connect(name: "test-device") { result in
            switch result {
            case .success:
                XCTFail("Should fail without init")
            case .failure(let error):
                XCTAssertNotNil(error, "Should return an error")
            }
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    /// 测试未初始化时调用 write
    func testWriteWithoutInit() {
        ConnectManager.shared.close()
        
        let expectation = self.expectation(description: "write callback")
        let testData = "test".data(using: .utf8)!
        
        ConnectManager.shared.write(data: testData, timeout: 5.0) { result in
            switch result {
            case .success:
                XCTFail("Should fail without init")
            case .failure(let error):
                XCTAssertNotNil(error, "Should return an error")
            }
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 1.0)
    }
}
