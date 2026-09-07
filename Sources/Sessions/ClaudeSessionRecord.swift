import Foundation

/// One entry in `~/.claude/sessions/<pid>.json`, as Claude Code writes it.
///
/// Kept separate from `AgentSession` because it carries things only the Claude
/// monitor needs — the pid and process start time used to tell a live session
/// from a file a crashed one left behind.
struct ClaudeSessionRecord {
    let pid: Int32
    /// Roughly when the process started. Only used to notice a recycled pid.
    let startedAt: Date?
    let session: AgentSession
    /// Where the session's own transcript is, for the state the registry does
    /// not carry — see `ClaudeTranscript`.
    let transcript: URL?
    /// Whether the registry actually said what the session is doing.
    ///
    /// False for every session the desktop app starts: it writes the file once
    /// and never updates it, so the absence of `status`/`tempo` is not "idle",
    /// it is "not stated". Only then is the transcript consulted — a registry
    /// that does say something is the better source, since it is the session's
    /// own word for its state rather than an inference from what it wrote.
    let declaresState: Bool

    /// Decoded leniently on purpose: the file is written by another program on
    /// its own release schedule, and an unknown field must never cost us a
    /// session we could have shown.
    init?(json: [String: Any]) {
        guard let pid = (json["pid"] as? NSNumber)?.int32Value,
              let cwd = json["cwd"] as? String else { return nil }

        let raw = json["status"] as? String
        let tempo = json["tempo"] as? String        // the normalised form, when present
        self.declaresState = raw != nil || tempo != nil
        let state: AgentSession.State
        switch (tempo, raw) {
        case ("blocked", _), (_, "waiting"): state = .waiting
        case ("active", _), (_, "busy"):     state = .busy
        default:                             state = .idle
        }

        let millis = (json["statusUpdatedAt"] as? NSNumber)?.doubleValue
            ?? (json["updatedAt"] as? NSNumber)?.doubleValue

        self.pid = pid
        if let started = (json["startedAt"] as? NSNumber)?.doubleValue {
            self.startedAt = Date(timeIntervalSince1970: started / 1000)
        } else {
            self.startedAt = (json["procStart"] as? String).flatMap(Self.parseProcStart)
        }

        let folder = (cwd as NSString).lastPathComponent
        self.transcript = (json["sessionId"] as? String).map {
            ClaudeTranscript.url(sessionID: $0, cwd: cwd)
        }
        self.session = AgentSession(
            id: "claude.\(pid)",
            name: (json["name"] as? String) ?? folder,
            detail: "\(Self.surface(json["entrypoint"] as? String)) · \(folder)",
            state: state,
            waitingFor: (json["waitingFor"] as? String) ?? (json["needs"] as? String),
            since: millis.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        )
    }

    /// The session as the notch should show it, with what the transcript says
    /// folded in where the registry said nothing.
    ///
    /// Only ever *adds* a working state. A transcript that looks finished
    /// leaves the session as the registry had it: the last word being an
    /// assistant message means Claude has answered, which is idle — the same
    /// thing the registry's silence already amounts to. Nothing here can
    /// produce `waiting`, because a session blocked on a permission prompt
    /// writes exactly what a long-running tool writes and the two cannot be
    /// told apart from the file.
    func withTranscript(_ progress: ClaudeTranscript.Progress?) -> AgentSession {
        guard !declaresState, let progress, progress.isBusy else { return session }
        return AgentSession(
            id: session.id,
            name: session.name,
            // The token count rides on the second line rather than taking a
            // row of its own: the card's height is budgeted per row, and one
            // more row per session costs the session list its own space.
            detail: progress.outputTokens.map {
                "\(session.detail) · \(ClaudeTranscript.tokenText($0)) tokens"
            } ?? session.detail,
            state: .busy,
            waitingFor: session.waitingFor,
            // Measured from the prompt that started the turn, which is what
            // "1m 28s" in Claude Code's own status line counts. Falls back to
            // the registry's own stamp when the turn began before the window.
            since: progress.turnStartedAt ?? session.since
        )
    }

    static func surface(_ entrypoint: String?) -> String {
        switch entrypoint {
        case "claude-desktop", "claude-desktop-3p": return "Desktop"
        case "claude-vscode":                       return "VS Code"
        case "local-agent":                         return "Agent"
        default:                                    return "Terminal"
        }
    }

    /// `procStart` looks like "Fri Aug 28 05:15:20 2026" — a ctime string, in
    /// **UTC**, with the day of month space-padded on single-digit days.
    static func parseProcStart(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let collapsed = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return formatter.date(from: collapsed)
    }
}
