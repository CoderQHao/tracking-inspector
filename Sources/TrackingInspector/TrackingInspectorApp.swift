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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.displayDevices.isEmpty {
                        Text("尚未发现设备\n连接 USB，或在手机 Debug 面板开启无线读取。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.displayDevices) { device in DeviceRow(device: device, model: model) }
                }
            }
            Divider()
            Text(model.discoveryStatus).font(.caption).foregroundStyle(.secondary)
            Text("勾选多台设备可同时查看。每台无线设备需单独配对。\n同一手机的 USB 和 Wi-Fi 会分别显示，通常只勾选一种连接。")
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
            if device.mode == "wifi", model.isEnabled(device.id) {
                SecureField("此设备的配对码", text: $pairingCode)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.pair(device.id, code: pairingCode) }
                    .accessibilityLabel("\(device.name) 配对码")
                Button("配对") { model.pair(device.id, code: pairingCode) }
                    .accessibilityLabel("配对 \(device.name)")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.isEnabled(device.id) ? Color.teal.opacity(0.09) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
