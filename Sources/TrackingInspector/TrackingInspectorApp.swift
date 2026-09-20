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
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.path.ecg").foregroundStyle(.teal)
                    Picker("设备", selection: $model.selection) {
                        Text("选择设备…").tag("")
                        if !model.selection.isEmpty, model.selectedDevice == nil {
                            Text("原设备已断开，等待重连").tag(model.selection)
                        }
                        ForEach(model.devices) { device in Text(device.name).tag(device.id) }
                    }.frame(maxWidth: 360)
                    if model.needsPairing {
                        SecureField("手机上的配对码", text: $model.pairingCode)
                            .frame(width: 220).onSubmit { model.pair() }
                        Button("配对") { model.pair() }
                    }
                    Spacer()
                    Button { model.refreshUSB() } label: { Image(systemName: "arrow.clockwise") }
                        .help("刷新 USB 设备")
                }.padding(.horizontal, 18).padding(.vertical, 12)
                HStack {
                    Text(model.discoveryStatus)
                    Spacer()
                    Text(model.connectionStatus).lineLimit(1).truncationMode(.middle)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 10)
                Divider()
                InspectorWebView(model: model)
            }
            .frame(minWidth: 940, minHeight: 640)
            .task { model.start() }
        }
        .defaultSize(width: 1240, height: 850)
        .commands { CommandGroup(replacing: .newItem) {} }
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
