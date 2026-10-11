//
//  ShuttleGrokResume.swift
//  ShuttleTerm
//
//  Reopen a coding-agent TUI on the session that was running when the window
//  last persisted. Grok, Claude Code, Codex, and OpenCode.
//

import Darwin
import Foundation

enum ShuttleAgentKind: String {
    case grok
    case claude
    case codex
    case opencode

    var binary: String { rawValue }

    static func fromBinary(_ token: String) -> ShuttleAgentKind? {
        switch (token as NSString).lastPathComponent.lowercased() {
        case "grok": return .grok
        case "claude", "claude-code": return .claude
        case "codex", "codex-cli": return .codex
        case "opencode": return .opencode
        default: return nil
        }
    }
}

enum ShuttleGrokResume {
    struct ActiveSession {
        var kind: ShuttleAgentKind
        var id: String?
        var cwd: String?
    }

    static func isAgentInvocation(_ command: String) -> Bool {
        agentSegment(command) != nil
    }

    static func isGrokInvocation(_ command: String) -> Bool {
        isAgentInvocation(command)
    }

    static func isGrokCommand(_ command: String) -> Bool {
        kind(of: command) == .grok
    }

    static func grokProcessRunning(shellPid: pid_t) -> Bool {
        guard shellPid > 0 else { return false }
        let parents = processParents()
        if liveGrokSession(shellPid: shellPid, parents: parents) != nil {
            return true
        }
        return descendantKind(shellPid: shellPid, parents: parents) == .grok
    }

    /// Agent still in this PTY's process tree. Does not infer from the host command.
    static func liveSession(shellPid: pid_t) -> ActiveSession? {
        guard shellPid > 0 else { return nil }
        let parents = processParents()
        if let live = liveGrokSession(shellPid: shellPid, parents: parents) {
            return live
        }
        guard let kind = descendantKind(shellPid: shellPid, parents: parents) else {
            return nil
        }
        return ActiveSession(kind: kind, id: nil, cwd: nil)
    }

    static func kind(of command: String) -> ShuttleAgentKind? {
        agentSegment(command)?.kind
    }

    static func resolve(
        shellPid: pid_t,
        directory: String?,
        command: String,
        after: String
    ) -> ActiveSession? {
        let cwd = path(fromOSC: directory) ?? cwdFromCommand(command) ?? cwdFromCommand(after)
        var live: ActiveSession?
        var fromTree: ShuttleAgentKind?
        if shellPid > 0 {
            let parents = processParents()
            live = liveGrokSession(shellPid: shellPid, parents: parents)
            if live == nil {
                fromTree = descendantKind(shellPid: shellPid, parents: parents)
            }
        }
        if let live { return live }
        let kind = fromTree
            ?? kind(of: command)
            ?? kind(of: after)
        guard let kind else { return nil }
        let id = cwd.flatMap { latestSessionId(kind: kind, cwd: $0) }
        return ActiveSession(kind: kind, id: id, cwd: cwd)
    }

    static func restoreQueue(
        command: String,
        after: String,
        remote: Bool,
        sessionId: String?,
        cwd: String?,
        kind: ShuttleAgentKind?
    ) -> [String] {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let afterCmd = after.trimmingCharacters(in: .whitespacesAndNewlines)
        let detected = kind
            ?? self.kind(of: cmd)
            ?? self.kind(of: afterCmd)
            ?? (sessionId != nil ? .grok : nil)

        if remote {
            guard let detected, isAgentInvocation(afterCmd) else { return [] }
            return [bindToExactCwd(afterCmd, kind: detected, sessionId: nil, cwd: cwdFromCommand(afterCmd) ?? cwd)]
        }

        let guess = cwd ?? cwdFromCommand(cmd) ?? cwdFromCommand(afterCmd)
        var id = sessionId
        if let detected {
            if detected == .grok {
                id = grokResumeId(preferred: sessionId, cwd: guess)
            } else if id == nil, let guess {
                id = latestSessionId(kind: detected, cwd: guess)
            }
        }

        var launch = cmd
        if let detected, isAgentInvocation(cmd) {
            launch = bindToExactCwd(cmd, kind: detected, sessionId: id, cwd: guess)
        } else if cmd.isEmpty, let detected {
            launch = agentLaunch(kind: detected, cwd: cwd, sessionId: id)
        }

        var follow = afterCmd
        if let detected, isAgentInvocation(afterCmd) {
            follow = bindToExactCwd(afterCmd, kind: detected, sessionId: id, cwd: guess)
        }

        var queue: [String] = []
        if !launch.isEmpty { queue.append(launch) }
        if !follow.isEmpty { queue.append(follow) }
        if queue == [cmd, afterCmd].filter({ !$0.isEmpty }) {
            return []
        }
        return queue
    }

    static func rewrite(
        _ command: String,
        kind: ShuttleAgentKind,
        sessionId: String?,
        allowContinue: Bool
    ) -> String {
        guard let span = agentSegment(command) else { return command }
        let args = resumeArgs(kind: kind, original: span.args, sessionId: sessionId, allowContinue: allowContinue)
        let body = ([span.binary] + args).joined(separator: " ")
        return span.prefix + body + span.suffix
    }

    /// Resume only a session whose recorded cwd is this directory. Parent-directory
    /// sessions and a bare `grok -c` (which walks up the tree) are not used.
    static func bindGrokToExactCwd(_ command: String, cwd: String?, preferredId: String? = nil) -> String {
        guard let span = agentSegment(command), span.kind == .grok else { return command }
        let id = grokResumeId(
            preferred: preferredId ?? resumeId(in: span.args),
            cwd: cwd ?? cwdFromCommand(command)
        )
        return rewrite(command, kind: .grok, sessionId: id, allowContinue: false)
    }

    private static func bindToExactCwd(
        _ command: String,
        kind: ShuttleAgentKind,
        sessionId: String?,
        cwd: String?
    ) -> String {
        if kind == .grok {
            return bindGrokToExactCwd(command, cwd: cwd, preferredId: sessionId)
        }
        return rewrite(command, kind: kind, sessionId: sessionId, allowContinue: true)
    }

    private static func agentLaunch(kind: ShuttleAgentKind, cwd: String?, sessionId: String?) -> String {
        let id: String?
        if kind == .grok {
            id = grokResumeId(preferred: sessionId, cwd: cwd)
        } else {
            id = sessionId
        }
        let args = resumeArgs(
            kind: kind,
            original: [],
            sessionId: id,
            allowContinue: kind != .grok
        )
        let cmd = ([kind.binary] + args).joined(separator: " ")
        guard let cwd, !cwd.isEmpty else { return cmd }
        return "cd \(shellQuote(cwd)) && \(cmd)"
    }

    private static func resumeArgs(
        kind: ShuttleAgentKind,
        original: [String],
        sessionId: String?,
        allowContinue: Bool
    ) -> [String] {
        switch kind {
        case .grok, .claude:
            return withFlagResume(
                original,
                longFlag: "--resume",
                shortFlag: "-r",
                continueFlags: ["-c", "--continue"],
                sessionId: sessionId,
                allowContinue: allowContinue
            )
        case .opencode:
            return withFlagResume(
                original,
                longFlag: "--session",
                shortFlag: "-s",
                continueFlags: ["-c", "--continue"],
                sessionId: sessionId,
                allowContinue: allowContinue
            )
        case .codex:
            return withCodexResume(original, sessionId: sessionId, allowContinue: allowContinue)
        }
    }

    private static func withFlagResume(
        _ args: [String],
        longFlag: String,
        shortFlag: String,
        continueFlags: Set<String>,
        sessionId: String?,
        allowContinue: Bool
    ) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if continueFlags.contains(a) {
                i += 1
                continue
            }
            if a == longFlag || a == shortFlag {
                i += 1
                if i < args.count, !args[i].hasPrefix("-") {
                    i += 1
                }
                continue
            }
            if a.hasPrefix(longFlag + "=") || a.hasPrefix(shortFlag + "=") {
                i += 1
                continue
            }
            out.append(a)
            i += 1
        }
        if let sessionId, !sessionId.isEmpty {
            out.append(contentsOf: [longFlag, sessionId])
        } else if allowContinue {
            out.append("-c")
        }
        return out
    }

    private static func withCodexResume(
        _ args: [String],
        sessionId: String?,
        allowContinue: Bool
    ) -> [String] {
        var i = 0
        if i < args.count, args[i] == "resume" || args[i] == "continue" {
            i += 1
        }
        var flags: [String] = []
        while i < args.count {
            let a = args[i]
            if a == "--last" || a == "--all" {
                i += 1
                continue
            }
            if a.hasPrefix("-") {
                flags.append(a)
                i += 1
                if i < args.count, !args[i].hasPrefix("-"), !a.contains("="), a != "--last" {
                    flags.append(args[i])
                    i += 1
                }
                continue
            }
            i += 1
        }
        var out = ["resume"] + flags
        if let sessionId, !sessionId.isEmpty {
            out.append(sessionId)
        } else if allowContinue {
            out.append("--last")
        }
        return out
    }

    private struct AgentSpan {
        var prefix: String
        var binary: String
        var args: [String]
        var kind: ShuttleAgentKind
        var suffix: String
    }

    private static func agentSegment(_ command: String) -> AgentSpan? {
        let pieces = splitKeepSep(command)
        for index in pieces.indices.reversed() {
            let body = pieces[index].body
            let tokens = tokenize(body)
            guard let binary = tokens.first, let kind = ShuttleAgentKind.fromBinary(binary) else {
                continue
            }
            var prefix = ""
            if index > 0 {
                prefix = pieces[0..<index].map { $0.sep + $0.body }.joined()
                prefix += pieces[index].sep
                let trimmed = body.prefix { $0.isWhitespace }
                prefix += String(trimmed)
            } else {
                let trimmed = body.prefix { $0.isWhitespace }
                prefix = pieces[index].sep + String(trimmed)
            }
            return AgentSpan(
                prefix: prefix,
                binary: binary,
                args: Array(tokens.dropFirst()),
                kind: kind,
                suffix: ""
            )
        }
        return nil
    }

    private static func splitKeepSep(_ command: String) -> [(sep: String, body: String)] {
        var result: [(sep: String, body: String)] = []
        var current = ""
        var pendingSep = ""
        var i = command.startIndex
        while i < command.endIndex {
            if command[i...].hasPrefix("&&") {
                result.append((pendingSep, current))
                pendingSep = "&&"
                current = ""
                i = command.index(i, offsetBy: 2)
                continue
            }
            if command[i] == ";" {
                result.append((pendingSep, current))
                pendingSep = ";"
                current = ""
                i = command.index(after: i)
                continue
            }
            current.append(command[i])
            i = command.index(after: i)
        }
        result.append((pendingSep, current))
        return result
    }

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for ch in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let q = quote {
                if ch == q {
                    quote = nil
                } else {
                    current.append(ch)
                }
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                continue
            }
            if ch.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func shellQuote(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-+/@~"))
        if path.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func path(fromOSC directory: String?) -> String? {
        guard let directory, let url = URL(string: directory) else { return nil }
        let path = url.path
        return path.isEmpty ? nil : path
    }

    static func cwdFromCommand(_ command: String) -> String? {
        let pieces = splitKeepSep(command)
        for piece in pieces {
            let tokens = tokenize(piece.body)
            guard tokens.first == "cd", tokens.count >= 2 else { continue }
            var path = tokens[1]
            if path == "-" { continue }
            if path.hasPrefix("~") {
                path = (path as NSString).expandingTildeInPath
            } else if !path.hasPrefix("/") {
                path = (NSHomeDirectory() as NSString).appendingPathComponent(path)
            }
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return nil
    }

    private struct ActiveFile: Codable {
        var session_id: String
        var pid: Int32
        var cwd: String?
    }

    private static func liveGrokSession(shellPid: pid_t, parents: [pid_t: pid_t]) -> ActiveSession? {
        guard shellPid > 0 else { return nil }
        let actives = loadActiveGrokSessions()
        guard !actives.isEmpty else { return nil }
        for item in actives {
            if isDescendant(pid: item.pid, of: shellPid, parents: parents) {
                return ActiveSession(kind: .grok, id: item.session_id, cwd: item.cwd)
            }
        }
        return nil
    }

    private static func descendantKind(shellPid: pid_t, parents: [pid_t: pid_t]) -> ShuttleAgentKind? {
        guard shellPid > 0 else { return nil }
        var found: ShuttleAgentKind?
        for pid in parents.keys where isDescendant(pid: pid, of: shellPid, parents: parents) {
            let command = processCommandLine(pid) ?? processComm(pid)
            if let kind = kindFromProcessCommand(command) {
                if kind == .grok { return kind }
                found = kind
            }
        }
        return found
    }

    private static func kindFromProcessCommand(_ command: String) -> ShuttleAgentKind? {
        for token in tokenize(command) where !token.hasPrefix("-") {
            if let kind = ShuttleAgentKind.fromBinary(token) {
                return kind
            }
        }
        return nil
    }

    private static func loadActiveGrokSessions() -> [ActiveFile] {
        let url = grokHome().appendingPathComponent("active_sessions.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ActiveFile].self, from: data)) ?? []
    }

    private static func grokHome() -> URL {
        envHome("GROK_HOME") ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok")
    }

    private static func claudeHome() -> URL {
        envHome("CLAUDE_CONFIG_DIR") ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    private static func codexHome() -> URL {
        envHome("CODEX_HOME") ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    }

    private static func opencodeHome() -> URL {
        if let env = envHome("OPENCODE_DATA") {
            return env
        }
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("opencode")
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local")
            .appendingPathComponent("share")
            .appendingPathComponent("opencode")
    }

    private static func envHome(_ key: String) -> URL? {
        guard let env = ProcessInfo.processInfo.environment[key], !env.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: env)
    }

    private static func latestSessionId(kind: ShuttleAgentKind, cwd: String) -> String? {
        let target = normalizedPath(cwd)
        switch kind {
        case .grok:
            return latestGrokId(cwd: target)
        case .claude:
            return latestClaudeId(cwd: target)
        case .codex:
            return latestCodexId(cwd: target)
        case .opencode:
            return latestOpencodeId(cwd: target)
        }
    }

    private static func grokResumeId(preferred: String?, cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let target = normalizedPath(cwd)
        if let preferred, !preferred.isEmpty, grokId(preferred, belongsTo: target) {
            return preferred
        }
        return latestGrokId(cwd: target)
    }

    private static func grokId(_ id: String, belongsTo cwd: String) -> Bool {
        guard let group = grokGroup(for: cwd) else { return false }
        var isDir: ObjCBool = false
        let folder = group.appendingPathComponent(id)
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func grokGroup(for cwd: String) -> URL? {
        let sessions = grokHome().appendingPathComponent("sessions")
        guard let groups = try? FileManager.default.contentsOfDirectory(
            at: sessions,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for group in groups {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: group.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            guard let path = groupCwd(group), samePath(path, cwd) else { continue }
            return group
        }
        return nil
    }

    private static func latestGrokId(cwd: String) -> String? {
        guard let group = grokGroup(for: cwd) else { return nil }
        return latestGrokId(in: group, cwd: cwd)
    }

    private static func groupCwd(_ group: URL) -> String? {
        let marker = group.appendingPathComponent(".cwd")
        if let data = try? String(contentsOf: marker, encoding: .utf8) {
            let path = data.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                return normalizedPath(path)
            }
        }
        guard let decoded = group.lastPathComponent.removingPercentEncoding else {
            return nil
        }
        return normalizedPath(decoded)
    }

    private static func samePath(_ a: String, _ b: String) -> Bool {
        normalizedPath(a) == normalizedPath(b)
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func resumeId(in args: [String]) -> String? {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--resume" || a == "-r" {
                let next = i + 1
                if next < args.count, !args[next].hasPrefix("-") {
                    return args[next]
                }
                return nil
            }
            if a.hasPrefix("--resume=") {
                let value = String(a.dropFirst("--resume=".count))
                return value.isEmpty ? nil : value
            }
            i += 1
        }
        return nil
    }

    private struct GrokSummary: Codable {
        var info: Info?
        var updated_at: String?
        var last_active_at: String?
        struct Info: Codable {
            var id: String?
            var cwd: String?
        }
    }

    private static func latestGrokId(in group: URL, cwd: String) -> String? {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: group,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var best: (id: String, stamp: String)?
        for child in children {
            let summaryURL = child.appendingPathComponent("summary.json")
            guard let data = try? Data(contentsOf: summaryURL),
                  let summary = try? JSONDecoder().decode(GrokSummary.self, from: data) else {
                continue
            }
            if let sessionCwd = summary.info?.cwd, !sessionCwd.isEmpty, !samePath(sessionCwd, cwd) {
                continue
            }
            let id = summary.info?.id ?? child.lastPathComponent
            guard isUUID(id) else { continue }
            let stamp = summary.last_active_at ?? summary.updated_at ?? ""
            if best == nil || stamp > best!.stamp {
                best = (id, stamp)
            }
        }
        return best?.id
    }

    private static func latestClaudeId(cwd: String) -> String? {
        let projects = claudeHome().appendingPathComponent("projects")
        let slug = claudeSlug(cwd)
        let dir = projects.appendingPathComponent(slug)
        return newestUUIDJsonl(in: dir)
    }

    private static func claudeSlug(_ cwd: String) -> String {
        String(cwd.map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : "-"
        })
    }

    private static func newestUUIDJsonl(in directory: URL) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var best: (id: String, date: Date)?
        for file in files where file.pathExtension == "jsonl" {
            let id = file.deletingPathExtension().lastPathComponent
            guard isUUID(id) else { continue }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best == nil || date > best!.date {
                best = (id, date)
            }
        }
        return best?.id
    }

    private static let codexRollout = try? NSRegularExpression(
        pattern: #"^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-([0-9a-fA-F-]{36})\.jsonl$"#
    )

    private static func latestCodexId(cwd: String) -> String? {
        let root = codexHome().appendingPathComponent("sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var best: (id: String, date: Date)?
        for case let file as URL in enumerator {
            guard let regex = codexRollout else { continue }
            let name = file.lastPathComponent
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard let match = regex.firstMatch(in: name, options: [], range: range),
                  let idRange = Range(match.range(at: 1), in: name) else {
                continue
            }
            let id = String(name[idRange])
            if let metaCwd = codexCwd(in: file), metaCwd != cwd {
                continue
            }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best == nil || date > best!.date {
                best = (id, date)
            }
        }
        return best?.id
    }

    private static func codexCwd(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 16_384)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").prefix(12) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            if obj["type"] as? String == "session_meta",
               let payload = obj["payload"] as? [String: Any],
               let cwd = payload["cwd"] as? String {
                return URL(fileURLWithPath: cwd).standardizedFileURL.path
            }
        }
        return nil
    }

    private static func latestOpencodeId(cwd: String) -> String? {
        if let id = latestOpencodeJsonId(cwd: cwd) {
            return id
        }
        return latestOpencodeSqliteId(cwd: cwd)
    }

    private static func latestOpencodeJsonId(cwd: String) -> String? {
        let roots = [
            opencodeHome().appendingPathComponent("storage").appendingPathComponent("session"),
            opencodeHome().appendingPathComponent("project")
        ]
        var best: (id: String, stamp: String)?
        let fm = FileManager.default
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let file as URL in enumerator where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                let directory = (obj["directory"] as? String)
                    ?? (obj["cwd"] as? String)
                    ?? (obj["dir"] as? String)
                guard let directory else { continue }
                let path = URL(fileURLWithPath: directory).standardizedFileURL.path
                guard path == cwd else { continue }
                if let parent = obj["parentID"] as? String, !parent.isEmpty { continue }
                if let parent = obj["parentId"] as? String, !parent.isEmpty { continue }
                if let parent = obj["parent_id"] as? String, !parent.isEmpty { continue }
                let id = (obj["id"] as? String)
                    ?? (obj["_id"] as? String)
                    ?? file.deletingPathExtension().lastPathComponent
                guard !id.isEmpty else { continue }
                let stamp = (obj["timeUpdated"] as? NSNumber)?.stringValue
                    ?? (obj["time_updated"] as? NSNumber)?.stringValue
                    ?? (obj["updatedAt"] as? String)
                    ?? (obj["updated_at"] as? String)
                    ?? ""
                if best == nil || stamp > best!.stamp {
                    best = (id, stamp)
                }
            }
        }
        return best?.id
    }

    private static func latestOpencodeSqliteId(cwd: String) -> String? {
        let db = opencodeHome().appendingPathComponent("opencode.db")
        guard FileManager.default.fileExists(atPath: db.path) else { return nil }
        guard let data = runCapturingStdout(
            path: "/usr/bin/sqlite3",
            arguments: [
                db.path,
                "-readonly",
                "-noheader",
                "-batch",
                "SELECT id FROM session WHERE (parent_id IS NULL OR parent_id = '') AND directory = '\(sqliteEscape(cwd))' ORDER BY time_updated DESC LIMIT 1;"
            ]
        ) else {
            return nil
        }
        let id = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (id?.isEmpty == false) ? id : nil
    }

    /// Drain stdout before waitUntilExit. Waiting first deadlocks once the pipe fills (64KB).
    private static func runCapturingStdout(path: String, arguments: [String]) -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return data
    }

    private static func sqliteEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static func isUUID(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count == 5, value.count == 36 else { return false }
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return value.unicodeScalars.allSatisfy { $0 == "-" || hex.contains($0) }
    }

    private static let parentsLock = NSLock()
    private static var parentsCache: (at: UInt64, map: [pid_t: pid_t])?

    /// pid → ppid via libproc. Cached ~1s so persisting several windows is one scan.
    /// Do not spawn `ps` into a Pipe on the main thread: waitUntilExit before draining
    /// stdout deadlocks once the 64KB pipe fills (that froze launch after restore).
    private static func processParents() -> [pid_t: pid_t] {
        let now = DispatchTime.now().uptimeNanoseconds
        parentsLock.lock()
        defer { parentsLock.unlock() }
        if let cache = parentsCache, now &- cache.at < 1_000_000_000 {
            return cache.map
        }
        let map = scanProcessParents()
        parentsCache = (now, map)
        return map
    }

    private static func scanProcessParents() -> [pid_t: pid_t] {
        var needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [:] }
        needed += Int32(16 * MemoryLayout<pid_t>.stride)
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride)
        let filled = proc_listpids(
            UInt32(PROC_ALL_PIDS),
            0,
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.stride)
        )
        guard filled > 0 else { return [:] }
        let n = Int(filled) / MemoryLayout<pid_t>.stride
        var map: [pid_t: pid_t] = [:]
        map.reserveCapacity(n)
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        for pid in pids.prefix(n) where pid > 0 {
            var info = proc_bsdinfo()
            let got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize)
            guard got == infoSize else { continue }
            map[pid] = pid_t(info.pbi_ppid)
        }
        return map
    }

    private static func processComm(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 32)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return "" }
        return String(cString: buf)
    }

    private static func processCommandLine(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }
        var i = 4
        while i < size && buffer[i] != 0 { i += 1 }
        while i < size && buffer[i] == 0 { i += 1 }
        var args: [String] = []
        let limit = min(Int(argc), 64)
        args.reserveCapacity(limit)
        for _ in 0..<limit {
            guard i < size else { break }
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            if start < i, let s = String(bytes: buffer[start..<i], encoding: .utf8), !s.isEmpty {
                args.append(s)
            }
            i += 1
        }
        return args.isEmpty ? nil : args.joined(separator: " ")
    }

    private static func isDescendant(pid: pid_t, of ancestor: pid_t, parents: [pid_t: pid_t]) -> Bool {
        if pid == ancestor { return true }
        var current = pid
        var seen = Set<pid_t>()
        for _ in 0..<32 {
            if current == ancestor { return true }
            if current <= 1 || seen.contains(current) { return false }
            seen.insert(current)
            guard let parent = parents[current] else { return false }
            current = parent
        }
        return false
    }
}
