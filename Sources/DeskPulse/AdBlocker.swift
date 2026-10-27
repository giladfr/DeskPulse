@preconcurrency import WebKit

/// WebKit content rules that block well-known ad networks and hide standard ad slots,
/// for the news-site cards, whose front pages are otherwise mostly ads in a small card.
@MainActor
enum AdBlocker {
    private(set) static var cachedRules: WKContentRuleList?
    private static var compiling: Task<WKContentRuleList?, Never>?

    static let adHosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com",
        "googletagservices.com", "amazon-adsystem.com", "adnxs.com", "taboola.com", "outbrain.com",
        "criteo.com", "criteo.net", "pubmatic.com", "rubiconproject.com", "openx.net",
        "casalemedia.com", "teads.tv", "smartadserver.com", "3lift.com", "yieldmo.com",
        "sharethrough.com", "mgid.com", "connatix.com", "kway.co.il", "adform.net"
    ]

    static let hiddenSelectors = [
        "[id^='div-gpt-ad']", "[id^='google_ads_iframe']", "ins.adsbygoogle", "[data-google-query-id]",
        "[id*='taboola']", "[class*='taboola']", "[id*='outbrain']", "[class*='outbrain']",
        "iframe[src*='doubleclick']", "iframe[src*='googlesyndication']"
    ]

    /// WebKit's rule format: one blocking rule per host (its patterns have no "|"), and
    /// one rule hiding the ad-slot selectors.
    static var rulesJSON: String {
        var rules: [[String: Any]] = adHosts.map { host in
            let escaped = host.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": ["url-filter": "^https?://[^/]*\(escaped)[:/]"],
                "action": ["type": "block"]
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": hiddenSelectors.joined(separator: ", ")]
        ])
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Compiles the rules once per launch; nil if WebKit rejects them (pages then load
    /// with ads rather than not at all).
    static func rules() async -> WKContentRuleList? {
        if let cachedRules { return cachedRules }
        if let compiling { return await compiling.value }
        let json = rulesJSON
        let task = Task { @MainActor () -> WKContentRuleList? in
            // The async form has no completion closure to be inferred main-actor
            // isolated and then called on a background queue.
            let list = try? await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: "DeskPulseAdBlock", encodedContentRuleList: json)
            cachedRules = list
            return list
        }
        compiling = task
        return await task.value
    }
}
