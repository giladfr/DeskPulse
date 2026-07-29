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
                openInChrome(url)
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
                openInChrome(url)
            }
            return nil
        }

        private func openInChrome(_ url: URL) {
            let workspace = NSWorkspace.shared
            guard let chrome = workspace.urlForApplication(
                withBundleIdentifier: "com.google.Chrome"
            ) else {
                workspace.open(url)
                return
            }
            workspace.open(
                [url],
                withApplicationAt: chrome,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }
}

enum StockDashboardHTML {
    static func make(symbols: [StockSymbol]) -> String {
        let pairs = symbols.map { "[\"\($0.tradingViewSymbol)\",\"\($0.label)\"]" }
            .joined(separator: ",")
        return """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="color-scheme" content="dark">
      <style>
        * { box-sizing: border-box; }
        html, body { margin: 0; height: 100%; overflow: hidden; background: #101521; }
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
        #grid {
          display: grid; grid-template-columns: repeat(\(max(symbols.count, 1)), minmax(190px, 1fr));
          gap: 1px; height: 100%; background: rgba(255,255,255,.07);
        }
        .chart { min-width: 0; height: 100%; background: #101521; }
        @media(max-width: 900px) {
          #grid { grid-template-columns: repeat(2, minmax(220px, 1fr)); overflow-y: auto; }
          .chart { min-height: 230px; }
        }
      </style>
    </head>
    <body>
      <div id="grid"></div>
      <script>
        const symbols = [\(pairs)];
        const grid = document.getElementById("grid");
        symbols.forEach(([symbol, label]) => {
          const box = document.createElement("div");
          box.className = "chart tradingview-widget-container";
          const widget = document.createElement("div");
          widget.className = "tradingview-widget-container__widget";
          widget.style.height = "100%";
          box.appendChild(widget);
          const script = document.createElement("script");
          script.type = "text/javascript";
          script.src = "https://s3.tradingview.com/external-embedding/embed-widget-advanced-chart.js";
          script.async = true;
          script.textContent = JSON.stringify({
            symbol, width: "100%", height: "100%", locale: "en",
            interval: "5", range: "1D", timezone: "America/New_York",
            colorTheme: "dark", backgroundColor: "#101521",
            gridColor: "rgba(255,255,255,0.055)", autosize: true,
            style: "3", hide_top_toolbar: true, hide_legend: false,
            hide_side_toolbar: true, allow_symbol_change: false,
            save_image: false, calendar: false, withdateranges: false,
            details: false, hotlist: false, support_host: "https://www.tradingview.com",
            overrides: {
              "mainSeriesProperties.showPrevClosePriceLine": true,
              "mainSeriesProperties.prevClosePriceLineWidth": 1
            }
          });
          box.appendChild(script);
          grid.appendChild(box);
        });
      </script>
    </body>
    </html>
    """
    }
}
