//
//  ManualDeviceAddress.swift
//  InspectorCore
//
//  Created by DongQing on 2026/9/20.
//  Copyright © 2026 DongQing. All rights reserved.
//

import Foundation
import Network

/// An explicit device endpoint; never contains a pairing key or URL credentials.
public struct ManualDeviceAddress: Equatable {
    public let host: String
    public let port: UInt16

    public init(_ input: String) throws {
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].split(separator: ".", omittingEmptySubsequences: false).count == 4,
              let address = IPv4Address(String(parts[0])),
              !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = UInt16(parts[1]), port > 0
        else {
            throw InspectorFailure("请填写手机显示的 IPv4 地址和端口，例如 192.168.1.20:54321。")
        }
        host = address.rawValue.map(String.init).joined(separator: ".")
        self.port = port
    }

    public var address: String {
        "\(host):\(port)"
    }

    public var id: String {
        "manual:\(address)"
    }

    public var endpoint: NWEndpoint {
        .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
    }
}
