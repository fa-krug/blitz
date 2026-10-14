import Foundation

@main
struct SessionToolTests {
    nonisolated(unsafe) static var failures = 0

    static func check(_ description: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS  \(description)")
        } else {
            print("FAIL  \(description)")
            failures += 1
        }
    }

    typealias Catalog = SessionToolCatalog
    typealias Engine = SessionToolEngine

    static let utc = TimeZone(identifier: "UTC")!
    static let noon = Date(timeIntervalSince1970: 1_760_443_200)

    static func main() {
        schemasAndRows()
        callsAreReadAndRefused()
        dialogsNameTheChat()
        callsSettleBeforeAsking()
        listingsExcludeThisChat()
        transcriptsReadOneLinePerEvent()
        transcriptsPageAndClip()
        if failures > 0 {
            print("\(failures) failed")
            exit(1)
        }
        print("all passed")
    }

    static func request(_ name: String, _ arguments: String) -> Catalog.Request? {
        try? Catalog.request(name: name, arguments: arguments)
    }

    static func refusal(_ name: String, _ arguments: String) -> String? {
        do throws(AIToolArguments.Invalid) {
            _ = try Catalog.request(name: name, arguments: arguments)
            return nil
        } catch {
            return error.message
        }
    }

    static func schemasAndRows() {
        let names = [Catalog.listName, Catalog.readName, Catalog.archiveName, Catalog.unarchiveName]
        check("the four wire names", names == [
            "sessions_list", "sessions_read", "sessions_archive", "sessions_unarchive"
        ])
        check(
            "both halves offered",
            Catalog.tools(read: true, archive: true).map(\.name) == names)
        check(
            "reading alone offers list and read",
            Catalog.tools(read: true, archive: false).map(\.name)
                == [Catalog.listName, Catalog.readName])
        check(
            "archiving alone offers archive and unarchive",
            Catalog.tools(read: false, archive: true).map(\.name)
                == [Catalog.archiveName, Catalog.unarchiveName])
        check("nothing offered, nothing listed", Catalog.tools(read: false, archive: false).isEmpty)
        check("the catalog handles its names", names.allSatisfy(Catalog.handles))
        check("and no other", !Catalog.handles("files_read"))
        check(
            "list and read map to Read Other Chats",
            AgentTool(builtInToolName: Catalog.listName) == .sessionsRead
                && AgentTool(builtInToolName: Catalog.readName) == .sessionsRead)
        check(
            "archive and unarchive map to Archive Chats",
            AgentTool(builtInToolName: Catalog.archiveName) == .sessionsArchive
                && AgentTool(builtInToolName: Catalog.unarchiveName) == .sessionsArchive)
        check(
            "reading only looks and can be allowed for a chat; archiving neither",
            AgentTool.sessionsRead.isReadOnly && AgentTool.sessionsRead.canAllowForSession
                && !AgentTool.sessionsArchive.isReadOnly
                && !AgentTool.sessionsArchive.canAllowForSession)
        check(
            "reading asks by default and archiving is denied",
            AgentRules.defaults.decision(for: .sessionsRead) == .ask
                && AgentRules.defaults.decision(for: .sessionsArchive) == .deny)
        let schema = Catalog.tools(read: true, archive: false)[0].parameters
        check(
            "the scope is spelled as an enum",
            schema.objectValue?["properties"]?.objectValue?["scope"]?.objectValue?["enum"]
                == .array([.string("recent"), .string("archived"), .string("all")]))
        let read = Catalog.tools(read: true, archive: false)[1].parameters
        check(
            "a read requires an id",
            read.objectValue?["required"] == .array([.string("id")]))
    }

    static func callsAreReadAndRefused() {
        let id = UUID()
        check(
            "a bare list is the recent chats, 20 at most",
            request(Catalog.listName, "") == .list(scope: .recent, query: nil, limit: 20))
        check(
            "scope, query and limit are read",
            request(Catalog.listName, #"{"scope":"ARCHIVED","query":"  trip ","limit":"5"}"#)
                == .list(scope: .archived, query: "trip", limit: 5))
        check(
            "a limit past the cap is capped",
            request(Catalog.listName, #"{"scope":"all","limit":500}"#)
                == .list(scope: .all, query: nil, limit: Catalog.listLimit))
        check(
            "an unknown scope is refused",
            refusal(Catalog.listName, #"{"scope":"pinned"}"#)
                == "\u{201C}scope\u{201D} must be recent, archived or all.")
        check(
            "a limit below 1 is refused",
            refusal(Catalog.listName, #"{"limit":0}"#)
                == "\u{201C}limit\u{201D} must be a whole number from 1.")
        check(
            "a read starts at the first message",
            request(Catalog.readName, #"{"id":"\#(id.uuidString)"}"#)
                == .read(id: id, fromMessage: 1, limit: nil))
        check(
            "a read takes fromMessage and limit",
            request(Catalog.readName, #"{"id":"\#(id.uuidString.lowercased())","fromMessage":3,"limit":2}"#)
                == .read(id: id, fromMessage: 3, limit: 2))
        check(
            "a read without an id is refused",
            refusal(Catalog.readName, "{}") == "\u{201C}id\u{201D} is required.")
        check(
            "an id that is not one is refused, naming where ids come from",
            refusal(Catalog.readName, #"{"id":"Trip planning"}"#)?.contains(Catalog.listName)
                == true)
        check(
            "fromMessage 0 is refused",
            refusal(Catalog.readName, #"{"id":"\#(id.uuidString)","fromMessage":0}"#)
                == "\u{201C}fromMessage\u{201D} must be a whole number from 1.")
        check(
            "archive and unarchive take an id",
            request(Catalog.archiveName, #"{"id":"\#(id.uuidString)"}"#) == .archive(id: id)
                && request(Catalog.unarchiveName, #"{"id":"\#(id.uuidString)"}"#)
                    == .unarchive(id: id))
        check(
            "arguments that are no object are refused",
            refusal(Catalog.archiveName, "[1]") == "The arguments must be one JSON object.")
        check("a name the catalog lacks is refused", refusal("sessions_delete", "{}") != nil)
        check(
            "each request names its row and its chat",
            Catalog.Request.list(scope: .all, query: nil, limit: 1).tool == .sessionsRead
                && Catalog.Request.list(scope: .all, query: nil, limit: 1).id == nil
                && Catalog.Request.read(id: id, fromMessage: 1, limit: nil).tool == .sessionsRead
                && Catalog.Request.archive(id: id).tool == .sessionsArchive
                && Catalog.Request.unarchive(id: id).id == id)
    }

    static func dialogsNameTheChat() {
        let id = UUID()
        let list = Catalog.prompt(for: .list(scope: .recent, query: nil, limit: 20), title: nil)
        check("listing asks about the chats", list.title == "Let the agent list your chats?")
        check(
            "and says what it sees and where it goes",
            list.message?.contains("title") == true
                && list.message?.contains("model\u{2019}s provider") == true)
        check(
            "listing may be allowed for the chat",
            list.choices.map(\.title) == ["Allow", "Allow This Chat", "Don't Allow"]
                && list.defaultIndex == 0)
        let read = Catalog.prompt(for: .read(id: id, fromMessage: 1, limit: nil), title: "Trip")
        check(
            "reading names the chat",
            read.title == "Let the agent read your chat \u{201C}Trip\u{201D}?"
                && read.choices.map(\.title) == ["Allow", "Allow This Chat", "Don't Allow"])
        let archive = Catalog.prompt(for: .archive(id: id), title: "Trip")
        check(
            "archiving names the chat and is asked each time",
            archive.title == "Let the agent archive \u{201C}Trip\u{201D}?"
                && archive.choices.map(\.title) == ["Allow", "Don't Allow"])
        check(
            "unarchiving says so",
            Catalog.prompt(for: .unarchive(id: id), title: "Trip").title
                == "Let the agent unarchive \u{201C}Trip\u{201D}?")
        check(
            "a refusal names what the model wanted",
            AgentRefusal.denied.message(for: .sessionsRead)
                == "Blitz's agent rules do not let the model read the user's other chats."
                && AgentRefusal.declined.message(for: .sessionsArchive)
                    == "The user declined to let the model archive or unarchive this chat.")
    }

    static func conversation(
        _ title: String, at date: Date, messages: Int = 2, pinned: Bool = false,
        archived: Bool = false
    ) -> ChatConversation {
        ChatConversation(
            id: UUID(), title: title, preview: "last words of \(title)", createdAt: date,
            updatedAt: date, messageCount: messages, isPinned: pinned,
            archivedAt: archived ? date : nil)
    }

    static func callsSettleBeforeAsking() {
        let current = UUID()
        let chat = conversation("Trip", at: noon)
        func settled(
            _ request: Catalog.Request, _ conversation: ChatConversation?,
            answering: Bool = false, open: Bool = false
        ) -> Engine.Settled? {
            Engine.settled(
                request, conversation: conversation, current: current, isAnswering: answering,
                isOpen: open)
        }
        check(
            "a listing has no chat to settle",
            settled(.list(scope: .all, query: nil, limit: 5), nil) == nil)
        check(
            "this chat is refused, read or archived",
            settled(.read(id: current, fromMessage: 1, limit: nil), nil)
                == Engine.Settled(message: Catalog.currentChat, isError: true)
                && settled(.archive(id: current), nil)?.message == Catalog.currentChat)
        check(
            "a chat not there is refused before any dialog",
            settled(.read(id: chat.id, fromMessage: 1, limit: nil), nil)
                == Engine.Settled(message: Catalog.unknown(chat.id), isError: true))
        check("a chat there is read", settled(.read(id: chat.id, fromMessage: 1, limit: nil), chat) == nil)
        check(
            "a chat still answering is never archived",
            settled(.archive(id: chat.id), chat, answering: true, open: true)
                == Engine.Settled(message: Catalog.answering("Trip"), isError: true))
        check(
            "nor one open in Blitz",
            settled(.archive(id: chat.id), chat, open: true)?.message
                == Catalog.openInBlitz("Trip"))
        check(
            "nor a pinned one",
            settled(.archive(id: chat.id), conversation("Kept", at: noon, pinned: true))?.message
                == Catalog.pinned("Kept"))
        check("any other chat goes on to ask", settled(.archive(id: chat.id), chat) == nil)
        let archived = conversation("Old", at: noon, archived: true)
        check(
            "archiving an archived chat changes nothing, and says so",
            settled(.archive(id: archived.id), archived)
                == Engine.Settled(message: Catalog.alreadyArchived("Old"), isError: false))
        check(
            "unarchiving a chat in the sidebar changes nothing",
            settled(.unarchive(id: chat.id), chat)
                == Engine.Settled(message: Catalog.notArchived("Trip"), isError: false))
        check("an archived chat goes on to ask", settled(.unarchive(id: archived.id), archived) == nil)
    }

    static func listingsExcludeThisChat() {
        let current = conversation("This chat", at: noon)
        let trip = conversation("Trip planning", at: noon.addingTimeInterval(-60), messages: 12)
        let old = conversation("Old trip", at: noon.addingTimeInterval(-86_400), archived: true)
        let recipe = conversation("Recipe", at: noon.addingTimeInterval(-90_000))
        let all = [current, trip, old, recipe]
        let listing = Engine.listing(
            all, scope: .all, query: nil, limit: 20, excluding: current.id, timeZone: utc)
        check(
            "a listing names each chat's id, title, activity, size and archive",
            listing == """
                3 saved chats, newest first.
                id\ttitle\tlast active\tmessages\tarchived
                \(trip.id.uuidString)\tTrip planning\t2025-10-14 11:59\t12\tno
                \(old.id.uuidString)\tOld trip\t2025-10-13 12:00\t2\tyes
                \(recipe.id.uuidString)\tRecipe\t2025-10-13 11:00\t2\tno
                """)
        check("this chat is never listed", !listing.contains(current.id.uuidString))
        let matching = Engine.listing(
            all, scope: .recent, query: "trip", limit: 1, excluding: current.id, timeZone: utc)
        check(
            "a query narrows, and what the limit left out is counted",
            matching.hasPrefix("2 recent chats, matching \u{201C}trip\u{201D}, newest first.")
                && matching.contains(trip.id.uuidString) && !matching.contains(old.id.uuidString)
                && matching.hasSuffix(
                    "[1 more not shown; narrow them with query or a larger limit, up to 50.]"))
        check(
            "the content matches too",
            Engine.listing(
                all, scope: .all, query: "last words of recipe", limit: 5, excluding: current.id
            ).contains(recipe.id.uuidString))
        check(
            "nothing to list says so per scope",
            Engine.listing([], scope: .archived, query: nil, limit: 5, excluding: current.id)
                == "No archived chats."
                && Engine.listing(
                    [current], scope: .recent, query: "x", limit: 5, excluding: current.id)
                    == "No recent chats, matching \u{201C}x\u{201D}.")
        check(
            "a title's line breaks never break a row",
            Engine.listing(
                [conversation("two\nlines", at: noon)], scope: .all, query: nil, limit: 5,
                excluding: current.id
            ).contains("\ttwo lines\t"))
    }

    static func transcriptsReadOneLinePerEvent() {
        let question = AskUserToolCatalog.Question(
            id: UUID(), question: "Which city?", options: ["Rome", "Paris"], multiSelect: false)
        let reply = ChatMessage(
            role: .assistant, text: "Looking.Found it.\n\nDone.", sentAt: noon,
            searches: [ChatSearch(query: "flights", isComplete: true, textOffset: 8, sequence: 0)],
            toolUses: [
                ChatToolUse(
                    callID: "1", origin: "Files", title: "Read File", state: .completed,
                    textOffset: 8, sequence: 1),
                ChatToolUse(
                    callID: "2", origin: "Web", title: "Fetch Page", state: .failed,
                    textOffset: 8, sequence: 2)
            ],
            questions: [
                ChatQuestion(
                    question: question, answer: AskUserToolCatalog.Answer(selected: [1]),
                    textOffset: 17, sequence: 3)
            ],
            plans: [
                ChatWrittenPlan(
                    plan: ChatPlan(title: "Book it", markdown: "1. Pay", updatedAt: noon),
                    textOffset: 17, sequence: 4)
            ],
            reasoning: [ChatReasoning(text: "secret thoughts", textOffset: 0, duration: 1)])
        let session = ChatSession(
            createdAt: noon, updatedAt: noon,
            messages: [
                ChatMessage(
                    role: .user, text: "Plan a trip", sentAt: noon,
                    images: [AIImage(data: Data([1]), mimeType: "image/png")],
                    documents: [
                        AIDocument(data: Data([1]), mimeType: "application/pdf", name: "map.pdf")
                    ]),
                reply,
                ChatMessage(
                    role: .assistant, text: "Response interrupted.", state: .failed, sentAt: noon)
            ])
        let text = Engine.transcript(
            of: session, title: "Trip", isArchived: true, fromMessage: 1, limit: nil,
            timeZone: utc)
        check(
            "a transcript numbers each message and puts each event on its own line",
            text == """
                Chat: Trip
                id: \(session.id.uuidString)
                Archived: yes
                Last active: 2025-10-14 12:00
                Messages: 3

                [1] User, 2025-10-14 12:00:
                Plan a trip
                [Attached: map.pdf, 1 image]

                [2] Assistant, 2025-10-14 12:00:
                Looking.
                [Searched the web: \u{201C}flights\u{201D}]
                [Tool: Files \u{2014} Read File, done]
                [Tool: Web \u{2014} Fetch Page, failed]
                Found it.
                [Asked: Which city? \u{2014} The user chose: Paris]
                [Wrote a plan: Book it]
                Done.

                [3] Assistant, 2025-10-14 12:00:
                Response interrupted.
                [This reply did not finish.]
                """)
        check("thinking is never read out", text?.contains("secret") == false)
        check("an image is named, never inlined", text?.contains("image/png") == false)
    }

    static func transcriptsPageAndClip() {
        let messages = (1...6).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? .assistant : .user,
                text: "message \(index) " + String(repeating: "x", count: 100), sentAt: noon)
        }
        let session = ChatSession(createdAt: noon, messages: messages)
        func read(_ from: Int, _ limit: Int? = nil, cap: Int = Catalog.readLimit) -> String? {
            Engine.transcript(
                of: session, title: "Long", isArchived: false, fromMessage: from, limit: limit,
                cap: cap, timeZone: utc)
        }
        let whole = read(1)
        check(
            "a chat that fits comes back whole, with no note",
            whole?.contains("[6] Assistant") == true && whole?.contains("Read on") == false
                && whole?.contains("Archived") == false)
        let limited = read(2, 2)
        check(
            "a limit reads that many and says where to read on",
            limited?.contains("[2] Assistant") == true && limited?.contains("[3] User") == true
                && limited?.contains("[4]") == false
                && limited?.hasSuffix("[Messages 2–3 of 6 shown. Read on with fromMessage 4.]")
                    == true)
        check(
            "the last page says it is the end",
            read(5)?.hasSuffix("[Messages 5–6 of 6 shown; that is the end of the chat.]") == true)
        let capped = read(1, cap: 550)
        check(
            "the cap stops at a whole message and says where to read on",
            capped.map { $0.utf8.count <= 550 } == true && capped?.contains("[2] Assistant") == true
                && capped?.contains("[3]") == false
                && capped?.hasSuffix("[Messages 1–2 of 6 shown. Read on with fromMessage 3.]")
                    == true)
        let huge = ChatSession(
            createdAt: noon,
            messages: [
                ChatMessage(role: .user, text: String(repeating: "é", count: 500), sentAt: noon),
                ChatMessage(role: .assistant, text: "short", sentAt: noon)
            ])
        let clipped = Engine.transcript(
            of: huge, title: "Huge", isArchived: false, fromMessage: 1, limit: nil, cap: 300,
            timeZone: utc)
        check(
            "one message longer than the cap still shows its start, cut on a character",
            clipped?.contains("[1] User") == true
                && clipped?.contains("only its start is shown") == true
                && clipped?.contains("\u{FFFD}") == false
                && clipped?.hasSuffix("[Messages 1 of 2 shown. Read on with fromMessage 2.]")
                    == true)
        check("reading past the end is nil", read(7) == nil)
        check(
            "and the caller says how many there are",
            Engine.pastTheEnd("Long", count: 6)
                == "\u{201C}Long\u{201D} has 6 messages; fromMessage must be from 1 to 6.")
        check(
            "the caps are as documented",
            Catalog.readLimit == 64 * 1024 && Catalog.listLimit == 50
                && Catalog.defaultListLimit == 20)
    }
}
