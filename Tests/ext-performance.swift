// Times the extension engine's hot paths: boot, a 1,000-row commit, local filtering, storage writes.

import AppKit
import Foundation
import SwiftUI

@main
struct ExtensionPerformance {
    static func main() async {
        await run()
    }

    @MainActor
    final class StubHost: ExtensionHostAPI {
        func perform(api: String, method: String, arguments: [RenderValue]) async throws -> String {
            switch "\(api).\(method)" {
            case "storage.all": return "{}"
            case "storage.get", "clipboard.readText": return #""""#
            default: return ""
            }
        }
        func sessionEnded() {}
    }

    @MainActor
    final class Recorder: ExtensionRuntimeDelegate {
        var trees: [RenderTree] = []
        var logs: [String] = []
        var failures: [String] = []
        var onRender: (() -> Void)?

        func runtime(_ runtime: ExtensionRuntime, session: String, didRender tree: RenderTree) {
            trees.append(tree)
            onRender?()
        }
        func runtime(_ runtime: ExtensionRuntime, session: String, didFail message: String) {
            failures.append(message)
        }
        func runtime(_ runtime: ExtensionRuntime, session: String, navigationDepth: Int) {}
        func runtime(_ runtime: ExtensionRuntime, session: String, didFinish: Void) {}
        func runtime(_ runtime: ExtensionRuntime, log level: String, message: String) {
            logs.append(message)
        }
    }

    static let rowCount = Int(ProcessInfo.processInfo.environment["EXT_PERF_ROWS"] ?? "") ?? 1000
    static let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("blitz-ext-performance-\(UUID().uuidString)")

    static func runtimeURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Blitz/Resources/RaycastRuntime.generated.js")
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1e3
    }

    static func report(_ label: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let mean = samples.reduce(0, +) / Double(samples.count)
        print(
            String(
                format: "%-44@ median %8.3f ms   mean %8.3f ms   (n=%d)", label as NSString, median,
                mean, samples.count))
    }

    static func time(_ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        return milliseconds(clock.measure(body))
    }

    @MainActor
    static func run() async {
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        await bootCost()
        await commitCost()
        filterCost()
        storageCost()
    }

    // MARK: - Boot

    @MainActor
    static func bootCost() async {
        let url = runtimeURL()
        let bytes = (try? Data(contentsOf: url))?.count ?? 0
        print("runtime script: \(bytes / 1024) KB")
        report(
            "read runtime script from disk",
            (0..<20).map { _ in
                time { _ = try? String(contentsOf: url, encoding: .utf8) }
            })
        var samples: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<10 {
            let runtime = ExtensionRuntime(hostAPI: StubHost(), runtimeURL: url)
            let elapsed = await clock.measure {
                try? await runtime.boot(config: .current(supportDirectory: scratch))
            }
            samples.append(milliseconds(elapsed))
            runtime.shutdown()
        }
        report("boot a fresh runtime (read + evaluate)", samples)
    }

    // MARK: - Commit

    static var listCommand: String {
        """
        "use strict";
        const { List, ActionPanel, Action, Icon } = require("@raycast/api");
        const React = require("react");
        const fs = require("node:fs");
        const h = React.createElement;
        const host = globalThis.__blitzHost;
        const original = host.render;
        let started = 0;
        let captured = 0;
        host.render = (session, json) => {
          if (started) console.log("js " + (Date.now() - started) + " " + json.length);
          if (captured < 2) fs.writeFileSync("\(scratch.path)/commit-" + captured++ + ".json", json);
          return original(session, json);
        };
        const rows = Array.from({ length: \(rowCount) }, (_, i) => i);
        module.exports.default = function Command() {
          const [tick, setTick] = React.useState(0);
          return h(List, { navigationTitle: "Perf", isLoading: false },
            h(List.Section, { title: "Rows" }, rows.map((i) =>
              h(List.Item, {
                key: String(i),
                id: "row-" + i,
                title: (i === 0 ? "Tick " + tick + " " : "") + "Item number " + i,
                subtitle: "Subtitle for row " + i,
                keywords: ["keyword" + i, "tag" + (i % 7)],
                icon: Icon.Circle,
                accessories: [{ text: "acc " + i }, { tag: { value: "t" + (i % 3) } }],
                actions: h(ActionPanel, null,
                  h(Action, { title: "Bump", onAction: () => { started = Date.now(); setTick((v) => v + 1); } }),
                  h(Action.CopyToClipboard, { title: "Copy", content: "row " + i }))
              }))));
        };
        """
    }

    @MainActor
    static func commitCost() async {
        let host = StubHost()
        let recorder = Recorder()
        let runtime = ExtensionRuntime(hostAPI: host, runtimeURL: runtimeURL())
        runtime.setDelegate(recorder)
        try? await runtime.boot(config: .current(supportDirectory: scratch))
        let context = ExtensionLaunchContext(
            extensionName: "perf", extensionTitle: "perf", commandName: "perf", commandMode: .view,
            assetsPath: scratch.path, supportPath: scratch.path, preferences: [:], caches: [:],
            arguments: [:], fallbackText: nil, isDarkAppearance: true)
        await runtime.start(
            session: "perf", code: listCommand, file: URL(fileURLWithPath: "/tmp/perf.js"),
            mode: .view, context: context)
        for _ in 0..<500 where recorder.trees.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        guard let first = recorder.trees.last else {
            print("FAIL no render", recorder.failures, recorder.logs.suffix(5))
            exit(1)
        }
        let screen = ExtensionScreen(tree: first, query: "")
        guard let bump = ExtensionScreen.actions(in: screen.actionPanel(forItemAt: 0)).first?.handler
        else {
            print("FAIL no Bump handler")
            exit(1)
        }
        var roundTrips: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<20 {
            let before = recorder.trees.count
            let start = clock.now
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                recorder.onRender = {
                    guard recorder.trees.count > before else { return }
                    recorder.onRender = nil
                    done.resume()
                }
                Task { await runtime.dispatch(session: "perf", handler: bump, payload: "[]") }
            }
            roundTrips.append(milliseconds(clock.now - start))
        }
        let jsSamples = recorder.logs.compactMap { line -> Double? in
            let parts = line.split(separator: " ")
            return parts.first == "js" ? Double(parts[1]) : nil
        }
        let whole = commit(0)
        let update = commit(1)
        print(
            "\(rowCount) rows: first commit \(whole.utf8.count) bytes, one-row update \(update.utf8.count) bytes"
        )
        report("JS setState → JSON handed to Swift", jsSamples)
        report("dispatch → tree delivered on main", roundTrips)
        report("decode the first commit", (0..<20).map { _ in time { _ = RenderTree(json: whole) } })
        guard let base = RenderTree(json: whole) else {
            print("FAIL first commit did not decode")
            exit(1)
        }
        report("collect its referenceable nodes", (0..<20).map { _ in time { _ = base.referenceableNodes } })
        let nodes = base.referenceableNodes
        report(
            "decode the update against it",
            (0..<20).map { _ in time { _ = try? RenderTree(json: update, reusing: nodes) } })
        runtime.shutdown()
    }

    static func commit(_ index: Int) -> String {
        let file = scratch.appendingPathComponent("commit-\(index).json")
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    // MARK: - Filtering

    static func filterCost() {
        guard
            let tree = RenderTree(json: commit(0))
        else {
            print("FAIL no captured tree")
            exit(1)
        }
        let typed = ["i", "it", "ite", "item", "item ", "item n", "item nu", "item 5", "item 50", "xq"]
        var perKeystroke: [Double] = []
        for _ in 0..<5 {
            for query in typed {
                perKeystroke.append(time { _ = ExtensionScreen(tree: tree, query: query) })
            }
        }
        report("filter \(rowCount) rows, folding every keystroke", perKeystroke)
        let index = ExtensionSearchIndex(tree)
        let reused: (RenderTree) -> ExtensionSearchIndex = { _ in index }
        var indexed: [Double] = []
        for _ in 0..<5 {
            for query in typed {
                indexed.append(time { _ = ExtensionScreen(tree: tree, query: query, searchIndex: reused) })
            }
        }
        report("build the search index", (0..<5).map { _ in time { _ = ExtensionSearchIndex(tree) } })
        report("filter \(rowCount) rows, index reused", indexed)
        let same = typed.allSatisfy {
            ExtensionScreen(tree: tree, query: $0)
                == ExtensionScreen(tree: tree, query: $0, searchIndex: reused)
        }
        print("reused index filters the same rows: \(same)")
        if !same { exit(1) }
    }

    // MARK: - Storage

    @MainActor
    static func storageCost() {
        for megabytes in [1, 5] {
            let storage = ExtensionStorage(directory: scratch.appendingPathComponent("storage-\(megabytes)"))
            let value = String(repeating: "x", count: 1024)
            for index in 0..<(megabytes * 1024) {
                storage.setCache(extension: "perf", namespace: "ns", key: "k\(index)", value: value)
            }
            storage.flushSynchronously()
            var onMain: [Double] = []
            var whole: [Double] = []
            for index in 0..<10 {
                storage.setCache(extension: "perf", namespace: "ns", key: "k0", value: "\(index)")
                onMain.append(time { storage.flush() })
                storage.flushSynchronously()
                storage.setCache(extension: "perf", namespace: "ns", key: "k0", value: "\(index)!")
                whole.append(time { storage.flushSynchronously() })
            }
            report("storage flush() on main, \(megabytes) MB", onMain)
            report("storage encode + write off main, \(megabytes) MB", whole)
        }
    }
}
