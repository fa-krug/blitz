import Foundation

// The agent's memory: admission, the two tools, the block every turn carries, and the store.
@main
@MainActor
struct MemoryTests {
    static var failures = 0

    static func check(_ description: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS  \(description)")
        } else {
            print("FAIL  \(description)")
            failures += 1
        }
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func memory(_ id: Int, _ text: String) -> AgentMemory {
        AgentMemory(id: id, text: text, createdAt: now, sourceConversation: nil)
    }

    static func main() {
        admission()
        catalog()
        instructions()
        store()
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Admission

    static func admission() {
        check("whitespace collapses to one line", AgentMemory.cleaned("  a\n\tb   c ") == "a b c")
        check("the key ignores case and spacing", AgentMemory.key(" Likes  TEA") == "likes tea")
        check("a handle is m and the id", memory(7, "x").handle == "m7")
        check(
            "an id is read from m3, M3 or 3",
            AgentMemory.id(fromHandle: "m3") == 3 && AgentMemory.id(fromHandle: " M3 ") == 3
                && AgentMemory.id(fromHandle: "3") == 3)
        check(
            "nothing else is an id",
            [" ", "m", "mx", "m-1", "0", "m0", "x3", "m３", "m3.5"].allSatisfy {
                AgentMemory.id(fromHandle: $0) == nil
            })

        let some = [memory(1, "Prefers metric units"), memory(2, "Lives in Berlin")]
        check(
            "new text is accepted, cleaned",
            AgentMemory.admission(of: " Has  a cat ", into: some) == .accepted("Has a cat"))
        check("blank text is empty", AgentMemory.admission(of: " \n ", into: some) == .empty)
        let limit = String(repeating: "a", count: AgentMemory.textLimit)
        check(
            "exactly 500 characters fit",
            AgentMemory.admission(of: limit, into: []) == .accepted(limit))
        check(
            "501 are too long, counted after cleaning",
            AgentMemory.admission(of: limit + "b", into: []) == .tooLong(501)
                && AgentMemory.admission(of: limit + "   ", into: []) == .accepted(limit))
        check(
            "an identical memory, case and spacing aside, is a duplicate",
            AgentMemory.admission(of: "prefers  METRIC units", into: some) == .duplicate(some[0]))
        check(
            "an edit is never its own duplicate",
            AgentMemory.admission(of: "Prefers metric UNITS", into: some, replacing: 1)
                == .accepted("Prefers metric UNITS"))
        check(
            "an edit onto another memory is a duplicate",
            AgentMemory.admission(of: "lives in berlin", into: some, replacing: 1)
                == .duplicate(some[1]))
        let hundred = (1...AgentMemory.countLimit).map { memory($0, "fact \($0)") }
        check(
            "the 101st memory is refused",
            AgentMemory.admission(of: "new", into: hundred) == .full)
        check(
            "an edit of one of a hundred still fits",
            AgentMemory.admission(of: "changed", into: hundred, replacing: 5)
                == .accepted("changed"))
        let big = (1...24).map { memory($0, String(repeating: "\($0 % 10)", count: 500)) }
        check(
            "24 long memories leave room",
            AgentMemory.admission(of: "x", into: big) == .accepted("x"))
        let bytesLeft = AgentMemory.byteLimit - big.reduce(0) { $0 + $1.text.utf8.count }
        let fits = String(repeating: "z", count: bytesLeft)
        check(
            "text up to the byte budget fits, and one byte more does not",
            AgentMemory.admission(of: fits, into: big) == .accepted(fits)
                && AgentMemory.admission(of: fits + "z", into: big) == .full)
        check(
            "the byte budget counts UTF-8",
            AgentMemory.admission(
                of: String(repeating: "é", count: bytesLeft / 2 + 1), into: big) == .full)
    }

    // MARK: The tools

    static func catalog() {
        let tools = MemoryToolCatalog.tools()
        check(
            "two tools, remember and forget",
            tools.map(\.name) == ["memory_remember", "memory_forget"]
                && tools.allSatisfy { MemoryToolCatalog.handles($0.name) }
                && !MemoryToolCatalog.handles("note_append"))
        check(
            "remember requires its text, and says the user may decline",
            tools[0].parameters.objectValue?["required"] == .array([.string("text")])
                && tools[0].description.contains("may decline")
                && tools[0].description.contains("never a password"))
        check(
            "forget takes an id or a text, neither required",
            tools[1].parameters.objectValue?["required"] == .array([])
                && tools[1].parameters.objectValue?["properties"]?.objectValue?.keys.sorted()
                    == ["id", "text"])
        check("both are titled for the transcript", tools.map(\.origin) == ["Memory", "Memory"])

        func request(_ name: String, _ arguments: String) -> MemoryToolCatalog.Request? {
            try? MemoryToolCatalog.request(name: name, arguments: arguments)
        }
        func refusal(_ name: String, _ arguments: String) -> String? {
            do throws(AIToolArguments.Invalid) {
                _ = try MemoryToolCatalog.request(name: name, arguments: arguments)
                return nil
            } catch {
                return error.message
            }
        }
        let remember = MemoryToolCatalog.rememberName
        let forget = MemoryToolCatalog.forgetName
        check(
            "remember reads its text, cleaned",
            request(remember, #"{"text":" Likes\n tea "}"#) == .remember("Likes tea"))
        check("remember without text is refused", refusal(remember, "{}") == "“text” is required.")
        check("remember with blank text is refused", refusal(remember, #"{"text":"  "}"#) != nil)
        check(
            "remember with too much text is refused with its length",
            refusal(remember, #"{"text":"\#(String(repeating: "a", count: 501))"}"#)?
                .contains("this is 501") == true)
        check("arguments that are not an object are refused", refusal(remember, "[1]") != nil)
        check("forget reads an id", request(forget, #"{"id":"m3"}"#) == .forget(.id(3)))
        check(
            "an id wins over a text",
            request(forget, #"{"id":"4","text":"x"}"#) == .forget(.id(4)))
        check(
            "forget reads a text, cleaned",
            request(forget, #"{"text":"Likes  tea"}"#) == .forget(.text("Likes tea")))
        check(
            "a bad id is refused",
            refusal(forget, #"{"id":"tea"}"#)?.contains("such as m3") == true)
        check("forget with neither is refused", refusal(forget, "{}") == "Give “id” or “text”.")
        check("an unknown name is refused", refusal("memory_list", "{}") != nil)

        let memories = [memory(1, "Prefers metric units"), memory(3, "Lives in Berlin")]
        check(
            "a new memory needs a dialog",
            MemoryToolCatalog.settled(.remember("Has a cat"), memories: memories) == nil)
        check(
            "a duplicate is answered without one, and is no error",
            MemoryToolCatalog.settled(.remember("lives in BERLIN"), memories: memories)
                == .init(
                    message: "That is already remembered as m3; nothing was added.",
                    isError: false))
        let full = (1...100).map { memory($0, "fact \($0)") }
        let refusedFull = MemoryToolCatalog.settled(.remember("one more"), memories: full)
        check(
            "a full memory refuses, asking to forget something first",
            refusedFull?.isError == true
                && refusedFull?.message.contains("forget something") == true
                && refusedFull?.message.contains("100 memories") == true
                && refusedFull?.message.contains("12 KB") == true)
        check(
            "forgetting a memory that is there needs a dialog",
            MemoryToolCatalog.settled(.forget(.id(3)), memories: memories) == nil
                && MemoryToolCatalog.settled(
                    .forget(.text("prefers metric units")), memories: memories) == nil)
        check(
            "an unknown id is refused without one",
            MemoryToolCatalog.settled(.forget(.id(2)), memories: memories)
                == .init(
                    message: "No memory is m2. Your instructions show each memory’s id.",
                    isError: true))
        check(
            "an unknown text is refused without one",
            MemoryToolCatalog.settled(.forget(.text("x")), memories: memories)?.message
                == "No memory reads “x”.")
        check(
            "with nothing remembered, forgetting says so",
            MemoryToolCatalog.settled(.forget(.id(1)), memories: [])?.message
                == "Nothing is remembered, so there is nothing to forget.")

        let rememberPrompt = MemoryToolCatalog.prompt(
            for: .remember("Has a cat"), memories: memories)
        check(
            "the remember dialog shows the text and says it goes with every chat",
            rememberPrompt?.title == "Let the agent remember this?"
                && rememberPrompt?.message?.hasPrefix("“Has a cat”") == true
                && rememberPrompt?.message?.contains("every chat from now on") == true
                && rememberPrompt?.message?.contains("provider") == true)
        check(
            "it asks each time: Allow or Don't Allow, never for the chat",
            rememberPrompt?.choices == [.allowOnce("Allow"), .refuse("Don't Allow")]
                && rememberPrompt?.defaultIndex == 0
                && rememberPrompt?.symbol == AgentTool.memoryWrite.symbolName)
        let forgetPrompt = MemoryToolCatalog.prompt(for: .forget(.id(3)), memories: memories)
        check(
            "the forget dialog names the memory",
            forgetPrompt?.title == "Let the agent forget “Lives in Berlin”?"
                && forgetPrompt?.choices == [.allowOnce("Allow"), .refuse("Don't Allow")])
        check(
            "a long memory is clipped in the forget title",
            AgentPrompt.forget(String(repeating: "a", count: 300)).title
                == "Let the agent forget “\(String(repeating: "a", count: 120))…”?")
        check(
            "no dialog for a memory that is not there",
            MemoryToolCatalog.prompt(for: .forget(.id(9)), memories: memories) == nil)
        check(
            "the answers name the id",
            MemoryToolCatalog.remembered(memory(4, "x")).hasPrefix("Remembered as m4.")
                && MemoryToolCatalog.forgot(memory(3, "Lives in Berlin"))
                    == "Forgot m3: “Lives in Berlin”."
                && MemoryToolCatalog.changed(memory(3, "x")).contains("nothing was forgotten"))
        check(
            "a refusal names the rows",
            AgentRefusal.denied.message(for: .memoryWrite)
                == "Blitz's agent rules do not let the model change its memory."
                && AgentRefusal.declined.message(for: .memoryWrite)
                    == "The user declined to let the model change its memory.")
    }

    // MARK: The block each turn carries

    static func instructions() {
        let memories = [memory(1, "Prefers metric units"), memory(3, "Lives in Berlin")]
        check(
            "nothing remembered carries nothing",
            AgentMemoryInstructions.block([], canForget: true) == nil)
        let expected =
            "The user asked you to remember these, oldest first. Use them where they help. "
            + "To forget one, call memory_forget with its id.\n- m1: Prefers metric units\n"
            + "- m3: Lives in Berlin"
        check(
            "each memory is a line with its id, oldest first",
            AgentMemoryInstructions.block(memories, canForget: true) == expected)
        check(
            "without the forget tool, the block does not mention it",
            AgentMemoryInstructions.block(memories, canForget: false)
                == "The user asked you to remember these, oldest first. Use them where they help."
                + "\n- m1: Prefers metric units\n- m3: Lives in Berlin")
        let padding = String(repeating: "x", count: 60)
        let many = (1...40).map { memory($0, "Fact number \($0) " + padding) }
        let clipped = AgentMemoryInstructions.block(
            many, canForget: true, budget: AgentMemoryInstructions.onDeviceBudget)
        check(
            "a budget keeps the newest that fit, oldest of them first",
            clipped.map { $0.utf8.count <= AgentMemoryInstructions.onDeviceBudget } == true
                && clipped?.contains("- m40: Fact number 40") == true
                && clipped?.contains("- m1: ") == false
                && clipped.flatMap { text in
                    guard let older = text.range(of: "- m39:"), let newer = text.range(of: "- m40:")
                    else { return nil }
                    return older.lowerBound < newer.lowerBound
                } == true)
        let kept = AgentMemoryInstructions.carried(
            many, canForget: true, budget: AgentMemoryInstructions.onDeviceBudget)
        check(
            "and says how many older ones it left out",
            !kept.isEmpty && kept.last?.id == 40
                && clipped?.hasSuffix("\n(\(40 - kept.count) older ones left out.)") == true)
        check(
            "no budget carries everything",
            AgentMemoryInstructions.carried(many, canForget: true, budget: nil).count == 40
                && AgentMemoryInstructions.block(many, canForget: true)?.contains("left out")
                    == false)
        check(
            "a budget too small for one memory carries none",
            AgentMemoryInstructions.block(many, canForget: true, budget: 100) == nil)
        check(
            "one left out is said in the singular",
            AgentMemoryInstructions.block(
                [memory(1, String(repeating: "a", count: 400)), memory(2, "short")],
                canForget: false, budget: 300)?.hasSuffix("\n(1 older one left out.)") == true)
        check(
            "the block goes after the turn's own instructions",
            AgentMemoryInstructions.appending("Block", to: "Base") == "Base\n\nBlock")
        check(
            "and alone when the turn has none",
            AgentMemoryInstructions.appending("Block", to: nil) == "Block"
                && AgentMemoryInstructions.appending("Block", to: "") == "Block")
        check(
            "no block leaves the instructions as they were",
            AgentMemoryInstructions.appending(nil, to: "Base") == "Base"
                && AgentMemoryInstructions.appending(nil, to: nil) == nil)
    }

    // MARK: The store

    static func store() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("agent-memory.json")

        let fresh = AgentMemoryStore(directory: directory)
        check("nothing is written before a load", fresh.add("x", from: nil) == nil)
        fresh.load()
        check(
            "a missing file loads as empty, and nothing is created",
            fresh.memories.isEmpty && fresh.isLoaded && fresh.isAvailable
                && !FileManager.default.fileExists(atPath: file.path))
        let chat = UUID()
        let first = fresh.add(" Prefers  metric units ", from: chat, at: now)
        check(
            "an added memory is cleaned, numbered from 1 and remembers its chat",
            first == AgentMemory(
                id: 1, text: "Prefers metric units", createdAt: now, sourceConversation: chat)
                && FileManager.default.fileExists(atPath: file.path))
        let second = fresh.add("Lives in Berlin", from: nil, at: now)
        check("the next is 2", second?.id == 2)
        check("a duplicate is not added", fresh.add("lives in berlin", from: nil) == nil)
        check("two are kept, oldest first", fresh.memories.map(\.id) == [1, 2])

        let reloaded = AgentMemoryStore(directory: directory)
        reloaded.load()
        check("they survive a reload", reloaded.memories == fresh.memories)
        check(
            "an edit keeps the id and the date",
            reloaded.update(id: 1, text: "Prefers  SI units")
                && reloaded.memory(id: 1)
                    == AgentMemory(
                        id: 1, text: "Prefers SI units", createdAt: now, sourceConversation: chat))
        check(
            "an edit onto another memory is refused",
            !reloaded.update(id: 1, text: "LIVES IN BERLIN")
                && reloaded.memory(id: 1)?.text == "Prefers SI units")
        check(
            "an edit of a memory that is not there is refused",
            !reloaded.update(id: 9, text: "x"))
        check("removing takes it out", reloaded.remove(id: 2) && reloaded.memory(id: 2) == nil)
        check("removing one that is not there says no", !reloaded.remove(id: 2))
        check(
            "a later memory never takes a removed id",
            reloaded.add("Has a cat", from: nil)?.id == 3)
        check("forgetting everything empties it", reloaded.removeAll() && reloaded.memories.isEmpty)
        check("even after that, ids go on", reloaded.add("Drinks tea", from: nil)?.id == 4)

        let again = AgentMemoryStore(directory: directory)
        again.load()
        check(
            "the counter survives a reload too",
            again.memories.map(\.id) == [4] && again.add("Walks to work", from: nil)?.id == 5)

        try? Data("not json".utf8).write(to: file)
        let broken = AgentMemoryStore(directory: directory)
        broken.load()
        check(
            "a file that does not decode is refused, never replaced",
            !broken.isAvailable && broken.memories.isEmpty && broken.add("x", from: nil) == nil
                && (try? String(contentsOf: file, encoding: .utf8)) == "not json")
    }
}
