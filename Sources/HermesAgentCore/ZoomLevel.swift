import Foundation

/// A page zoom that reflows the layout, applied through `WKWebView.pageZoom`.
///
/// `WKWebView.magnification` scales an already-laid-out page inside a viewport
/// that keeps its pre-zoom size: zooming in pushes bottom-anchored UI out of the
/// window, zooming out leaves gutters on the right and bottom.
public struct ZoomLevel: Equatable {

    public static let step: Double = 0.1
    public static let minimumFactor: Double = Double(minimumTenths) / 10
    public static let maximumFactor: Double = Double(maximumTenths) / 10
    /// 100% — restored by ⌘0.
    public static let identity = ZoomLevel(tenths: 10)

    private static let minimumTenths = 5
    private static let maximumTenths = 30

    public let factor: Double

    private init(tenths: Int) {
        self.factor = Double(tenths) / 10
    }

    /// Clamps into range and snaps onto the step grid.
    public init(clamping raw: Double) {
        guard raw.isFinite else {
            self = .identity
            return
        }
        // Integer tenths: `factor + 0.1` accumulates binary float error.
        let clamped = min(max(raw, Self.minimumFactor), Self.maximumFactor)
        self.init(tenths: Int((clamped * 10).rounded()))
    }

    /// Rejects the 0 `UserDefaults` reports for a missing key, and out-of-range values.
    public init?(restoring stored: Double) {
        guard stored.isFinite,
              stored >= Self.minimumFactor,
              stored <= Self.maximumFactor
        else { return nil }
        self.init(clamping: stored)
    }

    public func increased() -> ZoomLevel {
        ZoomLevel(clamping: factor + Self.step)
    }

    public func decreased() -> ZoomLevel {
        ZoomLevel(clamping: factor - Self.step)
    }

    public var isMinimum: Bool { factor <= Self.minimumFactor }
    public var isMaximum: Bool { factor >= Self.maximumFactor }
}

/// Persists the page zoom, migrating the magnification value of earlier releases.
public struct ZoomPreferences {

    public static let currentKey = "webViewPageZoom"

    /// Written by the magnification implementation (v1.1.0–v1.7.3); read only.
    public static let legacyKey = "webViewMagnification"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The persisted zoom, or 100% when nothing usable is stored.
    public func load() -> ZoomLevel {
        storedLevel(forKey: Self.currentKey)
            ?? storedLevel(forKey: Self.legacyKey)
            ?? .identity
    }

    public func save(_ level: ZoomLevel) {
        defaults.set(level.factor, forKey: Self.currentKey)
    }

    private func storedLevel(forKey key: String) -> ZoomLevel? {
        guard let number = defaults.object(forKey: key) as? NSNumber else { return nil }
        return ZoomLevel(restoring: number.doubleValue)
    }
}
