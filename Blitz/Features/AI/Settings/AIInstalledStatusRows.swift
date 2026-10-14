import AppKit
import SwiftUI

/// An installed tool's Overview: checking, ready, sign-in required, missing or failed.
struct AIInstalledStatusRows: View {
    @Environment(AppCore.self) private var core
    @Environment(CodexSubscriptionManager.self) private var subscription
    @Environment(InstalledAIManager.self) private var installedAI

    let kind: InstalledAIKind

    var body: some View {
        if kind == .codex {
            codexRows
        } else {
            installedRows
        }
    }

    @ViewBuilder
    private var codexRows: some View {
        switch subscription.phase {
        case .idle, .starting:
            checkingRow("Codex")
        case .signedOut:
            signInRow(check: { subscription.refresh() })
        case .connected:
            LabeledContent {
                Button("Refresh") { subscription.refresh() }
            } label: {
                Text("Ready")
                Text(AIProviderRoute.modelCount(subscription.models.count) + " available")
            }
            if let account = subscription.account {
                LabeledContent {
                    Text(account.planTitle == "API key" ? "Codex API key" : "ChatGPT \(account.planTitle)")
                        .foregroundStyle(.secondary)
                } label: {
                    Text("Account")
                    if let email = account.email { redacted(email) }
                }
            }
            if let limits = subscription.rateLimits {
                if let primary = limits.primary { usageRow(primary, fallbackTitle: "Primary window") }
                if let secondary = limits.secondary {
                    usageRow(secondary, fallbackTitle: "Secondary window")
                }
            }
            if let executable = subscription.executable { commandRow(executable) }
        case .unavailable(let message):
            LabeledContent {
                HStack(spacing: Theme.Spacing.sm) {
                    Button("Install Codex CLI…") { NSWorkspace.shared.open(InstalledAIKind.codex.installURL) }
                    Button("Check Again") { subscription.refresh() }
                }
                .fixedSize()
            } label: {
                Text("Not installed")
                Text(message)
            }
        case .failed(let message):
            failedRow(message, retry: { subscription.refresh() })
        }
    }

    @ViewBuilder
    private var installedRows: some View {
        let status = installedAI.status(for: kind)
        switch status.phase {
        case .idle, .checking:
            checkingRow(kind.title)
        case .ready:
            LabeledContent {
                Button("Refresh") { installedAI.refresh(kind: kind) }
            } label: {
                Text("Ready")
                Text(AIProviderRoute.modelCount(status.models.count) + " available")
            }
            if let account = status.account {
                LabeledContent {
                    if let plan = account.planTitle {
                        Text("\(kind.title) \(plan)").foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Account")
                    if let email = account.email { redacted(email) }
                }
            }
        case .signInRequired:
            signInRow(check: { installedAI.refresh(kind: kind) })
        case .notInstalled:
            LabeledContent {
                HStack(spacing: Theme.Spacing.sm) {
                    Button("Install…") { NSWorkspace.shared.open(kind.installURL) }
                    Button("Check Again") { installedAI.refresh(kind: kind) }
                }
                .fixedSize()
            } label: {
                Text("Not installed")
                Text("Blitz could not find the \(kind.command) command.")
            }
        case .failed(let message):
            failedRow(message, retry: { installedAI.refresh(kind: kind) })
        }
        if let executable = status.executable { commandRow(executable) }
    }

    private func redacted(_ email: String) -> some View {
        RedactedText(
            value: email,
            revealHelp: "Click to reveal the signed-in account",
            hideHelp: "Click to hide the signed-in account")
    }

    private func commandRow(_ executable: URL) -> some View {
        LabeledContent("Command") {
            Text((executable.path as NSString).abbreviatingWithTildeInPath)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func checkingRow(_ title: String) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            ProgressView().controlSize(.small)
            Text("Checking \(title)…").foregroundStyle(.secondary)
        }
    }

    private func signInRow(check: @escaping () -> Void) -> some View {
        LabeledContent {
            HStack(spacing: Theme.Spacing.sm) {
                Button("Copy Sign-In Command") { copySignInCommand() }
                Button("Check Again", action: check)
            }
            .fixedSize()
        } label: {
            Text("Sign in required")
            Text("Run \(kind.signInCommand) in Terminal, then check again.")
        }
    }

    private func failedRow(_ message: String, retry: @escaping () -> Void) -> some View {
        LabeledContent {
            Button("Try Again", action: retry)
        } label: {
            Label("Check failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
        }
    }

    private func usageRow(
        _ window: ChatGPTSubscription.UsageWindow, fallbackTitle: String
    ) -> some View {
        LabeledContent {
            HStack(spacing: Theme.Spacing.md) {
                ProgressView(value: Double(window.remainingPercent), total: 100)
                    .frame(width: Theme.Size.aiUsageBar)
                Text("\(window.remainingPercent)% left")
                    .monospacedDigit()
            }
        } label: {
            Text(usageTitle(window, fallback: fallbackTitle))
            if let reset = window.resetsAt {
                Text("Resets \(reset, style: .relative)")
            }
        }
    }

    private func usageTitle(
        _ window: ChatGPTSubscription.UsageWindow, fallback: String
    ) -> String {
        guard let minutes = window.durationMinutes else { return fallback }
        if minutes >= 1_440 { return "\(minutes / 1_440)-day window" }
        if minutes >= 60 { return "\(minutes / 60)-hour window" }
        return "\(minutes)-minute window"
    }

    private func copySignInCommand() {
        Paster.copyPlainText(kind.signInCommand)
        core.showMessage("Copied \(kind.signInCommand)")
    }
}
