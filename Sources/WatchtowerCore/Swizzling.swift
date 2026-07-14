#if canImport(UIKit)
import UIKit
import ObjectiveC

/// Centralized method swizzling for UIWindow.sendEvent and
/// UIViewController.viewDidAppear. Installed once, idempotent. All capture work
/// is wrapped so it can never crash the host app.
enum Swizzling {
    private static var installed = false

    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        swizzle(
            cls: UIWindow.self,
            original: #selector(UIWindow.sendEvent(_:)),
            swizzled: #selector(UIWindow.wt_sendEvent(_:))
        )
        swizzle(
            cls: UIViewController.self,
            original: #selector(UIViewController.viewDidAppear(_:)),
            swizzled: #selector(UIViewController.wt_viewDidAppear(_:))
        )
    }

    private static func swizzle(cls: AnyClass, original: Selector, swizzled: Selector) {
        guard let orig = class_getInstanceMethod(cls, original),
              let swiz = class_getInstanceMethod(cls, swizzled) else { return }
        let didAdd = class_addMethod(cls, original,
                                     method_getImplementation(swiz),
                                     method_getTypeEncoding(swiz))
        if didAdd {
            class_replaceMethod(cls, swizzled,
                                method_getImplementation(orig),
                                method_getTypeEncoding(orig))
        } else {
            method_exchangeImplementations(orig, swiz)
        }
    }
}

extension UIWindow {
    @objc func wt_sendEvent(_ event: UIEvent) {
        // Call original first (this is the swizzled-in original IMP).
        self.wt_sendEvent(event)
        // Capture is best-effort and must never throw / crash.
        guard WatchtowerEngine.shared.isRunning else { return }
        WatchtowerEngine.shared.handle(event: event, in: self)
    }
}

extension UIViewController {
    @objc func wt_viewDidAppear(_ animated: Bool) {
        self.wt_viewDidAppear(animated)
        guard WatchtowerEngine.shared.isRunning else { return }
        WatchtowerEngine.shared.didAppear(viewController: self)
    }
}
#endif
