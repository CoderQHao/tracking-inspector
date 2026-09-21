//
//  InspectorWebView.swift
//  TrackingInspector
//
//  Created by DongQing on 2026/9/20.
//  Copyright © 2026 DongQing. All rights reserved.
//

import AppKit
import InspectorCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct InspectorWebView: NSViewRepresentable {
    let model: InspectorModel

    func makeCoordinator() -> WebBridge {
        WebBridge(model: model)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "inspector")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false
        let directory = Bundle.main.url(forResource: "Web", withExtension: nil)!
        context.coordinator.root = directory.standardizedFileURL
        web.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        return web
    }

    func updateNSView(_: WKWebView, context _: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator _: WebBridge) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "inspector", contentWorld: .page)
        nsView.stopLoading()
    }
}

@MainActor
final class WebBridge: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    private let model: InspectorModel
    var root: URL?
    private var savePanel: NSSavePanel?
    private var openPanel: NSOpenPanel?

    init(model: InspectorModel) {
        self.model = model
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url?.standardizedFileURL,
              url == root?.appendingPathComponent("index.html"),
              let value = message.body as? [String: Any], let command = value["command"] as? String
        else {
            replyHandler(nil, "拒绝来自非本地界面的请求。")
            return
        }
        switch command {
        case "recording":
            guard let version = value["version"] as? Int, version >= -1,
                  let after = value["after"] as? Int, after >= 0
            else {
                replyHandler(nil, "无效的记录读取参数。")
                return
            }
            replyHandler(model.recordingSnapshot(version: version, after: after), nil)
        case "clearRecording":
            guard let sourceID = value["sourceID"] as? String, sourceID.utf8.count <= 512 else {
                replyHandler(nil, "无效的设备标识。")
                return
            }
            model.clearRecording(sourceID: sourceID)
            replyHandler(true, nil)
        case "copy":
            guard let text = value["text"] as? String, text.utf8.count <= 1024 * 1024 else {
                replyHandler(nil, "复制内容超限。")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            replyHandler(true, nil)
        case "loadPreferences":
            replyHandler(UserDefaults.standard.string(forKey: "analysisPreferences") ?? "{}", nil)
        case "savePreferences":
            guard let text = value["text"] as? String, text.utf8.count <= 256 * 1024,
                  (try? JSONSerialization.jsonObject(with: Data(text.utf8))) is [String: Any]
            else {
                replyHandler(nil, "设置无效或超限。")
                return
            }
            UserDefaults.standard.set(text, forKey: "analysisPreferences")
            replyHandler(true, nil)
        case "import":
            guard openPanel == nil, savePanel == nil, let window = message.webView?.window else {
                replyHandler(nil, "请先完成当前文件操作。")
                return
            }
            let panel = NSOpenPanel()
            openPanel = panel
            panel.allowedContentTypes = [.json]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.beginSheetModal(for: window) { [weak self] result in
                self?.openPanel = nil
                guard result == .OK, let source = panel.url else { replyHandler(NSNull(), nil); return }
                do {
                    // Bounded read also handles a file that grows after the panel opens.
                    let handle = try FileHandle(forReadingFrom: source)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: 40 * 1024 * 1024 + 1) ?? Data()
                    guard data.count <= 40 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
                        replyHandler(nil, "记录超过 40 MB 或不是 UTF-8 文件。")
                        return
                    }
                    replyHandler(["name": source.lastPathComponent, "text": text], nil)
                } catch { replyHandler(nil, error.localizedDescription) }
            }
        case "export":
            guard savePanel == nil, openPanel == nil, let text = value["text"] as? String, text.utf8.count <= 40 * 1024 * 1024 else {
                replyHandler(nil, "正在保存或导出内容超限。")
                return
            }
            guard let window = message.webView?.window else {
                replyHandler(nil, "请在应用窗口中导出。")
                return
            }
            let panel = NSSavePanel()
            savePanel = panel
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "tracking-\(Int(Date().timeIntervalSince1970)).json"
            panel.beginSheetModal(for: window) { [weak self] result in
                self?.savePanel = nil
                guard result == .OK, let destination = panel.url else { replyHandler(false, nil); return }
                do {
                    try Data(text.utf8).write(to: destination, options: .atomic)
                    replyHandler(true, nil)
                } catch { replyHandler(nil, error.localizedDescription) }
            }
        default: replyHandler(nil, "不支持的操作。")
        }
    }

    func webView(_: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url?.standardizedFileURL
        decisionHandler(url == root?.appendingPathComponent("index.html") ? .allow : .cancel)
    }
}
