#if canImport(UIKit)
import UIKit

/// A tagged region registered by a SwiftUI `.watchtowerTag` / `.watchtowerScreen`
/// / `.watchtowerSensitive` modifier. Frames are stored in window (screen) space
/// and resolved at touch / capture time.
final class TaggedRegion {
    let id: String?           // watchtowerTag element id
    let screenName: String?   // watchtowerScreen identity
    let sensitive: Bool
    var frameInWindow: CGRect
    weak var window: UIWindow?

    init(id: String?, screenName: String?, sensitive: Bool, frameInWindow: CGRect, window: UIWindow?) {
        self.id = id
        self.screenName = screenName
        self.sensitive = sensitive
        self.frameInWindow = frameInWindow
        self.window = window
    }
}

/// Shared registry the swizzle consults to resolve SwiftUI element identity,
/// screen identity, and sensitive rects. Thread-confined to main (touches and
/// SwiftUI layout both run on main).
final class WatchtowerRegistry {
    static let shared = WatchtowerRegistry()

    private var regions: [ObjectIdentifier: TaggedRegion] = [:]

    func update(token: ObjectIdentifier, region: TaggedRegion) {
        regions[token] = region
    }

    func remove(token: ObjectIdentifier) {
        regions.removeValue(forKey: token)
    }

    /// Deepest (smallest-area) tag region containing `point` in the given window.
    func tag(at point: CGPoint, in window: UIWindow) -> TaggedRegion? {
        var best: TaggedRegion?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for r in regions.values where r.id != nil {
            guard r.window === window else { continue }
            if r.frameInWindow.contains(point) {
                let area = r.frameInWindow.width * r.frameInWindow.height
                if area < bestArea { bestArea = area; best = r }
            }
        }
        return best
    }

    /// Nearest enclosing screen-name region for a point.
    func screenName(at point: CGPoint, in window: UIWindow) -> String? {
        var best: TaggedRegion?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for r in regions.values where r.screenName != nil {
            guard r.window === window else { continue }
            if r.frameInWindow.contains(point) {
                let area = r.frameInWindow.width * r.frameInWindow.height
                if area < bestArea { bestArea = area; best = r }
            }
        }
        return best?.screenName
    }

    /// Most recently laid-out screen-name region in this window (for capture
    /// when no specific point is relevant).
    func topScreenName(in window: UIWindow) -> String? {
        var best: TaggedRegion?
        var bestArea: CGFloat = -1
        for r in regions.values where r.screenName != nil {
            guard r.window === window else { continue }
            let area = r.frameInWindow.width * r.frameInWindow.height
            if area > bestArea { bestArea = area; best = r }
        }
        return best?.screenName
    }

    /// All sensitive rects in window space for the given window.
    func sensitiveRects(in window: UIWindow) -> [CGRect] {
        regions.values
            .filter { $0.sensitive && $0.window === window }
            .map { $0.frameInWindow }
    }
}
#endif
