import Foundation

/// Adds the routing facts `codecat-hook` knows (being a child of `claude`) to the
/// JSON payload Claude Code hands it, before forwarding it to the app.
public enum HookPayload {

    public struct RouteFields: Equatable, Sendable {
        public let hostPID: pid_t?
        public let hostBundlePath: String?
        public let hostBundleID: String?
        public let tty: String?
        /// PID of this session's `claude` process — see `Session.agentPID`.
        public let agentPID: pid_t?

        public init(hostPID: pid_t?, hostBundlePath: String?, hostBundleID: String?,
                    tty: String?, agentPID: pid_t? = nil) {
            self.hostPID = hostPID
            self.hostBundlePath = hostBundlePath
            self.hostBundleID = hostBundleID
            self.tty = tty
            self.agentPID = agentPID
        }
    }

    /// Returns `data` with the route fields added. Anything that is not a JSON
    /// object — or that fails to re-encode — comes back byte for byte: enrichment
    /// must never be the reason an event is lost.
    public static func enriched(_ data: Data, with fields: RouteFields) -> Data {
        guard !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data),
              var object = parsed as? [String: Any] else { return data }

        if let pid = fields.hostPID { object["host_pid"] = Int(pid) }
        if let path = fields.hostBundlePath { object["host_bundle_path"] = path }
        if let id = fields.hostBundleID { object["host_bundle_id"] = id }
        // Namespaced like the other three: an un-namespaced `tty` would clobber any
        // field Claude Code ships under that name, and a non-string value left in
        // place would fail `HookEvent` decoding — losing *every* event, not just this one.
        if let tty = fields.tty { object["host_tty"] = tty }
        if let agentPID = fields.agentPID { object["agent_pid"] = Int(agentPID) }

        guard let encoded = try? JSONSerialization.data(withJSONObject: object) else { return data }
        return encoded
    }
}
