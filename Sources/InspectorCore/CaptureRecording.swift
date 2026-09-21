//
//  CaptureRecording.swift
//  InspectorCore
//
//  Created by DongQing on 2026/9/21.
//  Copyright © 2026 DongQing. All rights reserved.
//

import Foundation

/// Application-owned cursors and bounded recordings. Views only read snapshots.
@MainActor
final class CaptureRecording {
    struct Source {
        let id: String
        let name: String
        let generation: String
        let mode: String
        let aliases: [String]

        init?(_ value: [String: Any]) {
            guard let id = value["id"] as? String, let name = value["name"] as? String,
                  let generation = value["generation"] as? String, let mode = value["mode"] as? String else { return nil }
            self.id = id
            self.name = name
            self.generation = generation
            self.mode = mode
            aliases = value["aliases"] as? [String] ?? []
        }
    }

    final class Channel {
        var source: Source
        var session = ""
        var cursor = 0
        var latestID = 0
        var missed = 0
        var trimmed = 0
        var clearRequested = false
        var epoch = UUID().uuidString
        var acceptedEpochs: Set<String> = []
        var connected = false
        var error = "正在连接…"
        var app: [String: Any] = [:]
        var dropped = 0
        var mode: String

        init(_ source: Source) {
            self.source = source
            mode = source.mode
            acceptedEpochs = [epoch]
        }
    }

    struct Event {
        var value: [String: Any]
        let id: Int
        var sourceID: String
        let session: String
        let arrival: Int
        var bytes: Int
    }

    private(set) var channels: [String: Channel] = [:]
    private(set) var events: [Event] = []
    private(set) var sequence = 0
    private(set) var version = 0
    private let limit: Int
    private let byteLimit: Int

    init(limit: Int = 2000, byteLimit: Int = 16 * 1024 * 1024) {
        self.limit = limit
        self.byteLimit = byteLimit
    }

    func updateSources(_ values: [[String: Any]]) {
        let sources = values.compactMap(Source.init)
        for source in sources {
            let aliases = source.aliases.filter { $0 != source.id && channels[$0] != nil }
            if !aliases.isEmpty {
                merge(source, aliases: aliases)
            }
        }
        let allowed = Set(sources.map(\.id))
        for id in Array(channels.keys) where !allowed.contains(id) {
            remove(id)
        }
        for source in sources {
            if let channel = channels[source.id], channel.source.generation == source.generation {
                channel.source = source
            } else {
                remove(source.id)
                channels[source.id] = Channel(source)
            }
        }
        trim()
    }

    private func merge(_ source: Source, aliases: [String]) {
        let existing = channels[source.id]
        let donors = aliases.compactMap { channels[$0] }
        guard let preferred = existing ?? donors.first else { return }
        let target = existing ?? Channel(source)
        let matching = ([existing].compactMap { $0 } + donors).filter { $0.session == preferred.session }
        target.session = preferred.session
        target.epoch = preferred.epoch
        target.acceptedEpochs = Set(matching.flatMap { $0.acceptedEpochs })
        target.cursor = matching.map(\.cursor).max() ?? 0
        target.latestID = matching.map(\.latestID).max() ?? 0
        target.missed = matching.map(\.missed).max() ?? 0
        target.trimmed = matching.map(\.trimmed).max() ?? 0
        target.clearRequested = matching.contains { $0.clearRequested }
        target.app = preferred.app
        target.connected = preferred.connected
        target.error = preferred.error
        target.mode = preferred.mode
        target.dropped = preferred.dropped
        if target.clearRequested {
            target.epoch = UUID().uuidString
            target.acceptedEpochs = [target.epoch]
        }
        let related = Set(aliases + [source.id])
        var seen: Set<Int> = []
        events = events.compactMap { event in
            guard related.contains(event.sourceID) else { return event }
            guard !target.clearRequested, event.session == target.session, seen.insert(event.id).inserted else { return nil }
            var event = event
            event.sourceID = source.id
            event.value["sourceID"] = source.id
            event.value["deviceName"] = source.name
            event.value["epoch"] = target.epoch
            event.bytes = Self.size(event.value)
            return event
        }
        for id in aliases {
            channels.removeValue(forKey: id)
        }
        channels[source.id] = target
        version += 1
    }

    private func remove(_ id: String) {
        guard channels.removeValue(forKey: id) != nil else { return }
        events.removeAll { $0.sourceID == id }
        version += 1
    }

    func ingest(_ batch: [String: Any], into channel: Channel) throws {
        let source = channel.source
        guard channels[source.id] === channel else { return }
        guard let session = batch["session"] as? String,
              let latest = batch["latestID"] as? Int, let next = batch["nextCursor"] as? Int,
              let oldest = batch["oldestID"] as? Int, let incoming = batch["events"] as? [[String: Any]]
        else {
            throw InspectorFailure("采集端数据格式不兼容。")
        }
        if channel.session != session {
            events.removeAll { $0.sourceID == source.id }
            channel.session = session
            channel.cursor = 0
            channel.missed = 0
            channel.trimmed = 0
            channel.epoch = UUID().uuidString
            channel.acceptedEpochs = [channel.epoch]
            version += 1
        }
        channel.latestID = latest
        channel.app = batch["app"] as? [String: Any] ?? [:]
        channel.mode = (batch["connection"] as? [String: Any])?["mode"] as? String ?? source.mode
        channel.dropped = batch["dropped"] as? Int ?? 0
        channel.connected = true
        channel.error = ""
        if channel.clearRequested {
            // A clear takes effect at a device snapshot boundary, including in-flight backlog.
            channel.cursor = latest
            channel.clearRequested = false
            return
        }
        channel.missed += max(0, oldest - channel.cursor - 1)
        for raw in incoming {
            guard let id = raw["id"] as? Int, id > channel.cursor else { continue }
            sequence += 1
            var value = raw
            value.merge(["sourceID": source.id, "deviceName": source.name, "session": session,
                         "mode": channel.mode, "app": channel.app, "arrival": sequence, "epoch": channel.epoch]) { _, new in new }
            events.append(Event(value: value, id: id, sourceID: source.id, session: session, arrival: sequence, bytes: Self.size(value)))
        }
        channel.cursor = next
        trim()
    }

    func clear(_ sourceID: String) {
        for (id, channel) in channels where sourceID.isEmpty || sourceID == id {
            channel.missed = 0
            channel.trimmed = 0
            channel.clearRequested = true
            channel.epoch = UUID().uuidString
            channel.acceptedEpochs = [channel.epoch]
        }
        events.removeAll { sourceID.isEmpty || $0.sourceID == sourceID }
        version += 1
    }

    func snapshot(version clientVersion: Int, after: Int) -> [String: Any] {
        let reset = clientVersion != version || after > sequence
        let metadata: [[String: Any]] = channels.values.sorted { $0.source.id < $1.source.id }.map { channel in
            ["id": channel.source.id, "name": channel.source.name, "mode": channel.mode,
             "session": channel.session, "epoch": channel.epoch, "acceptedEpochs": Array(channel.acceptedEpochs), "aliases": channel.source.aliases,
             "app": channel.app, "connected": channel.connected, "error": channel.error, "dropped": channel.dropped]
        }
        return ["version": version, "sequence": sequence, "reset": reset,
                "oldestArrival": events.first?.arrival ?? sequence + 1,
                "events": events.filter { reset || $0.arrival > after }.map(\.value), "channels": metadata,
                "trimmed": channels.values.reduce(0) { $0 + $1.trimmed },
                "missed": channels.values.reduce(0) { $0 + $1.missed }]
    }

    private func trim() {
        var bytes = events.reduce(0) { $0 + $1.bytes }
        var count = 0
        while events.count - count > limit || bytes > byteLimit {
            let event = events[count]
            bytes -= event.bytes
            channels[event.sourceID]?.trimmed += 1
            count += 1
        }
        if count > 0 { events.removeFirst(count) }
    }

    private static func size(_ value: [String: Any]) -> Int {
        // Conservatively budget the JSON plus its UTF-16 presentation/search copy.
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return Int.max / 2001 }
        return data.count * 2
    }
}
