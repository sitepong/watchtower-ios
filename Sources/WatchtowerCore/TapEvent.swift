import Foundation

/// A single capture event — the tagged union from spec §1.1. `type` selects
/// which optional fields are populated ("tap" | "screen_view" | "session_start"
/// | "session_end"). Synthesized Codable omits nil optionals on the wire.
public struct CaptureEvent: Codable {
    // Common fields (every type)
    public var type: String
    public var session_id: String
    public var sequence: UInt64
    public var timestamp: String
    public var platform: String
    public var app_version: String?
    public var distinct_id: String?
    public var device_model: String?
    public var os_version: String?
    /// Persistent per-install id (identifierForVendor) — stamped on every event
    /// so the dashboard can stitch consecutive sessions from the same install
    /// into a journey at read time, even for anonymous users.
    public var install_id: String?

    // session_start (only on a session that opened after a background→foreground
    // gap): the id of the session this one continues from, and the idle gap in
    // milliseconds. These are the read-time linking hints.
    public var previous_session_id: String?
    public var session_gap_ms: UInt64?

    // identity traits — only populated on an "identify" event (Watchtower.setUser
    // with email/name), so PII is sent once per identify, not on every tap.
    public var email: String?
    public var name: String?

    // screen_view
    public var screen_name: String?
    public var prev_screen_name: String?

    // session_end
    public var duration_ms: UInt64?
    public var reason: String?

    // tap
    public var screen_fp: String?
    public var element_id: String?
    public var element_label: String?
    public var element_role: String?
    public var x: Double?
    public var y: Double?
    public var viewport_w: UInt?
    public var viewport_h: UInt?
    public var frame_hash: String?
    /// Client-side heuristic (§1.1): tap produced no observable response.
    /// nil when false or undetermined — never sent as false.
    public var dead: Bool?
}

struct TapsBatch: Codable {
    let events: [CaptureEvent]
}

struct TemplateUpload: Codable {
    let route_name: String
    let p_hash: String
    let width: Int
    let height: Int
    let image_base64: String
}

struct FrameUpload: Codable {
    let session_id: String
    let timestamp: String
    let screen_name: String
    let frame_hash: String
    let width: Int
    let height: Int
    let image_base64: String
}
