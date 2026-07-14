#if canImport(UIKit)
import UIKit
import ObjectiveC

private var watchtowerTagKey: UInt8 = 0
private var watchtowerSensitiveKey: UInt8 = 0

public extension UIView {
    /// A stable element id for tap attribution (§3.3, resolution order #2).
    var watchtowerTag: String? {
        get { objc_getAssociatedObject(self, &watchtowerTagKey) as? String }
        set { objc_setAssociatedObject(self, &watchtowerTagKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }

    /// Marks this UIKit view as sensitive; blurred before hashing / upload (§5).
    var watchtowerSensitive: Bool {
        get { (objc_getAssociatedObject(self, &watchtowerSensitiveKey) as? NSNumber)?.boolValue ?? false }
        set { objc_setAssociatedObject(self, &watchtowerSensitiveKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

private var watchtowerScreenNameKey: UInt8 = 0

public extension UIViewController {
    /// Explicit screen identity override (§3.2, highest precedence).
    var watchtowerScreenName: String? {
        get { objc_getAssociatedObject(self, &watchtowerScreenNameKey) as? String }
        set { objc_setAssociatedObject(self, &watchtowerScreenNameKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }
}
#endif
