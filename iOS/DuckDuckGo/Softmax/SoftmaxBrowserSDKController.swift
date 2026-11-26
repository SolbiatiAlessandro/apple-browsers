//
//  SoftmaxBrowserSDKController.swift
//  DuckDuckGo (Softmax Browser SDK Fork — surface: "iphone-chromia")
//
//  Connects the DuckDuckGo iOS browser to the Softmax Browser SDK & Softmax Cloud Dark Factory (AIDE v3):
//  - Injects the Softmax universal content runtime (`content-runtime.js`) and active PRDs (`spec_001`..`spec_004`)
//    into every DuckDuckGo `TabViewController` `WKWebView`.
//  - Polls `/api/browser/active-features?surface=iphone-chromia` for live PRD updates and Dark Factory build status.
//  - Provides a floating Softmax Agent & PRDs pill and SwiftUI drawer on `MainViewController` so the user can
//    talk to the Softmax Voice Agent (`MiniCPM-o-4_5` / `gpt-live-1`), toggle PRDs on iPhone, and send new PRDs
//    to the Softmax Cloud Dark Factory directly from inside DuckDuckGo iOS.
//

import Combine
import Foundation
import SwiftUI
import UIKit
import WebKit

// MARK: - Softmax Browser SDK Configuration ("iphone-chromia")

public enum SoftmaxBrowserSDKConfig {
    public static let surface = "iphone-chromia"

    public static var portalOrigin: String {
        if let env = ProcessInfo.processInfo.environment["SOFTMAX_PORTAL_ORIGIN"], !env.isEmpty {
            return env
        }
        #if targetEnvironment(simulator)
        return "http://127.0.0.1:4321"
        #else
        if let stored = UserDefaults.standard.string(forKey: "com.softmax.duckduckgo.portalOrigin"), !stored.isEmpty {
            return stored
        }
        return "http://127.0.0.1:4321"
        #endif
    }

    public static func jsQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

// MARK: - PRD & Chat Models

public struct SoftmaxPRDItem: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let description: String
    public let hostPattern: String
    public let version: String
    public var enabledOnIphone: Bool
    public var buildStatus: String // "shipped" | "in_progress" | "not_built"
    public var buildLabel: String
    public var jobId: String?
}

public struct SoftmaxAgentMessage: Identifiable, Equatable {
    public let id = UUID()
    public let role: String // "user" | "assistant"
    public let text: String
}

// MARK: - Softmax Browser SDK Runtime Coordinator

@MainActor
public final class SoftmaxBrowserSDKCoordinator: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    public static let shared = SoftmaxBrowserSDKCoordinator()

    @Published public var prds: [SoftmaxPRDItem] = []
    @Published public var chatMessages: [SoftmaxAgentMessage] = [
        SoftmaxAgentMessage(
            role: "assistant",
            text: "DuckDuckGo iOS Fork connected to Softmax Cloud Dark Factory (AIDE v3). Talk or type a PRD below, or toggle any PRD on your iPhone."
        )
    ]
    @Published public var agentInputText: String = ""
    @Published public var isSendingAgentTurn: Bool = false
    @Published public var isPlayingVoice: Bool = false
    @Published public var isConnectingVoice: Bool = false

    private var cachedFeaturesJSON: String = "[]"
    private var attachedWebViews = NSHashTable<WKWebView>.weakObjects()
    private var pollTimer: Timer?
    public let voiceBridgeWebView: WKWebView

    public weak var activeMainViewController: UIViewController?
    public var activeTabProvider: (() -> (title: String, url: String)?)?

    private override init() {
        let voiceConfig = WKWebViewConfiguration()
        voiceConfig.allowsInlineMediaPlayback = true
        voiceConfig.mediaTypesRequiringUserActionForPlayback = []
        self.voiceBridgeWebView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: voiceConfig)

        super.init()

        self.voiceBridgeWebView.navigationDelegate = self
        self.voiceBridgeWebView.uiDelegate = self
        loadVoiceBridge()
        syncSpecsFromSoftmaxDB()

        self.pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncSpecsFromSoftmaxDB()
                self?.syncVoiceButtonState()
            }
        }
    }

    // MARK: - WKUserContentController & WKWebView Integration for DuckDuckGo TabViewController

    public func installUserScripts(into userContentController: WKUserContentController) {
        let bootstrapJS = """
        window.__chromiaIosSurface = true;
        window.__duckDuckGoSoftmaxFork = true;
        window.__chromiaPortalOrigin = \(SoftmaxBrowserSDKConfig.jsQuoted(SoftmaxBrowserSDKConfig.portalOrigin));
        document.addEventListener('DOMContentLoaded', function() {
            if (document.documentElement) {
                document.documentElement.dataset.softmaxSurface = 'iphone-chromia';
                document.documentElement.dataset.softmaxBrowserFork = 'duckduckgo-ios';
            }
        });
        """
        userContentController.addUserScript(
            WKUserScript(source: bootstrapJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        let loaderJS = """
        (function() {
            if (document.documentElement) {
                document.documentElement.dataset.softmaxSurface = 'iphone-chromia';
                document.documentElement.dataset.softmaxBrowserFork = 'duckduckgo-ios';
            }
            if (!document.getElementById('softmax-ios-runtime-loader')) {
                var s = document.createElement('script');
                s.id = 'softmax-ios-runtime-loader';
                s.src = \(SoftmaxBrowserSDKConfig.jsQuoted(SoftmaxBrowserSDKConfig.portalOrigin)) + '/content-runtime.js';
                (document.head || document.documentElement).appendChild(s);
            }
        })();
        """
        userContentController.addUserScript(
            WKUserScript(source: loaderJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
    }

    public func registerWebView(_ webView: WKWebView) {
        attachedWebViews.add(webView)
        injectCachedSpecs(into: webView)
    }

    public func injectCachedSpecs(into webView: WKWebView) {
        let js = """
        window.__chromiaIosSurface = true;
        window.__duckDuckGoSoftmaxFork = true;
        if (document.documentElement) {
            document.documentElement.dataset.softmaxSurface = 'iphone-chromia';
            document.documentElement.dataset.softmaxBrowserFork = 'duckduckgo-ios';
        }
        if (window.__softmaxBrowserRuntime && typeof window.__softmaxBrowserRuntime.applyFeaturesToDocument === 'function') {
            window.__softmaxBrowserRuntime.applyFeaturesToDocument(\(cachedFeaturesJSON));
        }
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Voice Bridge (`/phone?surface=iphone-chromia`)

    public func loadVoiceBridge() {
        guard let url = URL(string: "\(SoftmaxBrowserSDKConfig.portalOrigin)/phone?surface=\(SoftmaxBrowserSDKConfig.surface)") else {
            return
        }
        voiceBridgeWebView.load(URLRequest(url: url))
    }

    public func toggleVoicePlayPause() {
        let js = """
        (function() {
            var btn = document.getElementById('softmax-btn');
            if (btn) { btn.click(); return btn.getAttribute('data-state') || 'paused'; }
            return 'paused';
        })();
        """
        voiceBridgeWebView.evaluateJavaScript(js) { [weak self] result, _ in
            Task { @MainActor in
                let state = (result as? String) ?? "paused"
                self?.isConnectingVoice = (state == "connecting")
                self?.isPlayingVoice = (state == "playing" || state == "connecting")
            }
        }
    }

    public func syncVoiceButtonState() {
        let js = "(function() { var b = document.getElementById('softmax-btn'); return b ? (b.getAttribute('data-state') || 'paused') : 'paused'; })();"
        voiceBridgeWebView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let state = result as? String else { return }
            Task { @MainActor in
                self?.isConnectingVoice = (state == "connecting")
                self?.isPlayingVoice = (state == "playing" || state == "connecting")
            }
        }
    }

    // MARK: - Softmax PRD Database & Cloud Dark Factory Sync

    public func syncSpecsFromSoftmaxDB() {
        guard let url = URL(string: "\(SoftmaxBrowserSDKConfig.portalOrigin)/api/browser/active-features?surface=\(SoftmaxBrowserSDKConfig.surface)") else {
            return
        }
        var request = URLRequest(url: url)
        request.setValue("DuckDuckGo-iOS-SoftmaxFork/1.0 (iPhone; iOS 18.1)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard error == nil, let data = data else { return }
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let features = json["features"] as? [[String: Any]],
                let featuresData = try? JSONSerialization.data(withJSONObject: features),
                let featuresJSON = String(data: featuresData, encoding: .utf8)
            else { return }

            let allFeatures = (json["allFeatures"] as? [[String: Any]]) ?? features
            var parsed: [SoftmaxPRDItem] = []
            for f in allFeatures {
                let id = (f["id"] as? String) ?? (f["jobId"] as? String) ?? "prd"
                let title = (f["title"] as? String) ?? "PRD"
                let desc = (f["description"] as? String) ?? ""
                let host = (f["hostPattern"] as? String) ?? "*"
                let ver = (f["version"] as? String) ?? "v1"
                let surfs = (f["enabledSurfaces"] as? [String]) ?? []
                let enabled = surfs.contains(SoftmaxBrowserSDKConfig.surface)
                var status = enabled ? "shipped" : "not_built"
                var label = enabled ? "Last Dark Factory job shipped" : "Not enabled"
                var jobId: String? = nil
                if let sb = f["surfaceBuilds"] as? [String: Any],
                   let phoneBuild = sb[SoftmaxBrowserSDKConfig.surface] as? [String: Any] {
                    status = (phoneBuild["status"] as? String) ?? status
                    label = (phoneBuild["statusLabel"] as? String) ?? label
                    jobId = phoneBuild["jobId"] as? String
                }
                parsed.append(
                    SoftmaxPRDItem(
                        id: id,
                        title: title,
                        description: desc,
                        hostPattern: host,
                        version: ver,
                        enabledOnIphone: enabled,
                        buildStatus: status,
                        buildLabel: label,
                        jobId: jobId
                    )
                )
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.prds = parsed
                self.cachedFeaturesJSON = featuresJSON
                for webView in self.attachedWebViews.allObjects {
                    self.injectCachedSpecs(into: webView)
                }
            }
        }.resume()
    }

    public func togglePRDOnIphone(_ prd: SoftmaxPRDItem) {
        guard let url = URL(string: "\(SoftmaxBrowserSDKConfig.portalOrigin)/api/browser/toggle-surface") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "id": prd.id,
            "surface": SoftmaxBrowserSDKConfig.surface,
            "enabled": !prd.enabledOnIphone
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            Task { @MainActor in
                self?.syncSpecsFromSoftmaxDB()
            }
        }.resume()
    }

    public func sendPromptToAgentAndDarkFactory(_ rawPrompt: String? = nil) {
        let text = (rawPrompt ?? agentInputText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSendingAgentTurn else { return }
        if rawPrompt == nil {
            agentInputText = ""
        }
        chatMessages.append(SoftmaxAgentMessage(role: "user", text: text))
        isSendingAgentTurn = true

        guard let url = URL(string: "\(SoftmaxBrowserSDKConfig.portalOrigin)/api/browser/chat-turn") else {
            isSendingAgentTurn = false
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let historyPayload: [[String: String]] = chatMessages.suffix(6).map {
            ["role": $0.role, "content": $0.text]
        }
        let tabInfo = activeTabProvider?()
        let payload: [String: Any] = [
            "surface": SoftmaxBrowserSDKConfig.surface,
            "messages": historyPayload,
            "activeTab": [
                "title": tabInfo?.title ?? "",
                "url": tabInfo?.url ?? ""
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSendingAgentTurn = false
                if let err = err {
                    self.chatMessages.append(SoftmaxAgentMessage(role: "assistant", text: "Error: \(err.localizedDescription)"))
                    return
                }
                guard
                    let data = data,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    self.chatMessages.append(SoftmaxAgentMessage(role: "assistant", text: "Sent PRD to Softmax Cloud Dark Factory."))
                    self.syncSpecsFromSoftmaxDB()
                    return
                }
                let reply = (json["reply"] as? String) ?? "Sent PRD to Softmax Cloud Dark Factory."
                self.chatMessages.append(SoftmaxAgentMessage(role: "assistant", text: reply))
                self.syncSpecsFromSoftmaxDB()
            }
        }.resume()
    }

    @available(iOS 15.0, *)
    public func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.grant)
    }
}

// MARK: - SwiftUI Drawer for DuckDuckGo iOS Fork

public struct SoftmaxDuckDuckGoAgentSheetView: View {
    @ObservedObject var coordinator: SoftmaxBrowserSDKCoordinator
    let onDismiss: () -> Void

    public init(coordinator: SoftmaxBrowserSDKCoordinator, onDismiss: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Softmax Agent & PRDs")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.primary)
                    Text("DuckDuckGo iOS Fork · Softmax Cloud Dark Factory (AIDE v3)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { coordinator.toggleVoicePlayPause() }) {
                    HStack(spacing: 5) {
                        Image(systemName: coordinator.isPlayingVoice ? "pause.fill" : "mic.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(coordinator.isConnectingVoice ? "Starting…" : (coordinator.isPlayingVoice ? "End Voice" : "Voice Call"))
                            .font(.system(size: 12, weight: .bold))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(coordinator.isPlayingVoice ? Color.red : Color(red: 0.87, green: 0.35, blue: 0.20))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button("Done", action: onDismiss)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.blue)
                    .padding(.leading, 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("YOUR PRDS ON DUCKDUCKGO IPHONE (\(coordinator.prds.filter { $0.enabledOnIphone }.count)/\(coordinator.prds.count))")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)

                    ForEach(coordinator.prds) { prd in
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(prd.title)
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text("\(prd.id) · \(prd.version)")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.14))
                                        .foregroundColor(Color(red: 0.87, green: 0.35, blue: 0.20))
                                        .clipShape(Capsule())
                                }
                                Text(prd.buildLabel)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(
                                        prd.buildStatus == "in_progress"
                                            ? .blue
                                            : (prd.enabledOnIphone ? Color(red: 0.08, green: 0.55, blue: 0.22) : .secondary)
                                    )
                            }
                            Spacer()
                            Button(action: { coordinator.togglePRDOnIphone(prd) }) {
                                Text(prd.buildStatus == "in_progress" ? "Building…" : (prd.enabledOnIphone ? "Enabled ✓" : "Build PRD"))
                                    .font(.system(size: 11.5, weight: .bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        prd.buildStatus == "in_progress"
                                            ? Color.blue.opacity(0.15)
                                            : (prd.enabledOnIphone ? Color(red: 0.09, green: 0.64, blue: 0.29) : Color(UIColor.secondarySystemFill))
                                    )
                                    .foregroundColor(
                                        prd.buildStatus == "in_progress"
                                            ? .blue
                                            : (prd.enabledOnIphone ? .white : .primary)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(11)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    Text("TALK TO AGENT → SEND TO DARK FACTORY")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(coordinator.chatMessages) { msg in
                            HStack {
                                if msg.role == "user" { Spacer() }
                                Text(msg.text)
                                    .font(.system(size: 12.5))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        msg.role == "user"
                                            ? Color(red: 0.87, green: 0.35, blue: 0.20)
                                            : Color(UIColor.secondarySystemFill)
                                    )
                                    .foregroundColor(msg.role == "user" ? .white : .primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                if msg.role != "user" { Spacer() }
                            }
                        }
                        if coordinator.isSendingAgentTurn {
                            Text("Dispatching PRD to Softmax Cloud Dark Factory (AIDE v3)…")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(.blue)
                                .padding(.horizontal, 6)
                        }
                    }
                    .padding(12)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(14)
            }
            .background(Color(UIColor.systemGroupedBackground))

            Divider()

            HStack(spacing: 8) {
                TextField("Ask agent or send a PRD to Dark Factory…", text: $coordinator.agentInputText, onCommit: {
                    coordinator.sendPromptToAgentAndDarkFactory()
                })
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Color(UIColor.secondarySystemFill))
                .clipShape(Capsule())

                Button(action: { coordinator.sendPromptToAgentAndDarkFactory() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(Color(red: 0.87, green: 0.35, blue: 0.20))
                }
                .buttonStyle(.plain)
                .disabled(coordinator.isSendingAgentTurn)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - MainViewController Integration Helper

extension MainViewController {
    func installSoftmaxBrowserSDKPill() {
        let coordinator = SoftmaxBrowserSDKCoordinator.shared
        coordinator.activeMainViewController = self
        coordinator.activeTabProvider = { [weak self] in
            guard let tab = self?.currentTab else { return nil }
            return (title: tab.name ?? "", url: tab.url?.absoluteString ?? "")
        }

        // Attach hidden 1x1 voice bridge webview if not yet in hierarchy
        if coordinator.voiceBridgeWebView.superview == nil {
            coordinator.voiceBridgeWebView.alpha = 0.01
            coordinator.voiceBridgeWebView.isUserInteractionEnabled = false
            view.addSubview(coordinator.voiceBridgeWebView)
        }

        // Add floating Softmax Agent · PRDs pill above the DuckDuckGo bottom toolbar
        let pillTag = 948_277
        if view.viewWithTag(pillTag) != nil { return }

        let button = UIButton(type: .system)
        button.tag = pillTag
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("✦ Softmax PRDs", for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 12.5, weight: .bold)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor(red: 0.87, green: 0.35, blue: 0.20, alpha: 0.96)
        button.layer.cornerRadius = 16
        button.contentEdgeInsets = UIEdgeInsets(top: 7, left: 13, bottom: 7, right: 13)
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.18
        button.layer.shadowRadius = 6
        button.layer.shadowOffset = CGSize(width: 0, height: 3)
        button.addTarget(self, action: #selector(presentSoftmaxBrowserSDKSheet), for: .touchUpInside)

        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -62),
            button.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    @objc func presentSoftmaxBrowserSDKSheet() {
        let coordinator = SoftmaxBrowserSDKCoordinator.shared
        coordinator.syncSpecsFromSoftmaxDB()
        let hosting = UIHostingController(
            rootView: SoftmaxDuckDuckGoAgentSheetView(coordinator: coordinator) { [weak self] in
                self?.dismiss(animated: true)
            }
        )
        if let sheet = hosting.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(hosting, animated: true)
    }
}
