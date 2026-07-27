import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Native feature-flag client — the Swift counterpart of the JS SDK's
/// FlagManager (`packages/sdk/src/flags/`). Fetches the project's flags from
/// `GET {endpoint}/api/sdk/flags` (same host + `sp_…` key the capture engine
/// uses), evaluates every rule client-side with semantics matched 1:1 to
/// `evaluator.ts`, and memoizes the boolean results.
///
/// Independent of the capture engine on purpose: capture may be suppressed in
/// debug builds (`ignoreChannels`), but flags must still resolve.
///
/// ```swift
/// WatchtowerFlags.start(apiKey: "sp_live_…", endpoint: URL(string: "https://ingest.sitepong.com")!)
/// if WatchtowerFlags.isEnabled("ff_coinflow") { … }
/// ```
///
/// Offline story: the last-good server response is persisted and re-evaluated
/// on the next launch before the network refresh lands, so a cold offline
/// launch serves the previous flag set instead of defaults.
public enum WatchtowerFlags {

    // MARK: - Public API

    /// Fetch + evaluate the project's flags. Safe to call more than once.
    /// `completion` (optional) fires on the main queue after the first
    /// resolution — from cache when offline, from the network when reachable.
    public static func start(apiKey: String, endpoint: URL,
                             completion: (() -> Void)? = nil) {
        queue.async {
            self.apiKey = apiKey
            self.endpoint = endpoint
            // Serve the persisted last-good payload immediately…
            if results.isEmpty, let cached = loadCachedPayload() {
                evaluate(payload: cached)
            }
            // …then refresh from the network.
            fetchLocked { _ in
                DispatchQueue.main.async { completion?() }
            }
        }
    }

    /// The evaluated value of `key`, or `defaultValue` while unresolved /
    /// unknown. Never blocks.
    public static func isEnabled(_ key: String, default defaultValue: Bool = false) -> Bool {
        queue.sync { results[key] ?? defaultValue }
    }

    /// All evaluated flags (empty until the first resolution).
    public static var allFlags: [String: Bool] {
        queue.sync { results }
    }

    /// True once any flag set (cache or network) has been evaluated.
    public static var isReady: Bool {
        queue.sync { ready }
    }

    /// Re-fetch from the network. `completion(success)` on the main queue.
    public static func refresh(completion: ((Bool) -> Void)? = nil) {
        queue.async {
            fetchLocked { success in
                DispatchQueue.main.async { completion?(success) }
            }
        }
    }

    /// Sticky identity used for `userbase_percentage` bucketing and variant
    /// assignment. Auto-generated (UUID, persisted) unless the host pins one —
    /// pin the SAME id you use on other platforms for cross-platform bucket
    /// parity (mirrors `setAnonymousId` in the JS SDK).
    public static func setAnonymousId(_ id: String) {
        queue.async {
            anonymousId = id
            UserDefaults.standard.set(id, forKey: anonIdDefaultsKey)
            // Bucketing input changed — re-evaluate whatever we have.
            if let payload = lastPayload { evaluate(payload: payload) }
        }
    }

    // MARK: - State

    private static let queue = DispatchQueue(label: "com.watchtower.flags")
    private static var apiKey: String = ""
    private static var endpoint: URL?
    private static var results: [String: Bool] = [:]
    private static var ready = false
    private static var lastPayload: [String: Any]?

    private static let anonIdDefaultsKey = "com.watchtower.flags.anonymous_id"
    private static let cacheDefaultsKey = "com.watchtower.flags.last_payload"

    private static var anonymousId: String = {
        if let existing = UserDefaults.standard.string(forKey: anonIdDefaultsKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: anonIdDefaultsKey)
        return fresh
    }()

    // MARK: - Fetch

    private static func fetchLocked(completion: ((Bool) -> Void)? = nil) {
        guard let endpoint = endpoint, !apiKey.isEmpty else { completion?(false); return }
        var req = URLRequest(url: endpoint.appendingPathComponent("api/sdk/flags"))
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            guard ok, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Network failure: keep whatever we have (cache or defaults) —
                // same "never break the host" posture as the JS manager.
                queue.async { ready = true; completion?(false) }
                return
            }
            queue.async {
                persistCachedPayload(data)
                evaluate(payload: obj)
                completion?(true)
            }
        }.resume()
    }

    private static func persistCachedPayload(_ data: Data) {
        UserDefaults.standard.set(data, forKey: cacheDefaultsKey)
    }

    private static func loadCachedPayload() -> [String: Any]? {
        guard let data = UserDefaults.standard.data(forKey: cacheDefaultsKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// Must run on `queue`.
    private static func evaluate(payload: [String: Any]) {
        lastPayload = payload
        var next: [String: Bool] = [:]
        let flags = payload["flags"] as? [[String: Any]] ?? []
        for flag in flags {
            guard let key = flag["key"] as? String else { continue }
            next[key] = FlagEvaluator.evaluate(flag: flag, anonymousId: anonymousId)
        }
        results = next
        ready = true
    }
}

/// Port of `packages/sdk/src/flags/evaluator.ts` — semantics (and the djb2
/// bucketing hash) must match EXACTLY or native users land in different
/// rollout buckets than web/RN users.
enum FlagEvaluator {

    /// djb2 over UTF-16 code units (JS `charCodeAt`), 32-bit wrapping, returned
    /// as the JS `>>> 0` unsigned value.
    static func djb2Hash(_ str: String) -> UInt32 {
        var hash: UInt32 = 5381
        for unit in str.utf16 {
            hash = ((hash << 5) &+ hash) ^ UInt32(unit)
        }
        return hash
    }

    static func evaluate(flag: [String: Any], anonymousId: String,
                         now: Date = Date()) -> Bool {
        let key = flag["key"] as? String ?? ""

        // 1. Override wins.
        if let override = flag["override"] as? String {
            if override == "force_on" { return true }
            if override == "force_off" { return false }
        }
        // 2. Kill switch.
        if (flag["enabled"] as? Bool) != true { return false }
        // 3. No rules → on.
        let rules = flag["rules"] as? [[String: Any]] ?? []
        if rules.isEmpty { return true }
        // 4. All rules ANDed; any failure → off.
        for rule in rules {
            let type = rule["rule_type"] as? String ?? ""
            let config = rule["config"] as? [String: Any] ?? [:]
            if !evaluateRule(type: type, config: config, flagKey: key,
                             anonymousId: anonymousId, now: now) {
                return false
            }
        }
        return true
    }

    private static func evaluateRule(type: String, config: [String: Any],
                                     flagKey: String, anonymousId: String,
                                     now: Date) -> Bool {
        switch type {
        case "percentage_rollout":
            // Non-sticky by design (matches Math.random() in evaluator.ts) —
            // re-rolled per fetch, not per call, because results are memoized.
            let pct = doubleValue(config["percentage"])
            return Double.random(in: 0..<100) < pct

        case "userbase_percentage":
            let pct = doubleValue(config["percentage"])
            let bucket = djb2Hash("\(anonymousId):\(flagKey)") % 100
            return Double(bucket) < pct

        case "time_based":
            return evaluateTimeBased(config: config, now: now)

        case "device_type":
            // Native context: no UA sniffing — derive from the device idiom.
            let types = stringArray(config["types"])
            return types.contains(currentDeviceType())

        case "browser":
            // A native app has no browser; fail closed like evaluator.ts does
            // for a missing context field.
            return false

        case "os":
            let systems = stringArray(config["operating_systems"])
            return systems.contains("ios")

        default:
            // Unknown rule type — fail closed.
            return false
        }
    }

    /// Mirrors evaluator.ts `evaluateTimeBased`, including the overnight-range
    /// branch, using the rule's IANA timezone.
    static func evaluateTimeBased(config: [String: Any], now: Date) -> Bool {
        let tz = TimeZone(identifier: config["timezone"] as? String ?? "") ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let comps = cal.dateComponents([.weekday, .hour, .minute], from: now)
        // Calendar weekday: 1=Sun … 7=Sat → JS 0=Sun … 6=Sat.
        let dayOfWeek = (comps.weekday ?? 1) - 1
        let currentMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)

        if let days = config["days_of_week"] as? [Any], !days.isEmpty {
            let allowed = days.compactMap { intValue($0) }
            if !allowed.contains(dayOfWeek) { return false }
        }

        let start = (config["start_time"] as? String).flatMap(parseTime)
        let end = (config["end_time"] as? String).flatMap(parseTime)
        if let s = start, let e = end {
            if s > e {
                // Overnight range (e.g. 22:00–06:00).
                if currentMinutes < s && currentMinutes >= e { return false }
            } else {
                if currentMinutes < s || currentMinutes >= e { return false }
            }
        } else if let s = start {
            if currentMinutes < s { return false }
        } else if let e = end {
            if currentMinutes >= e { return false }
        }
        return true
    }

    /// "HH:mm" → minutes since midnight.
    private static func parseTime(_ str: String) -> Int? {
        let parts = str.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    private static func currentDeviceType() -> String {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "mobile"
        #else
        return "mobile"
        #endif
    }

    private static func doubleValue(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) ?? 0 }
        return 0
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func stringArray(_ any: Any?) -> [String] {
        (any as? [Any])?.compactMap { $0 as? String } ?? []
    }
}
