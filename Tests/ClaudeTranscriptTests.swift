import XCTest
@testable import Codenotch

/// The rule that answers "is Claude still working" for a session the registry
/// says nothing about. Every fixture here is shaped like a real tail from
/// `~/.claude/projects/<project>/<session>.jsonl`.
final class ClaudeTranscriptTests: XCTestCase {
    private let start = "2026-09-07T07:59:04.000Z"

    private func prompt(_ ts: String, sidechain: Bool = false) -> String {
        """
        {"type":"user","isSidechain":\(sidechain),"timestamp":"\(ts)",\
        "message":{"role":"user","content":"go on then"}}
        """
    }

    private func toolResult(_ ts: String) -> String {
        """
        {"type":"user","isSidechain":false,"timestamp":"\(ts)",\
        "message":{"role":"user","content":[{"type":"tool_result"}]}}
        """
    }

    private func assistant(_ ts: String, _ kind: String,
                           request: String = "req_1", tokens: Int = 100) -> String {
        """
        {"type":"assistant","isSidechain":false,"timestamp":"\(ts)","requestId":"\(request)",\
        "message":{"role":"assistant","content":[{"type":"\(kind)"}],\
        "usage":{"input_tokens":2,"output_tokens":\(tokens)}}}
        """
    }

    /// The bookkeeping entries Claude Code writes *after* the last assistant
    /// message. Taking one of them for the session's last word is what would
    /// leave a finished session spinning for ever.
    private let bookkeeping = [
        #"{"type":"last-prompt","content":"…"}"#,
        #"{"type":"mode","mode":"default"}"#,
        #"{"type":"ai-title","title":"…"}"#,
        #"{"type":"bridge-session","sessionId":"…","lastSequenceNum":42}"#,
    ]

    func testAFinishedTurnIsNotBusy() throws {
        let lines = [prompt(start),
                     assistant("2026-09-07T07:59:10.000Z", "thinking"),
                     assistant("2026-09-07T07:59:12.000Z", "text")] + bookkeeping
        let progress = try XCTUnwrap(ClaudeTranscript.progress(lines: lines))
        XCTAssertFalse(progress.isBusy)
    }

    /// The three shapes a turn in flight takes: a tool called, its result just
    /// back, and the model thinking about what to do with it.
    func testAnUnfinishedTurnIsBusy() throws {
        for tail in [assistant("2026-09-07T07:59:12.000Z", "tool_use"),
                     toolResult("2026-09-07T07:59:13.000Z"),
                     assistant("2026-09-07T07:59:14.000Z", "thinking")] {
            let progress = try XCTUnwrap(
                ClaudeTranscript.progress(lines: [prompt(start), tail])
            )
            XCTAssertTrue(progress.isBusy, tail)
        }
    }

    /// A subagent's line counts as the session working — its task is the
    /// session's work — but its *prompt* is not where the human's turn began.
    func testASubagentCountsAsWorkButNotAsATurn() throws {
        let lines = [
            prompt(start),
            assistant("2026-09-07T07:59:10.000Z", "tool_use"),
            prompt("2026-09-07T07:59:20.000Z", sidechain: true),
            """
            {"type":"assistant","isSidechain":true,"timestamp":"2026-09-07T07:59:30.000Z",\
            "requestId":"req_side","message":{"role":"assistant","content":[{"type":"tool_use"}],\
            "usage":{"output_tokens":40}}}
            """,
        ]
        let progress = try XCTUnwrap(ClaudeTranscript.progress(lines: lines))
        XCTAssertTrue(progress.isBusy)
        XCTAssertEqual(progress.turnStartedAt,
                       ISO8601DateFormatter().date(from: "2026-09-07T07:59:04Z"))
    }

    /// A tool result is written as a `user` entry too, and dating the turn from
    /// one would restart the clock on every tool call.
    func testTheTurnIsDatedFromThePromptNotFromAToolResult() throws {
        let lines = [prompt(start),
                     assistant("2026-09-07T07:59:10.000Z", "tool_use"),
                     toolResult("2026-09-07T07:59:11.000Z"),
                     assistant("2026-09-07T07:59:12.000Z", "tool_use")]
        let progress = try XCTUnwrap(ClaudeTranscript.progress(lines: lines))
        XCTAssertEqual(progress.turnStartedAt,
                       ISO8601DateFormatter().date(from: "2026-09-07T07:59:04Z"))
    }

    /// One request writes several entries, each repeating the same running
    /// total. Summing the entries counts it twice.
    func testTokensAreSummedPerRequestNotPerEntry() throws {
        let lines = [
            prompt(start),
            assistant("2026-09-07T07:59:10.000Z", "thinking", request: "req_1", tokens: 1_500),
            assistant("2026-09-07T07:59:11.000Z", "tool_use", request: "req_1", tokens: 1_500),
            toolResult("2026-09-07T07:59:12.000Z"),
            assistant("2026-09-07T07:59:20.000Z", "thinking", request: "req_2", tokens: 200),
            assistant("2026-09-07T07:59:21.000Z", "tool_use", request: "req_2", tokens: 200),
        ]
        let progress = try XCTUnwrap(ClaudeTranscript.progress(lines: lines))
        XCTAssertEqual(progress.outputTokens, 1_700)
    }

    /// A turn that began before the window is a turn whose age and token count
    /// are unknown. A lower bound presented as a figure is worse than none.
    func testATurnOlderThanTheWindowReportsNoFigures() throws {
        let lines = [assistant("2026-09-07T07:59:10.000Z", "tool_use", tokens: 900)]
        let progress = try XCTUnwrap(
            ClaudeTranscript.progress(lines: lines, completeFromStart: false)
        )
        XCTAssertTrue(progress.isBusy)
        XCTAssertNil(progress.turnStartedAt)
        XCTAssertNil(progress.outputTokens)
    }

    /// A window that starts mid-line leaves a fragment, and the file carries
    /// entry types this has never seen. Neither may cost a reading.
    func testFragmentsAndUnknownEntriesAreSkipped() throws {
        let lines = ["ontent\":[{\"type\":\"text\"}]}}",
                     #"{"type":"attachment","isSidechain":false}"#,
                     prompt(start),
                     assistant("2026-09-07T07:59:10.000Z", "tool_use")]
        let progress = try XCTUnwrap(ClaudeTranscript.progress(lines: lines))
        XCTAssertTrue(progress.isBusy)
        XCTAssertNotNil(progress.turnStartedAt)
    }

    func testNothingToGoOnIsNilRatherThanIdle() {
        XCTAssertNil(ClaudeTranscript.progress(lines: []))
        XCTAssertNil(ClaudeTranscript.progress(lines: bookkeeping))
        XCTAssertNil(ClaudeTranscript.progress(lines: ["not json at all"]))
    }

    /// Claude Code's own slug: every character that is not a letter, a digit or
    /// a hyphen becomes one — so a dot and an underscore collapse the same way
    /// a slash does.
    func testTheTranscriptPathIsDerivedFromTheWorkingDirectory() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(
            ClaudeTranscript.url(sessionID: "abc", cwd: "/Users/me/My_App", home: home).path,
            "/Users/me/.claude/projects/-Users-me-My-App/abc.jsonl"
        )
        XCTAssertEqual(
            ClaudeTranscript.url(sessionID: "abc", cwd: "/Users/me/a.b/.claude/worktrees/x",
                                 home: home).path,
            "/Users/me/.claude/projects/-Users-me-a-b--claude-worktrees-x/abc.jsonl"
        )
    }

    func testTokenTextReadsLikeAStatusLine() {
        XCTAssertEqual(ClaudeTranscript.tokenText(412), "412")
        XCTAssertEqual(ClaudeTranscript.tokenText(1_712), "1.7k")
        XCTAssertEqual(ClaudeTranscript.tokenText(23_800), "24k")
    }
}

/// Folding the transcript into the session the notch shows.
final class SessionTranscriptMergeTests: XCTestCase {
    private func record(status: String? = nil) -> ClaudeSessionRecord {
        var json: [String: Any] = [
            "pid": 4321,
            "cwd": "/Users/me/Repos/thing",
            "sessionId": "sess-1",
            "entrypoint": "claude-desktop",
            "statusUpdatedAt": NSNumber(value: 1_788_000_000_000),
        ]
        if let status { json["status"] = status }
        return ClaudeSessionRecord(json: json)!
    }

    private let busy = ClaudeTranscript.Progress(
        isBusy: true,
        turnStartedAt: Date(timeIntervalSince1970: 1_788_100_000),
        outputTokens: 1_712
    )

    func testABusyTranscriptLightsUpASilentRegistry() {
        let session = record().withTranscript(busy)
        XCTAssertEqual(session.state, .busy)
        XCTAssertEqual(session.since, busy.turnStartedAt)
        XCTAssertEqual(session.detail, "Desktop · thing · 1.7k tokens")
    }

    /// A registry that states its own status is the better source — it is the
    /// session's own word rather than an inference — so it is not overruled.
    func testAStatedStatusIsNotOverruled() {
        let session = record(status: "waiting").withTranscript(busy)
        XCTAssertEqual(session.state, .waiting)
        XCTAssertFalse(session.detail.contains("tokens"))
    }

    /// A finished transcript adds nothing: an assistant message with text in it
    /// means Claude has answered, which is what the registry's silence already
    /// amounts to.
    func testAFinishedTranscriptChangesNothing() {
        let idle = ClaudeTranscript.Progress(isBusy: false, turnStartedAt: Date(), outputTokens: 9)
        XCTAssertEqual(record().withTranscript(idle).state, .idle)
        XCTAssertEqual(record().withTranscript(nil).state, .idle)
    }

    /// No token count is no row rather than a zero, and the turn's age falls
    /// back to the registry's own stamp.
    func testMissingFiguresLeaveTheLineAlone() {
        let bare = ClaudeTranscript.Progress(isBusy: true, turnStartedAt: nil, outputTokens: nil)
        let session = record().withTranscript(bare)
        XCTAssertEqual(session.state, .busy)
        XCTAssertEqual(session.detail, "Desktop · thing")
        XCTAssertEqual(session.since, Date(timeIntervalSince1970: 1_788_000_000))
    }
}
