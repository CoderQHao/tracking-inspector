//
//  CaptureChannels.swift
//  InspectorCore
//
//  Created by DongQing on 2026/9/20.
//  Copyright © 2026 DongQing. All rights reserved.
//

import Foundation

/// A request can publish only while its device and connection generation are still active.
public struct CaptureChannels {
    public static let limit = 8
    public private(set) var generations: [String: String] = [:]

    public init() {}

    public mutating func enable(_ id: String) throws {
        guard generations[id] == nil else { return }
        guard generations.count < Self.limit else { throw InspectorFailure("最多同时连接 8 台设备，请先取消一台。") }
        generations[id] = UUID().uuidString
    }

    public mutating func disable(_ id: String) {
        generations.removeValue(forKey: id)
    }

    public mutating func renew(_ id: String) {
        guard generations[id] != nil else { return }
        generations[id] = UUID().uuidString
    }

    public func accepts(_ id: String, generation: String) -> Bool {
        generations[id] == generation
    }
}
