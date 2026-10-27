import AppKit
import SwiftUI
@preconcurrency import WebKit

struct EmbeddedWebView: NSViewRepresentable {
    enum Source: Equatable {
        case url(URL)
        /// Generated HTML. Pages that embed players needing a referrer (YouTube) give
        /// it a web origin.
        case html(String, baseURL: URL? = nil)
    }

    let source: Source
    var allowedHosts: Set<String> = []
    var pageZoom: Double = 0.82
    var userScript: String?
    /// Mutes each video or audio element when it first plays, in every frame (players
    /// are often cross-origin iframes). The player's own controls can unmute it.
    var startsMuted = false
    /// Blocks common ad networks and hides standard ad slots (news front pages).
    var blocksAds = false

    static let muteOnFirstPlayScript = """
    (() => {
      const muteOnce = (media) => {
        if (media.dataset.deskpulseMuted) return;
        media.dataset.deskpulseMuted = '1';
        media.muted = true;
      };
      document.addEventListener('play', (event) => {
        if (event.target instanceof HTMLMediaElement) muteOnce(event.target);
      }, true);
      document.querySelectorAll('video, audio').forEach(muteOnce);
    })();
    """

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
        if startsMuted {
            configuration.userContentController.addUserScript(WKUserScript(
                source: Self.muteOnFirstPlayScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }

        let cachedRules = blocksAds ? AdBlocker.cachedRules : nil
        if let cachedRules {
            configuration.userContentController.add(cachedRules)
        }

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsMagnification = true
        view.pageZoom = pageZoom
        view.setValue(false, forKey: "drawsBackground")
        view.customUserAgent = Self.safariUserAgent
        context.coordinator.loadedSource = source
        if blocksAds && cachedRules == nil {
            // The first page compiles the rules (a moment, once per launch), then loads.
            let source = source
            Task { @MainActor in
                if let rules = await AdBlocker.rules() {
                    view.configuration.userContentController.add(rules)
                }
                load(source, in: view)
            }
        } else {
            load(source, in: view)
        }
        return view
    }

    /// Closing a card or switching channel must silence it at once. Releasing the view
    /// is not enough: its web process can keep playing until it is torn down.
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.pauseAllMediaPlayback(completionHandler: nil)
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
        view.navigationDelegate = nil
        view.uiDelegate = nil
        coordinator.loadedSource = nil
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
        case .html(let html, let baseURL):
            view.loadHTMLString(html, baseURL: baseURL)
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

        /// macOS ends a page's web content process under memory pressure (and it can
        /// crash), which leaves the view blank. On a dashboard that runs for days that
        /// would mean an empty Gmail or WhatsApp card, so the page is loaded again.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            switch loadedSource {
            // Generated players (live TV) are rebuilt; their URL is about:blank.
            case .html(let html, let baseURL): webView.loadHTMLString(html, baseURL: baseURL)
            // Sites reload where the user was, e.g. an open Gmail thread.
            case .url(let url):
                if webView.url == nil {
                    webView.load(URLRequest(url: url))
                } else {
                    webView.reload()
                }
            case nil: webView.reload()
            }
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
