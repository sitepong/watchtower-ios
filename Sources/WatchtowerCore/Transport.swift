import Foundation

/// URLSession-based transport: batches tap events (§1.3) and uploads screenshot
/// templates on a miss (§1.2). All work is dispatched onto a private serial
/// queue; failures retry with backoff and drop after N attempts. Never throws to
/// the host app.
final class Transport {
    private let apiKey: String
    private let projectId: String
    private let endpoint: URL
    private let session: URLSession
    private let queue = DispatchQueue(label: "com.watchtower.transport")

    private var buffer: [CaptureEvent] = []
    private var flushTimer: DispatchSourceTimer?

    private let batchSize = 50
    private let flushInterval: TimeInterval = 10
    private let maxRetries = 3

    init(apiKey: String, projectId: String, endpoint: URL) {
        self.apiKey = apiKey
        self.projectId = projectId
        self.endpoint = endpoint
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
        startTimer()
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        t.setEventHandler { [weak self] in self?.flushLocked() }
        t.resume()
        flushTimer = t
    }

    func enqueue(_ event: CaptureEvent) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.buffer.append(event)
            if self.buffer.count >= self.batchSize {
                self.flushLocked()
            }
        }
    }

    /// Flush remaining events (called on background / teardown).
    func flush() {
        queue.async { [weak self] in self?.flushLocked() }
    }

    /// Synchronous flush used at teardown to give pending events a chance to send.
    func flushAndWait(timeout: TimeInterval = 3) {
        let sem = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            self?.flushLocked()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
    }

    private func flushLocked() {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        postTaps(batch, attempt: 0)
    }

    private func headers(for request: inout URLRequest) {
        request.setValue(projectId, forHTTPHeaderField: "X-Project-ID")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    private func postTaps(_ events: [CaptureEvent], attempt: Int) {
        guard let data = try? JSONEncoder().encode(TapsBatch(events: events)) else { return }
        var req = URLRequest(url: endpoint.appendingPathComponent("api/taps"))
        req.httpMethod = "POST"
        headers(for: &req)
        req.httpBody = data

        session.dataTask(with: req) { [weak self] _, resp, err in
            guard let self = self else { return }
            let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            if !ok || err != nil {
                if attempt < self.maxRetries {
                    let delay = pow(2.0, Double(attempt)) // 1,2,4s
                    self.queue.asyncAfter(deadline: .now() + delay) {
                        self.postTaps(events, attempt: attempt + 1)
                    }
                }
                // else: drop silently (never crash the host).
            }
        }.resume()
    }

    /// Upload a redacted screenshot template. Calls `completion(isNew)` on success.
    func postTemplate(routeName: String, pHash: String, width: Int, height: Int,
                      pngBase64: String, completion: ((Bool) -> Void)? = nil) {
        let payload = TemplateUpload(route_name: routeName, p_hash: pHash,
                                     width: width, height: height, image_base64: pngBase64)
        guard let data = try? JSONEncoder().encode(payload) else { completion?(false); return }
        var req = URLRequest(url: endpoint.appendingPathComponent("api/taps/template"))
        req.httpMethod = "POST"
        headers(for: &req)
        req.httpBody = data

        session.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            var isNew = false
            if ok, let data = data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                isNew = (obj["isNew"] as? Bool) ?? false
            }
            completion?(ok ? isNew : false)
        }.resume()
    }

    /// Upload a Layer-3 sampled session frame (§1.4). Fire-and-forget: frames
    /// are best-effort and never retried (they are replay enrichment, not the
    /// canonical record).
    func postFrame(sessionId: String, timestamp: String, screenName: String,
                   frameHash: String, width: Int, height: Int, pngBase64: String) {
        let payload = FrameUpload(session_id: sessionId, timestamp: timestamp,
                                  screen_name: screenName, frame_hash: frameHash,
                                  width: width, height: height, image_base64: pngBase64)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        var req = URLRequest(url: endpoint.appendingPathComponent("api/frames"))
        req.httpMethod = "POST"
        headers(for: &req)
        req.httpBody = data
        session.dataTask(with: req).resume()
    }
}
