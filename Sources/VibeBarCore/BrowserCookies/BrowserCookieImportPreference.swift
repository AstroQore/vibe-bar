import Foundation
import os.lock
import SweetCookieKit

/// The browsers cookie imports may read, as chosen in Settings or the setup
/// assistant.
///
/// A process-wide mirror of `AppSettings.cookieImportBrowsers`, kept by the
/// app whenever the setting loads or changes, so every importer that takes
/// the default order — the four core providers' importers, the misc
/// resolver — walks the chosen browsers without settings being threaded
/// through each of them. `nil` means the choice was never narrowed: every
/// installed browser, in the catalogue's order.
public enum BrowserCookieImportPreference {
    private static let selection = OSAllocatedUnfairLock<[Browser]?>(initialState: nil)

    /// Adopt the setting: `Browser` raw values in preference order, or nil
    /// for every installed browser. Unknown values — a browser a later
    /// catalogue named — are dropped; an empty list is treated as nil
    /// rather than as "read nothing", which is not a choice the picker
    /// offers.
    public static func apply(_ rawValues: [String]?) {
        let browsers = rawValues?.compactMap(Browser.init(rawValue:))
        selection.withLock { $0 = (browsers?.isEmpty ?? true) ? nil : browsers }
    }

    public static var selected: [Browser]? {
        selection.withLock { $0 }
    }

    /// The order an importer with no preference of its own walks.
    public static var order: [Browser] {
        selected ?? BrowserCookieDefaults.importOrder
    }

    /// A provider's own order restricted to the chosen browsers, in the
    /// chosen order; the provider's order untouched when nothing was chosen.
    public static func restrict(_ order: [Browser]) -> [Browser] {
        guard let selected else { return order }
        return selected.filter(order.contains)
    }

    /// What the picker lists: the installed browsers with a cookie store on
    /// this Mac, in the catalogue's order.
    public static func available(using detection: BrowserDetection = BrowserDetection()) -> [Browser] {
        Browser.defaultImportOrder.filter { detection.isCookieSourceAvailable($0) }
    }
}
