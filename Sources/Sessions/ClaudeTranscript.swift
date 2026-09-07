import Foundation

/// What a Claude Code session is doing *right now*, read from the transcript it
/// appends as it works.
///
/// Why not the session registry: `~/.claude/sessions/<pid>.json` carries a
/// `status`/`tempo` only from some entrypoints. A session started by the
/// desktop app (`"entrypoint": "claude-desktop"`, Claude Code 2.1.x) writes
/// that file once at launch and never touches it again — no status, no
/// `statusUpdatedAt` — so `ClaudeSessionRecord` reads every desktop session as
/// idle, the ring's activity arc never turns, and the notch cannot answer the
/// one question it exists to answer. The transcript is written by the session
/// itself whatever launched it, within about a second of each step, so it is
/// the only source that covers both.
///
/// Only the *shape* of the conversation is read: an entry's type, its
/// timestamp, the kinds of its content blocks, its request id and its token
/// counts. No message text is decoded, kept or shown — the fields that carry
/// what was said are never touched, and `Progress` has nowhere to put them.
struct ClaudeTranscript {
    /// The state of the session's current turn.
    struct Progress: Equatable {
        /// True while the turn is still running — a tool in flight, a request
        /// on its way back, a subagent working.
        ///
        /// False only once the session's last word is an assistant message
        /// with text in it, which is what a finished answer looks like.
        let isBusy: Bool
        /// When the human's last prompt landed, which is what "how long has it
        /// been working" is measured from. Nil when the turn began further back
        /// than the window read, rather than reporting a start that is wrong.
        let turnStartedAt: Date?
        /// Tokens the model has produced in this turn. Nil for the same reason.
        let outputTokens: Int?
    }

    /// How much of the tail to read. A transcript grows to megabytes over a
    /// session, and everything this needs is at the end of it.
    static let window = 256 * 1024

    /// `~/.claude/projects/<slugged cwd>/<session id>.jsonl`.
    ///
    /// The slug is the working directory with every character that is not a
    /// letter, a digit or a hyphen replaced by one — so `/Users/me/My_App`
    /// becomes `-Users-me-My-App`, and a path with a dot in it collapses the
    /// same way. Claude Code's own rule; if it ever changes, the file is simply
    /// not found and the session keeps whatever the registry said about it.
    static func url(sessionID: String, cwd: String,
                    home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        let slug = String(cwd.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        return home
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(slug)
            .appendingPathComponent("\(sessionID).jsonl")
    }

    /// Reads the tail of the file at `url`. Nil when there is nothing there to
    /// read, or nothing in the window that says anything about a turn.
    static func progress(at url: URL) -> Progress? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        try? handle.seek(toOffset: UInt64(max(0, size - window)))
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }

        // A window that starts mid-line leaves a fragment at the front; it is
        // dropped by the `{` test in `progress(lines:)` rather than by counting
        // bytes, because a multi-byte character can straddle the boundary too.
        return progress(lines: text.split(separator: "\n").map(String.init),
                        completeFromStart: size <= window)
    }

    /// The rule itself, over lines. Separate so it can be tested against tails
    /// taken from a real transcript without a file.
    ///
    /// Walked from the end: what matters is the last thing that happened, and
    /// the further back a line is the less it can say about that.
    static func progress(lines: [String], completeFromStart: Bool = true) -> Progress? {
        var isBusy: Bool?
        var turnStartedAt: Date?
        /// Keyed by request, because one request writes several entries — a
        /// thinking block, then a tool call — and every one of them repeats the
        /// same running total. Summing the entries would count it twice.
        var tokensByRequest: [String: Int] = [:]

        for line in lines.reversed() {
            guard line.hasPrefix("{"),
                  let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // Everything that is not a turn of the conversation: the title, the
            // mode, the bridge's own bookkeeping, attachments. They are written
            // *after* the last assistant message, so mistaking one for the last
            // word would make a finished session look busy for ever.
            let type = entry["type"] as? String
            guard type == "user" || type == "assistant" else { continue }

            let message = entry["message"] as? [String: Any]
            let kinds = contentKinds(message?["content"])

            // The last word, whatever it was. A subagent's line counts: the
            // session is working while one of its tasks is.
            if isBusy == nil {
                isBusy = !(type == "assistant" && kinds.contains("text"))
            }

            if type == "assistant" {
                if let requestID = entry["requestId"] as? String,
                   let usage = message?["usage"] as? [String: Any],
                   let produced = (usage["output_tokens"] as? NSNumber)?.intValue {
                    // First seen walking back is the last written for that
                    // request, which is its final count.
                    if tokensByRequest[requestID] == nil { tokensByRequest[requestID] = produced }
                }
                continue
            }

            // A prompt from the person, which is where the turn began. A tool
            // result is also written as a `user` entry and is emphatically not
            // that; nor is a subagent's own prompt, which would date the turn
            // from whenever the task was handed out.
            let isSidechain = (entry["isSidechain"] as? NSNumber)?.boolValue ?? false
            guard !isSidechain, kinds.contains("text") else { continue }
            turnStartedAt = timestamp(entry["timestamp"])
            break
        }

        guard let isBusy else { return nil }
        // The turn started further back than the window, so its age and its
        // token count are both unknown — and a lower bound presented as a
        // figure is worse than no figure.
        guard turnStartedAt != nil || completeFromStart else {
            return Progress(isBusy: isBusy, turnStartedAt: nil, outputTokens: nil)
        }
        return Progress(isBusy: isBusy,
                        turnStartedAt: turnStartedAt,
                        outputTokens: tokensByRequest.values.reduce(0, +))
    }

    /// The kinds of a message's content blocks. A plain string is a prompt with
    /// nothing but words in it, which is a `text` block written the short way.
    private static func contentKinds(_ content: Any?) -> Set<String> {
        if content is String { return ["text"] }
        guard let blocks = content as? [[String: Any]] else { return [] }
        return Set(blocks.compactMap { $0["type"] as? String })
    }

    /// The transcript's timestamps carry fractional seconds; `.iso8601` alone
    /// will not parse them — the same pair `ClaudeOAuthProvider` needs.
    private static func timestamp(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFraction.date(from: text) ?? plain.date(from: text)
    }

    /// "412", "1.7k", "24k" — the shape Claude Code's own status line uses.
    static func tokenText(_ tokens: Int) -> String {
        if tokens < 1_000 { return "\(tokens)" }
        if tokens < 10_000 {
            return "\(String(format: "%.1f", Double(tokens) / 1_000))k"
        }
        return "\(Int((Double(tokens) / 1_000).rounded()))k"
    }
}
