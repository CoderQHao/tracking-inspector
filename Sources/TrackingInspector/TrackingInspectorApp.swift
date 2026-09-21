//
//  TrackingInspectorApp.swift
//  TrackingInspector
//
//  Created by DongQing on 2026/9/20.
//  Copyright © 2026 DongQing. All rights reserved.
//

import AppKit
import InspectorCore
import SwiftUI

@main
struct TrackingInspectorApp: App {
    @NSApplicationDelegateAdaptor(InspectorAppDelegate.self) private var delegate

    var body: some Scene {
        Window("Tracking Inspector", id: "inspector") {
            InspectorWindow(appDelegate: delegate)
        }
        .defaultSize(width: 1440, height: 900)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra("Tracking Inspector", systemImage: "waveform.path") {
            InspectorMenu(appDelegate: delegate)
        }
    }
}

private struct InspectorWindow: View {
    @ObservedObject var appDelegate: InspectorAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HSplitView {
            DeviceSidebar(model: appDelegate.model, showingManualConnection: $appDelegate.showingManualConnection)
                .frame(minWidth: 230, idealWidth: 250, maxWidth: 320)
            InspectorWebView(model: appDelegate.model).frame(minWidth: 880)
        }
        .frame(minWidth: 1120, minHeight: 720)
        .sheet(isPresented: $appDelegate.showingManualConnection) { ManualConnectionSheet(model: appDelegate.model) }
        .onAppear { appDelegate.reopenWindow = { openWindow(id: "inspector") } }
    }
}

private struct InspectorMenu: View {
    @ObservedObject var appDelegate: InspectorAppDelegate
    @ObservedObject private var model: InspectorModel
    @Environment(\.openWindow) private var openWindow

    init(appDelegate: InspectorAppDelegate) {
        self.appDelegate = appDelegate
        model = appDelegate.model
    }

    var body: some View {
        Button("打开埋点观察台") { showWindow() }
            .keyboardShortcut("1", modifiers: .command)
        Divider()
        Text("\(model.connectedDeviceCount) / \(model.channels.generations.count) 台已连接")
        ForEach(model.displayDevices.filter { model.isEnabled($0.id) }) { device in
            Text("\(device.name) · \(model.status(device.id))")
        }
        Divider()
        Button("连接设备…") {
            showWindow()
            appDelegate.showingManualConnection = true
        }
        Button("刷新 USB 设备") { model.refreshUSB() }
        Divider()
        Text("关闭窗口后继续采集")
        Button("退出 Tracking Inspector") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private func showWindow() {
        openWindow(id: "inspector")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct DeviceSidebar: View {
    @ObservedObject var model: InspectorModel
    @Binding var showingManualConnection: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("设备", systemImage: "iphone.and.arrow.forward").font(.headline)
                Spacer()
                Button { model.refreshUSB() } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新 USB 设备").accessibilityLabel("刷新设备")
            }
            Text("已选择 \(model.channels.generations.count) / 8 台")
                .font(.subheadline).foregroundStyle(.secondary)
            Button { showingManualConnection = true } label: {
                Label("连接设备…", systemImage: "plus")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.displayDevices.isEmpty {
                        Text("尚未发现设备\n在手机埋点观察台复制连接信息，点「连接设备」粘贴即可连接。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.displayDevices) { device in DeviceRow(device: device, model: model) }
                }
            }
            Divider()
            Text(model.discoveryStatus).font(.caption).foregroundStyle(.secondary)
            Text("每台局域网设备需单独配对。自动发现不可用时，可粘贴手机连接信息。\n连接验证后，同一手机自动合并；优先 USB，断开后尝试已配对的局域网。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct DeviceRow: View {
    let device: InspectorDevice
    @ObservedObject var model: InspectorModel
    @State private var pairingCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(device.name, isOn: Binding(get: { model.isEnabled(device.id) }, set: { model.setEnabled($0, device: device) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12, weight: .medium))
            Text(model.status(device.id)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.transportSummary(device.id)).font(.caption2).foregroundStyle(.secondary)
            if model.hasWireless(device.id), model.isEnabled(device.id) {
                SecureField("此设备的配对码", text: $pairingCode)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.pair(device.id, code: pairingCode) }
                    .accessibilityLabel("\(device.name) 配对码")
                Button("配对") { model.pair(device.id, code: pairingCode) }
                    .accessibilityLabel("配对 \(device.name)")
            }
            ForEach(model.manualEndpoints(for: device.id)) { endpoint in
                Button("移除 \(endpoint.name)") { model.removeManualDevice(endpoint.id) }
                    .font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.isEnabled(device.id) ? Color.teal.opacity(0.09) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ManualConnectionSheet: View {
    let model: InspectorModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var code = ""
    @State private var error = ""
    @State private var manualExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接设备").font(.title2.bold())
            Text("在手机「埋点观察台」点击「复制连接信息」，然后在这里粘贴并连接。")
                .font(.callout).foregroundStyle(.secondary)
            Button {
                guard let text = NSPasteboard.general.string(forType: .string) else {
                    error = "剪贴板中没有连接信息，请先在手机复制。"
                    return
                }
                connect { try model.addConnectionInfo(text) }
            } label: {
                Label("粘贴并连接", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            DisclosureGroup("手动填写地址和配对码", isExpanded: $manualExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("IPv4 地址:端口", text: $address).textFieldStyle(.roundedBorder)
                    SecureField("32 位配对码", text: $code).textFieldStyle(.roundedBorder)
                    Button("连接此地址") { connectManually() }
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || code.isEmpty)
                }
                .padding(.top, 10)
                .onSubmit { connectManually() }
            }
            Text("两台设备需能通过局域网互相访问。地址会保存在本机，Mac 退出后需重新配对；手机重新开启无线时，请复制新的连接信息。")
                .font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func connectManually() {
        connect { try model.addManualDevice(address: address, code: code) }
    }

    private func connect(_ action: () throws -> Void) {
        do {
            try action()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
final class InspectorAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let model = InspectorModel()
    @Published var showingManualConnection = false
    var reopenWindow: (() -> Void)?

    func applicationDidFinishLaunching(_: Notification) {
        model.start()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        reopenWindow?()
        NSApp.activate(ignoringOtherApps: true)
        return false
    }

    func applicationWillTerminate(_: Notification) {
        model.stop()
    }
}
