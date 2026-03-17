import SwiftUI
import WebKit

// MARK: - Shared WKWebView (hidden, acts as communication bridge)

@MainActor
final class SharedRCWebView: ObservableObject {
    static let shared = SharedRCWebView()
    static let rcURL = URL(string: "https://claude.ai/code")!

    let webView: WKWebView
    private let delegate = RCWebViewDelegate()

    @Published var isConnected = false
    @Published var lastResponse = ""
    @Published var sessionName = "Connecting..."
    @Published var actionButtons: [String] = []  // Dynamic buttons from the web UI

    private init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.navigationDelegate = delegate
        wv.uiDelegate = delegate
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        self.webView = wv
        delegate.owner = self

        BrowserCookieService.injectBrowserCookies(into: wv, for: "claude.ai") {
            wv.load(URLRequest(url: Self.rcURL))
        }
    }

    func reload() {
        BrowserCookieService.injectBrowserCookies(into: webView, for: "claude.ai") { [weak self] in
            self?.webView.load(URLRequest(url: Self.rcURL))
        }
    }

    /// Send a message via the RC web interface
    func sendMessage(_ text: String) {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        let js = """
        (function() {
            // Find visible textarea or contenteditable
            const textareas = document.querySelectorAll('textarea');
            let input = null;
            for (const t of textareas) {
                if (t.offsetParent !== null) { input = t; break; }
            }
            if (!input) {
                const editables = document.querySelectorAll('[contenteditable="true"]');
                for (const e of editables) {
                    if (e.offsetParent !== null) { input = e; break; }
                }
            }
            if (!input) return 'no_input_found';

            // For React: use native setter + React's input event
            if (input.tagName === 'TEXTAREA') {
                const nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
                nativeSetter.call(input, '\(escaped)');
                input.dispatchEvent(new Event('input', { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));
            } else {
                input.focus();
                input.textContent = '\(escaped)';
                input.dispatchEvent(new Event('input', { bubbles: true }));
            }

            // Find and click the send/submit button
            setTimeout(() => {
                // Try form submit
                const form = input.closest('form');
                if (form) {
                    form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
                }
                // Try clicking send button (usually has an arrow-up SVG icon)
                const buttons = document.querySelectorAll('button[type="submit"], button[aria-label*="Send"], button[aria-label*="send"]');
                for (const btn of buttons) {
                    if (btn.offsetParent !== null) { btn.click(); return; }
                }
                // Fallback: find button near the textarea
                const parent = input.closest('div') || input.parentElement;
                if (parent) {
                    const nearButtons = parent.querySelectorAll('button');
                    for (const btn of nearButtons) {
                        if (btn.offsetParent !== null && btn.querySelector('svg')) {
                            btn.click(); return;
                        }
                    }
                }
                // Last resort: Enter keypress
                input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
                input.dispatchEvent(new KeyboardEvent('keypress', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
                input.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
            }, 300);
            return 'sent';
        })();
        """
        webView.evaluateJavaScript(js) { result, error in
            if let r = result as? String { NSLog("[AgentHub RC] send: %@", r) }
            if let e = error { NSLog("[AgentHub RC] error: %@", e.localizedDescription) }
        }
    }

    /// Click a specific action button in the web UI by its label
    func clickAction(_ label: String) {
        let escaped = label.replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
            const buttons = document.querySelectorAll('button');
            for (const btn of buttons) {
                const text = btn.textContent.trim();
                if (text === '\(escaped)' && btn.offsetParent !== null) {
                    btn.click();
                    return 'clicked: ' + text;
                }
            }
            // Try partial match
            for (const btn of buttons) {
                const text = btn.textContent.trim().toLowerCase();
                if (text.includes('\(escaped.lowercased())') && btn.offsetParent !== null) {
                    btn.click();
                    return 'clicked_partial: ' + btn.textContent.trim();
                }
            }
            return 'not_found';
        })();
        """
        webView.evaluateJavaScript(js) { result, _ in
            if let r = result as? String { NSLog("[AgentHub RC] action: %@", r) }
        }
    }

    /// Poll for status, last response, and available action buttons
    func pollStatus() {
        let js = """
        (function() {
            // Check if input exists (connected)
            const hasInput = document.querySelector('textarea') !== null ||
                            document.querySelector('[contenteditable="true"]') !== null;

            // Get last visible text block (response)
            let lastMsg = '';
            const paras = document.querySelectorAll('p, span, div');
            for (const el of paras) {
                if (el.children.length > 2) continue;
                const txt = el.textContent.trim();
                if (txt.length > 10 && txt.length < 300 && el.offsetParent !== null) {
                    lastMsg = txt;
                }
            }

            // Find action buttons — ONLY permission/response buttons, not UI chrome
            const actionLabels = [];
            const skipWords = ['share', 'copy', 'edit', 'new session', 'sign in', 'log in',
                              'download', 'all projects', 'search', 'settings', 'menu',
                              'close', 'back', 'opus', 'sonnet', 'haiku', 'auto accept',
                              'macbook', 'projects'];
            const allowWords = ['yes', 'no', 'allow', 'deny', 'continue', 'approve',
                               'reject', 'accept', 'cancel', 'retry', 'skip', 'stop',
                               'proceed', 'confirm'];
            const buttons = document.querySelectorAll('button');
            for (const btn of buttons) {
                if (btn.offsetParent === null) continue;
                const txt = btn.textContent.trim();
                if (txt.length < 2 || txt.length > 25) continue;
                const lower = txt.toLowerCase();
                // Skip known UI chrome
                if (skipWords.some(w => lower.includes(w))) continue;
                // Skip single/two letter buttons (initials like "RG")
                if (txt.length <= 2) continue;
                // Skip icon-only buttons
                if (btn.querySelector('svg') && txt.length < 4) continue;
                // Only include if it matches known action words
                if (allowWords.some(w => lower.includes(w))) {
                    actionLabels.push(txt);
                }
            }

            return JSON.stringify({ hasInput, lastMsg, actions: actionLabels });
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            DispatchQueue.main.async {
                self?.isConnected = dict["hasInput"] as? Bool ?? false
                if let msg = dict["lastMsg"] as? String, !msg.isEmpty {
                    self?.lastResponse = msg
                }
                if let actions = dict["actions"] as? [String] {
                    // Only update if changed (avoid UI flicker)
                    let unique = Array(Set(actions))
                    if unique != self?.actionButtons {
                        self?.actionButtons = unique
                    }
                }
            }
        }
    }
}

class RCWebViewDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var mainWebView: WKWebView?
    weak var owner: SharedRCWebView?

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url?.absoluteString else { return }
        let isSessionList = url.hasSuffix("/code") || url.hasSuffix("/code/")

        if isSessionList {
            // Auto-navigate to first session
            let js = """
            (function() {
                let attempts = 0;
                const tryNav = () => {
                    attempts++;
                    // Find all links and try to match session detail URLs
                    const links = document.querySelectorAll('a');
                    for (const a of links) {
                        const href = a.getAttribute('href') || '';
                        // Match /code/<uuid> or /code/<any-id>
                        if (href.includes('/code/') && href !== '/code/' && href.length > 10) {
                            const parts = href.split('/code/');
                            if (parts[1] && parts[1].length > 5) {
                                window.location.href = href;
                                return;
                            }
                        }
                    }
                    // Fallback: click on any element containing "session" text
                    if (attempts > 10) {
                        const els = document.querySelectorAll('a, div[role="button"], button');
                        for (const el of els) {
                            const txt = el.textContent.trim().toLowerCase();
                            if ((txt.includes('session') || txt.includes('interactive'))
                                && el.offsetParent !== null
                                && el.closest('a')) {
                                el.closest('a').click();
                                return;
                            }
                        }
                    }
                    if (attempts < 60) setTimeout(tryNav, 500);
                };
                setTimeout(tryNav, 800);
            })();
            """
            webView.evaluateJavaScript(js)
        } else {
            // On session detail — mark connected and start polling
            DispatchQueue.main.async { [weak self] in
                self?.owner?.isConnected = true
                self?.owner?.sessionName = "Connected"
                self?.owner?.pollStatus()
            }
        }
    }
}

// MARK: - Floating Panel View

struct CompactDashboardView: View {
    @EnvironmentObject var windowManager: WindowManager
    @ObservedObject var rc = SharedRCWebView.shared
    let onExpand: () -> Void
    var onMinimize: (() -> Void)? = nil
    var onRestore: (() -> Void)? = nil

    @State private var isMinimized = false
    @State private var showRC = true
    @State private var messageText = ""
    @State private var selectedWindowID: CGWindowID?

    private var selectedWindow: MonitoredWindow? {
        let windows = windowManager.monitoredWindows
        if let id = selectedWindowID, let w = windows.first(where: { $0.id == id }) { return w }
        return windows.first
    }

    private var projectName: String {
        guard let window = selectedWindow else { return "Remote Control" }
        let title = window.windowTitle
        if let lastDash = title.range(of: " — ", options: .backwards) {
            return String(title[lastDash.upperBound...])
        }
        if !title.isEmpty { return title }
        return window.ownerName
    }

    var body: some View {
        VStack(spacing: 0) {
            if isMinimized {
                minimizedPill
            } else {
                dragBar

                ZStack(alignment: .bottom) {
                    // Live window screenshot
                    windowScreenshot

                    // Native RC input overlay
                    if showRC {
                        rcOverlay
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Window tabs
                if windowManager.monitoredWindows.count > 1 {
                    windowTabs
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(.ultraThinMaterial)
        .onAppear {
            Task { await windowManager.autoDiscoverAgentWindows() }
            // Start polling
            startStatusPolling()
        }
    }

    private func startStatusPolling() {
        Task {
            while true {
                try? await Task.sleep(for: .seconds(3))
                rc.pollStatus()
            }
        }
    }

    // MARK: - RC Overlay (native SwiftUI)

    private var rcOverlay: some View {
        VStack(spacing: 0) {
            // Project name + status
            HStack(spacing: 6) {
                Circle()
                    .fill(rc.isConnected ? .green : .orange)
                    .frame(width: 6, height: 6)
                if let window = selectedWindow, let icon = window.icon {
                    Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                }
                Text(projectName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                if let window = selectedWindow {
                    TapIconButton(
                        systemName: "macwindow",
                        action: { windowManager.bringWindowToFront(window) },
                        color: .white.opacity(0.6)
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.7))

            // Message input field
            HStack(spacing: 6) {
                TextField("Send a message...", text: $messageText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onSubmit { sendMessage() }

                TapIconButton(
                    systemName: "arrow.up.circle.fill",
                    action: sendMessage,
                    color: messageText.isEmpty ? .gray : .blue
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.black.opacity(0.6))

            // Dynamic action buttons (only when available)
            if !rc.actionButtons.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(rc.actionButtons, id: \.self) { label in
                            TapButton(
                                label: label,
                                action: { rc.clickAction(label) },
                                color: .white,
                                bgColor: buttonColor(for: label),
                                font: .system(size: 10, weight: .semibold)
                            )
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .background(.black.opacity(0.6))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 6)
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .transition(.move(edge: .bottom))
    }

    private func buttonColor(for label: String) -> Color {
        let l = label.lowercased()
        if l.contains("yes") || l.contains("allow") || l.contains("accept") { return .green.opacity(0.6) }
        if l.contains("no") || l.contains("deny") || l.contains("reject") { return .red.opacity(0.6) }
        return .blue.opacity(0.5)
    }

    private func sendMessage() {
        guard !messageText.isEmpty else { return }
        rc.sendMessage(messageText)
        messageText = ""
    }

    // MARK: - Window Screenshot

    private var windowScreenshot: some View {
        Group {
            if let window = selectedWindow, let screenshot = windowManager.screenshots[window.id] {
                Image(nsImage: screenshot)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { windowManager.bringWindowToFront(window) }
            } else {
                Color.black.opacity(0.3)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "rectangle.on.rectangle.angled")
                                .font(.system(size: 28))
                                .foregroundStyle(.tertiary)
                            Text("No windows detected")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
            }
        }
    }

    // MARK: - Window Tabs

    private var windowTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(windowManager.monitoredWindows) { window in
                    HStack(spacing: 4) {
                        if let icon = window.icon {
                            Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                        }
                        Text(window.ownerName)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(selectedWindow?.id == window.id ? .white.opacity(0.15) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { selectedWindowID = window.id }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .background(.bar)
    }

    // MARK: - Drag Bar

    private var dragBar: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.white.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.leading, 12)

            Spacer()

            TapIconButton(
                systemName: showRC ? "message.fill" : "message",
                action: { withAnimation(.easeInOut(duration: 0.2)) { showRC.toggle() } },
                color: showRC ? .blue : .white
            )

            TapIconButton(
                systemName: "arrow.clockwise",
                action: { rc.reload() },
                color: .white
            )

            TapIconButton(
                systemName: "chevron.down.2",
                action: { isMinimized = true; onMinimize?() },
                color: .white
            )

            TapIconButton(systemName: "arrow.up.left.and.arrow.down.right", action: onExpand, color: .white)
                .padding(.trailing, 8)
        }
        .frame(height: 28)
        .background(.black.opacity(0.4))
    }

    // MARK: - Minimized Pill

    private var minimizedPill: some View {
        HStack(spacing: 8) {
            Circle().fill(rc.isConnected ? .green : .orange).frame(width: 6, height: 6)
            let count = windowManager.monitoredWindows.count
            Text(count > 0 ? "\(count) window\(count == 1 ? "" : "s")" : "AgentHub")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            TapIconButton(systemName: "chevron.up.2", action: { isMinimized = false; onRestore?() }, color: .white)
            TapIconButton(systemName: "arrow.up.left.and.arrow.down.right", action: onExpand, color: .white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.5))
        .contentShape(Rectangle())
        .onTapGesture { isMinimized = false; onRestore?() }
    }
}
