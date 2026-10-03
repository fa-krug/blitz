import Foundation

/// Turns one typed sentence into a reminder draft; writing it is the coordinator's call, not this.
@MainActor
enum SmartReminderRunner {
    enum Failure: LocalizedError {
        case unreadable

        var errorDescription: String? {
            "The model's answer didn't contain a reminder. Try saying what needs doing, and when."
        }
    }

    static func draft(
        from note: String, now: Date, calendar: Calendar, using provider: any AIProvider
    ) async throws -> ReminderDraft {
        let request = AIRequest(
            instructions: SmartReminderPrompt.instructions(now: now, calendar: calendar),
            messages: [AIMessage(role: .user, text: note)],
            maxOutputTokens: SmartReminderPrompt.maxOutputTokens)
        var reply = ""
        for try await event in provider.stream(request) {
            guard case .text(let delta) = event else { continue }
            reply += delta
        }
        guard let draft = SmartReminderPrompt.draft(from: reply, calendar: calendar) else {
            throw Failure.unreadable
        }
        return draft
    }
}
