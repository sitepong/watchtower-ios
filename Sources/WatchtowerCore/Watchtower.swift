import Foundation

/// Public entrypoint for the Watchtower capture engine (spec §3).
/// Bridge-free: zero React/RN imports. All methods are exception-safe and a
/// no-op if `start` was not called (except `start` itself).
public enum Watchtower {

    /// Begin capturing taps + gated screenshots and uploading to `endpoint`.
    ///
    /// `platform` stamps the `platform` field on every emitted TapEvent (spec
    /// §1.1). It defaults to `"ios"` for native hosts; the React Native bridge
    /// (§4) passes `"react-native-ios"`. This is the only host-overridable
    /// identity knob — capture logic is identical regardless of platform.
    ///
    /// `channel` tags every event with a release channel / environment so dev
    /// traffic can be kept out of prod analytics. When omitted it is resolved
    /// automatically: **debug builds → `"development"`, release builds →
    /// `"production"`**. Any channel listed in `ignoreChannels` is *suppressed*
    /// — `start` becomes a complete no-op (no swizzles, no observers, zero
    /// network). The default `["development"]` means debug builds capture
    /// nothing unless you opt in (pass `ignoreChannels: []` or an explicit
    /// `channel`). Release builds send `"production"` and are never suppressed
    /// by the default.
    public static func start(apiKey: String, projectId: String,
                             endpoint: URL, sampleRate: Double = 0.1,
                             platform: String = "ios", sessionGraceMs: Double = 30_000,
                             channel: String? = nil,
                             ignoreChannels: [String] = ["development"]) {
        let resolved = resolveChannel(channel)
        // Suppressed channel → don't start at all. This is the "ignore dev,
        // listen to prod" gate: zero capture and zero ingest cost for dev.
        let ignored = Set(ignoreChannels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        if ignored.contains(resolved) { return }

        #if canImport(UIKit)
        // Ensure UIKit work happens on the main thread.
        if Thread.isMainThread {
            WatchtowerEngine.shared.start(apiKey: apiKey, projectId: projectId,
                                          endpoint: endpoint, sampleRate: sampleRate,
                                          platform: platform, sessionGraceMs: sessionGraceMs,
                                          channel: resolved)
        } else {
            DispatchQueue.main.async {
                WatchtowerEngine.shared.start(apiKey: apiKey, projectId: projectId,
                                              endpoint: endpoint, sampleRate: sampleRate,
                                              platform: platform, sessionGraceMs: sessionGraceMs,
                                              channel: resolved)
            }
        }
        #endif
    }

    /// Resolve the effective channel: an explicit, non-empty override wins
    /// (lowercased); otherwise debug builds are `"development"` and release
    /// builds `"production"`. Exposed at module scope so tests can assert the
    /// build-config default without a running engine.
    static func resolveChannel(_ explicit: String?) -> String {
        if let c = explicit?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !c.isEmpty {
            return c
        }
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    /// The channel the engine is currently tagging events with, or nil when not
    /// running (e.g. suppressed). Useful for diagnostics and tests.
    public static var channel: String? {
        #if canImport(UIKit)
        return WatchtowerEngine.shared.currentChannel
        #else
        return nil
        #endif
    }

    public static func stop() {
        #if canImport(UIKit)
        WatchtowerEngine.shared.stop()
        #endif
    }

    /// Explicit screen identity, overrides auto-detection until the next call
    /// (or the next UIKit screen appearance).
    public static func setScreen(_ name: String) {
        #if canImport(UIKit)
        WatchtowerEngine.shared.setScreen(name)
        #endif
    }

    /// Record a semantic breadcrumb: what the user actually did, not just where
    /// they touched.
    ///
    /// Tap capture is anonymous by construction — hit-testing yields a view, so
    /// it can tell you a product card was tapped but never *which* product. Call
    /// this at the point where that meaning is in scope:
    ///
    /// ```swift
    /// Watchtower.track("product_opened", props: [
    ///     "item_id": product.id,
    ///     "source_screen": "home.for_you",
    ///     "price": String(product.price)
    /// ])
    /// ```
    ///
    /// The current screen is stamped automatically. Values are strings so the
    /// wire format cannot vary by host; ingest stores the JSON verbatim and
    /// queries it with JSONExtract*. No-op if `start` was never called or the
    /// channel is suppressed, so leaving these calls in a debug build is free.
    public static func track(_ name: String, props: [String: String] = [:]) {
        #if canImport(UIKit)
        if Thread.isMainThread {
            WatchtowerEngine.shared.track(name, props: props)
        } else {
            DispatchQueue.main.async { WatchtowerEngine.shared.track(name, props: props) }
        }
        #endif
    }

    /// Attach sticky context that rides **every subsequent event**.
    ///
    /// Where `track` records what happened, context records the conditions it
    /// happened under — so you can segment after the fact without a join:
    ///
    /// ```swift
    /// Watchtower.setContext("shipping_cost", "25.00")
    /// Watchtower.setContext("cart_value", "180.00")
    /// Watchtower.setContext("flag.free_shipping", "off")
    /// Watchtower.setContext("user_tier", "new")
    /// ```
    ///
    /// Every tap, screen view and breadcrumb from that point carries those
    /// keys, which is what lets you ask "do people abandon checkout more when
    /// shipping is $25+?" or "does the free-shipping flag change exit rate?" —
    /// the condition is on the abandon event itself.
    ///
    /// Pass `nil` to clear a single key. Bounded to 32 keys / 256 chars each,
    /// because this rides the whole event stream.
    public static func setContext(_ key: String, _ value: String?) {
        #if canImport(UIKit)
        if Thread.isMainThread { WatchtowerEngine.shared.setContext(key, value) }
        else { DispatchQueue.main.async { WatchtowerEngine.shared.setContext(key, value) } }
        #endif
    }

    /// Bulk context update — useful for stamping a whole feature-flag set at
    /// launch. Keys not mentioned are left untouched.
    public static func setContext(_ values: [String: String]) {
        #if canImport(UIKit)
        if Thread.isMainThread { WatchtowerEngine.shared.setContext(values) }
        else { DispatchQueue.main.async { WatchtowerEngine.shared.setContext(values) } }
        #endif
    }

    /// Drop all sticky context — call on sign-out so one user's conditions
    /// never bleed into the next session.
    public static func clearContext() {
        #if canImport(UIKit)
        if Thread.isMainThread { WatchtowerEngine.shared.clearContext() }
        else { DispatchQueue.main.async { WatchtowerEngine.shared.clearContext() } }
        #endif
    }

    /// The context currently stamped on outgoing events.
    public static var context: [String: String] {
        #if canImport(UIKit)
        return WatchtowerEngine.shared.currentContext
        #else
        return [:]
        #endif
    }

    /// Force a one-shot capture of the current screen (gated on dedup).
    public static func captureScreenshot() {
        #if canImport(UIKit)
        if Thread.isMainThread {
            WatchtowerEngine.shared.captureScreenshot()
        } else {
            DispatchQueue.main.async { WatchtowerEngine.shared.captureScreenshot() }
        }
        #endif
    }

    /// Identity (§1.1 distinct_id): stamped on every subsequent event. Pass nil
    /// to return to anonymous. The RN layer feeds the SDK's identify() through
    /// this; native hosts call it directly.
    ///
    /// Optionally pass `email` / `name` traits: they are sent once as an
    /// `identify` event (not stamped on every tap) so the dashboard can label
    /// the user by name/email instead of a raw id.
    public static func setUser(_ distinctId: String?, email: String? = nil, name: String? = nil) {
        #if canImport(UIKit)
        if Thread.isMainThread {
            WatchtowerEngine.shared.setUser(distinctId, email: email, name: name)
        } else {
            DispatchQueue.main.async {
                WatchtowerEngine.shared.setUser(distinctId, email: email, name: name)
            }
        }
        #endif
    }

    /// The engine's current session id, or nil when not running. Attach this to
    /// the host SDK's error/analytics events — it is the replay/error join key.
    public static var sessionId: String? {
        #if canImport(UIKit)
        return WatchtowerEngine.shared.currentSessionId
        #else
        return nil
        #endif
    }
}
