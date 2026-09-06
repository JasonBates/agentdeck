import Foundation

// MARK: - Pulling readable content out of a session transcript
//
// All three agents converged on the same broad shape — a message entry whose `content`
// is an array of blocks carrying a `text` string — but they disagree on every detail:
//
//   claude  {"message": {"role": "user",      "content": [{"type": "text",        "text": …}]}}
//   pi      {"type": "message", "message": {"role": "assistant", "content": [{"type": "thinking", …}]}}
//   codex   {"type": "response_item", "payload": {"type": "message", "role": "user",
//                                                 "content": [{"type": "input_text", "text": …}]}}
//
// So the extractor walks blocks generically and takes any `text` it finds, while
// selecting entries per-format. pi also emits role "toolResult", which is noise.

struct TranscriptDigest {
    /// Opening request — what the session was convened to do.
    var opening: String
    /// The user's requests only, oldest-first, no agent prose. Titles and subtitles are
    /// built from these alone: mixing in the agent's replies made both tiers describe
    /// the same work back, which is what kept tripping the redundancy guard.
    var requests: String
    /// The last few turns including replies — context for nothing but fallbacks.
    var recent: String
    /// The most recent thing the user actually asked for. The subtitle is built from
    /// this rather than the whole recent block: given the block, a small model just
    /// paraphrases the title back and the redundancy guard throws it away.
    var lastPrompt: String
    /// Hash of the most recent user turn. This is the honest "a new prompt arrived"
    /// signal: mtime changes on every tool call, so keying off the file makes the
    /// subtitle regenerate every 30s forever, which is what made names wobble.
    var lastPromptKey: Int
    /// The agent's most recent reply, and a key that changes when it finishes a turn.
    /// This is what the state summary reads: did it finish, what's next, what's blocked.
    var lastReply: String
    var lastReplyKey: Int
    var stamp: Date
}

enum Transcript {
    private static let cacheLock = NSLock()
    private static var digests: [String: (stamp: Date, size: Int, value: TranscriptDigest?)] = [:]

    /// Recent conversation, oldest-first, for handing to a model.
    /// User turns are what actually define the work, so they're kept preferentially.
    static func digest(agent kind: String, path: String,
                       userTurns: Int = 5, assistantTurns: Int = 2) -> TranscriptDigest? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int,
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }

        // Re-reading and JSON-parsing 512KB per agent on every poll was the whole cost
        // of a tick, and it capped how fast we could poll — which is what put a floor
        // under how quickly a desktop focus change showed up here.
        cacheLock.lock()
        if let hit = digests[path], hit.size == size, hit.stamp == mtime {
            cacheLock.unlock()
            return hit.value
        }
        cacheLock.unlock()

        let result = build(kind: kind, path: path, size: size, mtime: mtime,
                           userTurns: userTurns, assistantTurns: assistantTurns)
        cacheLock.lock(); digests[path] = (mtime, size, result); cacheLock.unlock()
        return result
    }

    private static func build(kind: String, path: String, size: Int, mtime: Date,
                              userTurns: Int, assistantTurns: Int) -> TranscriptDigest? {

        var users: [String] = []
        var assistants: [String] = []
        // Greetings and acknowledgements, kept only in case the session has nothing else.
        var social: [String] = []

        for obj in tail(path, size, mtime) {
            guard let (role, raw) = message(kind: kind, obj) else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count > 2 else { continue }
            let clipped = String(text.prefix(400))

            switch role {
            // Tool results wear the user's role. Feeding them in as "USER:" told the
            // model the user had asked for whatever a command happened to print —
            // which is how a sed on subjectiv.book.yaml became a session's summary.
            case "user" where users.count < userTurns && Self.isRealPrompt(text):
                // "good morning" is a real turn but asks for nothing, so it must not be
                // counted as a request — see carriesIntent.
                if Self.carriesIntent(text) {
                    users.append(clipped)
                } else if social.count < 2 {
                    social.append(clipped)
                }
            case "assistant" where assistants.count < assistantTurns:
                // Keep the newest reply at full length; it's the state summary's input.
                assistants.append(assistants.isEmpty ? String(text.prefix(1400)) : clipped)
            default:
                continue
            }
            if users.count >= userTurns && assistants.count >= assistantTurns { break }
        }

        // A session that so far consists only of "good morning" still has to say
        // something, so the greeting is used rather than nothing at all.
        if users.isEmpty { users = social }

        guard !users.isEmpty || !assistants.isEmpty else { return nil }

        var recent: [String] = []
        for u in users.reversed() { recent.append("USER: \(u)") }
        for a in assistants.reversed() { recent.append("ASSISTANT: \(a)") }

        return TranscriptDigest(
            opening: opening(agent: kind, path: path) ?? users.last ?? "",
            requests: users.reversed().map { "- \($0)" }.joined(separator: "\n"),
            recent: recent.joined(separator: "\n"),
            lastPrompt: users.first ?? "",
            lastPromptKey: (users.first ?? "").hashValue,
            lastReply: assistants.first ?? "",
            lastReplyKey: (assistants.first ?? "").hashValue,
            stamp: mtime
        )
    }

    private static let openingLock = NSLock()
    private static var openings: [String: String] = [:]

    /// The session's first real request, read from the head of the file. A real opening is
    /// cached, because it never changes once written; the greeting fallback below is not.
    static func opening(agent kind: String, path: String) -> String? {
        openingLock.lock()
        if let hit = openings[path] { openingLock.unlock(); return hit.isEmpty ? nil : hit }
        openingLock.unlock()

        var found = ""
        var social = ""
        if let fh = FileHandle(forReadingAtPath: path) {
            defer { try? fh.close() }
            if let data = try? fh.read(upToCount: 256 * 1024),
               let text = String(data: data, encoding: .utf8) {
                for line in text.components(separatedBy: .newlines) {
                    guard line.hasPrefix("{"), let d = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let (role, raw) = message(kind: kind, obj), role == "user"
                    else { continue }
                    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Skip hook output, injected context and resumed-session blobs.
                    guard isRealPrompt(t) else { continue }
                    // A greeting is a turn, not an opening request. Taken as the opening
                    // it becomes the whole basis of the title, and the title prompt is
                    // told to stay with the opening while history is thin — so the
                    // session gets named after the hello and keeps that name.
                    if carriesIntent(t) {
                        found = String(t.prefix(300))
                        break
                    }
                    if social.isEmpty { social = String(t.prefix(300)) }
                }
            }
        }
        // Only a real opening is cached. The greeting fallback is deliberately not:
        // the substantive first request usually arrives moments later, and caching the
        // hello would pin the session's name to it for the rest of its life.
        if found.isEmpty { return social.isEmpty ? nil : social }
        openingLock.lock(); openings[path] = found; openingLock.unlock()
        return found
    }

    /// Returns (role, text) for entries that are actual conversation turns.
    private static func message(kind: String, _ obj: [String: Any]) -> (String, String)? {
        switch kind {
        case "claude", "pi":
            // pi tags entries with type "message"; claude has no type on these.
            if kind == "pi", obj["type"] as? String != "message" { return nil }
            // Claude identifies harness-injected user-role entries directly. These
            // include skill bodies, hook continuations, cross-session notifications
            // and automated prompts. Their prose can look exactly like a real request,
            // so preserving this structural distinction is safer than guessing from
            // text after flattening it.
            if kind == "claude", obj["isMeta"] as? Bool == true { return nil }
            guard let m = obj["message"] as? [String: Any],
                  let role = m["role"] as? String,
                  let text = flatten(m["content"]) else { return nil }
            // A slash command hides the user's words inside an envelope. Lift them out
            // here, before any of the filters below see the turn.
            return (role, role == "user" ? unwrapCommand(text) : text)
        case "codex":
            guard obj["type"] as? String == "response_item",
                  let p = obj["payload"] as? [String: Any],
                  p["type"] as? String == "message",
                  let role = p["role"] as? String,
                  let text = flatten(p["content"]) else { return nil }
            return (role, text)
        default:
            return nil
        }
    }

    /// `content` is a plain string for a typed prompt and an array of blocks for
    /// everything else. Handling only the array form skips every message the user
    /// actually wrote — which left titles with nothing to anchor on, and made the
    /// "new prompt" key a constant so subtitles never refreshed.
    private static func flatten(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            let t = blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
            return t.isEmpty ? nil : t
        }
        return nil
    }

    /// A slash command arrives as an envelope — `<command-name>/goal</command-name>`,
    /// `<command-message>`, `<command-args>` — which `isRealPrompt` drops on both the
    /// leading `<` and the marker, taking with it the only place the user's own words
    /// appear. Opening a session with `/goal fix the drag bug` therefore left nothing to
    /// title at all: the `<local-command-stdout>` echo that follows is filtered too, and
    /// the Stop-hook injection quoting the goal back is `isMeta`. Handed two empty slots
    /// the title model replied by asking for the text, and the card fell back to Herdr's
    /// terminal title — "Claude Code" — for the life of the session.
    ///
    /// The arguments are what the user typed, so they stand in for the turn. A command
    /// carrying none is left alone and filtered as before: `/endday` names a routine,
    /// not a request, and reading the command name as one would title sessions after the
    /// harness rather than the work.
    static func unwrapCommand(_ text: String) -> String {
        guard text.contains("<command-name>"),
              let open = text.range(of: "<command-args>"),
              let close = text.range(of: "</command-args>",
                                     range: open.upperBound..<text.endIndex)
        else { return text }
        let args = text[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return args.isEmpty ? text : args
    }

    /// Tool results, hook output and injected context all arrive wearing the user's
    /// role. They aren't requests and must not be mistaken for one.
    ///
    /// The worst offenders are **skill bodies**: invoking a skill injects its entire
    /// documentation as a user message. Hundreds of words of skill prose then outweigh
    /// everything actually typed, and the title comes out describing the skill —
    /// "Manage Subjectiv intellectual collaboration", "Organize terminal workspaces" —
    /// rather than the work. In a sample of 54 user-role turns, 7 were injected.
    static func isRealPrompt(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 8, !t.hasPrefix("<"), !t.hasPrefix("{") else { return false }

        // Skill invocation: the harness prepends this before the skill's own markdown.
        if t.hasPrefix("Base directory for this skill") { return false }
        // Codex records its injected repository instructions as a user-role turn. The
        // block can include the global Mem0 policy, machine details and project rules,
        // so it easily outweighs the actual opening request and produces titles such
        // as "Update memory instruction file". Match the harness header, not ordinary
        // requests that happen to mention AGENTS.md or Mem0.
        if t.hasPrefix("# AGENTS.md instructions")
            || t.hasPrefix("## Mem0 context") {
            return false
        }
        // Claude's context-compaction handoff is a synthetic user turn but, unlike
        // its other injected entries, is not marked `isMeta`. The summary is useful to
        // Claude itself, but it must not replace the user's real opening request here.
        if t.hasPrefix("This session is being continued from a previous conversation") {
            return false
        }
        // Interruption notices are harness state, not follow-up requests.
        if t.hasPrefix("[Request interrupted by user") { return false }
        // Attachment placeholders carry no intent.
        if t.hasPrefix("[Image") || t.hasPrefix("[Screenshot") { return false }
        // A pasted URL on its own is data, not a request. A URL *inside* a sentence is
        // fine — "recreate something like this on the mac? https://…" is a real ask.
        if t.hasPrefix("http"), !t.contains(" ") { return false }

        for marker in ["system-reminder", "command-name", "local-command",
                       "tool_use_error", "Caveat:"] where t.contains(marker) {
            return false
        }
        return true
    }

    /// True when a turn actually asks for something.
    ///
    /// "good morning" is a genuine thing the user typed, so `isRealPrompt` rightly keeps
    /// it — but it names no work. Handed to the title model as the opening request, the
    /// only thing left to describe is the assistant's own reply to it, so a daily-notes
    /// session came out titled "Greet user and start conversation" with the subtitle
    /// "Acknowledge user update and personal reflections". Both read like instructions to
    /// the agent rather than anything the user said, because in effect that is what they
    /// are. Conversations that open with a hello are the norm in the daily-notes vault.
    ///
    /// Only whole-turn pleasantries are filtered. "good morning, can you check the
    /// deploy?" carries intent and must survive, so the match is anchored to the entire
    /// normalised turn and only short turns are candidates at all.
    static func carriesIntent(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 40 else { return true }

        // Strip punctuation and emoji, collapse spacing: "Good morning!! ☀️" → "good morning".
        let stripped = t.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        let words = String(stripped)
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }

        // Vocatives and softeners: "morning claude", "thanks mate", "ok cool".
        // "you" is deliberately absent: it belongs to whole phrases that are matched
        // outright ("thank you", "how are you"), and stripping it left "thank" unmatched.
        let filler: Set<String> = ["claude", "codex", "pi", "there", "mate", "buddy",
                                   "again", "all", "cool", "please", "now", "then"]
        let core = words.filter { !filler.contains($0) }
        guard !core.isEmpty else { return false }

        let pleasantries: Set<String> = [
            "hi", "hey", "hello", "yo", "gm", "morning", "afternoon", "evening", "hiya",
            "good morning", "good afternoon", "good evening", "good day", "good night",
            "howdy", "greetings", "welcome back", "how are you", "how are things",
            "thanks", "thank you", "thanks so much", "cheers", "ta", "much appreciated",
            "appreciated", "nice one", "perfect", "great", "excellent", "lovely",
            "brilliant", "awesome", "amazing", "wonderful", "sounds good", "looks good",
            "ok", "okay", "k", "sure", "yes", "yep", "yeah", "yup", "no", "nope", "nah",
            "right", "fine", "got it", "understood", "noted", "agreed", "indeed",
            "no worries", "no problem", "np", "never mind", "nvm", "carry on",
            "go ahead", "go on", "continue", "proceed", "keep going", "done", "ready",
            "bye", "goodbye", "see you", "later", "good stuff", "well done", "nice",
        ]
        return !pleasantries.contains(core.joined(separator: " "))
    }

    /// Newest-first objects from the tail, parsed only as far as the caller reads.
    /// Codex rollouts reach 66MB, so never read whole. Shared with the context gauge
    /// through JSONL so one write costs one read.
    private static func tail(_ path: String, _ size: Int, _ mtime: Date) -> AnySequence<[String: Any]> {
        JSONL.tailObjects(path, size: size, mtime: mtime)
    }

    /// Drop per-file caches for transcripts no live pane reads any more.
    static func retain(paths: Set<String>) {
        cacheLock.lock(); digests = digests.filter { paths.contains($0.key) }; cacheLock.unlock()
        openingLock.lock(); openings = openings.filter { paths.contains($0.key) }; openingLock.unlock()
    }
}
