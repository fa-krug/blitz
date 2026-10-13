import Foundation

/// A server a CLI route's own client runs, as `AITool` is a tool for the loop Blitz runs.
struct AIToolServer: Equatable, Sendable {
    enum Transport: Equatable, Sendable {
        /// A local process. The values travel in the child's environment, never on its argv.
        case command(path: String, arguments: [String], environment: [String: String])
        /// A remote endpoint. An empty value sends no header, as Blitz's own transport does.
        case url(String, headerName: String, headerValue: String)
    }

    /// The handle a tool name routes back to, and the name the CLI knows the server by.
    let handle: String
    let title: String
    let transport: Transport
}

/// One call a route's own client is asking permission for, named the way Blitz addresses it.
struct AIToolServerCall: Equatable, Sendable {
    let handle: String
    let tool: String
}

/// Blitz's own tools, served from inside Blitz to a client that can host a server in-process.
struct AIHostedTools: Sendable {
    let tools: @Sendable () async -> [AITool]
    let run: @Sendable (AIToolCall) async -> AIToolResult

    static let none = AIHostedTools(
        tools: { [] }, run: { .failure($0.id, "Blitz offers no tool named \($0.name).") })
}

/// How a route whose own client runs the tool loop reaches Blitz's servers and its reader.
struct AIToolServerSession: Sendable {
    let servers: @Sendable () async -> [AIToolServer]
    /// Main-actor so a caller there joins the queue before suspending; a hop would race the order.
    let consent: @MainActor @Sendable (AIToolServerCall) async -> Bool
    /// The BYOK loop's bound, `nil` for none, applied to the CLI's own loop so a reply stops alike.
    let rounds: Int?
    /// Only Claude can host these; Codex is handed servers alone.
    let hosted: AIHostedTools

    init(
        rounds: Int?,
        hosted: AIHostedTools = .none,
        servers: @escaping @Sendable () async -> [AIToolServer],
        consent: @escaping @Sendable (AIToolServerCall) async -> Bool
    ) {
        self.rounds = rounds
        self.hosted = hosted
        self.servers = servers
        let queue = AIConsentQueue()
        self.consent = { @MainActor call in
            await queue.ask(cancelled: false) { await consent(call) }
        }
    }
}

/// One question at a time: a second would find the dialog busy, and must see the first's grant.
@MainActor
final class AIConsentQueue {
    private var isAsking = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// `cancelled` answers for a question whose task ended while it waited its turn.
    func ask<Answer: Sendable>(
        cancelled: Answer, _ question: @Sendable () async -> Answer
    ) async -> Answer {
        if isAsking {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            isAsking = true
        }
        defer {
            if waiting.isEmpty { isAsking = false } else { waiting.removeFirst().resume() }
        }
        guard !Task.isCancelled else { return cancelled }
        return await question()
    }
}

/// What a transcript row may say about a call the CLI reported; the names come from someone else.
enum AIToolServerRow {
    /// A row is one line: a server that answers with a kilobyte of name must not become one.
    static let maxNameLength = 64

    static func label(_ name: String) -> String {
        name.count <= maxNameLength ? name : String(name.prefix(maxNameLength)) + "\u{2026}"
    }

    static func title(of server: String, in servers: [AIToolServer]) -> String {
        label(servers.first { $0.handle == server }?.title ?? server)
    }
}
