//
//  DeviceIdentity.swift
//  InspectorCore
//
//  Created by DongQing on 2026/9/20.
//  Copyright © 2026 DongQing. All rights reserved.
//

import Foundation

/// Identity is learned only from a successfully read USB or authenticated TLS snapshot.
/// Legacy clients can merge transports within one app session.
public struct DeviceIdentity {
    public private(set) var aliases: [String: String] = [:]

    public init() {}

    public static func identifier(_ snapshot: [String: Any]) throws -> String {
        let app = snapshot["app"] as? [String: Any]
        let bundle = app?["bundleID"] as? String ?? ""
        guard bundle.utf8.count <= 256 else { throw InspectorFailure("设备标识无效。") }
        if let value = snapshot["deviceID"] as? String, let uuid = UUID(uuidString: value) {
            return "device:\(bundle):\(uuid.uuidString)"
        }
        guard let session = snapshot["session"] as? String, !session.isEmpty, session.utf8.count <= 128 else {
            throw InspectorFailure("设备会话无效。")
        }
        return "session:\(bundle):\(session)"
    }

    public func group(for endpoint: String) -> String {
        aliases[endpoint] ?? endpoint
    }

    @discardableResult
    public mutating func identify(_ endpoint: String, snapshot: [String: Any]) throws -> String {
        let identity = try Self.identifier(snapshot)
        aliases[endpoint] = identity
        return identity
    }

    public func endpoints(for group: String) -> [String] {
        aliases.filter { $0.value == group }.map(\.key).sorted()
    }

    public mutating func forget(_ endpoint: String) {
        aliases.removeValue(forKey: endpoint)
    }
}
