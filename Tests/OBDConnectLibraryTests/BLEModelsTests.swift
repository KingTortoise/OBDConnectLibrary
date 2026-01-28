//
//  BLEModelsTests.swift
//  OBDConnectLibraryTests
//
//  Created by OBDConnectLibrary on 2026/01/28.
//  Copyright © 2026 OBDConnectLibrary. All rights reserved.
//

import XCTest
@testable import OBDConnectLibrary

/// BLE 数据模型单元测试
final class BLEModelsTests: XCTestCase {
    
    // MARK: - DiscoveredDevice Tests
    
    /// 测试 DiscoveredDevice 创建
    func testDiscoveredDeviceCreation() {
        let device = DiscoveredDevice(
            identifier: "12345678-1234-1234-1234-123456789012",
            name: "Test Device",
            rssi: -50
        )
        
        XCTAssertEqual(device.identifier, "12345678-1234-1234-1234-123456789012")
        XCTAssertEqual(device.name, "Test Device")
        XCTAssertEqual(device.rssi, -50)
    }
    
    /// 测试 DiscoveredDevice Hashable
    func testDiscoveredDeviceHashable() {
        let device1 = DiscoveredDevice(identifier: "uuid1", name: "Device 1", rssi: -50)
        let device2 = DiscoveredDevice(identifier: "uuid1", name: "Device 1", rssi: -50)
        let device3 = DiscoveredDevice(identifier: "uuid2", name: "Device 2", rssi: -60)
        
        // 相同设备应该相等
        XCTAssertEqual(device1, device2)
        
        // 不同设备应该不等
        XCTAssertNotEqual(device1, device3)
        
        // 可以放入 Set
        var devices: Set<DiscoveredDevice> = []
        devices.insert(device1)
        devices.insert(device2) // 相同设备，不会增加
        devices.insert(device3)
        
        XCTAssertEqual(devices.count, 2)
    }
    
    // MARK: - ConnectType Tests
    
    /// 测试 ConnectType 原始值
    func testConnectTypeRawValues() {
        XCTAssertEqual(ConnectType.wifi.rawValue, 0)
        XCTAssertEqual(ConnectType.bt.rawValue, 1)
        XCTAssertEqual(ConnectType.ble.rawValue, 2)
    }
    
    /// 测试从原始值创建
    func testConnectTypeFromRawValue() {
        XCTAssertEqual(ConnectType(rawValue: 0), .wifi)
        XCTAssertEqual(ConnectType(rawValue: 1), .bt)
        XCTAssertEqual(ConnectType(rawValue: 2), .ble)
        XCTAssertNil(ConnectType(rawValue: 99))
    }
    
    // MARK: - ConnectState Tests
    
    /// 测试 ConnectState 枚举
    func testConnectState() {
        let disconnected = ConnectState.disconnected
        let connecting = ConnectState.connecting
        let connected = ConnectState.connected
        
        XCTAssertNotEqual(disconnected, connecting)
        XCTAssertNotEqual(connecting, connected)
        XCTAssertNotEqual(connected, disconnected)
    }
    
    // MARK: - VLContext Tests
    
    /// 测试 VLContext 创建
    func testVLContextCreation() {
        let context = VLContext(type: .ble, name: "Device", isOpen: false, port: nil)
        
        XCTAssertEqual(context.type, .ble)
        XCTAssertEqual(context.name, "Device")
        XCTAssertFalse(context.isOpen)
        XCTAssertNil(context.port)
    }
    
    /// 测试 VLContext 默认值
    func testVLContextDefaults() {
        let context = VLContext(type: .wifi)
        
        XCTAssertEqual(context.type, .wifi)
        XCTAssertNil(context.name)
        XCTAssertFalse(context.isOpen)
        XCTAssertNil(context.port)
    }
    
    /// 测试 VLContext 可修改
    func testVLContextMutable() {
        let context = VLContext(type: .ble)
        
        context.name = "Updated Device"
        context.isOpen = true
        
        XCTAssertEqual(context.name, "Updated Device")
        XCTAssertTrue(context.isOpen)
    }
}
