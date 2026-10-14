import Foundation

struct InstalledAIStreamFrame: Equatable, Sendable {
    var events: [AIStreamEvent] = []
    var sessionID: String?
    var error: String?
    var completed = false
    /// A tool call the CLI is holding open; the runner answers it and the turn carries on.
    var controlRequest: ClaudeControlProtocol.Request?
    /// A message for the server Blitz hosts in-process, answered on the same pipe.
    var hostedMessage: ClaudeHostedServer.Message?
    var unsupportedRequestID: String?
    /// The round cap ended the turn. Only the runner knows the number to say it with.
    var stoppedAtRoundCap = false
    /// Searches this frame started, by tool-use id, for the runner to match their results to.
    var startedSearches: [String: String?] = [:]
}

enum InstalledAIStreamDecoder {
    /// `searches` is nil on a turn offered no web search, else the ones it started so far.
    static func decode(
        _ data: Data, kind: InstalledAIKind, servers: [AIToolServer] = [],
        hosted: [AITool] = [], searches: [String: String?]? = nil
    ) -> InstalledAIStreamFrame {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { return InstalledAIStreamFrame() }
        switch kind {
        case .openCode: return openCode(object, type: type)
        case .claude:
            return claude(object, type: type, servers: servers, hosted: hosted, searches: searches)
        case .cursor: return cursor(object, type: type)
        case .grok: return grok(object, type: type)
        case .codex: return InstalledAIStreamFrame()
        }
    }

    private static func openCode(
        _ object: [String: Any], type: String
    ) -> InstalledAIStreamFrame {
        var frame = InstalledAIStreamFrame(sessionID: object["sessionID"] as? String)
        let part = object["part"] as? [String: Any]
        switch type {
        case "text":
            if let text = part?["text"] as? String, !text.isEmpty { frame.events = [.text(text)] }
        case "step_start":
            frame.events = [.thinking]
        case "step_finish":
            if let tokens = part?["tokens"] as? [String: Any] {
                frame.events.append(
                    .usage(
                        AIUsage(
                            inputTokens: integer(tokens["input"]),
                            outputTokens: integer(tokens["output"]))))
            }
            frame.completed = true
        case "error":
            frame.error = message(in: object) ?? "OpenCode could not finish the response."
        default:
            break
        }
        return frame
    }

    private static func claude(
        _ object: [String: Any], type: String, servers: [AIToolServer], hosted: [AITool] = [],
        searches: [String: String?]? = nil
    ) -> InstalledAIStreamFrame {
        var frame = InstalledAIStreamFrame()
        let armed = !servers.isEmpty || !hosted.isEmpty
        if armed, type == "control_request" {
            frame.controlRequest = ClaudeControlProtocol.request(object)
            if !hosted.isEmpty { frame.hostedMessage = ClaudeControlProtocol.hostedMessage(object) }
            frame.unsupportedRequestID = ClaudeControlProtocol.unsupportedRequestID(object)
            return frame
        }
        // Text is read from the deltas alone, so these frames only ever add tool and search rows.
        if armed || searches != nil, type == "assistant" || type == "user" {
            var content =
                (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            if let searches {
                frame.startedSearches = startedSearches(in: content)
                let known = searches.merging(frame.startedSearches) { $1 }
                frame.events = searchEvents(in: content, searches: known)
                content.removeAll { known[blockID($0) ?? ""] != nil }
            }
            if armed {
                frame.events += toolEvents(in: content, servers: servers, hosted: hosted)
            }
            return frame
        }
        // Summaries arrive as several thinking blocks; a break keeps them from running together.
        if type == "stream_event", let event = object["event"] as? [String: Any],
            event["type"] as? String == "content_block_start",
            (event["content_block"] as? [String: Any])?["type"] as? String == "thinking"
        {
            frame.events = [.thinking, .reasoning("\n\n")]
            return frame
        }
        if type == "stream_event", let event = object["event"] as? [String: Any],
            let delta = event["delta"] as? [String: Any]
        {
            switch delta["type"] as? String {
            case "text_delta":
                if let text = delta["text"] as? String, !text.isEmpty {
                    frame.events = [.text(text)]
                }
            case "thinking_delta":
                let thinking = delta["thinking"] as? String ?? ""
                frame.events = thinking.isEmpty ? [.thinking] : [.thinking, .reasoning(thinking)]
            default:
                break
            }
            return frame
        }
        guard type == "result" else { return frame }
        // The cap's own subtype comes with an empty `result`, so it is read before the error is.
        if object["subtype"] as? String == "error_max_turns" {
            frame.stoppedAtRoundCap = true
            return frame
        }
        if object["is_error"] as? Bool == true {
            frame.error = object["result"] as? String ?? "Claude could not finish the response."
            return frame
        }
        if let usage = object["usage"] as? [String: Any] {
            frame.events.append(.usage(claudeUsage(usage, result: object)))
        }
        frame.completed = true
        return frame
    }

    private static func startedSearches(in content: [[String: Any]]) -> [String: String?] {
        var started: [String: String?] = [:]
        for block in content
        where block["type"] as? String == "tool_use"
            && block["name"] as? String == ClaudeMCPLaunch.searchTool
        {
            guard let id = block["id"] as? String else { continue }
            started[id] = (block["input"] as? [String: Any])?["query"] as? String
        }
        return started
    }

    /// The built-in search as the search row the API routes draw, never a tool row or a question.
    private static func searchEvents(
        in content: [[String: Any]], searches: [String: String?]
    ) -> [AIStreamEvent] {
        content.compactMap { block in
            guard let id = blockID(block), let query = searches[id] else { return nil }
            switch block["type"] as? String {
            case "tool_use": return .searching(query)
            case "tool_result": return .searched(query)
            default: return nil
            }
        }
    }

    private static func blockID(_ block: [String: Any]) -> String? {
        (block["type"] as? String == "tool_result" ? block["tool_use_id"] : block["id"]) as? String
    }

    /// `tool_use` and `tool_result` blocks, as the two events a transcript row is built from.
    private static func toolEvents(
        in content: [[String: Any]], servers: [AIToolServer], hosted: [AITool]
    ) -> [AIStreamEvent] {
        content.compactMap { block in
            switch block["type"] as? String {
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String,
                    let call = ClaudeMCPLaunch.route(name)
                else { return nil }
                if call.handle == ClaudeHostedServer.handle {
                    let tool = hosted.first { $0.name == call.tool }
                    guard tool?.showsCallRow ?? true else { return nil }
                    return .toolCall(
                        id: id, origin: tool?.origin ?? "Blitz",
                        title: AIToolServerRow.label(tool?.title ?? call.tool))
                }
                return .toolCall(
                    id: id, origin: AIToolServerRow.title(of: call.handle, in: servers),
                    title: AIToolServerRow.label(call.tool))
            case "tool_result":
                guard let id = block["tool_use_id"] as? String else { return nil }
                return .toolResult(id: id, isError: block["is_error"] as? Bool == true)
            default:
                return nil
            }
        }
    }

    /// Cached prompt tokens sit outside `input_tokens`, and only `modelUsage` names the window.
    private static func claudeUsage(_ usage: [String: Any], result: [String: Any]) -> AIUsage {
        let cached = [usage["cache_read_input_tokens"], usage["cache_creation_input_tokens"]]
            .compactMap(integer)
        let details = usage["output_tokens_details"] as? [String: Any]
        // A side model (Haiku) may share the turn; the conversation's read the largest prompt.
        let model = (result["modelUsage"] as? [String: Any])?.values
            .compactMap { $0 as? [String: Any] }
            .max { rank($0) < rank($1) }
        return AIUsage(
            inputTokens: integer(usage["input_tokens"]),
            outputTokens: integer(usage["output_tokens"]),
            cachedInputTokens: cached.isEmpty ? nil : cached.reduce(0, +),
            reasoningTokens: integer(details?["thinking_tokens"]),
            contextWindow: integer(model?["contextWindow"]),
            costUSD: (result["total_cost_usd"] as? NSNumber)?.doubleValue)
    }

    private static func rank(_ model: [String: Any]) -> (prompt: Int, window: Int) {
        let prompt = ["inputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"]
            .compactMap { integer(model[$0]) }.reduce(0, +)
        return (prompt, integer(model["contextWindow"]) ?? 0)
    }

    /// Grok's error result omits `result` and names the cause in `errors`.
    private static func grok(
        _ object: [String: Any], type: String
    ) -> InstalledAIStreamFrame {
        // Grok shares the frame shape but never the tools: `--deny *` refuses every call.
        var frame = claude(object, type: type, servers: [])
        if let sessionID = object["session_id"] as? String, !sessionID.isEmpty {
            frame.sessionID = sessionID
        }
        if type == "result", object["is_error"] as? Bool == true {
            frame.error = grokFailure(object)
        }
        return frame
    }

    private static func grokFailure(_ object: [String: Any]) -> String {
        if let errors = object["errors"] as? [Any] {
            let lines = errors.compactMap { item -> String? in
                guard let text = item as? String else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if !lines.isEmpty { return lines.joined(separator: "\n") }
        }
        if let result = object["result"] as? String {
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "Grok could not finish the response."
    }

    private static func cursor(
        _ object: [String: Any], type: String
    ) -> InstalledAIStreamFrame {
        var frame = InstalledAIStreamFrame()
        if let sessionID = object["session_id"] as? String, !sessionID.isEmpty {
            frame.sessionID = sessionID
        }
        switch type {
        case "assistant":
            // Live deltas carry timestamp_ms; buffered flushes omit it or carry model_call_id.
            guard object["timestamp_ms"] != nil, object["model_call_id"] == nil else {
                return frame
            }
            if let text = assistantText(in: object), !text.isEmpty {
                frame.events = [.text(text)]
            }
        case "result":
            if object["is_error"] as? Bool == true
                || (object["subtype"] as? String) == "error"
            {
                frame.error =
                    (object["result"] as? String)
                    ?? message(in: object)
                    ?? "Cursor could not finish the response."
                return frame
            }
            frame.completed = true
        default:
            break
        }
        return frame
    }

    private static func assistantText(in object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]]
        else { return nil }
        let parts = content.compactMap { part -> String? in
            guard (part["type"] as? String) == "text" || part["type"] == nil else { return nil }
            return part["text"] as? String
        }
        let text = parts.joined()
        return text.isEmpty ? nil : text
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func message(in object: [String: Any]) -> String? {
        if let message = object["message"] as? String { return message }
        if let error = object["error"] as? [String: Any] {
            return error["message"] as? String
        }
        return nil
    }
}
