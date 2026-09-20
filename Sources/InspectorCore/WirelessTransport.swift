//
//  WirelessTransport.swift
//  InspectorCore
//
//  Created by DongQing on 2026/9/20.
//  Copyright © 2026 DongQing. All rights reserved.
//

import Foundation
import Network
import Security

public enum WirelessSecurity {
    public static func key(_ code: String) throws -> Data {
        let code = code.filter { !$0.isWhitespace && $0 != "-" }.lowercased()
        guard code.count == 32, code.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw InspectorFailure("请粘贴手机上显示的 32 位配对码。")
        }
        var result = Data()
        var index = code.startIndex
        while index < code.endIndex {
            let next = code.index(index, offsetBy: 2)
            guard let byte = UInt8(code[index ..< next], radix: 16) else { throw InspectorFailure("配对码无效。") }
            result.append(byte)
            index = next
        }
        return result
    }

    public static func parameters(code: String) throws -> NWParameters {
        let key = try key(code)
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        // Always authenticate the current pairing key, including after a key change.
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0x00A8)!)
        let secret = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("tracking-inspector-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, secret as __DispatchData, identity as __DispatchData)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }
}

public enum WirelessTransport {
    public static func fetch(endpoint: NWEndpoint, code: String, after: Int, session: String) async throws -> [String: Any] {
        let parameters = try WirelessSecurity.parameters(code: code)
        let request = try InspectorProtocol.request(after: after, session: session)
        let transaction = NetworkTransaction(endpoint: endpoint, parameters: parameters)
        let data = try await withTaskCancellationHandler {
            try await transaction.perform(request)
        } onCancel: {
            transaction.cancel()
        }
        return try InspectorProtocol.snapshot(data)
    }
}

private final class NetworkTransaction: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tracking-inspector.tls")
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Data, Error>?
    private var parser = HTTPResponseParser()
    private var finished = false

    init(endpoint: NWEndpoint, parameters: NWParameters) {
        connection = NWConnection(to: endpoint, using: parameters)
    }

    func perform(_ request: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !finished else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self, !self.finished else { return }
                    switch state {
                    case .ready:
                        connection.send(content: request, completion: .contentProcessed { [weak self] error in
                            guard let self else { return }
                            if let error { finish(.failure(error)) } else { receive() }
                        })
                    case .failed:
                        finish(.failure(InspectorFailure("无线连接失败，请检查配对码、局域网权限和手机上的无线开关。")))
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now() + 6) { [weak self] in
                    self?.finish(.failure(InspectorFailure("无线连接超时。请确认设备在同一局域网，App 未停在断点。")))
                }
                connection.start(queue: queue)
            }
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func receive() {
        guard !finished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            do {
                if let body = try parser.append(data ?? Data()) {
                    finish(.success(body))
                } else if complete || error != nil {
                    finish(.failure(InspectorFailure("无线连接在完整响应前中断。")))
                } else {
                    receive()
                }
            } catch { finish(.failure(error)) }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }
}
