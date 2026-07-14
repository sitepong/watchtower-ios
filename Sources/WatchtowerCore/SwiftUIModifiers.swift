#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// Internal reporter view that publishes its window-space frame into the
/// registry whenever layout changes, then resolves cleanly on disappear.
private struct WatchtowerReporter: UIViewRepresentable {
    let id: String?
    let screenName: String?
    let sensitive: Bool

    func makeUIView(context: Context) -> ReporterView {
        let v = ReporterView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.tagId = id
        v.screenName = screenName
        v.sensitive = sensitive
        return v
    }

    func updateUIView(_ uiView: ReporterView, context: Context) {
        uiView.tagId = id
        uiView.screenName = screenName
        uiView.sensitive = sensitive
        uiView.publish()
    }

    static func dismantleUIView(_ uiView: ReporterView, coordinator: ()) {
        WatchtowerRegistry.shared.remove(token: ObjectIdentifier(uiView))
    }

    final class ReporterView: UIView {
        var tagId: String?
        var screenName: String?
        var sensitive: Bool = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publish()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            publish()
        }

        func publish() {
            guard let window = window, let superview = superview else { return }
            // The reporter is a zero-or-overlay view; report the *superview*'s
            // frame in window space, which corresponds to the modified content.
            let frame = superview.convert(superview.bounds, to: window)
            let region = TaggedRegion(id: tagId, screenName: screenName,
                                      sensitive: sensitive, frameInWindow: frame,
                                      window: window)
            WatchtowerRegistry.shared.update(token: ObjectIdentifier(self), region: region)
        }
    }
}

public extension View {
    /// Declares the enclosing SwiftUI subtree as a named screen (§3.2).
    func watchtowerScreen(_ name: String) -> some View {
        self.background(WatchtowerReporter(id: nil, screenName: name, sensitive: false))
    }

    /// Tags this view with a stable element id used as `element_id` (§3.3).
    func watchtowerTag(_ id: String) -> some View {
        self.background(WatchtowerReporter(id: id, screenName: nil, sensitive: false))
    }

    /// Marks this view's region as sensitive; it is blurred before hashing /
    /// upload (§5).
    func watchtowerSensitive() -> some View {
        self.background(WatchtowerReporter(id: nil, screenName: nil, sensitive: true))
    }
}
#endif
