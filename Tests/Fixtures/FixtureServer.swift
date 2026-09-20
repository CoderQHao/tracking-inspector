//
//  FixtureServer.swift
//  DevelopmentOnly
//
//  Created by DongQing on 2026/9/20.
//  Copyright © 2026 DongQing. All rights reserved.
//

// Compiled only by Scripts/run-fixtures.sh; never linked into TrackingInspector.app.
import Foundation
import Network

private final class FixtureServer: @unchecked Sendable {
    let name: String
    let code: String
    private let queue: DispatchQueue
    private let listener: NWListener
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var session = UUID().uuidString
    private var started = Date()
    private var paused = false

    init(name: String, code: String) throws {
        self.name = name
        self.code = code
        queue = DispatchQueue(label: name)
        listener = try NWListener(using: WirelessSecurity.parameters(code: code), on: .any)
        listener.service = .init(name: name, type: InspectorProtocol.serviceType)
        listener.stateUpdateHandler = { [weak listener] state in
            if case .ready = state, let port = listener?.port {
                print("\(name) manual address: 127.0.0.1:\(port.rawValue)")
                fflush(stdout)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    func command(_ command: String) {
        queue.async {
            if command == "restart" { self.session = UUID().uuidString; self.started = Date() }
            if command == "pause" { self.paused = true }
            if command == "resume" { self.paused = false }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.connections.removeValue(forKey: id) }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { connection.cancel() }
        receive(connection, bytes: Data())
    }

    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            let bytes = bytes + (data ?? Data())
            guard bytes.count <= 8192 else { connection.cancel(); return }
            guard bytes.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { connection.cancel() } else { receive(connection, bytes: bytes) }
                return
            }
            guard !paused else { return }
            let path = String(decoding: bytes, as: UTF8.self).split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let query = URLComponents(string: "http://localhost" + path)?.queryItems ?? []
            let requestedSession = query.first { $0.name == "session" }?.value
            let cursor = requestedSession == session ? Int(query.first { $0.name == "after" }?.value ?? "0") ?? 0 : 0
            let latest = max(1, Int(Date().timeIntervalSince(started)))
            let first = max(cursor + 1, latest - 499, 1)
            let last = min(latest, first + 99)
            let events: [[String: Any]] = first <= last ? (first ... last).map { id in
                let names = ["page_view", "episode_click", "play_start", "play_pause"]
                let event = names[(id - 1) % names.count]
                return ["id": id, "timestamp": self.started.timeIntervalSince1970 + Double(id), "name": event,
                        "payload": ["event_info": ["event": event, "action": event == "page_view" ? "VIEW" : "CLICK",
                                                   "current_page_name": event == "page_view" ? "Feed" : "Player",
                                                   "source_page_name": "Feed", "trace_page_name": "Explore"],
                                    "content_info": ["id": "sample-episode-042", "title": "A Walk Through the City", "source": "recommendation"],
                                    "extra": ["quality": "high", "playback_speed": 1.25], "test_only": true]]
            } : []
            let value: [String: Any] = ["protocolVersion": 1, "session": session, "oldestID": max(1, latest - 499),
                                        "latestID": latest, "nextCursor": events.last?["id"] ?? latest, "events": events,
                                        "capacity": 500, "dropped": 0, "app": ["bundleID": "example.fixture", "version": "test", "build": name]]
            guard let body = try? JSONSerialization.data(withJSONObject: value) else { connection.cancel(); return }
            let response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@main
private enum Fixtures {
    static func main() async throws {
        let a = try FixtureServer(name: "Inspector-Test-A", code: "00112233445566778899aabbccddeeff")
        let b = try FixtureServer(name: "Inspector-Test-B", code: "ffeeddccbbaa99887766554433221100")
        print("Development-only emitters; fixed keys authenticate synthetic events only.")
        print("\(a.name): \(a.code)\n\(b.name): \(b.code)")
        print("Commands: pause-a, resume-a, restart-a, pause-b, resume-b, restart-b. Ctrl-C stops both.")
        fflush(stdout)
        let input = Task.detached {
            while let line = readLine() {
                let parts = line.split(separator: "-")
                guard parts.count == 2 else { continue }
                (parts[1] == "a" ? a : b).command(String(parts[0]))
                print("Applied \(line)"); fflush(stdout)
            }
        }
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        withExtendedLifetime((a, b, input)) {}
    }
}
