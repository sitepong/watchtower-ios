#if canImport(UIKit)
import UIKit
import CoreImage

/// One-shot screenshot capture (§3.4) + redaction (§5).
/// Renders the key window at 0.5× via `UIGraphicsImageRenderer`, blurs sensitive
/// rects BEFORE hashing/upload, then hands back redacted RGBA + PNG.
enum Screenshotter {

    static let captureScale: CGFloat = 0.5
    static let blurRadius: Double = 16 // radius >= 16 px at capture scale (§5)

    struct Capture {
        let rgba: [UInt8]
        let width: Int
        let height: Int
        let pngBase64: String
    }

    /// True when the window's layout is mid-animation and a captured frame would be
    /// a transient in-between state rather than the settled, canonical screen (§3.4).
    /// Covers: a scroll view actively dragging or decelerating (a swipe gesture whose
    /// `.ended` fires mid-fling), and a view-controller push/pop transition in flight.
    /// Used to defer template storage so dedup stays stable across runs.
    static func isLayoutInFlight(in window: UIWindow) -> Bool {
        if scrollViewAnimating(in: window) { return true }
        if viewControllerTransitioning(window: window) { return true }
        return false
    }

    private static func scrollViewAnimating(in view: UIView) -> Bool {
        if let sv = view as? UIScrollView, sv.isDragging || sv.isDecelerating || sv.isZooming {
            return true
        }
        for sub in view.subviews where scrollViewAnimating(in: sub) { return true }
        return false
    }

    private static func viewControllerTransitioning(window: UIWindow) -> Bool {
        guard let root = window.rootViewController else { return false }
        return viewControllerTransitioning(root)
    }

    /// Recurse the FULL view-controller tree: children as well as the presented
    /// chain. A React Native app nests its navigation controller (RNSScreen /
    /// react-native-screens) inside the root RCTRootViewController as a CHILD,
    /// so walking only root.presentedViewController misses every RN push/pop
    /// transition and mid-slide frames get stored as canonical templates.
    private static func viewControllerTransitioning(_ vc: UIViewController) -> Bool {
        if vc.transitionCoordinator != nil { return true }
        if let presented = vc.presentedViewController,
           viewControllerTransitioning(presented) { return true }
        for child in vc.children where viewControllerTransitioning(child) {
            return true
        }
        return false
    }

    /// Collect sensitive rects (window space) for a window:
    /// secureTextEntry fields + watchtowerSensitive UIViews + SwiftUI .watchtowerSensitive().
    static func sensitiveRects(in window: UIWindow) -> [CGRect] {
        var rects: [CGRect] = []
        func walk(_ view: UIView) {
            var isSensitive = view.watchtowerSensitive
            if let tf = view as? UITextField, tf.isSecureTextEntry { isSensitive = true }
            if isSensitive {
                rects.append(view.convert(view.bounds, to: window))
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(window)
        rects.append(contentsOf: WatchtowerRegistry.shared.sensitiveRects(in: window))
        return rects
    }

    struct RawCapture {
        let image: UIImage
        let sensitiveRects: [CGRect]
        let scale: CGFloat
    }

    /// Main-thread-only work: raw render (UIKit drawing) + sensitive-rect walk.
    /// Everything downstream (blur, RGBA extraction, hashing, PNG encode) runs
    /// off-main via `redact(_:)` — never call this inside the touch-delivery
    /// call stack; hop to the next runloop turn first.
    static func renderRaw(window: UIWindow) -> RawCapture? {
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = captureScale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)

        let rects = sensitiveRects(in: window)

        let image = renderer.image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        return RawCapture(image: image, sensitiveRects: rects, scale: captureScale)
    }

    /// Blur the sensitive rects of a raw capture (§5). CoreImage only — safe to
    /// run off the main thread.
    static func redact(_ raw: RawCapture) -> UIImage {
        guard !raw.sensitiveRects.isEmpty else { return raw.image }
        return blur(image: raw.image, rects: raw.sensitiveRects, captureScale: raw.scale)
    }

    private static func blur(image: UIImage, rects: [CGRect], captureScale: CGFloat) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let ciContext = CIContext(options: nil)
        let pixelW = cgImage.width
        let pixelH = cgImage.height
        let base = CIImage(cgImage: cgImage)

        // Build a fully-blurred version of the whole image once.
        let clamped = base.clampedToExtent()
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return image }
        blurFilter.setValue(clamped, forKey: kCIInputImageKey)
        blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
        guard let blurredFull = blurFilter.outputImage?.cropped(to: base.extent) else { return image }

        // Composite: start with sharp base, paste blurred patches over sensitive rects.
        var composite = base
        for rect in rects {
            // Convert window-space (points) rect to pixel space (origin top-left ->
            // CoreImage origin bottom-left).
            let px = rect.origin.x * captureScale
            let pyTop = rect.origin.y * captureScale
            let pw = rect.size.width * captureScale
            let ph = rect.size.height * captureScale
            let pyBottomLeft = CGFloat(pixelH) - pyTop - ph
            let pixelRect = CGRect(x: px, y: pyBottomLeft, width: pw, height: ph)
                .intersection(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
            guard !pixelRect.isNull, pixelRect.width > 0, pixelRect.height > 0 else { continue }

            let patch = blurredFull.cropped(to: pixelRect)
            composite = patch.composited(over: composite)
        }

        guard let outCG = ciContext.createCGImage(composite, from: base.extent) else { return image }
        return UIImage(cgImage: outCG)
    }

    /// Extract tightly-packed RGBA bytes from a CGImage.
    static func rgbaBytes(from image: UIImage) -> (rgba: [UInt8], width: Int, height: Int)? {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width
        let height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &data, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (data, width, height)
    }
}
#endif
