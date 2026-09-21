//
//  InspectorModel.swift
//  InspectorCore
//
//  Created by DongQing on 2026/9/20.
//  Copyright © 2026 DongQing. All rights reserved.
//

import Combine
import Foundation
import Network

public struct InspectorDevice: Identifiable, Equatable {
    public enum Transport: Equatable { case usb(String), wireless(NWEndpoint), unavailable }
    public let id: String
    public let name: String
    public let transport: Transport

    public var mode: String {
        switch transport {
        case .usb: "usb"
        case .wireless: "lan"
        case .unavailable: id.hasPrefix("usb:") ? "usb" : "lan"
        }
    }
}

@MainActor
public final class InspectorModel: ObservableObject {
    @Published public private(set) var devices: [InspectorDevice] = []
    @Published public private(set) var channels = CaptureChannels()
    @Published public private(set) var statuses: [String: String] = [:]
    @Published public private(set) var connectedDeviceCount = 0
    @Published public var discoveryStatus = "正在查找设备…"
    private var identities = DeviceIdentity()
    private var activeEndpoints: [String: String] = [:]
    private var failedUntil: [String: Date] = [:]
    private var endpointDevices: [InspectorDevice] = []
    private var usb: [InspectorDevice] = []
    private var wireless: [InspectorDevice] = []
    private var manualAddresses: [ManualDeviceAddress]
    private var keys: [String: String] = [:]
    private var names: [String: String]
    private var browser: NWBrowser?
    private var timer: Timer?
    private var refreshing = false
    private let recording = CaptureRecording()
    private var captureLoop: Task<Void, Never>?
    private var captureRun = UUID()
    private var captureTasks: [String: (channel: CaptureRecording.Channel, token: UUID, task: Task<Void, Never>)] = [:]
    private var nextReads: [String: Date] = [:]
    private var activity: NSObjectProtocol?
    private var autoSelect: Bool
    private var requests: [String: (token: UUID, task: Task<[String: Any], Error>)] = [:]

    public typealias Reader = @MainActor (InspectorDevice, String, Int, String) async throws -> [String: Any]
    private let defaults: UserDefaults
    private let reader: Reader

    public init(defaults: UserDefaults = .standard, reader: Reader? = nil) {
        self.defaults = defaults
        self.reader = reader ?? Self.read
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

    public var displayDevices: [InspectorDevice] {
        let known = Set(devices.map(\.id))
        let missing = channels.generations.keys.filter { !known.contains($0) }.sorted().map { id in
            InspectorDevice(id: id, name: names[id] ?? "USB · \(id.suffix(8))", transport: .unavailable)
        }
        return devices + missing
    }

    public func isEnabled(_ id: String) -> Bool {
        channels.generations[id] != nil
    }

    public func status(_ id: String) -> String {
        statuses[id] ?? (isEnabled(id) ? "等待连接" : "未连接")
    }

    public func setEnabled(_ enabled: Bool, device: InspectorDevice) {
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

    public func pair(_ id: String, code: String) {
        guard isEnabled(id) else { return }
        do {
            _ = try WirelessSecurity.key(code)
            for endpoint in endpoints(for: id) where endpoint.mode == "lan" {
                keys[endpoint.id] = code
                failedUntil.removeValue(forKey: endpoint.id)
            }
            cancelRequest(id)
            setStatus("正在验证配对…", for: id)
        } catch { setStatus(error.localizedDescription, for: id) }
    }

    public func addManualDevice(address: String, code: String) throws {
        let address = try ManualDeviceAddress(address)
        _ = try WirelessSecurity.key(code)
        guard manualAddresses.contains(address) || manualAddresses.count < CaptureChannels.limit else {
            throw InspectorFailure("最多保存 8 个手动地址，请先移除不再使用的地址。")
        }
        try channels.enable(identities.group(for: address.id))
        autoSelect = false
        if !manualAddresses.contains(address) { manualAddresses.append(address) }
        names[address.id] = "地址 · \(address.address)"
        mergeDevices()
        keys[address.id] = code
        failedUntil.removeValue(forKey: address.id)
        cancelRequest(identities.group(for: address.id))
        saveSelection()
    }

    public func addConnectionInfo(_ text: String) throws {
        let info = try ConnectionInfo(text)
        try addManualDevice(address: info.address.address, code: info.pairingCode)
    }

    public func removeManualDevice(_ id: String) {
        guard manualAddresses.contains(where: { $0.id == id }) else { return }
        let group = identities.group(for: id)
        cancelRequest(group)
        identities.forget(id)
        if endpoints(for: group).allSatisfy({ $0.id == id }) { channels.disable(group) }
        manualAddresses.removeAll { $0.id == id }
        keys.removeValue(forKey: id)
        names.removeValue(forKey: id)
        statuses.removeValue(forKey: id)
        mergeDevices()
        saveSelection()
    }

    public func channelSnapshot() -> [[String: Any]] {
        displayDevices.compactMap { device in
            guard let generation = channels.generations[device.id] else { return nil }
            return ["id": device.id, "name": device.name, "generation": generation, "mode": endpointDevices.first(where: { $0.id == activeEndpoints[device.id] })?.mode ?? device.mode, "aliases": identities.endpoints(for: device.id)]
        }
    }

    public func start() {
        guard browser == nil else { return }
        startCapture()
        let run = captureRun
        let browser = NWBrowser(for: .bonjour(type: InspectorProtocol.serviceType, domain: nil), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self, captureRun == run else { return }
                wireless = results.compactMap { result in
                    guard case let .service(name, type, domain, _) = result.endpoint,
                          type.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == InspectorProtocol.serviceType else { return nil }
                    return InspectorDevice(id: "wifi:\(name)@\(domain)", name: "局域网 · \(name)", transport: .wireless(result.endpoint))
                }.sorted { $0.name < $1.name }
                mergeDevices()
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, captureRun == run else { return }
                switch state {
                case .ready: discoveryStatus = "USB / 局域网自动发现"
                case .waiting, .failed: discoveryStatus = "无线发现暂不可用，请检查局域网权限；USB 仍可使用"
                default: break
                }
            }
        }
        browser.start(queue: DispatchQueue(label: "tracking-inspector.discovery"))
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, captureRun == run else { return }
                refreshUSB()
            }
        }
        refreshUSB()
    }

    /// Capture is owned by the application, independently of windows and WebKit.
    func startCapture() {
        guard captureLoop == nil else { return }
        captureLoop = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollRecording()
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { break }
            }
        }
        updateActivity()
    }

    public func stop() {
        captureRun = UUID()
        captureLoop?.cancel()
        captureLoop = nil
        timer?.invalidate()
        timer = nil
        browser?.cancel()
        browser = nil
        for operation in captureTasks.values {
            operation.task.cancel()
        }
        captureTasks.removeAll()
        for id in Array(requests.keys) {
            cancelRequest(id)
        }
        nextReads.removeAll()
        refreshing = false
        for channel in recording.channels.values {
            channel.connected = false
            channel.error = "已停止采集"
        }
        connectedDeviceCount = 0
        updateActivity()
    }

    public func recordingSnapshot(version: Int, after: Int) -> [String: Any] {
        synchronizeRecording()
        return recording.snapshot(version: version, after: after)
    }

    public func clearRecording(sourceID: String) {
        synchronizeRecording()
        recording.clear(sourceID)
    }

    func pollRecording(now: Date = Date()) {
        synchronizeRecording()
        let run = captureRun
        for (id, channel) in recording.channels {
            guard captureTasks[id] == nil, nextReads[id, default: .distantPast] <= now else { continue }
            let token = UUID()
            let source = channel.source
            let task = Task { [weak self] in
                guard let self, captureRun == run, !Task.isCancelled, captureTasks[id]?.token == token else { return }
                let batch = await fetch(deviceID: id, generation: source.generation, after: channel.cursor, session: channel.session)
                guard captureRun == run, !Task.isCancelled, captureTasks[id]?.token == token else { return }
                captureTasks.removeValue(forKey: id)
                synchronizeRecording()
                guard recording.channels[id] === channel else { return }
                if batch["superseded"] as? Bool != true {
                    do {
                        if let error = batch["error"] as? String { throw InspectorFailure(error) }
                        try recording.ingest(batch, into: channel)
                    } catch {
                        channel.connected = false
                        channel.error = error.localizedDescription
                        setStatus(error.localizedDescription, for: id)
                    }
                }
                nextReads[id] = Date().addingTimeInterval(channel.connected && channel.cursor < channel.latestID ? 0.05 : 0.6)
                updateConnectedCount()
            }
            captureTasks[id] = (channel, token, task)
        }
    }

    private func synchronizeRecording() {
        recording.updateSources(channelSnapshot())
        for (id, operation) in captureTasks where recording.channels[id] !== operation.channel {
            operation.task.cancel()
            captureTasks.removeValue(forKey: id)
            cancelRequest(id)
            nextReads.removeValue(forKey: id)
        }
        nextReads = nextReads.filter { recording.channels[$0.key] != nil }
        updateConnectedCount()
        updateActivity()
    }

    private func updateConnectedCount() {
        let count = recording.channels.values.filter(\.connected).count
        if connectedDeviceCount != count { connectedDeviceCount = count }
    }

    private func updateActivity() {
        let needed = captureLoop != nil && !channels.generations.isEmpty
        if needed, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "接收用户选择设备的实时埋点")
        } else if !needed, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    public func refreshUSB() {
        guard !refreshing else { return }
        refreshing = true
        let run = captureRun
        Task {
            let result = await Task.detached(priority: .utility) { Result { try USBMuxClient.devices() } }.value
            guard captureRun == run else { return }
            refreshing = false
            switch result {
            case let .success(found): updateUSB(found)
            case .failure: updateUSB([])
            }
        }
    }

    func updateUSB(_ found: [USBDevice]) {
        usb = found.map { InspectorDevice(id: "usb:\($0.serial)", name: "USB · \($0.serial.suffix(8))", transport: .usb($0.serial)) }
        mergeDevices()
    }

    public func endpoints(for id: String) -> [InspectorDevice] {
        endpointDevices.filter { identities.group(for: $0.id) == id }
    }

    public func manualEndpoints(for id: String) -> [InspectorDevice] {
        endpoints(for: id).filter { $0.id.hasPrefix("manual:") }
    }

    public func hasWireless(_ id: String) -> Bool {
        endpoints(for: id).contains { $0.mode == "lan" }
    }

    public func transportSummary(_ id: String) -> String {
        let options = endpoints(for: id)
        let modes = Set(options.map(\.mode))
        let available = [modes.contains("usb") ? "USB" : nil, modes.contains("lan") ? "局域网" : nil].compactMap { $0 }.joined(separator: " + ")
        guard let active = activeEndpoints[id], let endpoint = options.first(where: { $0.id == active }) else { return available }
        return "\(available) · 当前 \(endpoint.mode == "usb" ? "USB" : "局域网")"
    }

    private func candidates(for id: String) -> [InspectorDevice] {
        endpoints(for: id).sorted {
            let left = failedUntil[$0.id, default: .distantPast] > Date()
            let right = failedUntil[$1.id, default: .distantPast] > Date()
            if left != right { return !left }
            if $0.mode != $1.mode { return $0.mode == "usb" }
            let leftPaired = keys[$0.id] != nil
            let rightPaired = keys[$1.id] != nil
            if leftPaired != rightPaired { return leftPaired }
            return $0.id < $1.id
        }
    }

    private func mergeDevices() {
        var seen: Set<String> = []
        let manual = manualAddresses.map { InspectorDevice(id: $0.id, name: "地址 · \($0.address)", transport: .wireless($0.endpoint)) }
        endpointDevices = (usb + wireless + manual).filter { seen.insert($0.id).inserted }
        seen = []
        let updated = endpointDevices.compactMap { endpoint -> InspectorDevice? in
            let id = identities.group(for: endpoint.id)
            guard seen.insert(id).inserted else { return nil }
            let current = candidates(for: id).first ?? endpoint
            let name = id == endpoint.id ? endpoint.name : (names[id] ?? "设备 · \(id.suffix(8))")
            return InspectorDevice(id: id, name: name, transport: current.transport)
        }
        if devices != updated { devices = updated }
        if autoSelect, usb.count == 1, let device = devices.first(where: { $0.id == identities.group(for: usb[0].id) }) { setEnabled(true, device: device) }
    }

    private func identify(_ endpoint: InspectorDevice, snapshot: [String: Any], previousID: String) throws -> String {
        let group = try identities.identify(endpoint.id, snapshot: snapshot)
        guard group != previousID else { return group }
        // An address reused by another device must not contribute to the old device's stream.
        let oldStillExists = !identities.endpoints(for: previousID).isEmpty
        if !oldStillExists { channels.disable(previousID) }
        if !isEnabled(group) { try channels.enable(group) }
        names[group] = "设备 · \(group.suffix(8))"
        statuses.removeValue(forKey: previousID)
        mergeDevices()
        saveSelection()
        return group
    }

    public func fetch(deviceID: String, generation: String, after: Int, session: String) async -> [String: Any] {
        let identity: [String: Any] = ["sourceID": deviceID, "generation": generation]
        let token = UUID()
        guard channels.accepts(deviceID, generation: generation) else { return identity.merging(["error": "连接已更新"]) { _, new in new } }
        do {
            guard requests[deviceID] == nil else { throw InspectorFailure("正在读取上一批事件。") }
            let choices = candidates(for: deviceID)
            guard !choices.isEmpty else { throw InspectorFailure("设备已断开，等待同一设备重新连接。") }
            var lastError: Error = InspectorFailure("设备已断开。")
            for device in choices {
                let code = keys[device.id] ?? ""
                if device.mode == "lan", code.isEmpty { lastError = InspectorFailure("请填写此设备的配对码并点击「配对」。"); continue }
                let operation = Task<[String: Any], Error> {
                    try await self.reader(device, code, after, session)
                }
                requests[deviceID] = (token, operation)
                do {
                    var result = try await operation.value
                    guard channels.accepts(deviceID, generation: generation), requests[deviceID]?.token == token else { throw CancellationError() }
                    let group = try identify(device, snapshot: result, previousID: deviceID)
                    requests.removeValue(forKey: deviceID)
                    activeEndpoints[group] = device.id
                    failedUntil.removeValue(forKey: device.id)
                    setStatus("已连接 · \(device.mode == "usb" ? "USB" : "局域网")", for: group)
                    // Canonicalization is published through channels first; the next read uses its cursor.
                    guard group == deviceID else { throw CancellationError() }
                    result.merge(identity) { _, new in new }
                    result["connection"] = ["mode": device.mode, "device": device.name]
                    return result
                } catch {
                    guard channels.accepts(deviceID, generation: generation), requests[deviceID]?.token == token else { throw CancellationError() }
                    requests.removeValue(forKey: deviceID)
                    failedUntil[device.id] = Date().addingTimeInterval(10)
                    lastError = error
                }
            }
            throw lastError
        } catch {
            if requests[deviceID]?.token == token { requests.removeValue(forKey: deviceID) }
            let message = error is CancellationError ? "连接已更新" : error.localizedDescription
            if error is CancellationError { return identity.merging(["superseded": true]) { _, new in new } }
            if channels.accepts(deviceID, generation: generation) { setStatus(message, for: deviceID) }
            return identity.merging(["error": message]) { _, new in new }
        }
    }

    private static func read(device: InspectorDevice, code: String, after: Int, session: String) async throws -> [String: Any] {
        switch device.transport {
        case let .usb(serial):
            return try await Task.detached(priority: .utility) { try USBMuxClient.fetch(serial: serial, after: after, session: session) }.value
        case let .wireless(endpoint):
            return try await WirelessTransport.fetch(endpoint: endpoint, code: code, after: after, session: session)
        case .unavailable: throw InspectorFailure("设备已断开。")
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
        let selectedEndpoints = ids.map { id in candidates(for: id).first?.id ?? id }
        defaults.set(selectedEndpoints, forKey: "enabledDevices")
        defaults.set(names.filter { ids.contains($0.key) }, forKey: "deviceNames")
        defaults.set(manualAddresses.map(\.address), forKey: "manualAddresses")
    }
}
