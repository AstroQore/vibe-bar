import Foundation

/// Request headers for calls that replay a browser's cookie session.
///
/// The cookies come from the user's browser, so the request should not
/// announce itself as `VibeBar/… CFNetwork`: a session that suddenly shows up
/// under a second, script-like client is what a provider's abuse checks look
/// for. The user agent follows the installed Chrome's major version, which is
/// all Chrome itself still reports.
public enum BrowserRequestHeaders {
    private static let fallbackChromeMajor = "143"

    public static let chromeUserAgent: String = {
        let plist = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/Info.plist")
        let version = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? ""
        let major = version.split(separator: ".").first.map(String.init)
        return chromeUserAgent(major: major.flatMap { Int($0) == nil ? nil : $0 } ?? fallbackChromeMajor)
    }()

    static func chromeUserAgent(major: String) -> String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Chrome/\(major).0.0.0 Safari/537.36"
    }

    /// Dress `request` as a same-origin `fetch` issued by the page at `referer`.
    public static func applySameOriginFetch(to request: inout URLRequest, referer: String) {
        request.setValue(chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
    }
}
