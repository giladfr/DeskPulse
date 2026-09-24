import AppKit
import SwiftUI
@preconcurrency import WebKit

struct EmbeddedWebView: NSViewRepresentable {
    enum Source: Equatable {
        case url(URL)
        case html(String)
    }

    let source: Source
    var allowedHosts: Set<String> = []
    var pageZoom: Double = 0.82
    var userScript: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(allowedHosts: allowedHosts)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        if let userScript {
            configuration.userContentController.addUserScript(WKUserScript(
                source: userScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsMagnification = true
        view.pageZoom = pageZoom
        view.setValue(false, forKey: "drawsBackground")
        view.customUserAgent = Self.safariUserAgent
        load(source, in: view)
        context.coordinator.loadedSource = source
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        view.pageZoom = pageZoom
        context.coordinator.allowedHosts = allowedHosts
        guard context.coordinator.loadedSource != source else { return }
        load(source, in: view)
        context.coordinator.loadedSource = source
    }

    private func load(_ source: Source, in view: WKWebView) {
        switch source {
        case .url(let url):
            view.load(URLRequest(url: url))
        case .html(let html):
            view.loadHTMLString(html, baseURL: URL(string: "https://s.tradingview.com"))
        }
    }

    private static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var allowedHosts: Set<String>
        var loadedSource: Source?

        init(allowedHosts: Set<String>) {
            self.allowedHosts = allowedHosts
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else {
                return .cancel
            }

            let host = url.host?.lowercased() ?? ""
            let isAllowed = allowedHosts.isEmpty ||
                allowedHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
            let isUserLink = navigationAction.navigationType == .linkActivated

            if isUserLink && !isAllowed {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            let host = url.host?.lowercased() ?? ""
            let isAllowed = allowedHosts.contains {
                host == $0 || host.hasSuffix(".\($0)")
            }
            if isAllowed {
                webView.load(navigationAction.request)
            } else {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }
}
