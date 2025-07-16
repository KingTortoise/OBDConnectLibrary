//
//  Error.swift
//  OBDUpdater
//
//  Created by myrc on 2025/7/2.
//

import Foundation

public enum ConnectError: Error, LocalizedError {
    case btUnEnable
    case invalidName
    case connectionTimeout
    case connecting
    case noCompatibleDevices
    case sendTimeout
    case receiveTimeout
    case connectionFailed(Error?)
    case sendFailed(Error?)
    case receiveFailed(Error?)
    case invalidData
    case notConnected
    case unknown
    
    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Invalid input parameter"
        case .connectionTimeout: return "Connection timeout"
        case .connecting: return "Connecting"
        case .btUnEnable: return "Bluetooth is currently unavailable"
        case .noCompatibleDevices: return "No matching devices"
        case .sendTimeout: return "Send timeout"
        case .receiveTimeout: return "Receive timeout"
        case .connectionFailed(let error): return "Connection failed: \(error?.localizedDescription ?? "unknown error")"
        case .sendFailed(let error): return "Send failed: \(error?.localizedDescription ?? "unknown error")"
        case .receiveFailed(let error): return "Receive failed: \(error?.localizedDescription ?? "unknown error")"
        case .invalidData: return "Invalid Data"
        case .notConnected: return "Not connected to device"
        case .unknown: return "Unknown error"
        }
    }
}

enum State {
    case disconnected
    case connecting
    case connected
}
