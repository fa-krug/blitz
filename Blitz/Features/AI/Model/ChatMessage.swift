import Foundation

struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Equatable, Sendable {
        case user
        case assistant
    }

    enum State: String, Equatable, Sendable {
        case streaming
        case complete
        case failed
    }

    let id: UUID
    let role: Role
    var text: String
    var state: State
    let sentAt: Date
    let images: [AIImage]
    /// Sent PDFs; a text file is not one, its contents reached the model as text.
    let documents: [AIDocument]
    /// Web searches the reply made, in order; each sits in the text where it happened.
    var searches: [ChatSearch]
    /// Tools the reply called, pinned the same way; the calls themselves never enter the context.
    var toolUses: [ChatToolUse]
    /// Questions the reply asked the reader, each pinned where it paused the reply to ask.
    var questions: [ChatQuestion]
    /// Plans the reply wrote; the chat's live one is the last any reply wrote.
    var plans: [ChatWrittenPlan]
    /// What the model shared of its thinking, a block per stretch of it, each where it happened.
    var reasoning: [ChatReasoning]
    /// What the route reported for this reply; the context card reads the latest one.
    var usage: AIUsage?
    /// The server a question was addressed to with `@server`; the text is stored without it.
    let toolScope: String?

    init(
        id: UUID = UUID(), role: Role, text: String, state: State = .complete,
        sentAt: Date = Date(), images: [AIImage] = [], documents: [AIDocument] = [],
        searches: [ChatSearch] = [],
        toolUses: [ChatToolUse] = [], questions: [ChatQuestion] = [],
        plans: [ChatWrittenPlan] = [], reasoning: [ChatReasoning] = [], usage: AIUsage? = nil,
        toolScope: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.state = state
        self.sentAt = sentAt
        self.images = images
        self.documents = documents
        self.searches = searches
        self.toolUses = toolUses
        self.questions = questions
        self.plans = plans
        self.reasoning = reasoning
        self.usage = usage
        self.toolScope = toolScope
    }

    /// Text still arrives only into the last of a streaming reply's `count` segments.
    func isArriving(segmentAt offset: Int, of count: Int) -> Bool {
        state == .streaming && offset == count - 1
    }

    /// The next interruption's place in the reply: with no text between them, offsets tie.
    var nextSequence: Int { searches.count + toolUses.count + questions.count + plans.count }

    var pendingQuestion: ChatQuestion? { questions.last(where: \.isPending) }

    /// What later turns read: the text, with each answered question and each plan where it was.
    var contextText: String {
        let records =
            (questions.filter { !$0.isPending }.map { question in
                (
                    offset: question.textOffset, sequence: question.sequence,
                    text: AskUserToolCatalog.record(
                        question.answer ?? AskUserToolCatalog.Answer.none, to: question.question)
                )
            }
            + plans.map { written in
                (
                    offset: written.textOffset, sequence: written.sequence,
                    text: PlanToolCatalog.record(written.plan)
                )
            })
            .sorted { ($0.offset, $0.sequence) < ($1.offset, $1.sequence) }
        guard !records.isEmpty else { return text }
        var parts: [String] = []
        var rest = Substring(text)
        var consumed = 0
        for record in records {
            let take = max(0, min(record.offset - consumed, rest.count))
            parts.append(String(rest.prefix(take)))
            parts.append(record.text)
            rest = rest.dropFirst(take)
            consumed += take
        }
        parts.append(String(rest))
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Every block joined, for find and for a transcript copied out whole.
    var reasoningText: String {
        reasoning.map(\.text).joined(separator: "\n\n")
    }

    /// The reply split around what it did: thinking, search or tool, text… each where it happened.
    var segments: [ChatSegment] {
        // At one offset, thinking came first: a model thinks, then searches or calls.
        let interruptions =
            (reasoning.map {
                (offset: $0.textOffset, sequence: -1, segment: ChatSegment.reasoning($0))
            }
            + searches.map {
                (offset: $0.textOffset, sequence: $0.sequence, segment: ChatSegment.search($0))
            }
            + toolUses.map {
                (offset: $0.textOffset, sequence: $0.sequence, segment: ChatSegment.tools([$0]))
            }
            + questions.map {
                (offset: $0.textOffset, sequence: $0.sequence, segment: ChatSegment.question($0))
            }
            + plans.map {
                (offset: $0.textOffset, sequence: $0.sequence, segment: ChatSegment.plan($0))
            })
            .sorted { ($0.offset, $0.sequence) < ($1.offset, $1.sequence) }
        var segments: [ChatSegment] = []
        var rest = Substring(text)
        var consumed = 0
        for interruption in interruptions {
            let take = max(0, min(interruption.offset - consumed, rest.count))
            if take > 0 { segments.append(.text(String(rest.prefix(take)))) }
            if case .tools(let uses) = interruption.segment,
                case .tools(let previous) = segments.last
            {
                segments[segments.count - 1] = .tools(previous + uses)
            } else {
                segments.append(interruption.segment)
            }
            rest = rest.dropFirst(take)
            consumed += take
        }
        if !rest.isEmpty { segments.append(.text(String(rest))) }
        return segments
    }
}

struct ChatSearch: Equatable, Hashable, Sendable {
    var query: String?
    var isComplete: Bool
    /// Characters of reply text that had arrived when the search began.
    let textOffset: Int
    let sequence: Int
}

/// One tool call inside a reply: live while it runs, a record of what ran once it is done.
struct ChatToolUse: Equatable, Hashable, Sendable {
    enum State: String, Equatable, Hashable, Sendable {
        case running
        case completed
        case failed
    }

    let callID: String
    let origin: String
    let title: String
    var state: State
    /// Characters of reply text that had arrived when the call started.
    let textOffset: Int
    let sequence: Int

    var label: String {
        let verb = state == .running ? "Calling" : "Called"
        return origin.isEmpty ? "\(verb) \(title)" : "\(verb) \(origin) · \(title)"
    }
}

extension Array where Element == ChatToolUse {
    var runningCall: ChatToolUse? { last { $0.state == .running } }
    var isLive: Bool { runningCall != nil }
    var failedCount: Int { count { $0.state == .failed } }

    var completedLabel: String {
        let label = "Called \(count) tools"
        let failures = failedCount
        return failures == 0 ? label : "\(label) · \(failures) failed"
    }
}

/// One stretch of thinking: a reply may think, answer, then think again before going on.
struct ChatReasoning: Equatable, Hashable, Sendable {
    var text: String
    /// Characters of reply text that had arrived when this stretch began.
    let textOffset: Int
    /// Until the answer resumed, or the reply ended; nil while it is still thinking.
    var duration: TimeInterval?

    var displayText: String {
        guard let last = text.lastIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(text[...last])
    }
}

enum ChatSegment: Equatable, Hashable {
    case text(String)
    case search(ChatSearch)
    case tools([ChatToolUse])
    case question(ChatQuestion)
    case plan(ChatWrittenPlan)
    case reasoning(ChatReasoning)
}
