import Foundation

/// The session tools' answers as text: a listing of chats, and one chat's transcript, clipped.
enum SessionToolEngine {
    typealias Catalog = SessionToolCatalog

    /// An answer reached without a dialog; an error is a refusal, else nothing needed doing.
    struct Settled: Equatable, Sendable {
        let message: String
        let isError: Bool
    }

    /// Checked before asking and again after: this chat, a chat not there, or one to leave alone.
    static func settled(
        _ request: Catalog.Request, conversation: ChatConversation?, current: UUID,
        isAnswering: Bool, isOpen: Bool
    ) -> Settled? {
        guard let id = request.id else { return nil }
        guard id != current else { return Settled(message: Catalog.currentChat, isError: true) }
        guard let conversation else { return Settled(message: Catalog.unknown(id), isError: true) }
        let title = conversation.displayTitle
        switch request {
        case .list, .read:
            return nil
        case .archive:
            if conversation.isArchived {
                return Settled(message: Catalog.alreadyArchived(title), isError: false)
            }
            if isAnswering { return Settled(message: Catalog.answering(title), isError: true) }
            if isOpen { return Settled(message: Catalog.openInBlitz(title), isError: true) }
            if conversation.isPinned {
                return Settled(message: Catalog.pinned(title), isError: true)
            }
            return nil
        case .unarchive:
            return conversation.isArchived
                ? nil : Settled(message: Catalog.notArchived(title), isError: false)
        }
    }

    /// `conversations` newest first; `current` is the asking chat, which is never listed.
    static func listing(
        _ conversations: [ChatConversation], scope: Catalog.Scope, query: String?, limit: Int,
        excluding current: UUID, timeZone: TimeZone = .current
    ) -> String {
        let matches = conversations.matching(query ?? "").filter { $0.id != current }
        let filter = query.map { ", matching \u{201C}\($0)\u{201D}" } ?? ""
        guard !matches.isEmpty else {
            return "No \(name(of: scope)) chats\(filter)."
        }
        let shown = matches.prefix(limit)
        var lines = [
            "\(matches.count) \(name(of: scope)) chat\(matches.count == 1 ? "" : "s")\(filter), "
                + "newest first.",
            "id\ttitle\tlast active\tmessages\tarchived"
        ]
        for conversation in shown {
            lines.append(
                [
                    conversation.id.uuidString, oneLine(conversation.displayTitle),
                    stamp(conversation.updatedAt, timeZone: timeZone),
                    String(conversation.messageCount), conversation.isArchived ? "yes" : "no"
                ].joined(separator: "\t"))
        }
        if matches.count > shown.count {
            let more = matches.count - shown.count
            let raise =
                limit < Catalog.listLimit ? " or a larger limit, up to \(Catalog.listLimit)" : ""
            lines.append("[\(more) more not shown; narrow them with query\(raise).]")
        }
        return lines.joined(separator: "\n")
    }

    private static func name(of scope: Catalog.Scope) -> String {
        switch scope {
        case .recent: "recent"
        case .archived: "archived"
        case .all: "saved"
        }
    }

    /// Nil when `fromMessage` is past the end; the caller says so with `pastTheEnd`.
    static func transcript(
        of session: ChatSession, title: String, isArchived: Bool, fromMessage: Int, limit: Int?,
        cap: Int = Catalog.readLimit, timeZone: TimeZone = .current
    ) -> String? {
        let total = session.messages.count
        guard fromMessage <= total else { return nil }
        var header = ["Chat: \(oneLine(title))", "id: \(session.id.uuidString)"]
        if isArchived { header.append("Archived: yes") }
        header.append("Last active: \(stamp(session.updatedAt, timeZone: timeZone))")
        header.append("Messages: \(total)")
        var text = header.joined(separator: "\n")
        let last = limit.map { min(total, fromMessage + $0 - 1) } ?? total
        var next = fromMessage
        while next <= last {
            let block =
                "\n\n" + message(session.messages[next - 1], number: next, timeZone: timeZone)
            let room = cap - noteRoom - text.utf8.count
            guard block.utf8.count > room else {
                text += block
                next += 1
                continue
            }
            // One message longer than the cap still shows its start, or the read could never move.
            if next == fromMessage {
                text += clipped(block, to: room)
                next += 1
            }
            break
        }
        let shownRange = fromMessage == next - 1 ? "\(fromMessage)" : "\(fromMessage)–\(next - 1)"
        if next <= total {
            text +=
                "\n\n[Messages \(shownRange) of \(total) shown. Read on with fromMessage \(next).]"
        } else if fromMessage > 1 {
            text += "\n\n[Messages \(shownRange) of \(total) shown; that is the end of the chat.]"
        }
        return text
    }

    /// Kept free under the cap for the closing note, so the answer as a whole stays within it.
    private static let noteRoom = 100

    static func pastTheEnd(_ title: String, count: Int) -> String {
        "\u{201C}\(title)\u{201D} has \(count) message\(count == 1 ? "" : "s"); "
            + "fromMessage must be from 1 to \(count)."
    }

    /// One message: who and when, the text, then what happened in it, a line each.
    static func message(_ message: ChatMessage, number: Int, timeZone: TimeZone) -> String {
        let speaker = message.role == .user ? "User" : "Assistant"
        var lines = ["[\(number)] \(speaker), \(stamp(message.sentAt, timeZone: timeZone)):"]
        for segment in message.segments {
            switch segment {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { lines.append(trimmed) }
            case .search(let search):
                lines.append(
                    search.query.map { "[Searched the web: \u{201C}\(oneLine($0))\u{201D}]" }
                        ?? "[Searched the web]")
            case .tools(let uses):
                lines += uses.map { use in
                    "[Tool: \(oneLine(use.origin)) \u{2014} \(oneLine(use.title)), "
                        + "\(state(of: use))]"
                }
            case .question(let asked):
                let answer = asked.answer.map {
                    AskUserToolCatalog.answer($0, to: asked.question)
                } ?? "Not answered."
                lines.append(
                    "[Asked: \(oneLine(asked.question.question)) \u{2014} \(oneLine(answer))]")
            case .plan(let written):
                lines.append("[Wrote a plan: \(oneLine(written.plan.title))]")
            case .reasoning:
                continue
            }
        }
        let attached =
            message.documents.map(\.name)
            + (message.images.isEmpty
                ? [] : ["\(message.images.count) image\(message.images.count == 1 ? "" : "s")"])
        if !attached.isEmpty { lines.append("[Attached: \(attached.joined(separator: ", "))]") }
        if message.role == .assistant, message.state != .complete {
            lines.append("[This reply did not finish.]")
        }
        return lines.joined(separator: "\n")
    }

    private static func state(of use: ChatToolUse) -> String {
        switch use.state {
        case .running: "running"
        case .completed: "done"
        case .failed: "failed"
        }
    }

    /// Cut at a character, never inside one, with a note saying the message goes on.
    private static func clipped(_ block: String, to room: Int) -> String {
        let note = "\n[This message is too long to show whole; only its start is shown.]"
        let budget = min(max(room - note.utf8.count, 0), block.utf8.count)
        var end = block.utf8.index(block.startIndex, offsetBy: budget)
        while end.samePosition(in: block) == nil { end = block.utf8.index(before: end) }
        return String(block[..<end]) + note
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// Fixed digits in the reader's time zone, so the model and a harness read the same text.
    static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0)
    }
}
