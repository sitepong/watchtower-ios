// SitePong — NATIVE (UIKit/Swift) structural session-replay capture.
//
// The RN adapter sources its tree from the React fiber tree; this native adapter
// sources it from the UIView hierarchy — the same traversal WatchtowerCore
// already does for redaction (Screenshotter walks rootViewController's subviews).
// Each UIView is serialized to a node with its REAL frame (native gives exact
// geometry, unlike RN where the dashboard replays flexbox), its class-derived
// tag, text, and accessibilityIdentifier (== the RN testID). Snapshots + taps
// are POSTed to the ingest server, where the SAME @sitepong/watchtower-replay
// core diffs them into the SAME rrweb-style message stream the RN adapter posts
// directly (POST /api/replay-stream/native → server-side differ).
//
// One platform-neutral core, two capture adapters (fiber / UIView), one stored
// stream, one dashboard Player.
//
// Parity with the RN structural SDK (all implemented here):
//  • Sensitive masking — honors watchtowerSensitive UIViews + SwiftUI
//    .watchtowerSensitive() regions (via WatchtowerRegistry), not just secure fields.
//  • Scroll fidelity — native nodes carry ABSOLUTE window frames, so scroll shows
//    up as frame deltas; we densify sampling while a UIScrollView is moving so fast
//    scrolls aren't aliased (no SetNodeScroll — that would double-translate here).
//  • Session follow — re-keys onto WatchtowerEngine's rolled session id (shared id,
//    roll-in-lockstep) via .sitePongWatchtowerSessionDidRoll, the native analogue
//    of the RN provider's watchForRoll.
//  • Crash-flush — a best-effort synchronous flush on uncaught exception.
//  • Adaptive sampling — a heavy tree walk backs the sampler off for a few ticks
//    so capture never pins the main thread.
import UIKit

extension Notification.Name {
    /// Posted by WatchtowerEngine on session start/roll so the structural recorder
    /// can share the session id and roll in lockstep.
    static let sitePongWatchtowerSessionDidRoll = Notification.Name("SitePongWatchtowerSessionDidRoll")
}

public final class SitePongStructuralCapture {
    public static let shared = SitePongStructuralCapture()

    private var endpoint = ""
    private var apiKey = ""
    private var projectId: String?
    private var platform = "ios"
    private var sessionId = ""
    private var installId: String?
    private var startedAt = Date()
    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextId = 1
    private var events: [[String: Any]] = []
    private var screen = ""
    private var flushTimer: Timer?
    private var running = false

    // Incremental delivery: count of events CONFIRMED stored (== next seq_start).
    // The device ships only the delta each flush and clears its buffer, so memory
    // stays bounded and the uplink never re-sends the whole session. Node ids
    // (`ids`/`nextId`) stay PERSISTENT across flushes — the server stitches the
    // deltas by id, so resetting them would corrupt the tree.
    private var flushedEventCount = 0
    private var sending = false

    // Change detection: hash of the last serialized tree. A snapshot is appended
    // only when the tree actually changed — an idle screen buffers nothing and
    // the sampler backs off (see scheduleSample), so a static app costs ~0.
    // 0 doubles as the "force a keyframe" sentinel after any event drop.
    private var lastTreeHash: UInt64 = 0
    private var walkHash: UInt64 = 0
    private var idleTicks = 0

    // Runaway guards. The server tolerates seq_start gaps (it appends whatever
    // arrives), so when we must drop events we advance the cursor past them and
    // force a fresh full snapshot — the replay resumes coherently with a bounded
    // gap instead of the uplink growing without limit.
    private let maxPendingEvents = 600
    private let maxBodyBytes = 2 * 1024 * 1024
    private var failStreak = 0
    private var flushBackoffUntil: Date?

    // Scroll fidelity: last seen content offset per node id; while any scroll view
    // moves we sample faster so the frame-delta capture isn't aliased.
    private var scrollOffsets: [Int: CGPoint] = [:]
    private var scanScrolls: [(id: Int, off: CGPoint)] = []
    private var scrollQuietTicks = 3

    // Adaptive sampling: a walk over `walkBudgetMs` backs off proportionally.
    private let walkBudgetMs: Double = 24
    private let maxOverloadSkip = 8
    private var overloadSkip = 0

    // Crash-flush chains any pre-existing uncaught-exception handler.
    private static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?

    private func now() -> Int { Int(Date().timeIntervalSince(startedAt) * 1000) }

    /// Start capturing. `endpoint` is the ingest base URL (e.g.
    /// https://ingest.sitepong.com); `apiKey` is the project key.
    public func start(endpoint: String, apiKey: String, projectId: String?, sessionId: String, platform: String = "ios") {
        guard !running else { return }
        self.endpoint = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        self.apiKey = apiKey
        self.projectId = projectId
        self.sessionId = sessionId
        self.platform = platform
        self.installId = UIDevice.current.identifierForVendor?.uuidString
        self.startedAt = Date()
        self.running = true

        // Global tap capture: a recognizer on the key window that never steals the
        // touch (cancelsTouchesInView=false, simultaneous) — the native analogue
        // of the RN touch wrapper.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self, let w = self.keyWindow() else { return }
            let g = UITapGestureRecognizer(target: self, action: #selector(self.onTap(_:)))
            g.cancelsTouchesInView = false
            g.delegate = SPStructuralTapDelegate.shared
            w.addGestureRecognizer(g)
        }
        scheduleSample()
        flushTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in self?.flush() }

        // Flush on background so the tail isn't stranded when timers suspend.
        NotificationCenter.default.addObserver(
            self, selector: #selector(onBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        // Follow WatchtowerEngine's session so structural + tap streams share one id.
        NotificationCenter.default.addObserver(
            self, selector: #selector(onSessionRoll(_:)),
            name: .sitePongWatchtowerSessionDidRoll, object: nil
        )
        installCrashFlush()
    }

    @objc private func onBackground() {
        guard running else { return }
        flush()
    }

    /// WatchtowerEngine rolled (or started) a session — re-key onto it so the
    /// structural stream follows the same (linked) session id. Mirrors the RN
    /// provider's stop()+begin() on a session roll.
    @objc private func onSessionRoll(_ note: Notification) {
        guard running, let newId = note.userInfo?["sessionId"] as? String, newId != sessionId else { return }
        // Best-effort ship the old-session tail under the OLD id (fire-and-forget,
        // decoupled from the flush cursor so it can't corrupt the new session).
        if !events.isEmpty, let w = keyWindow() {
            sendBestEffort(batch: events, seqStart: flushedEventCount, sessionId: sessionId,
                           viewport: (Int(w.bounds.width), Int(w.bounds.height)))
        }
        // Reset to a clean new session and take a fresh full snapshot.
        sessionId = newId
        events.removeAll(keepingCapacity: true)
        ids.removeAll(keepingCapacity: true)
        nextId = 1
        flushedEventCount = 0
        scrollOffsets.removeAll(keepingCapacity: true)
        screen = ""
        startedAt = Date()
        lastTreeHash = 0
        idleTicks = 0
        failStreak = 0
        flushBackoffUntil = nil
        sample()
    }

    public func setScreen(_ name: String) {
        guard running, name != screen else { return }
        idleTicks = 0
        sample()
        appendEvent(["t": now(), "type": "screen", "name": name])
        screen = name
    }

    public func stop() {
        guard running else { return }
        running = false
        flushTimer?.invalidate(); flushTimer = nil
        NotificationCenter.default.removeObserver(self)
        flush()
    }

    private func idFor(_ v: UIView) -> Int {
        let k = ObjectIdentifier(v)
        if let id = ids[k] { return id }
        let id = nextId; nextId += 1; ids[k] = id
        return id
    }

    private func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
            .first(where: { $0.isKeyWindow }) ??
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first
    }

    // MARK: - tree serialization
    private func tagFor(_ v: UIView) -> String {
        switch v {
        case is UILabel: return "Text"
        case is UIImageView: return "Image"
        case is UITextField, is UITextView: return "TextInput"
        case is UIScrollView: return "ScrollView"
        case is UIButton, is UIControl: return "Pressable"
        default: return "View"
        }
    }

    private func hex(_ c: UIColor?) -> String? {
        guard let c = c else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getRed(&r, green: &g, blue: &b, alpha: &a), a > 0.01 else { return nil }
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    private func textFor(_ v: UIView) -> String? {
        if let l = v as? UILabel { return l.text }
        if let b = v as? UIButton { return b.title(for: .normal) ?? b.titleLabel?.text }
        if let t = v as? UITextField { return t.isSecureTextEntry ? nil : t.text }
        return nil
    }

    /// djb2-fold a string into the running walk hash (same cheap hash family as
    /// WatchtowerHash; deterministic, unlike Swift's per-process Hasher).
    private func fold(_ s: String) {
        for b in s.utf8 { walkHash = walkHash &* 33 &+ UInt64(b) }
        walkHash = walkHash &* 33 &+ 0x1F // field separator
    }

    private func serialize(_ v: UIView, in window: UIWindow, sensitiveRects: [CGRect]) -> [String: Any]? {
        if v.isHidden || v.alpha < 0.02 { return nil }
        let f = v.convert(v.bounds, to: window)
        // Sensitive if the view opts in (UIKit flag), is a secure field, or its
        // center falls inside a SwiftUI .watchtowerSensitive() region — the same
        // sources Screenshotter blurs, so structural replay masks them too.
        let center = CGPoint(x: f.midX, y: f.midY)
        let inSensitive = v.watchtowerSensitive
            || ((v as? UITextField)?.isSecureTextEntry ?? false)
            || sensitiveRects.contains { $0.contains(center) }

        var attrs: [String: String] = [:]
        if let aid = v.accessibilityIdentifier, !aid.isEmpty { attrs["testID"] = aid }
        if let al = v.accessibilityLabel, !al.isEmpty, !inSensitive { attrs["accessibilityLabel"] = al }
        if let bg = hex(v.backgroundColor) { attrs["backgroundColor"] = bg }
        if v.layer.cornerRadius > 0 { attrs["borderRadius"] = String(Int(v.layer.cornerRadius)) }
        if inSensitive { attrs["wtSensitive"] = "true" }
        if let l = v as? UILabel {
            attrs["color"] = hex(l.textColor) ?? "#111111"
            attrs["fontSize"] = String(Int(l.font.pointSize))
        }
        attrs["frame"] = "\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.size.width)),\(Int(f.size.height))"

        if let sv = v as? UIScrollView { scanScrolls.append((idFor(v), sv.contentOffset)) }

        let tag = tagFor(v)
        var node: [String: Any] = ["id": idFor(v), "tag": tag, "attrs": attrs]
        // Never serialize text inside a sensitive region.
        if !inSensitive, let t = textFor(v), !t.isEmpty { node["text"] = t }
        fold("\(idFor(v))|\(tag)")
        for k in attrs.keys.sorted() { fold("\(k)=\(attrs[k] ?? "")") }
        if let t = node["text"] as? String { fold(t) }
        // Don't descend into text/controls' internal subviews (keeps the tree clean).
        if !(v is UILabel) && !(v is UIButton) {
            var kids: [[String: Any]] = []
            for sub in v.subviews { if let s = serialize(sub, in: window, sensitiveRects: sensitiveRects) { kids.append(s) } }
            node["children"] = kids
        } else {
            node["children"] = []
        }
        return node
    }

    private func sample() {
        guard running, let w = keyWindow() else { return }
        // Adaptive back-off: while recovering from a heavy walk, skip the body.
        if overloadSkip > 0 { overloadSkip -= 1; return }

        scanScrolls.removeAll(keepingCapacity: true)
        let sensitiveRects = WatchtowerRegistry.shared.sensitiveRects(in: w)
        let t0 = Date()
        walkHash = 5381
        guard let root = serialize(w, in: w, sensitiveRects: sensitiveRects) else { return }
        let walkMs = Date().timeIntervalSince(t0) * 1000
        if walkMs > walkBudgetMs { overloadSkip = min(maxOverloadSkip, Int(walkMs / walkBudgetMs)) }

        // Only buffer a snapshot when the tree actually changed — the server
        // diffs consecutive snapshots, so identical ones are pure waste (they
        // were ~8/s of upload + battery on a static screen).
        if walkHash != lastTreeHash {
            lastTreeHash = walkHash
            idleTicks = 0
            appendEvent(["t": now(), "type": "snapshot", "tree": root])
        } else {
            idleTicks += 1
        }

        // Scroll detection: did any scroll view's offset move? Densify sampling
        // for a few ticks so fast scrolls (captured as frame deltas) aren't aliased.
        var scrolled = false
        for (id, off) in scanScrolls {
            if let last = scrollOffsets[id], abs(last.x - off.x) > 0.5 || abs(last.y - off.y) > 0.5 { scrolled = true }
            scrollOffsets[id] = off
        }
        scrollQuietTicks = scrolled ? 0 : scrollQuietTicks + 1
    }

    /// Buffer an event, bounded: on overflow drop the oldest and advance the
    /// flush cursor past them (the server tolerates seq gaps), then force a
    /// keyframe so replay resumes coherently. Only trims while no batch is in
    /// flight so the cursor arithmetic stays race-free (all on main).
    private func appendEvent(_ e: [String: Any]) {
        events.append(e)
        if !sending && events.count > maxPendingEvents {
            let excess = events.count - maxPendingEvents
            events.removeFirst(excess)
            flushedEventCount += excess
            lastTreeHash = 0
        }
    }

    /// Self-scheduling sampler: 60ms while scrolling, 120ms at rest, easing to
    /// 0.5s after ~3s without a tree change and 1s after ~15s. Taps and screen
    /// changes sample immediately and reset the idle backoff.
    private func scheduleSample() {
        guard running else { return }
        let interval: Double
        if scrollQuietTicks < 3 { interval = 0.06 }
        else if idleTicks > 50 { interval = 1.0 }
        else if idleTicks > 25 { interval = 0.5 }
        else { interval = 0.12 }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self = self, self.running else { return }
            self.sample()
            self.scheduleSample()
        }
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        guard running, let w = keyWindow() else { return }
        let p = g.location(in: w)
        let hit = w.hitTest(p, with: nil)
        idleTicks = 0
        sample()
        var nodeId = 0
        if let hit = hit { nodeId = idFor(deepestInteresting(hit)) }
        let bounds = w.bounds
        appendEvent([
            "t": now(), "type": "tap", "nodeId": nodeId,
            "x": Double(p.x / max(bounds.width, 1)), "y": Double(p.y / max(bounds.height, 1)),
        ])
    }

    private func deepestInteresting(_ v: UIView) -> UIView {
        var cur: UIView? = v
        while let c = cur {
            if c.accessibilityIdentifier?.isEmpty == false { return c }
            if c is UIControl { return c }
            cur = c.superview
        }
        return v
    }

    /// Ship the pending event delta (only what's accumulated since the last
    /// confirmed flush), then clear the device buffer. The batch carries its
    /// `seq_start` so the server dedups retries; a failed batch is re-queued so
    /// nothing is lost offline. All buffer mutation stays on the main thread.
    private func flush() {
        guard !endpoint.isEmpty, !sending, !events.isEmpty, let w = keyWindow() else { return }
        // Cooling off after a failed retry cycle — don't hammer a sick server.
        if let until = flushBackoffUntil, Date() < until { return }
        let batch = events
        let seqStart = flushedEventCount
        events.removeAll(keepingCapacity: true) // drain the device buffer
        sending = true
        post(batch: batch, seqStart: seqStart,
             viewport: (Int(w.bounds.width), Int(w.bounds.height)), attempt: 0)
    }

    /// A batch we will never deliver (oversized or rejected outright): advance
    /// the cursor past it so the seq stays consistent, and force a keyframe so
    /// the stored replay picks back up from a full snapshot.
    private func dropBatch(seqStart: Int, count: Int) {
        flushedEventCount = seqStart + count
        lastTreeHash = 0
        sending = false
    }

    private func requestBody(batch: [[String: Any]], seqStart: Int, sessionId: String, viewport: (Int, Int)) -> Data? {
        var payload: [String: Any] = [
            "session_id": sessionId,
            "platform": platform,
            "viewport": ["w": viewport.0, "h": viewport.1],
            "seq_start": seqStart,
            "events": batch,
        ]
        if let iid = installId { payload["install_id"] = iid }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private func makeRequest(body: Data) -> URLRequest? {
        guard let url = URL(string: "\(endpoint)/api/replay-stream/native") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        if let pid = projectId { req.setValue(pid, forHTTPHeaderField: "X-Project-ID") }
        req.httpBody = body
        return req
    }

    private func post(batch: [[String: Any]], seqStart: Int, viewport: (Int, Int), attempt: Int) {
        guard let body = requestBody(batch: batch, seqStart: seqStart, sessionId: sessionId, viewport: viewport),
              let req = makeRequest(body: body) else {
            DispatchQueue.main.async { self.sending = false }
            return
        }
        // A body this size will only ever 413 — retrying it grows it further
        // (the exact runaway that took down ingest). Drop it and keyframe.
        if body.count > maxBodyBytes {
            DispatchQueue.main.async { self.dropBatch(seqStart: seqStart, count: batch.count) }
            return
        }
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
            guard let self = self else { return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ok = (200..<300).contains(status)
            // 4xx (except timeout/rate-limit) is permanent — the server will
            // never accept this exact batch, so retrying is pure waste.
            let permanent = err == nil && (400..<500).contains(status) && status != 408 && status != 429
            DispatchQueue.main.async {
                if ok && err == nil {
                    self.flushedEventCount = seqStart + batch.count
                    self.failStreak = 0
                    self.flushBackoffUntil = nil
                    self.sending = false
                } else if permanent {
                    self.dropBatch(seqStart: seqStart, count: batch.count)
                } else if attempt < 3 {
                    let delay = pow(2.0, Double(attempt)) // 1,2,4s
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.post(batch: batch, seqStart: seqStart, viewport: viewport, attempt: attempt + 1)
                    }
                } else {
                    // Give up on this cycle: re-queue at the front so the seq
                    // stays contiguous and the delta re-sends after a cooldown
                    // that doubles per consecutive failure (8s … 2min).
                    self.events.insert(contentsOf: batch, at: 0)
                    self.failStreak += 1
                    let cooldown = min(120.0, 8.0 * pow(2.0, Double(self.failStreak - 1)))
                    self.flushBackoffUntil = Date().addingTimeInterval(cooldown)
                    self.sending = false
                }
            }
        }.resume()
    }

    /// Fire-and-forget send under an explicit session id — used for the old-session
    /// tail on a roll, decoupled from the flush cursor so it can't corrupt the new
    /// session's seq. Best-effort (no retry / no re-queue).
    private func sendBestEffort(batch: [[String: Any]], seqStart: Int, sessionId: String, viewport: (Int, Int)) {
        guard !endpoint.isEmpty,
              let body = requestBody(batch: batch, seqStart: seqStart, sessionId: sessionId, viewport: viewport),
              let req = makeRequest(body: body) else { return }
        URLSession.shared.dataTask(with: req).resume()
    }

    // MARK: - crash flush
    private func installCrashFlush() {
        SitePongStructuralCapture.previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { ex in
            SitePongStructuralCapture.shared.crashFlush()
            SitePongStructuralCapture.previousExceptionHandler?(ex)
        }
    }

    /// Synchronous best-effort flush from an uncaught-exception handler (the run
    /// loop is dead, so we block briefly on URLSession's own queue). Mirrors the
    /// JS ErrorUtils crash-flush.
    func crashFlush() {
        guard running, !events.isEmpty,
              let w = keyWindow(),
              let body = requestBody(batch: events, seqStart: flushedEventCount, sessionId: sessionId,
                                     viewport: (Int(w.bounds.width), Int(w.bounds.height))),
              let req = makeRequest(body: body) else { return }
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 1.5)
    }
}

/// Allow the capture recognizer to run alongside buttons/scroll gestures.
final class SPStructuralTapDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = SPStructuralTapDelegate()
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { true }
}
