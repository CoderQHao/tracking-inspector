//
//  InspectorModel.swift
//  TrackingInspector
//
//  Created by DongQing on 2026/9/20.
//  Copyright © 2026 DongQing. All rights reserved.
//

import Combine
import Foundation
import InspectorCore
import Network

struct InspectorDevice: Identifiable, Equatable {
    enum Transport: Equatable { case usb(String), wireless(NWEndpoint), demo }
    let id: String
    let name: String
    let transport: Transport
}

@MainActor
final class InspectorModel: ObservableObject {
    @Published var devices: [InspectorDevice] = []
    @Published var selection: String = UserDefaults.standard.string(forKey: "selectedDevice") ?? "" {
        didSet {
            guard oldValue != selection else { return }
            generation += 1
            activeFetch?.cancel()
            pairingCode = keys[selection] ?? ""
            UserDefaults.standard.set(selection, forKey: "selectedDevice")
        }
    }

    @Published var pairingCode = ""
    @Published var discoveryStatus = "正在查找设备…"
    @Published var connectionStatus = "等待选择设备"
    private var usb: [InspectorDevice] = []
    private var wireless: [InspectorDevice] = []
    private var keys: [String: String] = [:]
    private var browser: NWBrowser?
    private var timer: Timer?
    private var refreshing = false
    private var generation = 0
    private var activeFetch: Task<[String: Any], Error>?
    private let demoStart = Date().timeIntervalSince1970
    private let demoSession = "demo-" + UUID().uuidString

    var selectedDevice: InspectorDevice? {
        devices.first { $0.id == selection }
    }

    var needsPairing: Bool {
        if case .wireless = selectedDevice?.transport { return true }
        return false
    }

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: InspectorProtocol.serviceType, domain: nil), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.wireless = results.compactMap { result in
                    guard case let .service(name, type, domain, _) = result.endpoint,
                          type == InspectorProtocol.serviceType else { return nil }
                    return InspectorDevice(id: "wifi:\(name)@\(domain)", name: "Wi-Fi · \(name)", transport: .wireless(result.endpoint))
                }.sorted { $0.name < $1.name }
                self?.mergeDevices()
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.discoveryStatus = "USB / 局域网自动发现"
                case .waiting, .failed: self?.discoveryStatus = "无线发现暂不可用，请检查局域网权限；USB 仍可使用"
                default: break
                }
            }
        }
        browser.start(queue: DispatchQueue(label: "tracking-inspector.discovery"))
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshUSB() }
        }
        refreshUSB()
    }

    func refreshUSB() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let result = await Task.detached(priority: .utility) { Result { try USBMuxClient.devices() } }.value
            refreshing = false
            switch result {
            case let .success(found):
                usb = found.map { InspectorDevice(id: "usb:\($0.serial)", name: "USB · \($0.serial.suffix(8))", transport: .usb($0.serial)) }
            case .failure: usb = []
            }
            mergeDevices()
        }
    }

    func pair() {
        do {
            _ = try WirelessSecurity.key(pairingCode)
            keys[selection] = pairingCode
            generation += 1
            activeFetch?.cancel()
            connectionStatus = "正在验证配对并连接…"
        } catch { connectionStatus = error.localizedDescription }
    }

    private func mergeDevices() {
        let updated = usb + wireless + [InspectorDevice(id: "demo", name: "界面演示（模拟数据）", transport: .demo)]
        if devices != updated { devices = updated }
        if selection.isEmpty, usb.count == 1 { selection = usb[0].id }
        // Retain a disappeared selection. Never silently switch to another device.
    }

    func fetch(after: Int, session: String) async -> [String: Any] {
        let sourceID = selection
        let revision = generation
        do {
            guard let device = selectedDevice else {
                throw InspectorFailure(selection.isEmpty ? "请在窗口顶部选择设备。USB 需运行 Debug App；无线需在手机内开启埋点观察台。" : "选中的设备已断开，正在等待同一设备重新连接。")
            }
            let prefix = sourceID + "|"
            let sameSource = session.hasPrefix(prefix)
            let cursor = sameSource ? after : 0
            let rawSession = sameSource ? String(session.dropFirst(prefix.count)) : ""
            let code = keys[sourceID] ?? ""
            let demo = demoSnapshot(after: cursor, session: rawSession)
            let operation = Task<[String: Any], Error> {
                switch device.transport {
                case let .usb(serial):
                    return try await Task.detached(priority: .utility) {
                        try USBMuxClient.fetch(serial: serial, after: cursor, session: rawSession)
                    }.value
                case let .wireless(endpoint):
                    guard !code.isEmpty else { throw InspectorFailure("请粘贴手机 Debug 面板上的配对码，然后点击「配对」。") }
                    return try await WirelessTransport.fetch(endpoint: endpoint, code: code, after: cursor, session: rawSession)
                case .demo: return demo
                }
            }
            activeFetch = operation
            var result = try await operation.value
            guard revision == generation, sourceID == selection else { throw CancellationError() }
            let mode: String
            switch device.transport { case .usb: mode = "usb"; case .wireless: mode = "wifi"; case .demo: mode = "demo" }
            result["session"] = prefix + (result["session"] as? String ?? "")
            result["selectionID"] = sourceID
            result["connection"] = ["mode": mode, "device": device.name]
            connectionStatus = mode == "demo" ? "模拟数据" : "已连接"
            return result
        } catch {
            guard revision == generation, sourceID == selection else {
                return ["error": "连接已切换，正在读取当前设备。", "selectionID": selection]
            }
            let message = error is CancellationError ? "连接已切换，正在读取当前设备。" : error.localizedDescription
            connectionStatus = message
            return ["error": message, "selectionID": selection]
        }
    }

    private func demoSnapshot(after cursor: Int, session: String) -> [String: Any] {
        let latest = 8 + Int((Date().timeIntervalSince1970 - demoStart) / 3)
        let cursor = session == demoSession ? cursor : 0
        let lower = max(1, latest - 499, cursor + 1)
        let upper = min(latest, lower + 99)
        let events: [[String: Any]] = lower <= upper ? (lower ... upper).map { id in
            let name = id.isMultiple(of: 3) ? "button_click" : "screen_view"
            return ["id": id, "timestamp": demoStart + Double(id - 8) * 3, "name": name,
                    "payload": ["event_info": ["event": name, "action": id.isMultiple(of: 3) ? "CLICK" : "VIEW", "current_page_name": "DEMO_PAGE"],
                                "content_info": ["id": "sample-item", "title": "这是一条模拟事件", "source": "demo"]]]
        } : []
        return ["protocolVersion": 1, "session": demoSession, "events": events,
                "oldestID": max(1, latest - 499), "latestID": latest, "nextCursor": events.last?["id"] ?? latest,
                "capacity": 500, "dropped": 0, "app": ["bundleID": "example.debug", "version": "1.0", "build": "DEMO"]]
    }
}
