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
        // `UserPromptSubmit` carries the whole prompt, and the whole prompt is how
        // this payload gets big. A unix datagram on macOS is capped at 2 048 bytes
        // (`net.local.dgram.maxdgram`) and `sendto` REFUSES anything larger — the
        // event is not truncated in transit, it never arrives. Measured on this
        // machine: of 1 760 delivered hook events not one exceeded 2 045 B, while
        // prompts of 2–27 KB are ordinary, and their events were logged as "did not
        // reach the socket (app not running?)" when the app was running perfectly
        // well.
        //
        // The app only ever shows `TaskText.maxLength` characters of it, so trimming
        // here costs nothing and buys back every long-prompt event. Trimmed to the
        // same one line the row draws, by the same code, so the hook and the
        // transcript can never disagree about what a prompt says.
        if let prompt = object["prompt"] as? String {
            object["prompt"] = TaskText.sanitized(prompt)
        }

        guard let encoded = try? JSONSerialization.data(withJSONObject: object) else { return data }
        return encoded
    }
}
