import Foundation

/// What an update check concludes from the version an install was recorded at.
@main
@MainActor
struct ExtensionVersionStoreTests {
    static var failures = 0
    static var passes = 0

    static func main() {
        reconciling()
        forgetting()
        persisting()
        scheduling()
        deferring()
        summarizing()

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func reconciling() {
        print("\n# reconciling")
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ExtensionVersionStore(fileURL: file)
        store.record("a1", for: "current")
        store.record("a1", for: "behind")
        store.record(nil, for: "imported")

        let latest = [
            listing("current", commit: "a1"), listing("behind", commit: "b2"),
            listing("imported", commit: "c3"), listing("untracked", commit: "d4"),
            listing("unversioned", commit: nil)
        ]
        let behind = store.reconcile(with: latest).map(\.name)
        check("a newer commit is behind", behind == ["behind"])
        check("an import adopts the store's version", store.reconcile(with: latest).map(\.name) == ["behind"])

        store.record(nil, for: "unversioned")
        check(
            "a listing without a commit never reads as behind",
            store.reconcile(with: [listing("unversioned", commit: nil)]).isEmpty)
        check(
            "an untracked install is never checked",
            !store.tracked.contains("untracked"))
    }

    static func forgetting() {
        print("\n# forgetting")
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ExtensionVersionStore(fileURL: file)
        store.record("a1", for: "github")
        store.forget("github")
        check("a forgotten install leaves tracking", !store.tracked.contains("github"))
        check(
            "and is never reported behind",
            store.reconcile(with: [listing("github", commit: "b2")]).isEmpty)
    }

    static func persisting() {
        print("\n# persisting")
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file) }
        ExtensionVersionStore(fileURL: file).record("a1", for: "coffee")
        let reopened = ExtensionVersionStore(fileURL: file)
        check("a recorded version survives a relaunch", reopened.tracked == ["coffee"])
        check(
            "and keeps its commit",
            reopened.reconcile(with: [listing("coffee", commit: "b2")]).map(\.name) == ["coffee"])
        check(
            "a missing file starts empty",
            ExtensionVersionStore(fileURL: makeFile()).tracked.isEmpty)
    }

    // MARK: - Automatic updates

    static func scheduling() {
        print("\n# scheduling")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let day = ExtensionUpdatePolicy.checkInterval
        let retry = ExtensionUpdatePolicy.retryInterval
        check("a first launch is due", ExtensionUpdatePolicy.isDue(lastCheckedAt: nil, now: now))
        check(
            "a check an hour ago is not",
            !ExtensionUpdatePolicy.isDue(lastCheckedAt: now.addingTimeInterval(-3600), now: now))
        check(
            "a day later it is",
            ExtensionUpdatePolicy.isDue(lastCheckedAt: now.addingTimeInterval(-day), now: now))
        check(
            "a future stamp can't park the loop past a day",
            ExtensionUpdatePolicy.nextWait(
                lastCheckedAt: now.addingTimeInterval(3 * day), now: now, hasDeferred: false) == day)
        check(
            "an answered check sleeps a day",
            ExtensionUpdatePolicy.nextWait(lastCheckedAt: now, now: now, hasDeferred: false) == day)
        check(
            "an unanswered one retries sooner",
            ExtensionUpdatePolicy.nextWait(
                lastCheckedAt: now.addingTimeInterval(-2 * day), now: now, hasDeferred: false)
                == retry)
        check(
            "and so does one that deferred an extension",
            ExtensionUpdatePolicy.nextWait(lastCheckedAt: now, now: now, hasDeferred: true) == retry)
    }

    static func deferring() {
        print("\n# deferring")
        let split = ExtensionUpdatePolicy.partition(["a", "b", "c"], busy: ["b"])
        check("an idle extension updates", split.ready == ["a", "c"])
        check("a busy one waits", split.deferred == ["b"])
        check("nothing busy defers nothing", ExtensionUpdatePolicy.partition(["a"], busy: []).deferred.isEmpty)
    }

    static func summarizing() {
        print("\n# summarizing")
        typealias Outcome = ExtensionUpdatePolicy.Outcome
        check(
            "updates are counted",
            Outcome(answered: true, available: 2, updated: 2).summary(installing: true)
                == "Updated 2 extensions")
        check(
            "one is singular",
            Outcome(answered: true, available: 1, updated: 1).summary(installing: true)
                == "Updated 1 extension")
        let partial = Outcome(answered: true, available: 2, updated: 1, failed: ["Coffee"])
        check(
            "a failure is named beside what worked",
            partial.summary(installing: true) == "Updated 1 extension; couldn't update Coffee")
        check("and reads as a failure", partial.isFailure)
        check(
            "an unreachable store says so",
            Outcome().summary(installing: true) == "Couldn't reach the Raycast Store"
                && Outcome().isFailure)
        check(
            "a check alone offers what it found",
            Outcome(answered: true, available: 3).summary(installing: false)
                == "3 extension updates available")
        check(
            "a busy extension is promised later",
            Outcome(answered: true, available: 1, deferred: ["coffee"]).summary(installing: true)
                == "1 extension is in use and will update later")
        check(
            "nothing pending is up to date",
            Outcome(answered: true).summary(installing: true) == "Extensions are up to date"
                && !Outcome(answered: true).isFailure)
    }

    // MARK: - Helpers

    /// Scratch state of its own, never the machine's extension files.
    static func makeFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-version-test-\(UUID().uuidString).json")
    }

    static func listing(_ name: String, commit: String?) -> ExtensionListing {
        ExtensionListing(
            id: name, name: name, title: name, summary: "", author: "", handle: nil,
            lightIconURL: nil, darkIconURL: nil, commandCount: 1, downloadCount: nil,
            downloadURL: URL(fileURLWithPath: "/dev/null"), commitSHA: commit, categories: [],
            updatedAt: nil, readmeURL: nil, readmeAssetsURL: nil, screenshotURLs: [],
            latestChange: nil)
    }

    static func check(_ description: String, _ condition: Bool) {
        if condition {
            passes += 1
            print("PASS  \(description)")
        } else {
            failures += 1
            print("FAIL  \(description)")
        }
    }
}
