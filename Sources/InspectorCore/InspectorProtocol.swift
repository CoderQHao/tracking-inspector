//
//  InspectorProtocol.swift
//  InspectorCore
//
//  Created by DongQing on 2026/9/20.
//  Copyright © 2026 DongQing. All rights reserved.
//

import Foundation

public struct InspectorFailure: LocalizedError {
    public let message: String
    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public enum InspectorProtocol {
    public static let serviceType = "_trackinspect._tcp"
    public static let usbPort: UInt16 = 18765
    public static let maximumResponseBytes = 8 * 1024 * 1024

    public static func request(after: Int, session: String) throws -> Data {
        guard after >= 0, after <= 9_007_199_254_740_991, session.utf8.count <= 256 else {
            throw InspectorFailure("事件游标无效。")
        }
        var query = URLComponents()
        query.queryItems = [.init(name: "after", value: String(after)), .init(name: "session", value: session)]
        return Data("GET /events?\(query.percentEncodedQuery ?? "after=0") HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)
    }

    public static func snapshot(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumResponseBytes,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["protocolVersion"] as? Int == 1,
              let session = value["session"] as? String, !session.isEmpty, session.utf8.count <= 128,
              let latest = value["latestID"] as? Int,
              let next = value["nextCursor"] as? Int, next >= 0, next <= latest,
              let oldest = value["oldestID"] as? Int, oldest >= 1,
              latest <= 9_007_199_254_740_990,
              let events = value["events"] as? [[String: Any]], events.count <= 100
        else {
            throw InspectorFailure("采集端数据格式不兼容，请更新 Debug App。")
        }
        var previous = 0
        for event in events {
            guard let id = event["id"] as? Int, id > previous, id <= next,
                  event["name"] is String, event["timestamp"] is NSNumber,
                  event["payload"] is [String: Any]
            else {
                throw InspectorFailure("采集端返回了无效的事件。")
            }
            previous = id
        }
        return value
    }
}

/// Incremental parser shared by USB and TLS transports. No chunked bodies or redirects.
public struct HTTPResponseParser {
    private var bytes = Data()
    public init() {}

    public mutating func append(_ chunk: Data) throws -> Data? {
        bytes.append(chunk)
        guard bytes.count <= InspectorProtocol.maximumResponseBytes + 8192 else {
            throw InspectorFailure("调试响应超出大小限制。")
        }
        guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            guard bytes.count <= 8192 else { throw InspectorFailure("HTTP 响应头过大。") }
            return nil
        }
        guard boundary.lowerBound <= 8192,
              let header = String(data: bytes[..<boundary.lowerBound], encoding: .utf8)
        else {
            throw InspectorFailure("无效的 HTTP 响应头。")
        }
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first?.split(separator: " ").dropFirst().first == "200" else {
            throw InspectorFailure("采集端拒绝读取，请检查 App 版本或配对状态。")
        }
        let lengths = lines.dropFirst().compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard lengths.count == 1, let rawLength = lengths.first, let count = Int(rawLength), count >= 0,
              count <= InspectorProtocol.maximumResponseBytes,
              !lines.contains(where: { $0.lowercased().hasPrefix("transfer-encoding:") })
        else {
            throw InspectorFailure("不支持的 HTTP 响应长度。")
        }
        let body = bytes[boundary.upperBound...]
        guard body.count >= count else { return nil }
        guard body.count == count else { throw InspectorFailure("HTTP 响应包含额外数据。") }
        return Data(body)
    }
}
