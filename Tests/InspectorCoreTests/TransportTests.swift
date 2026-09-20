//
//  TransportTests.swift
//  InspectorCoreTests
//
//  Created by DongQing on 2026/9/20.
//  Copyright © 2026 DongQing. All rights reserved.
//

import Foundation
@testable import InspectorCore
import Network
import Testing

private let sample = Data(#"{"protocolVersion":1,"session":"fixture","oldestID":1,"latestID":1,"nextCursor":1,"events":[{"id":1,"timestamp":1,"name":"sample_click","payload":{"message":"模拟数据"}}]}"#.utf8)

@Test func fragmentedHTTP() throws {
    let response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(sample.count)\r\n\r\n".utf8) + sample
    var parser = HTTPResponseParser()
    for byte in response.dropLast() {
        #expect(try parser.append(Data([byte])) == nil)
    }
    #expect(try parser.append(Data([#require(response.last)])) == sample)
    #expect(try InspectorProtocol.snapshot(sample)["session"] as? String == "fixture")
}

@Test(arguments: [
    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n",
    "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: 999999999\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\nextra",
])
func rejectsInvalidHTTP(_ response: String) {
    var parser = HTTPResponseParser()
    #expect(throws: (any Error).self) { try parser.append(Data(response.utf8)) }
}

@Test func rejectsInvalidSnapshotsAndEscapesRequests() throws {
    var data = try InspectorProtocol.snapshot(sample)
    data["nextCursor"] = 0
    #expect(throws: (any Error).self) { try InspectorProtocol.snapshot(JSONSerialization.data(withJSONObject: data)) }
    data["nextCursor"] = 1
    data["protocolVersion"] = 2
    #expect(throws: (any Error).self) { try InspectorProtocol.snapshot(JSONSerialization.data(withJSONObject: data)) }
    #expect(throws: (any Error).self) { try InspectorProtocol.request(after: -1, session: "") }
    let request = try String(decoding: InspectorProtocol.request(after: 0, session: "x\r\nInjected: yes"), as: UTF8.self)
    #expect(!request.contains("\r\nInjected:"))
}

@Test func pairingKeyValidation() throws {
    #expect(try WirelessSecurity.key("0011-2233 445566778899AABBCCDDEEFF") == Data((0 ... 15).map { UInt8($0 * 17) }))
    for bad in ["123456", "", String(repeating: "g", count: 32)] {
        #expect(throws: (any Error).self) { try WirelessSecurity.key(bad) }
    }
}

@Test func encryptedTransportAndWrongKey() async throws {
    let fixture = try TLSFixture()
    let endpoint = try await fixture.start()
    defer { fixture.stop() }
    let result = try await WirelessTransport.fetch(endpoint: endpoint, code: TLSFixture.code, after: 0, session: "")
    #expect(result["latestID"] as? Int == 1)
    do {
        _ = try await WirelessTransport.fetch(endpoint: endpoint, code: String(repeating: "f", count: 32), after: 0, session: "")
        Issue.record("A wrong pairing key must never read events")
    } catch { #expect(!(error is CancellationError)) }
}

@Test func cancellationClosesPendingTransport() async throws {
    let fixture = try TLSFixture(responds: false)
    let endpoint = try await fixture.start()
    defer { fixture.stop() }
    let operation = Task { try await WirelessTransport.fetch(endpoint: endpoint, code: TLSFixture.code, after: 0, session: "") }
    try await Task.sleep(nanoseconds: 100_000_000)
    operation.cancel()
    do {
        _ = try await operation.value
        Issue.record("Cancelled request unexpectedly succeeded")
    } catch { #expect(error is CancellationError) }
}

private final class TLSFixture: @unchecked Sendable {
    static let code = "00112233445566778899aabbccddeeff" // Public test fixture, never a production pairing key.
    private let listener: NWListener
    private let queue = DispatchQueue(label: "tls-fixture")
    private let responds: Bool
    private var connections: [NWConnection] = []
    private var ready: CheckedContinuation<NWEndpoint, Error>?

    init(responds: Bool = true) throws {
        self.responds = responds
        listener = try NWListener(using: WirelessSecurity.parameters(code: Self.code), on: .any)
    }

    func start() async throws -> NWEndpoint {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                ready = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = listener.port { ready?.resume(returning: .hostPort(host: "127.0.0.1", port: port)); ready = nil }
                    case let .failed(error): ready?.resume(throwing: error); ready = nil
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    connections.append(connection)
                    connection.start(queue: queue)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                        guard self.responds else { return }
                        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(sample.count)\r\n\r\n".utf8) + sample
                        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    }
                }
                queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    self?.ready?.resume(throwing: InspectorFailure("Fixture startup timed out")); self?.ready = nil
                }
                listener.start(queue: queue)
            }
        }
    }

    func stop() {
        queue.async { self.listener.cancel(); self.connections.forEach { $0.cancel() }; self.connections.removeAll() }
    }
}
