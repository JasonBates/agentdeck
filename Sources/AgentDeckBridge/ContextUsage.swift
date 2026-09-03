import Foundation

// MARK: - How full is each agent's context window
//
// All three agents write transcripts to disk, in three different shapes. None of this
// touches an API or a credential — it's all local files.
//
//   claude  ~/.claude/projects/<cwd-as-dashes>/<session-uuid>.jsonl
//           last assistant `message.usage`; context = input + cache_read + cache_creation
//   pi      path handed to us directly by Herdr (agent_session.kind == "path")
//           last `type:"message"` with `message.usage`; context = input + cacheRead
//   codex   ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl
//           last event_msg/token_count; context = info.last_token_usage.total_tokens
//           and — uniquely — the real limit in info.model_context_window
//
// Transcripts get large (a live codex rollout here is 66MB), so every reader seeks to
// the tail and caches against file size + mtime.

struct ContextUse: Encodable {
    var used: Int
    var limit: Int
    var percent: Int
    var model: String?
}

enum ContextReader {
    private static let lock = NSLock()
    private static var cache: [String: (stamp: Date, size: Int, value: ContextUse?)] = [:]
    private static var codexPaths: [String: String] = [:]

    /// Where an agent's transcript lives. Shared with the titler, which reads the same
    /// files for their content rather than their token counts.
    static func path(agent kind: String, session: HerdrAgentSession?, cwd: String) -> String? {
        guard let value = session?.value, !value.isEmpty else { return nil }
        let fm = FileManager.default
        switch kind {
        case "claude":
            // Spaces are slugified too: "…/000 Daily Notes" becomes
            // "…-000-Daily-Notes". Replacing only slashes silently loses those sessions.
            let slug = cwd
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: " ", with: "-")
            let p = "\(NSHomeDirectory())/.claude/projects/\(slug)/\(value).jsonl"
            return fm.fileExists(atPath: p) ? p : nil
        case "pi":
            // Herdr hands us the exact path, so there is nothing to resolve.
            guard session?.kind == "path", fm.fileExists(atPath: value) else { return nil }
            return value
        case "codex":
            return codexPath(for: value)
        default:
            return nil
        }
    }

    static func read(agent kind: String, session: HerdrAgentSession?, cwd: String) -> ContextUse? {
        guard let p = path(agent: kind, session: session, cwd: cwd) else { return nil }
        switch kind {
        case "claude": return cached(p, parse: parseClaude)
        case "pi":     return cached(p, parse: parsePi)
        case "codex":  return cached(p, parse: parseCodex)
        default:       return nil
        }
    }

    /// Rollout filenames embed the session uuid but also a date directory we don't know.
    /// The glob is bounded (94 files here, ~2ms) and the result is memoised anyway.
    private static func codexPath(for uuid: String) -> String? {
        lock.lock()
        if let hit = codexPaths[uuid] {
            lock.unlock()
            return FileManager.default.fileExists(atPath: hit) ? hit : nil
        }
        lock.unlock()

        let root = "\(NSHomeDirectory())/.codex/sessions"
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: root) else { return nil }
        var found: String?
        for case let rel as String in e where rel.hasSuffix("\(uuid).jsonl") {
            found = "\(root)/\(rel)"
            break
        }
        if let found {
            lock.lock(); codexPaths[uuid] = found; lock.unlock()
        }
        return found
    }

    private static func cached(_ path: String,
                               parse: (String, Int) -> ContextUse?) -> ContextUse? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int,
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }

        lock.lock()
        if let hit = cache[path], hit.size == size, hit.stamp == mtime {
            lock.unlock()
            return hit.value
        }
        lock.unlock()

        let value = parse(path, size)

        lock.lock(); cache[path] = (mtime, size, value); lock.unlock()
        return value
    }

    /// Reads the tail and yields decoded JSON objects newest-first.
    private static func tailObjects(_ path: String, _ size: Int,
                                    window: Int = 1_024 * 1024) -> [[String: Any]] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        if size > window { try? fh.seek(toOffset: UInt64(size - window)) }
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var out: [[String: Any]] = []
        for line in text.components(separatedBy: .newlines).reversed() {
            guard line.hasPrefix("{"), let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { continue }
            out.append(obj)
        }
        return out
    }

    // MARK: Per-agent parsers

    private static func parseClaude(_ path: String, _ size: Int) -> ContextUse? {
        for obj in tailObjects(path, size) {
            guard let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let used = (usage["input_tokens"] as? Int ?? 0)
                + (usage["cache_read_input_tokens"] as? Int ?? 0)
                + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            guard used > 0 else { continue }
            let model = message["model"] as? String
            return make(used: used, limit: inferLimit(model: model, used: used), model: model)
        }
        return nil
    }

    private static func parsePi(_ path: String, _ size: Int) -> ContextUse? {
        for obj in tailObjects(path, size) {
            guard obj["type"] as? String == "message",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            // `totalTokens` includes output, which isn't resident context — sum the
            // input side only.
            let used = (usage["input"] as? Int ?? 0) + (usage["cacheRead"] as? Int ?? 0)
            guard used > 0 else { continue }
            let model = message["model"] as? String
            return make(used: used, limit: inferLimit(model: model, used: used), model: model)
        }
        return nil
    }

    private static func parseCodex(_ path: String, _ size: Int) -> ContextUse? {
        for obj in tailObjects(path, size) {
            guard obj["type"] as? String == "event_msg",
                  let p = obj["payload"] as? [String: Any],
                  p["type"] as? String == "token_count",
                  let info = p["info"] as? [String: Any] else { continue }
            // last_token_usage is the live turn's resident context; total_token_usage
            // is a lifetime counter and would read far over 100%.
            guard let last = info["last_token_usage"] as? [String: Any],
                  let used = last["total_tokens"] as? Int, used > 0 else { continue }
            // The only agent that states its own window. Trust it.
            let limit = info["model_context_window"] as? Int ?? inferLimit(model: nil, used: used)
            return make(used: used, limit: limit, model: nil)
        }
        return nil
    }

    private static func make(used: Int, limit: Int, model: String?) -> ContextUse {
        ContextUse(used: used, limit: limit,
                   percent: min(100, Int((Double(used) / Double(limit) * 100).rounded())),
                   model: model)
    }

    /// Only used where the transcript doesn't state a window. Transcripts record
    /// "claude-opus-5" whether or not the session is the 1M variant, so the id alone
    /// can't settle it — escalate through the tiers rather than ever exceeding 100%.
    private static func inferLimit(model: String?, used: Int) -> Int {
        let m = (model ?? "").lowercased()
        if m.contains("[1m]") { return 1_000_000 }

        // Real tiers per family — Claude has no 400k window, so escalating a 255k
        // Opus session to 400k invents a limit that doesn't exist.
        let tiers: [Int]
        if m.contains("gemini") { tiers = [1_000_000] }
        else if m.contains("gpt") { tiers = [400_000] }
        else { tiers = [200_000, 1_000_000] }

        for t in tiers where used <= t - 20_000 { return t }
        return tiers.last ?? 200_000
    }
}
