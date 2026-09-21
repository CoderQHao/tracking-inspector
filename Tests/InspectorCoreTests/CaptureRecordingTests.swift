//
//  CaptureRecordingTests.swift
//  InspectorCoreTests
//
//  Created by DongQing on 2026/9/21.
//  Copyright © 2026 DongQing. All rights reserved.
//

import Foundation
@testable import InspectorCore
import Testing

@MainActor
struct CaptureRecordingTests {
    func source(_ id: String, generation: String = "g", aliases: [String] = []) -> [String: Any] {
        ["id": id, "name": "Phone \(id)", "mode": "usb", "generation": generation, "aliases": aliases]
    }

    func batch(_ ids: [Int], session: String = "s", latest: Int? = nil, oldest: Int = 1) -> [String: Any] {
        ["session": session, "oldestID": oldest, "latestID": latest ?? ids.last ?? 0, "nextCursor": ids.last ?? 0,
         "events": ids.map { ["id": $0, "timestamp": Double($0), "name": "play_click", "payload": ["value": "中文"]] }]
    }

    func ingest(_ store: CaptureRecording, _ id: String, _ batch: [String: Any]) throws {
        try store.ingest(batch, into: #require(store.channels[id]))
    }

    @Test func deviceSessionsDeduplicateAndRestartIndependently() throws {
        let store = CaptureRecording()
        store.updateSources([source("a"), source("b")])
        try ingest(store, "a", batch([1, 2]))
        try ingest(store, "a", batch([1, 2, 3]))
        try ingest(store, "b", batch([1, 2]))
        #expect(store.events.count == 5)
        let oldEpoch = store.channels["a"]?.epoch
        try ingest(store, "a", batch([1], session: "new"))
        #expect(store.events.map(\.id) == [1, 2, 1])
        #expect(store.channels["a"]?.cursor == 1)
        #expect(store.channels["a"]?.epoch != oldEpoch)
        #expect(store.channels["b"]?.cursor == 2)
    }

    @Test func clearRejectsInFlightBacklogAndPreservesOtherDevices() throws {
        let store = CaptureRecording()
        store.updateSources([source("a"), source("b")])
        try ingest(store, "a", batch([1]))
        try ingest(store, "b", batch([1]))
        store.clear("a")
        try ingest(store, "a", batch([2, 3], latest: 8))
        #expect(store.channels["a"]?.cursor == 8)
        #expect(store.events.map(\.sourceID) == ["b"])
        try ingest(store, "a", batch([9]))
        #expect(store.events.map(\.id) == [1, 9])
        store.clear("")
        try ingest(store, "a", batch([1, 2], session: "restarted", latest: 6))
        #expect(store.events.isEmpty)
        #expect(store.channels["a"]?.cursor == 6)
    }

    @Test func retentionAndViewRecreationUseOneNativeRecording() throws {
        let store = CaptureRecording(limit: 3)
        store.updateSources([source("a"), source("b")])
        try ingest(store, "a", batch([4, 5], oldest: 4))
        let before = store.snapshot(version: -1, after: 0)
        try ingest(store, "b", batch([1, 2]))
        let delta = try store.snapshot(version: store.version, after: #require(before["sequence"] as? Int))
        #expect(delta["reset"] as? Bool == false)
        #expect((delta["events"] as? [[String: Any]])?.count == 2)
        #expect(store.events.map(\.id) == [5, 1, 2])
        #expect(delta["trimmed"] as? Int == 1)
        #expect(delta["missed"] as? Int == 3)
        let reopened = store.snapshot(version: -1, after: 0)
        #expect(reopened["reset"] as? Bool == true)
        #expect((reopened["events"] as? [[String: Any]])?.count == 3)
        #expect((store.snapshot(version: store.version, after: store.sequence)["events"] as? [[String: Any]])?.isEmpty == true)
        let tiny = CaptureRecording(byteLimit: 1000)
        tiny.updateSources([source("a"), source("b")])
        try ingest(tiny, "a", batch([1, 2, 3]))
        try ingest(tiny, "b", batch([1, 2, 3]))
        #expect(tiny.events.reduce(0) { $0 + $1.bytes } <= 1000)
        #expect(tiny.events.count < 6)
    }

    @Test func mergedAliasesKeepCursorsArrivalOrderAndPauseIdentity() throws {
        let store = CaptureRecording()
        store.updateSources([source("a"), source("b"), source("c")])
        try ingest(store, "a", batch([1, 2]))
        try ingest(store, "b", batch([1, 2, 3]))
        try ingest(store, "c", batch([1]))
        let aEpoch = try #require(store.channels["a"]?.epoch)
        let bEpoch = try #require(store.channels["b"]?.epoch)
        let old = try #require(store.channels["a"])
        store.updateSources([source("device", aliases: ["a", "b"]), source("c")])
        #expect(store.channels["device"]?.cursor == 3)
        #expect(store.events.map(\.id) == [1, 2, 3, 1])
        #expect(store.channels["device"]?.acceptedEpochs == [aEpoch, bEpoch])
        try store.ingest(batch([4]), into: old)
        #expect(store.events.count == 4)
        var wireless = batch([3, 4])
        wireless["connection"] = ["mode": "lan"]
        try ingest(store, "device", wireless)
        #expect(store.events.last?.value["mode"] as? String == "lan")
        #expect(store.channels["device"]?.cursor == 4)
    }

    @Test func mergedClearBoundaryAndRenewedGenerationRejectHistory() throws {
        let store = CaptureRecording()
        store.updateSources([source("a"), source("b"), source("c")])
        try ingest(store, "a", batch([1]))
        try ingest(store, "b", batch([1, 2]))
        try ingest(store, "c", batch([1]))
        store.clear("a")
        store.updateSources([source("a", aliases: ["b"]), source("c")])
        try ingest(store, "a", batch([2, 3], latest: 10))
        #expect(store.channels["a"]?.cursor == 10)
        #expect(store.events.map(\.sourceID) == ["c"])
        let old = try #require(store.channels["a"])
        store.updateSources([source("a", generation: "new"), source("c")])
        try store.ingest(batch([11]), into: old)
        #expect(store.events.map(\.sourceID) == ["c"])
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 2000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw InspectorFailure("等待采集超时")
    }

    func rows(_ model: InspectorModel) -> [[String: Any]] {
        model.recordingSnapshot(version: -1, after: 0)["events"] as? [[String: Any]] ?? []
    }

    @Test func applicationCollectsWithoutAViewAndStopsScheduling() async throws {
        let defaults = try #require(UserDefaults(suiteName: "CaptureTests.\(UUID())"))
        var calls = 0
        let model = InspectorModel(defaults: defaults) { _, _, after, _ in
            calls += 1
            return batch([after + 1])
        }
        defer { model.stop() }
        try model.addManualDevice(address: "127.0.0.1:31001", code: "00112233445566778899aabbccddeeff")
        model.startCapture()
        model.startCapture()
        try await waitUntil { rows(model).count >= 2 }
        #expect(model.connectedDeviceCount == 1)
        let firstView = rows(model)
        try await waitUntil { rows(model).count > firstView.count }
        #expect(rows(model).prefix(firstView.count).map { $0["id"] as? Int } == firstView.map { $0["id"] as? Int })
        model.stop()
        let stoppedCalls = calls
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(calls == stoppedCalls)
        #expect(model.connectedDeviceCount == 0)
    }

    @Test func nativePollingPreservesRecordingAcrossUSBFallback() async throws {
        let model = try InspectorModel(defaults: #require(UserDefaults(suiteName: "CaptureTests.\(UUID())"))) { _, _, after, _ in
            batch([after + 1])
        }
        defer { model.stop() }
        model.updateUSB([USBDevice(id: 1, serial: "capture-test")])
        model.startCapture()
        try await waitUntil { rows(model).count >= 2 }
        let group = try #require(model.channelSnapshot().first?["id"] as? String)
        let generation = model.channels.generations[group]
        try model.addManualDevice(address: "127.0.0.1:31005", code: "00112233445566778899aabbccddeeff")
        try await waitUntil { model.channelSnapshot().count == 1 && model.hasWireless(group) }
        let before = rows(model).compactMap { $0["id"] as? Int }
        model.updateUSB([])
        try await waitUntil { rows(model).last?["mode"] as? String == "lan" }
        let after = rows(model).compactMap { $0["id"] as? Int }
        #expect(Array(after.prefix(before.count)) == before)
        #expect(after == Array(1 ... after.count))
        #expect(model.channels.generations[group] == generation)
        #expect(model.connectedDeviceCount == 1)
    }

    @Test func stoppingBeforeQueuedReadsStartDoesNotOpenAConnection() async throws {
        var calls = 0
        let model = try InspectorModel(defaults: #require(UserDefaults(suiteName: "CaptureTests.\(UUID())"))) { _, _, _, _ in
            calls += 1
            return batch([1])
        }
        try model.addManualDevice(address: "127.0.0.1:31004", code: "00112233445566778899aabbccddeeff")
        model.pollRecording()
        model.stop()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(calls == 0)
        #expect(rows(model).isEmpty)
    }

    @Test func slowDeviceDoesNotBlockOthersAndLateCompletionAfterStopIsRejected() async throws {
        let defaults = try #require(UserDefaults(suiteName: "CaptureTests.\(UUID())"))
        var pending: CheckedContinuation<[String: Any], Error>?
        let model = InspectorModel(defaults: defaults) { endpoint, _, after, _ in
            if endpoint.id.hasSuffix(":31002") {
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
            return batch([after + 1], session: "fast")
        }
        defer { model.stop() }
        for port in [31002, 31003] {
            try model.addManualDevice(address: "127.0.0.1:\(port)", code: "00112233445566778899aabbccddeeff")
        }
        model.startCapture()
        try await waitUntil { pending != nil && rows(model).count >= 2 }
        model.stop()
        let before = rows(model).count
        pending?.resume(returning: batch([100], session: "slow"))
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(rows(model).count == before)
        #expect(model.connectedDeviceCount == 0)
    }
}
