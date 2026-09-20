//
//  ConnectionInfo.swift
//  InspectorCore
//
//  Created by DongQing on 2026/9/20.
//  Copyright © 2026 DongQing. All rights reserved.
//

import Foundation

/// Explicitly pasted pairing information. Never persist or log this value.
public struct ConnectionInfo {
    public let address: ManualDeviceAddress
    public let pairingCode: String

    public init(_ text: String) throws {
        let prefix = "TRACKING-INSPECTOR/1\n"
        guard text.utf8.count <= 4096 else {
            throw InspectorFailure("连接信息过长，请重新复制手机上的连接信息。")
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\r\n", with: "\n")
        guard text.hasPrefix(prefix),
              let payload = try? JSONDecoder().decode(Payload.self, from: Data(text.dropFirst(prefix.count).utf8))
        else {
            throw InspectorFailure("未找到有效的连接信息。请在手机埋点观察台点击「复制连接信息」，或展开手动填写。")
        }
        address = try ManualDeviceAddress(payload.address)
        _ = try WirelessSecurity.key(payload.pairingCode)
        pairingCode = payload.pairingCode
    }

    private struct Payload: Decodable {
        let address: String
        let pairingCode: String
    }
}
