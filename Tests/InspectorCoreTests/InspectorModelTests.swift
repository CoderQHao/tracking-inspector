//
//  InspectorModelTests.swift
//  InspectorCoreTests
//
//  Created by DongQing on 2026/9/20.
//  Copyright © 2026 DongQing. All rights reserved.
//

import Foundation
@testable import InspectorCore
import Testing

@MainActor
struct InspectorModelTests {
    let code = "00112233445566778899aabbccddeeff"
    let deviceID = "D3AC3C42-20AA-450E-B962-5F6F4CDF4D25"

    func defaults() -> UserDefaults {
        UserDefaults(suiteName: "TrackingInspector.Tests.\(UUID().uuidString)")!
    }

    func snapshot(session: String = "one") -> [String: Any] {
        ["deviceID": deviceID, "session": session, "events": [], "latestID": 0, "nextCursor": 0, "oldestID": 1]
    }

    func read(_ model: InspectorModel, id: String, after: Int = 0, session: String = "") async throws -> [String: Any] {
        let generation = try #require(model.channels.generations[id])
        return await model.fetch(deviceID: id, generation: generation, after: after, session: session)
    }

    @Test func sameDeviceMergesAndFailoverKeepsChannelGenerationAndCursor() async throws {
        let prefs = defaults()
        var failFirst = false
        var reads: [(String, Int, String)] = []
        let model = InspectorModel(defaults: prefs) { endpoint, _, after, session in
            reads.append((endpoint.id, after, session))
            if failFirst, endpoint.id == "manual:127.0.0.1:30001" { throw InspectorFailure("offline") }
            return snapshot()
        }
        try model.addManualDevice(address: "127.0.0.1:30001", code: code)
        _ = try await read(model, id: "manual:127.0.0.1:30001")
        let group = try #require(model.channelSnapshot().first?["id"] as? String)
        _ = try await read(model, id: group)
        try model.addManualDevice(address: "127.0.0.1:30002", code: code)
        _ = try await read(model, id: "manual:127.0.0.1:30002")
        #expect(model.channelSnapshot().count == 1)
        #expect(model.displayDevices.count == 1)
        #expect((model.channelSnapshot().first?["aliases"] as? [String])?.count == 2)
        let generation = model.channels.generations[group]
        failFirst = true
        let result = try await read(model, id: group, after: 42, session: "one")
        #expect(result["error"] == nil)
        #expect(model.channels.generations[group] == generation)
        #expect(reads.suffix(2).allSatisfy { $0.1 == 42 && $0.2 == "one" })
        #expect(reads.last?.0 == "manual:127.0.0.1:30002")
        #expect(prefs.stringArray(forKey: "enabledDevices")?.count == 1)
        #expect(prefs.stringArray(forKey: "enabledDevices")?.allSatisfy { $0.hasPrefix("manual:") } == true)
        model.removeManualDevice("manual:127.0.0.1:30001")
        #expect(model.channels.generations[group] == generation)
        model.removeManualDevice("manual:127.0.0.1:30002")
        #expect(model.channelSnapshot().isEmpty)
    }

    @Test func usbPreferredAndUnplugKeepsAuthenticatedWirelessRecording() async throws {
        var modes: [String] = []
        let model = InspectorModel(defaults: defaults()) { endpoint, _, _, _ in
            modes.append(endpoint.mode)
            return snapshot()
        }
        model.updateUSB([USBDevice(id: 1, serial: "fixture-usb")])
        _ = try await read(model, id: "usb:fixture-usb")
        let group = try #require(model.channelSnapshot().first?["id"] as? String)
        try model.addManualDevice(address: "127.0.0.1:30005", code: code)
        _ = try await read(model, id: "manual:127.0.0.1:30005")
        let generation = model.channels.generations[group]
        _ = try await read(model, id: group, after: 100, session: "one")
        #expect(modes.last == "usb")
        model.updateUSB([])
        _ = try await read(model, id: group, after: 101, session: "one")
        #expect(modes.last == "lan")
        #expect(model.channels.generations[group] == generation)
        #expect(model.channelSnapshot().count == 1)
        #expect(model.channelSnapshot().first?["mode"] as? String == "lan")
        model.updateUSB([USBDevice(id: 1, serial: "fixture-usb")])
        _ = try await read(model, id: group, after: 102, session: "one")
        #expect(modes.last == "usb")
    }

    @Test func cancelledPairingResponseCannotOverwriteNewRequestOrStatus() async throws {
        var pending: CheckedContinuation<[String: Any], Error>?
        var shouldSuspend = false
        let model = InspectorModel(defaults: defaults()) { _, _, _, _ in
            if shouldSuspend {
                shouldSuspend = false
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
            return snapshot()
        }
        try model.addManualDevice(address: "127.0.0.1:30003", code: code)
        _ = try await read(model, id: "manual:127.0.0.1:30003")
        let group = try #require(model.channelSnapshot().first?["id"] as? String)
        shouldSuspend = true
        let old = Task { try await read(model, id: group) }
        while pending == nil {
            await Task.yield()
        }
        model.pair(group, code: code)
        let fresh = try await read(model, id: group)
        #expect(fresh["error"] == nil)
        pending?.resume(returning: snapshot(session: "stale"))
        let stale = try await old.value
        #expect(stale["superseded"] as? Bool == true)
        #expect(model.status(group).hasPrefix("已连接"))
    }

    @Test func reusedAddressCannotPublishAnotherDeviceUnderOldIdentity() async throws {
        var identity = deviceID
        let model = InspectorModel(defaults: defaults()) { _, _, _, _ in
            ["deviceID": identity, "session": "one", "events": [], "latestID": 0, "nextCursor": 0, "oldestID": 1]
        }
        try model.addManualDevice(address: "127.0.0.1:30004", code: code)
        _ = try await read(model, id: "manual:127.0.0.1:30004")
        let oldGroup = try #require(model.channelSnapshot().first?["id"] as? String)
        identity = "6E4CA9CD-EC10-48C2-A151-07A9B4845141"
        let result = try await read(model, id: oldGroup)
        #expect(result["superseded"] as? Bool == true)
        #expect(model.channelSnapshot().count == 1)
        #expect(model.channelSnapshot().first?["id"] as? String != oldGroup)
    }
}
