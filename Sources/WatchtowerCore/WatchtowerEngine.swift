#if canImport(UIKit)
import UIKit

/// The capture engine: resolves taps/screens, gates screenshot uploads on a
/// per-session set, and drives the transport. Bridge-free (no React/RN imports).
final class WatchtowerEngine {
    static let shared = WatchtowerEngine()

    private(set) var isRunning = false

    private var transport: Transport?
    private var sessionId = UUID().uuidString
    private var sequence: UInt64 = 0
    private var sampleRate: Double = 0.1
    private var appVersion: String?
    /// Identity from Watchtower.setUser (§1.1 distinct_id). nil = anonymous.
    private var distinctId: String?
    /// Optional identity traits, sent once via an "identify" event.
    private var userEmail: String?
    private var userName: String?
    /// Hardware identifier (utsname.machine, e.g. "iPhone17,1") + OS version,
    /// stamped on every event (§1.1).
    private var deviceModel: String?
    private var osVersion: String?
    private var sessionStartedAt: Date?
    /// Layer-3 sampling (§1.4): drawn once per session against sampleRate. A
    /// sampled session uploads a frame after every screen capture and stamps
    /// frame_hash on its taps.
    private var isSampledSession = false
    private var lastFrameHash: String?
    /// The last screen_view we emitted — dedup guard + prev_screen_name source.
    private var lastEmittedScreenName: String?
    /// Bumped on every emitted screen_view; dead-tap checks compare it to rule
    /// out taps that navigated.
    private var navCounter: UInt64 = 0
    /// Platform stamped on every TapEvent (§1.1). Default "ios"; the RN bridge
    /// overrides to "react-native-ios" via start(platform:).
    private var platform: String = "ios"

    /// Release channel / environment stamped on every event (dev | preview |
    /// production | …). Resolved by Watchtower.start (debug→"development",
    /// release→"production", or an explicit override) and passed in here. The
    /// suppression decision (don't run at all on an ignored channel) is made in
    /// Watchtower.start before this engine is ever started.
    private var channel: String = "production"

    /// Persistent per-install id (identifierForVendor), resolved once at start
    /// and stamped on every event so the dashboard can stitch consecutive
    /// sessions from the same install into a journey at read time.
    private var installId: String?
    /// Wall-clock of the last background transition (nil until first background).
    /// Drives the reopen-is-a-new-session decision on the next foreground.
    private var lastBackgroundedAt: Date?
    /// Idle grace: a foreground within this window of the last background resumes
    /// the SAME session (a momentary app-switch shouldn't fragment); beyond it, a
    /// fresh session is rolled. Default 30s; overridable via start(sessionGraceMs:).
    private var sessionGraceMs: Double = 30_000
    /// On a rolled session these carry the prior session id + idle gap (ms); they
    /// ride the new session's session_start, then clear.
    private var pendingPreviousSessionId: String?
    private var pendingSessionGapMs: UInt64?

    /// Explicit screen identity override via setScreen (§3.2). Cleared/overridden
    /// by viewDidAppear unless re-set.
    private var explicitScreenName: String?
    /// Last screen name resolved from a UIViewController.viewDidAppear.
    private var lastUIKitScreenName: String?

    /// Per-session set of uploaded screen fingerprints (upload-on-miss, §1.3/§3.4).
    private var uploadedScreenFps = Set<String>()
    /// In-flight uploads, to avoid duplicate template POSTs for the same fp.
    private var inFlightScreenFps = Set<String>()

    /// Last computed pHash per screen name. Taps read this cache — the touch
    /// pipeline NEVER renders or hashes (§3.4). Captures refresh it on screen
    /// appearance and on a throttled per-tap cadence.
    private var fpCache: [String: String] = [:]
    /// Wall-clock of the last completed capture per screen (throttling).
    private var lastCaptureAt: [String: CFTimeInterval] = [:]
    /// Screens with a capture currently in the render/hash/upload pipeline.
    private var capturesInFlight = Set<String>()
    /// Minimum interval between captures of the same screen. A tap only
    /// triggers a re-capture after this cooldown, so a burst of taps costs at
    /// most one render per second (industry pattern: frames on their own
    /// cadence, decoupled from the tap event stream).
    private let captureThrottle: CFTimeInterval = 1.0

    private let encodeQueue = DispatchQueue(label: "com.watchtower.encode", qos: .utility)

    // MARK: - Lifecycle

    func start(apiKey: String, projectId: String, endpoint: URL, sampleRate: Double,
               platform: String = "ios", sessionGraceMs: Double = 30_000,
               channel: String = "production") {
        guard !isRunning else { return }
        self.transport = Transport(apiKey: apiKey, projectId: projectId, endpoint: endpoint)
        self.sessionId = UUID().uuidString
        self.sequence = 0
        self.sampleRate = sampleRate
        self.platform = platform
        self.channel = channel
        self.sessionGraceMs = sessionGraceMs
        self.installId = UIDevice.current.identifierForVendor?.uuidString
        self.lastBackgroundedAt = nil
        self.pendingPreviousSessionId = nil
        self.pendingSessionGapMs = nil
        self.uploadedScreenFps.removeAll()
        self.inFlightScreenFps.removeAll()
        self.fpCache.removeAll()
        self.lastCaptureAt.removeAll()
        self.capturesInFlight.removeAll()
        self.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        self.deviceModel = Self.hardwareModel()
        self.osVersion = UIDevice.current.systemVersion
        self.sessionStartedAt = Date()
        self.isSampledSession = Double.random(in: 0..<1) < sampleRate
        self.lastFrameHash = nil
        self.lastEmittedScreenName = nil
        self.navCounter = 0
        self.pendingTaps.removeAll()
        Swizzling.installIfNeeded()
        observeBackground()
        isRunning = true
        emit(baseEvent(type: "session_start"))
        // Announce the session so the structural recorder can share this id and
        // roll in lockstep (the native analogue of the RN provider adopting the
        // native session id).
        NotificationCenter.default.post(
            name: .sitePongWatchtowerSessionDidRoll,
            object: nil, userInfo: ["sessionId": sessionId]
        )
    }

    func stop() {
        guard isRunning else { return }
        flushPendingTaps()
        var end = baseEvent(type: "session_end")
        end.reason = "stop"
        end.duration_ms = durationMs()
        emit(end)
        isRunning = false
        transport?.flushAndWait()
        transport = nil
    }

    func setUser(_ id: String?, email: String? = nil, name: String? = nil) {
        distinctId = id
        userEmail = email
        userName = name
        // Emit a one-shot identify so downstream can attach name/email to this
        // distinct_id without stamping PII on every tap. No-op until running.
        guard isRunning, id != nil || email != nil || name != nil else { return }
        var ev = baseEvent(type: "identify")
        ev.email = email
        ev.name = name
        emit(ev)
    }

    var currentSessionId: String? { isRunning ? sessionId : nil }

    /// The channel events are being tagged with, or nil when not running.
    var currentChannel: String? { isRunning ? channel : nil }

    private func durationMs() -> UInt64 {
        guard let started = sessionStartedAt else { return 0 }
        return UInt64(max(0, Date().timeIntervalSince(started) * 1000))
    }

    /// Common fields for every event type (§1.1); increments the shared
    /// per-session sequence.
    private func baseEvent(type: String) -> CaptureEvent {
        sequence += 1
        var event = CaptureEvent(
            type: type, session_id: sessionId, sequence: sequence,
            timestamp: ISO8601DateFormatter.wt.string(from: Date()),
            platform: platform, app_version: appVersion,
            distinct_id: distinctId, device_model: deviceModel,
            os_version: osVersion
        )
        event.install_id = installId
        event.channel = channel
        // Link hints ride only the session_start of a rolled session.
        if type == "session_start" {
            event.previous_session_id = pendingPreviousSessionId
            event.session_gap_ms = pendingSessionGapMs
        }
        return event
    }

    /// Diagnostic seam: when set, receives every emitted event before it is
    /// enqueued for transport. nil in production; used by tests to assert the
    /// session lifecycle + linking fields without a network round-trip.
    var debugOnEmit: ((CaptureEvent) -> Void)?

    private func emit(_ event: CaptureEvent) {
        debugOnEmit?(event)
        transport?.enqueue(event)
    }

    private static func hardwareModel() -> String? {
        // On simulator utsname.machine is the host arch ("arm64"); the real
        // device identifier is in the environment.
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return sim
        }
        var sys = utsname()
        uname(&sys)
        return withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) }
        }
    }

    func setScreen(_ name: String) {
        explicitScreenName = name
        scheduleAppearanceCapture()
    }

    private func observeBackground() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc private func appDidEnterBackground() {
        // Pending dead-checks can't complete in the background — flush them
        // undetermined (dead omitted), then mark the (soft) session boundary and
        // record when we backgrounded so the next foreground can decide whether
        // this was a momentary switch (resume) or a real reopen (roll). The
        // session does NOT end here: reason "background" lets the server close it
        // on timeout if the app never returns.
        flushPendingTaps()
        lastBackgroundedAt = Date()
        var end = baseEvent(type: "session_end")
        end.reason = "background"
        end.duration_ms = durationMs()
        emit(end)
        transport?.flush()
    }

    /// A reopen. If we were backgrounded longer than the idle grace, the old
    /// session is done — roll a fresh one (linked to the old via prev id + gap).
    /// Within the grace it was just an app-switch, so the same session resumes.
    @objc private func appWillEnterForeground() {
        guard isRunning, let backgroundedAt = lastBackgroundedAt else { return }
        let gapMs = Date().timeIntervalSince(backgroundedAt) * 1000
        lastBackgroundedAt = nil
        guard gapMs > sessionGraceMs else { return }
        rollSession(gapMs: UInt64(max(0, gapMs)))
    }

    /// Open a brand-new session on the same install. Mirrors start()'s
    /// per-session reset but keeps transport, identity, device, and install id.
    /// The prior session already emitted a session_end (reason "background") when
    /// it backgrounded, so we only open the new one here.
    private func rollSession(gapMs: UInt64) {
        pendingPreviousSessionId = sessionId
        pendingSessionGapMs = gapMs
        sessionId = UUID().uuidString
        sequence = 0
        sessionStartedAt = Date()
        isSampledSession = Double.random(in: 0..<1) < sampleRate
        uploadedScreenFps.removeAll()
        inFlightScreenFps.removeAll()
        fpCache.removeAll()
        lastCaptureAt.removeAll()
        capturesInFlight.removeAll()
        lastFrameHash = nil
        lastEmittedScreenName = nil
        navCounter = 0
        pendingTaps.removeAll()
        emit(baseEvent(type: "session_start"))
        pendingPreviousSessionId = nil
        pendingSessionGapMs = nil
        // Structural recorder re-keys onto the rolled session id.
        NotificationCenter.default.post(
            name: .sitePongWatchtowerSessionDidRoll,
            object: nil, userInfo: ["sessionId": sessionId]
        )
    }

    // MARK: - Screen views (§1.1 screen_view)

    /// Single choke point for screen identity changes — called with the
    /// resolved name from scheduleAppearanceCapture (which both viewDidAppear
    /// and setScreen funnel through). Emits a screen_view with the transition
    /// edge (prev_screen_name) and bumps navCounter for dead-tap checks.
    private func noteScreenChanged(_ name: String) {
        guard name != lastEmittedScreenName else { return }
        var ev = baseEvent(type: "screen_view")
        ev.screen_name = name
        ev.prev_screen_name = lastEmittedScreenName
        lastEmittedScreenName = name
        navCounter += 1
        emit(ev)
    }

    // MARK: - Screen identity (§3.2)

    func didAppear(viewController vc: UIViewController) {
        // Skip container controllers that don't represent a screen.
        if vc is UINavigationController || vc is UITabBarController { return }
        // SwiftUI hosting controllers get their identity from the
        // `.watchtowerScreen` modifier inside, not the generic class name; don't
        // let them clobber the auto screen name.
        if String(describing: type(of: vc)).hasPrefix("UIHostingController") {
            if let explicit = vc.watchtowerScreenName { lastUIKitScreenName = explicit }
            // An explicit setScreen (e.g. React-Navigation route via the RN
            // bridge) overrides until the NEXT setScreen — a SwiftUI hosting
            // appearance must not silently clear it. Only an explicit
            // watchtowerScreenName on the VC itself supersedes (handled above
            // by updating lastUIKitScreenName, which currentScreenName falls
            // back to only when no explicit name is set).
            scheduleAppearanceCapture()
            return
        }
        let name = vc.watchtowerScreenName
            ?? vc.restorationIdentifier
            ?? String(describing: type(of: vc))
        lastUIKitScreenName = name
        // Per §3.2 the explicit setScreen overrides until the next setScreen.
        // We update the auto fallback (lastUIKitScreenName) but intentionally do
        // NOT clear explicitScreenName here: on the RN path every view is a
        // generic RNSScreen / transient keyboard controller, so the React-
        // Navigation route fed via setScreen must remain authoritative. Native
        // UIKit hosts that never call setScreen are unaffected (explicit is nil).
        scheduleAppearanceCapture()
    }

    private func currentScreenName(forPoint point: CGPoint, in window: UIWindow) -> String {
        if let explicit = explicitScreenName { return explicit }
        // SwiftUI screen region wins if the touch is inside one.
        if let sui = WatchtowerRegistry.shared.screenName(at: point, in: window) {
            return sui
        }
        // A currently-visible SwiftUI screen region (e.g. a pushed hosting
        // controller) takes precedence over the last UIKit screen, so taps in
        // chrome (nav bar back button) still attribute to the SwiftUI screen.
        if let sui = WatchtowerRegistry.shared.topScreenName(in: window) { return sui }
        if let uikit = lastUIKitScreenName { return uikit }
        return "Unknown"
    }

    // MARK: - Touch capture (§3.1)

    func handle(event: UIEvent, in window: UIWindow) {
        guard event.type == .touches, let touches = event.allTouches else { return }
        // Never record keyboard input. The swizzle sees every UIWindow,
        // including the system keyboard windows (UIRemoteKeyboardWindow /
        // UITextEffectsWindow) — a tap there with normalized coordinates is a
        // keystroke, and recording it would let a password be reconstructed
        // from the event stream.
        if Self.isSystemInputWindow(window) { return }
        for touch in touches where touch.phase == .ended {
            let point = touch.location(in: window)
            captureTap(at: point, in: window)
        }
    }

    /// True for the system keyboard / input-accessory windows. Matched by class
    /// name (they're private UIKit classes).
    static func isSystemInputWindow(_ window: UIWindow) -> Bool {
        let cls = String(describing: type(of: window))
        return cls.contains("Keyboard") || cls.contains("TextEffects")
    }

    private func captureTap(at point: CGPoint, in window: UIWindow) {
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let screenName = currentScreenName(forPoint: point, in: window)

        // Resolve element identity (§3.3).
        let resolved = resolveElement(at: point, in: window)

        let nx = max(0, min(1, Double(point.x / bounds.width)))
        let ny = max(0, min(1, Double(point.y / bounds.height)))

        // The touch pipeline never renders or hashes (§3.4): read the cached
        // fingerprint for this screen and ask for a (throttled, next-runloop)
        // capture refresh. The first tap on a not-yet-captured screen carries
        // the zero-hash fallback; the appearance-triggered capture normally
        // fills the cache before a human can tap.
        let screenFp = "\(screenName):\(fpCache[screenName] ?? "0000000000000000")"
        requestCapture(screenName: screenName)

        var event = baseEvent(type: "tap")
        event.screen_fp = screenFp
        event.screen_name = screenName
        event.element_id = resolved.id
        event.element_label = resolved.label
        event.element_role = resolved.role
        event.x = nx
        event.y = ny
        event.viewport_w = UInt(bounds.width)
        event.viewport_h = UInt(bounds.height)
        event.frame_hash = isSampledSession ? lastFrameHash : nil
        stageForDeadCheck(event, screenName: screenName)
    }

    // MARK: - Dead-tap detection (§1.1 `dead`)

    private struct PendingTap {
        var event: CaptureEvent
        let screenName: String
        let fpAtTap: String?
        let navAtTap: UInt64
        let stagedAt: CFTimeInterval
    }
    /// Taps held ~1s before enqueue so the dead heuristic can stamp them.
    /// Batch flush is 10s, so this delay is invisible on the wire.
    private var pendingTaps: [UInt64: PendingTap] = [:]

    /// Hold the tap briefly: a tap is dead when, ~1s later, the screen hasn't
    /// changed (navCounter), no transition ran, and the screen's redacted
    /// dHash is unchanged. Cheap signals rule most taps out before the one
    /// render the fp re-check needs (and that render is coalesced per screen).
    private func stageForDeadCheck(_ event: CaptureEvent, screenName: String) {
        let seq = event.sequence
        pendingTaps[seq] = PendingTap(event: event, screenName: screenName,
                                      fpAtTap: fpCache[screenName], navAtTap: navCounter,
                                      stagedAt: CACurrentMediaTime())
        // Half-way point: if the user didn't navigate, force a fresh capture so
        // the fp comparison at +1.0s reflects the post-tap screen state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, let p = self.pendingTaps[seq], self.isRunning else { return }
            if self.navCounter == p.navAtTap {
                self.requestCapture(screenName: p.screenName, force: true)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            guard var p = self.pendingTaps.removeValue(forKey: seq) else { return }
            // dead only when a capture COMPLETED after the tap and the hash is
            // still identical — a stale cache (capture pending/failed) leaves
            // the tap undetermined rather than false-flagging it.
            if self.isRunning,
               self.navCounter == p.navAtTap,
               let before = p.fpAtTap,
               let capturedAt = self.lastCaptureAt[p.screenName],
               capturedAt > p.stagedAt,
               self.fpCache[p.screenName] == before {
                p.event.dead = true
            }
            self.emit(p.event)
        }
    }

    /// Enqueue all held taps immediately, dead undetermined (omitted). Called
    /// on stop/background so nothing is lost to the hold window.
    private func flushPendingTaps() {
        let held = pendingTaps.values.sorted { $0.event.sequence < $1.event.sequence }
        pendingTaps.removeAll()
        for p in held { emit(p.event) }
    }

    struct Resolved {
        let id: String
        let label: String?
        let role: String?
    }

    /// Hit-test → resolve deepest interactive view → element identity (§3.3).
    private func resolveElement(at point: CGPoint, in window: UIWindow) -> Resolved {
        let hit = window.hitTest(point, with: nil)
        let view = deepestInteractive(from: hit) ?? hit

        // SwiftUI tag region takes precedence for id if the hit view itself
        // has no identity (SwiftUI hit views are generic hosting views).
        let tagRegion = WatchtowerRegistry.shared.tag(at: point, in: window)

        let role = roleFor(view: view)
        let label = labelFor(view: view)

        // Resolution order: accessibilityIdentifier -> watchtowerTag (UIView) ->
        // SwiftUI tag -> accessibilityLabel -> "<Class>@<tag>".
        if let aid = view?.accessibilityIdentifier, !aid.isEmpty {
            return Resolved(id: aid, label: label, role: role)
        }
        if let wt = view?.watchtowerTag, !wt.isEmpty {
            return Resolved(id: wt, label: label, role: role)
        }
        if let tag = tagRegion?.id, !tag.isEmpty {
            return Resolved(id: tag, label: label ?? "", role: role ?? "view")
        }
        if let al = view?.accessibilityLabel, !al.isEmpty {
            return Resolved(id: al, label: label, role: role)
        }
        let cls = view.map { String(describing: type(of: $0)) } ?? "UnknownView"
        let tagNum = view?.tag ?? 0
        return Resolved(id: "\(cls)@\(tagNum)", label: label, role: role)
    }

    private func deepestInteractive(from view: UIView?) -> UIView? {
        var v = view
        while let cur = v {
            if cur is UIControl { return cur }
            if cur is UITableViewCell { return cur }
            if cur is UICollectionViewCell { return cur }
            if cur.accessibilityIdentifier?.isEmpty == false { return cur }
            if cur.watchtowerTag?.isEmpty == false { return cur }
            if cur.isAccessibilityElement { return cur }
            v = cur.superview
        }
        return view
    }

    private func roleFor(view: UIView?) -> String? {
        switch view {
        case is UIButton: return "button"
        case is UISwitch: return "switch"
        case is UISlider: return "slider"
        case is UITextField: return "textfield"
        case is UITableViewCell: return "cell"
        case is UICollectionViewCell: return "cell"
        case is UIControl: return "control"
        default: return view == nil ? nil : "view"
        }
    }

    private func labelFor(view: UIView?) -> String? {
        if let button = view as? UIButton {
            if let t = button.titleLabel?.text, !t.isEmpty { return t }
        }
        if let al = view?.accessibilityLabel, !al.isEmpty { return al }
        return nil
    }

    // MARK: - Screenshot capture pipeline (§3.4)

    /// Resolve the current screen name without a touch point, mirroring
    /// currentScreenName(forPoint:)'s precedence: explicit setScreen > visible
    /// SwiftUI screen region > last UIKit appearance. SwiftUI must come before
    /// the UIKit fallback — a pushed hosting controller doesn't update
    /// lastUIKitScreenName (its identity lives in the .watchtowerScreen region),
    /// so checking lastUIKitScreenName first would report the screen underneath.
    private func resolveScreenName(in window: UIWindow) -> String {
        return explicitScreenName
            ?? WatchtowerRegistry.shared.topScreenName(in: window)
            ?? lastUIKitScreenName ?? "Unknown"
    }

    /// Warm the fingerprint cache when a screen appears (viewDidAppear /
    /// setScreen). The short delay lets the transition begin so the settled-
    /// layout gate in performCapture sees it and defers to the settled frame.
    private func scheduleAppearanceCapture() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.isRunning, let window = self.keyWindow() else { return }
            let name = self.resolveScreenName(in: window)
            self.noteScreenChanged(name)
            self.requestCapture(screenName: name)
        }
    }

    /// Ask for a capture of `screenName`. Coalesced (one in flight per screen),
    /// throttled (at most one per captureThrottle once the cache is warm), and
    /// ALWAYS deferred to the next main-runloop turn — never renders inside the
    /// touch-delivery call stack.
    private func requestCapture(screenName: String, force: Bool = false) {
        guard isRunning else { return }
        guard !capturesInFlight.contains(screenName) else { return }
        if !force, fpCache[screenName] != nil,
           let last = lastCaptureAt[screenName],
           CACurrentMediaTime() - last < captureThrottle {
            return
        }
        capturesInFlight.insert(screenName)
        DispatchQueue.main.async { [weak self] in
            self?.performCapture(screenName: screenName, attempt: 0)
        }
    }

    /// One capture attempt. Templates are only STORED from a SETTLED layout: a
    /// frame rendered mid-scroll or mid-transition reflects an in-between state,
    /// not the canonical screen, and storing it would create a spurious second
    /// template for the same screen. While layout is in flight this re-polls a
    /// bounded number of runloop turns (~50ms each; 12 turns covers a push
    /// animation or scroll deceleration), converging on the settled frame.
    ///
    /// Thread split: main thread does the raw render + sensitive-rect walk only;
    /// blur, RGBA extraction, dHash, and PNG encode all run on encodeQueue.
    private func performCapture(screenName: String, attempt: Int) {
        guard isRunning, let window = keyWindow(),
              resolveScreenName(in: window) == screenName else {
            capturesInFlight.remove(screenName)
            return
        }
        if Screenshotter.isLayoutInFlight(in: window) {
            guard attempt < 12 else { capturesInFlight.remove(screenName); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.performCapture(screenName: screenName, attempt: attempt + 1)
            }
            return
        }
        guard let raw = Screenshotter.renderRaw(window: window) else {
            capturesInFlight.remove(screenName)
            return
        }

        encodeQueue.async { [weak self] in
            guard let self = self else { return }
            // Redaction happens BEFORE hashing (§5), so the hash is computed
            // over the same pixels that would be uploaded.
            let redacted = Screenshotter.redact(raw)
            guard let bytes = Screenshotter.rgbaBytes(from: redacted) else {
                DispatchQueue.main.async { self.capturesInFlight.remove(screenName) }
                return
            }
            let pHash = WatchtowerHash.dHash(rgba: bytes.rgba, width: bytes.width, height: bytes.height)
            let png = redacted.pngData()

            DispatchQueue.main.async {
                self.capturesInFlight.remove(screenName)
                guard self.isRunning else { return }
                self.fpCache[screenName] = pHash
                self.lastCaptureAt[screenName] = CACurrentMediaTime()

                // Layer-3 sampled session (§1.4): every successful capture also
                // uploads a session-scoped frame; taps carry its hash.
                if self.isSampledSession, self.lastFrameHash != pHash, let png = png {
                    self.lastFrameHash = pHash
                    self.transport?.postFrame(
                        sessionId: self.sessionId,
                        timestamp: ISO8601DateFormatter.wt.string(from: Date()),
                        screenName: screenName, frameHash: pHash,
                        width: bytes.width, height: bytes.height,
                        pngBase64: png.base64EncodedString()
                    )
                }

                let screenFp = "\(screenName):\(pHash)"
                guard !self.uploadedScreenFps.contains(screenFp),
                      !self.inFlightScreenFps.contains(screenFp),
                      let png = png else { return }
                self.inFlightScreenFps.insert(screenFp)
                self.transport?.postTemplate(
                    routeName: screenName, pHash: pHash,
                    width: bytes.width, height: bytes.height,
                    pngBase64: png.base64EncodedString()
                ) { _ in
                    DispatchQueue.main.async {
                        self.inFlightScreenFps.remove(screenFp)
                        self.uploadedScreenFps.insert(screenFp)
                    }
                }
            }
        }
    }

    // MARK: - Manual capture (§3 captureScreenshot)

    func captureScreenshot() {
        guard isRunning, let window = keyWindow() else { return }
        requestCapture(screenName: resolveScreenName(in: window), force: true)
    }

    func keyWindow() -> UIWindow? {
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow }) ??
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first
    }
}

extension ISO8601DateFormatter {
    static let wt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
#endif
