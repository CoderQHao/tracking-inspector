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
    enum Transport: Equatable { case usb(String), wireless(NWEndpoint), unavailable }
    let id: String
    let name: String
    let transport: Transport

    var mode: String {
        switch transport {
        case .usb: "usb"
        case .wireless: "lan"
        case .unavailable: id.hasPrefix("usb:") ? "usb" : "lan"
        }
    }
}

@MainActor
final class InspectorModel: ObservableObject {
    @Published private(set) var devices: [InspectorDevice] = []
    @Published private(set) var channels = CaptureChannels()
    @Published private(set) var statuses: [String: String] = [:]
    @Published var discoveryStatus = "正在查找设备…"
    private var usb: [InspectorDevice] = []
    private var wireless: [InspectorDevice] = []
    private var manualAddresses: [ManualDeviceAddress]
    private var keys: [String: String] = [:]
    private var names: [String: String]
    private var browser: NWBrowser?
    private var timer: Timer?
    private var refreshing = false
    private var autoSelect: Bool
    private var requests: [String: (generation: String, task: Task<[String: Any], Error>)] = [:]

    init() {
        let defaults = UserDefaults.standard
        manualAddresses = Array((defaults.stringArray(forKey: "manualAddresses") ?? []).compactMap { try? ManualDeviceAddress($0) }.prefix(CaptureChannels.limit))
        names = defaults.dictionary(forKey: "deviceNames") as? [String: String] ?? [:]
        let saved = defaults.stringArray(forKey: "enabledDevices")?.filter { !["demo", "demo-a", "demo-b"].contains($0) }
        let legacy = defaults.string(forKey: "selectedDevice").flatMap { $0.isEmpty || $0 == "demo" ? nil : $0 }
        autoSelect = saved == nil && legacy == nil
        for id in (saved ?? legacy.map { [$0] } ?? []).prefix(CaptureChannels.limit) {
            try? channels.enable(id)
        }
        mergeDevices()
    }

    var displayDevices: [InspectorDevice] {
        let known = Set(devices.map(\.id))
        let missing = channels.generations.keys.filter { !known.contains($0) }.sorted().map { id in
            InspectorDevice(id: id, name: names[id] ?? "USB · \(id.suffix(8))", transport: .unavailable)
        }
        return devices + missing
    }

    func isEnabled(_ id: String) -> Bool {
        channels.generations[id] != nil
    }

    func status(_ id: String) -> String {
        statuses[id] ?? (isEnabled(id) ? "等待连接" : "未连接")
    }

    func setEnabled(_ enabled: Bool, device: InspectorDevice) {
        autoSelect = false
        if enabled {
            do { try channels.enable(device.id); names[device.id] = device.name }
            catch { setStatus(error.localizedDescription, for: device.id) }
        } else {
            channels.disable(device.id)
            cancelRequest(device.id)
            statuses.removeValue(forKey: device.id)
        }
        saveSelection()
    }

    func pair(_ id: String, code: String) {
        guard isEnabled(id) else { return }
        do {
            _ = try WirelessSecurity.key(code)
            keys[id] = code
            channels.renew(id)
            cancelRequest(id)
            setStatus("正在验证配对…", for: id)
        } catch { setStatus(error.localizedDescription, for: id) }
    }

    func addManualDevice(address: String, code: String) throws {
        let address = try ManualDeviceAddress(address)
        _ = try WirelessSecurity.key(code)
        guard manualAddresses.contains(address) || manualAddresses.count < CaptureChannels.limit else {
            throw InspectorFailure("最多保存 8 个手动地址，请先移除不再使用的地址。")
        }
        try channels.enable(address.id)
        autoSelect = false
        if !manualAddresses.contains(address) { manualAddresses.append(address) }
        names[address.id] = "地址 · \(address.address)"
        mergeDevices()
        pair(address.id, code: code)
        saveSelection()
    }

    func addConnectionInfo(_ text: String) throws {
        let info = try ConnectionInfo(text)
        try addManualDevice(address: info.address.address, code: info.pairingCode)
    }

    func removeManualDevice(_ id: String) {
        guard manualAddresses.contains(where: { $0.id == id }) else { return }
        channels.disable(id)
        cancelRequest(id)
        manualAddresses.removeAll { $0.id == id }
        keys.removeValue(forKey: id)
        names.removeValue(forKey: id)
        statuses.removeValue(forKey: id)
        mergeDevices()
        saveSelection()
    }

    func channelSnapshot() -> [[String: Any]] {
        displayDevices.compactMap { device in
            guard let generation = channels.generations[device.id] else { return nil }
            return ["id": device.id, "name": device.name, "generation": generation, "mode": device.mode]
        }
    }

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: InspectorProtocol.serviceType, domain: nil), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.wireless = results.compactMap { result in
                    guard case let .service(name, type, domain, _) = result.endpoint,
                          type.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == InspectorProtocol.serviceType else { return nil }
                    return InspectorDevice(id: "wifi:\(name)@\(domain)", name: "局域网 · \(name)", transport: .wireless(result.endpoint))
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

    private func mergeDevices() {
        var seen: Set<String> = []
        let manual = manualAddresses.map { InspectorDevice(id: $0.id, name: "地址 · \($0.address)", transport: .wireless($0.endpoint)) }
        let updated = (usb + wireless + manual).filter { seen.insert($0.id).inserted }
        if devices != updated { devices = updated }
        if autoSelect, usb.count == 1 { setEnabled(true, device: usb[0]) }
    }

    func fetch(deviceID: String, generation: String, after: Int, session: String) async -> [String: Any] {
        let identity: [String: Any] = ["sourceID": deviceID, "generation": generation]
        guard channels.accepts(deviceID, generation: generation) else { return identity.merging(["error": "连接已更新"]) { _, new in new } }
        do {
            guard let device = devices.first(where: { $0.id == deviceID }) else {
                throw InspectorFailure("设备已断开，等待同一设备重新连接。")
            }
            guard requests[deviceID] == nil else { throw InspectorFailure("正在读取上一批事件。") }
            let code = keys[deviceID] ?? ""
            let operation = Task<[String: Any], Error> {
                switch device.transport {
                case let .usb(serial):
                    return try await Task.detached(priority: .utility) {
                        try USBMuxClient.fetch(serial: serial, after: after, session: session)
                    }.value
                case let .wireless(endpoint):
                    guard !code.isEmpty else { throw InspectorFailure("请填写此设备的配对码并点击「配对」。") }
                    return try await WirelessTransport.fetch(endpoint: endpoint, code: code, after: after, session: session)
                case .unavailable: throw InspectorFailure("设备已断开。")
                }
            }
            requests[deviceID] = (generation, operation)
            defer { if requests[deviceID]?.generation == generation { requests.removeValue(forKey: deviceID) } }
            var result = try await operation.value
            guard channels.accepts(deviceID, generation: generation) else { throw CancellationError() }
            result.merge(identity) { _, new in new }
            result["connection"] = ["mode": device.mode, "device": device.name]
            setStatus("已连接", for: deviceID)
            return result
        } catch {
            let message = error is CancellationError ? "连接已更新" : error.localizedDescription
            if channels.accepts(deviceID, generation: generation) { setStatus(message, for: deviceID) }
            return identity.merging(["error": message]) { _, new in new }
        }
    }

    private func cancelRequest(_ id: String) {
        requests.removeValue(forKey: id)?.task.cancel()
    }

    private func setStatus(_ value: String, for id: String) {
        if statuses[id] != value { statuses[id] = value }
    }

    private func saveSelection() {
        let ids = channels.generations.keys.sorted()
        UserDefaults.standard.set(ids, forKey: "enabledDevices")
        UserDefaults.standard.set(names.filter { ids.contains($0.key) }, forKey: "deviceNames")
        UserDefaults.standard.set(manualAddresses.map(\.address), forKey: "manualAddresses")
    }
}
