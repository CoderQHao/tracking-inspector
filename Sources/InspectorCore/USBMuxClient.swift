//
//  USBMuxClient.swift
//  InspectorCore
//
//  Created by DongQing on 2026/9/20.
//  Copyright © 2026 DongQing. All rights reserved.
//

import Darwin
import Foundation

public struct USBDevice: Equatable {
    public let id: UInt32
    public let serial: String
}

/// Uses macOS's existing usbmuxd service; no Python, Homebrew, or subprocesses.
public enum USBMuxClient {
    public static func devices() throws -> [USBDevice] {
        let socket = try MuxSocket()
        let result = try socket.command("ListDevices")
        return (result["DeviceList"] as? [[String: Any]] ?? []).compactMap { record in
            guard let properties = record["Properties"] as? [String: Any],
                  properties["ConnectionType"] as? String == "USB",
                  let id = record["DeviceID"] as? UInt32,
                  let serial = properties["SerialNumber"] as? String else { return nil }
            return USBDevice(id: id, serial: serial)
        }
    }

    public static func fetch(serial: String, after: Int, session: String) throws -> [String: Any] {
        guard let device = try devices().first(where: { $0.serial == serial }) else {
            throw InspectorFailure("目标 USB 设备已断开。请插线、解锁，并信任这台 Mac。")
        }
        let socket = try MuxSocket()
        let result = try socket.command("Connect", values: ["DeviceID": device.id, "PortNumber": InspectorProtocol.usbPort.bigEndian])
        guard result["Number"] as? Int == 0 else {
            throw InspectorFailure("USB 已连接，等待 App 中的调试采集端。请运行 Debug App 并继续执行断点。")
        }
        try socket.send(InspectorProtocol.request(after: after, session: session))
        var parser = HTTPResponseParser()
        while true {
            let chunk = try socket.receive(maximum: 65536)
            guard !chunk.isEmpty else { throw InspectorFailure("App 在完整响应前断开了连接。") }
            if let body = try parser.append(chunk) { return try InspectorProtocol.snapshot(body) }
        }
    }
}

private final class MuxSocket {
    private let fd: Int32
    private let deadline = Date().addingTimeInterval(6)

    init() throws {
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw InspectorFailure("无法创建 USB 连接。") }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            "/var/run/usbmuxd".utf8CString.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw InspectorFailure("无法访问 macOS USB 服务。")
        }
    }

    deinit { Darwin.close(fd) }

    func command(_ name: String, values: [String: Any] = [:]) throws -> [String: Any] {
        var message: [String: Any] = ["MessageType": name, "ClientVersionString": "TrackingInspector/1", "ProgName": "TrackingInspector", "kLibUSBMuxVersion": 3]
        message.merge(values) { _, new in new }
        let payload = try PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
        var packet = Data()
        for value: UInt32 in [UInt32(payload.count + 16), 1, 8, 1] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { packet.append(contentsOf: $0) }
        }
        packet.append(payload)
        try send(packet)
        let header = try readExactly(16)
        let values = stride(from: 0, to: 16, by: 4).map { offset in
            header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        guard values[0] >= 16, values[0] <= InspectorProtocol.maximumResponseBytes,
              Array(values[1...]) == [1, 8, 1],
              let result = try PropertyListSerialization.propertyList(from: readExactly(Int(values[0]) - 16), format: nil) as? [String: Any]
        else {
            throw InspectorFailure("macOS USB 服务协议不兼容。")
        }
        return result
    }

    func send(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            try checkDeadline()
            let count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw InspectorFailure("USB 写入失败或超时。") }
            offset += count
        }
    }

    func receive(maximum: Int) throws -> Data {
        try checkDeadline()
        var bytes = [UInt8](repeating: 0, count: maximum)
        var count: Int
        repeat {
            count = Darwin.recv(fd, &bytes, maximum, 0)
        } while count < 0 && errno == EINTR && Date() < deadline
        guard count >= 0 else {
            throw InspectorFailure("读取 USB 超时，请检查断点或 App 状态。")
        }
        return Data(bytes.prefix(count))
    }

    private func readExactly(_ count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            let part = try receive(maximum: count - result.count)
            guard !part.isEmpty else { throw InspectorFailure("USB 服务已断开。") }
            result.append(part)
        }
        return result
    }

    private func checkDeadline() throws {
        guard Date() < deadline else { throw InspectorFailure("USB 请求超时。") }
    }
}
