# OBDConnectLibrary 使用指南

## 概述

OBDConnectLibrary 是一个 iOS 蓝牙（BLE）和 TCP 连接管理库，提供统一的接口用于设备扫描、连接、数据传输等功能。

该库从 Android Connect 库移植而来，保持了 100% 的逻辑一致性。

## 系统要求

- iOS 12.0+
- Swift 5.0+
- Xcode 14.0+

## 安装

### Swift Package Manager

在 Xcode 中：
1. File → Add Packages...
2. 输入仓库 URL
3. 选择版本规则
4. 添加到项目

或在 `Package.swift` 中添加：

```swift
dependencies: [
    .package(url: "https://github.com/your-org/OBDConnectLibrary.git", from: "1.0.0")
]
```

### CocoaPods

```ruby
pod 'OBDConnectLibrary', '~> 1.0'
```

## 快速开始

### 1. 导入库

```swift
import OBDConnectLibrary
```

### 2. 初始化连接管理器

```swift
// 初始化 BLE 连接
let context = ConnectManager.shared.initManager(type: .ble)

// 或初始化 TCP 连接
let context = ConnectManager.shared.initManager(type: .wifi)
```

### 3. 设置回调

```swift
// 设备断开连接回调
ConnectManager.shared.onDeviceDisconnect = {
    print("Device disconnected")
}

// 发现新设备回调（BLE 扫描）
ConnectManager.shared.onDeviceFound = { devices in
    for device in devices {
        print("Found: \(device.name ?? "Unknown") - RSSI: \(device.rssi)")
    }
}

// 接收数据回调
ConnectManager.shared.onDataReceived = { data in
    print("Received: \(data.count) bytes")
}

// RSSI 更新回调
ConnectManager.shared.onHandleRssiUpdate = { rssi in
    print("RSSI: \(rssi)")
}
```

### 4. 扫描设备（BLE）

```swift
ConnectManager.shared.startScan { result in
    switch result {
    case .success:
        print("Scan started")
    case .failure(let error):
        print("Scan failed: \(error.localizedDescription)")
    }
}

// 停止扫描
ConnectManager.shared.stopScan()
```

### 5. 连接设备

```swift
// BLE 连接（使用设备 UUID）
ConnectManager.shared.connect(name: deviceUUID) { result in
    switch result {
    case .success(let connected):
        print("Connected: \(connected)")
    case .failure(let error):
        print("Connection failed: \(error.localizedDescription)")
    }
}

// TCP 连接（格式: ip:port:timeout）
ConnectManager.shared.connect(name: "192.168.1.100:8080:5000") { result in
    // ...
}
```

### 6. 发送数据

```swift
let data = "AT+VERSION\r\n".data(using: .utf8)!

ConnectManager.shared.write(data: data, timeout: 10.0) { result in
    switch result {
    case .success:
        print("Data sent successfully")
    case .failure(let error):
        print("Send failed: \(error.localizedDescription)")
    }
}
```

### 7. 关闭连接

```swift
ConnectManager.shared.close()
```

## BLE 特定功能

### 获取设备信息

```swift
ConnectManager.shared.getBleDeviceInfo { info in
    guard let info = info else { return }
    
    // 广播数据
    if let broadcast = info.broadcastData {
        print("Device Name: \(broadcast.localName ?? "Unknown")")
    }
    
    // 设备信息
    if let deviceInfo = info.deviceInfo {
        print("Manufacturer: \(deviceInfo.manufacturerName ?? "Unknown")")
        print("Model: \(deviceInfo.modelNumber ?? "Unknown")")
    }
    
    // 服务列表
    for service in info.serviceInfo {
        print("Service: \(service.uuid)")
        for char in service.characteristics {
            print("  Characteristic: \(char.uuid)")
        }
    }
}
```

### 更改写入配置

```swift
// 切换写入特征值
ConnectManager.shared.onChangeBleWriteInfo(
    uuid: "FFE1",
    typeName: "writeWithResponse",
    status: true
)

// 切换通知/指示订阅
ConnectManager.shared.onChangeBleDescriptorInfo(
    uuid: "FFE1",
    typeName: "notify",
    status: true
)
```

## TCP 特定功能

### 连接格式

TCP 连接使用格式: `ip:port:timeout`

- `ip`: 服务器 IP 地址
- `port`: 端口号
- `timeout`: 连接超时时间（毫秒）

```swift
ConnectManager.shared.connect(name: "192.168.1.100:8080:5000") { result in
    // 连接到 192.168.1.100:8080，超时 5 秒
}
```

### 数据接收

TCP 连接需要手动启动数据接收监听：

```swift
// 启动数据接收
ConnectManager.shared.startTCPReceiveMonitoring()

// 停止数据接收
ConnectManager.shared.stopTCPReceiveMonitoring()
```

## 错误处理

库定义了 `ConnectError` 枚举来表示各种错误：

```swift
switch error {
case .bluetoothUnavailable:
    print("蓝牙不可用")
case .connecting:
    print("正在连接中")
case .notConnected:
    print("未连接")
case .connectionTimeout:
    print("连接超时")
case .connectionFailed(let underlyingError):
    print("连接失败: \(underlyingError?.localizedDescription ?? "Unknown")")
case .sendFailed(let underlyingError):
    print("发送失败: \(underlyingError?.localizedDescription ?? "Unknown")")
case .sendTimeout:
    print("发送超时")
case .receiveTimeout:
    print("接收超时")
case .invalidName:
    print("无效的设备名称/地址")
}
```

## 工具类

### HexDump

用于十六进制数据转换：

```swift
// Data 转十六进制字符串
let data = Data([0x01, 0x02, 0x03])
let hex = HexDump.toHexString(data) // "01 02 03"

// 十六进制字符串转 Data
let data = HexDump.fromHexString("01 02 03") // Data([0x01, 0x02, 0x03])
```

### LogUtil

用于日志输出：

```swift
logD("Debug message")
logI("Info message")
logW("Warning message")
logE("Error message")
```

## 线程安全

- 所有回调都在主线程执行
- 内部使用 `NSLock` 保证数据访问的线程安全
- 可以从任何线程调用公开方法

## 与 Android 版本的差异

1. **Context 参数**: iOS 版本不需要 Android Context
2. **经典蓝牙**: iOS 不支持 SPP，`.bt` 类型返回 nil
3. **异步模型**: 使用闭包回调替代 Kotlin 协程
4. **数据流**: 使用回调替代 Kotlin Flow
5. **Java 兼容方法**: iOS 版本不需要 `*Java()` 后缀方法

## 权限配置

在 `Info.plist` 中添加蓝牙权限：

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>需要蓝牙权限来连接 OBD 设备</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>需要蓝牙权限来连接 OBD 设备</string>
```

如果使用后台蓝牙：

```xml
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
</array>
```

## 示例代码

完整的使用示例：

```swift
import OBDConnectLibrary

class BluetoothManager {
    
    func setup() {
        // 初始化
        _ = ConnectManager.shared.initManager(type: .ble)
        
        // 设置回调
        ConnectManager.shared.onDeviceFound = { [weak self] devices in
            self?.handleDevicesFound(devices)
        }
        
        ConnectManager.shared.onDataReceived = { [weak self] data in
            self?.handleDataReceived(data)
        }
        
        ConnectManager.shared.onDeviceDisconnect = { [weak self] in
            self?.handleDisconnect()
        }
    }
    
    func scan() {
        ConnectManager.shared.startScan { result in
            if case .failure(let error) = result {
                print("Scan error: \(error)")
            }
        }
    }
    
    func connect(to device: DiscoveredDevice) {
        ConnectManager.shared.stopScan()
        
        ConnectManager.shared.connect(name: device.identifier) { result in
            switch result {
            case .success:
                print("Connected!")
            case .failure(let error):
                print("Connection error: \(error)")
            }
        }
    }
    
    func sendCommand(_ command: String) {
        guard let data = command.data(using: .utf8) else { return }
        
        ConnectManager.shared.write(data: data, timeout: 10.0) { result in
            if case .failure(let error) = result {
                print("Send error: \(error)")
            }
        }
    }
    
    func disconnect() {
        ConnectManager.shared.close()
    }
    
    private func handleDevicesFound(_ devices: Set<DiscoveredDevice>) {
        for device in devices {
            print("Found: \(device.name ?? "Unknown")")
        }
    }
    
    private func handleDataReceived(_ data: Data) {
        let hex = HexDump.toHexString(data)
        print("Received: \(hex)")
    }
    
    private func handleDisconnect() {
        print("Disconnected")
    }
}
```

## 问题排查

### 蓝牙不可用

- 检查设备是否支持 BLE
- 检查蓝牙是否已开启
- 检查权限是否已授权

### 连接失败

- 确保设备在范围内
- 检查设备 UUID 是否正确
- 尝试重新扫描设备

### 数据发送失败

- 确保已成功连接
- 检查特征值是否支持写入
- 检查 MTU 大小是否足够

## 版本历史

- **1.0.0**: 初始版本
  - BLE 连接支持
  - TCP 连接支持
  - 统一 ConnectManager 接口
