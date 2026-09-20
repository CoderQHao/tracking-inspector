//
//  TrackingInspectorApp.swift
//  TrackingInspector
//
//  Created by DongQing on 2026/9/20.
//  Copyright © 2026 DongQing. All rights reserved.
//

import AppKit
import SwiftUI

@main
struct TrackingInspectorApp: App {
    @NSApplicationDelegateAdaptor(InspectorAppDelegate.self) private var delegate
    @StateObject private var model = InspectorModel()

    var body: some Scene {
        WindowGroup("Tracking Inspector") {
            HSplitView {
                DeviceSidebar(model: model).frame(minWidth: 230, idealWidth: 250, maxWidth: 320)
                InspectorWebView(model: model).frame(minWidth: 880)
            }
            .frame(minWidth: 1120, minHeight: 720)
            .task { model.start() }
        }
        .defaultSize(width: 1440, height: 900)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

private struct DeviceSidebar: View {
    @ObservedObject var model: InspectorModel
    @State private var showingManualConnection = false

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
                Label("手动连接…", systemImage: "plus")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.displayDevices.isEmpty {
                        Text("尚未发现设备\n在手机测试选项中开启无线读取。自动发现不到时，点「手动连接」填写手机地址。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.displayDevices) { device in DeviceRow(device: device, model: model) }
                }
            }
            Divider()
            Text(model.discoveryStatus).font(.caption).foregroundStyle(.secondary)
            Text("每台局域网设备需单独配对。自动发现依赖本地广播；跨子网时可手动连接。\n同一手机通常只选择一种连接，避免事件重复。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingManualConnection) { ManualConnectionSheet(model: model) }
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
            if device.mode != "usb", model.isEnabled(device.id) {
                SecureField("此设备的配对码", text: $pairingCode)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.pair(device.id, code: pairingCode) }
                    .accessibilityLabel("\(device.name) 配对码")
                Button("配对") { model.pair(device.id, code: pairingCode) }
                    .accessibilityLabel("配对 \(device.name)")
            }
            if device.id.hasPrefix("manual:") {
                Button("移除此地址") { model.removeManualDevice(device.id) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("手动连接设备").font(.title2.bold())
            Text("粘贴手机埋点观察台中的连接地址。无需自动发现，但两台设备必须能通过网络互相访问。")
                .font(.callout).foregroundStyle(.secondary)
            TextField("IPv4 地址:端口", text: $address).textFieldStyle(.roundedBorder)
            SecureField("32 位配对码", text: $code).textFieldStyle(.roundedBorder)
            Text("地址会保存在本机，配对码仅保留在当前进程。手机重新开启无线读取后，地址或配对码可能变化。")
                .font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("连接") {
                    do {
                        try model.addManualDevice(address: address, code: code)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || code.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

final class InspectorAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }
}
