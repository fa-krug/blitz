import AppKit
import SwiftUI

/// The first-launch wizard, built from the app's own controls; re-runnable as the Welcome Tour.
struct OnboardingView: View {
    @State private var step = OnboardingStep.first
    @State private var model = OnboardingModel()
    @State private var spotlight: SpotlightHandoffSession
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @Environment(HotKeyManager.self) private var hotKeys

    @State private var accessibilityTrusted = Permissions.isAccessibilityTrusted()

    static let width: CGFloat = 520
    /// Only until the first layout measures the real one, which is what the window then takes.
    static let initialSize = CGSize(width: width, height: 352)

    init(spotlight: SpotlightHandoffSession) {
        _spotlight = State(initialValue: spotlight)
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            hero
            stepContent
            footer
        }
        // Less on top: the title bar adds 32pt, and the lights must be cleared.
        .padding(.top, Theme.Spacing.xs)
        .padding([.horizontal, .bottom], Theme.Spacing.xxl)
        .frame(maxWidth: .infinity)
        // The ideal height, not the window's, so sizing to it converges instead of feeding back.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            core.onboardingCoordinator.fit(height: $0)
        }
        // Only the gradient reaches under the titlebar; the content stays in the safe area.
        .background(
            LinearGradient(
                colors: [Theme.Colors.sheen, Color.clear],
                startPoint: .top, endPoint: .center
            )
            .ignoresSafeArea()
        )
        // Onboarding's shortcut step has a recorder too, and it isn't inside a `SettingsPane`.
        .shortcutRecorderPopoverHost()
        .animation(.easeInOut(duration: 0.2), value: step)
        .animation(.easeInOut(duration: 0.2), value: spotlight.showsGuide)
        .onAppear {
            accessibilityTrusted = Permissions.isAccessibilityTrusted()
            spotlight.refresh()
        }
        .task {
            while !Task.isCancelled {
                let trusted = Permissions.isAccessibilityTrusted()
                if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // Coming back from System Settings is what activates Blitz again.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            spotlight.refresh()
        }
    }

    // MARK: - Hero (icon/glyph + title + subtitle)

    private var hero: some View {
        VStack(spacing: Theme.Spacing.md) {
            heroMark
            VStack(spacing: Theme.Spacing.xs) {
                Text(step.title)
                    .font(.title2.weight(.bold))
                Text(step.subtitle ?? readyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var heroMark: some View {
        if step == .shortcut {
            Image(nsImage: Self.appIcon)
                .resizable()
                .frame(width: 60, height: 60)
        } else {
            Image(systemName: heroSymbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(heroTint)
                .frame(width: 60, height: 60)
                .background(Circle().fill(heroTint.opacity(0.14)))
        }
    }

    private var heroSymbol: String {
        switch step {
        case .accessibility: "accessibility"
        case .raycastImport: "wand.and.stars"
        case .tips: "lightbulb"
        case .shortcut, .done: "checkmark"
        }
    }

    private var heroTint: Color {
        switch step {
        case .accessibility: .blue
        case .raycastImport: .orange
        case .tips: .purple
        case .shortcut, .done: .green
        }
    }

    private var readyMessage: String {
        if let caps = hotKeys.binding(for: .togglePalette)?.keycaps {
            return "Press \(caps.joined()) anytime to start using Blitz."
        }
        return "Blitz is ready. Set a shortcut in Settings to summon it."
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .shortcut: shortcutStep
        case .accessibility: accessibilityStep
        case .raycastImport: raycastStep
        case .tips: tipsStep
        case .done: doneStep
        }
    }

    private var shortcutStep: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            OnboardingCard {
                OnboardingRow(
                    title: "App Launcher",
                    subtitle: "Press this shortcut to open Blitz.",
                    systemImage: "magnifyingglass", tint: .blue
                ) {
                    HStack(spacing: Theme.Spacing.sm) {
                        commandSpaceControl
                        ShortcutRecorder(action: .togglePalette)
                    }
                }
                OnboardingDivider()
                OnboardingRow(
                    title: "Launch at login",
                    subtitle: "Start Blitz automatically when you log in.",
                    systemImage: "power", tint: .green
                ) {
                    Toggle("", isOn: $settings.launchAtLogin)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            if spotlight.showsGuide {
                OnboardingCard {
                    SpotlightShortcutGuide(holders: spotlight.holders)
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.vertical, Theme.Spacing.lg)
                }
            }
            if let owner = spotlight.conflictOwner {
                statusLine(
                    "⌘Space is already \(owner)'s shortcut. Change that one first.",
                    systemImage: "exclamationmark.triangle.fill", tint: .orange)
            } else {
                caption("You can change these anytime in Settings.")
            }
        }
    }

    /// Spotlight owns ⌘Space out of the box, and the recorder can't capture a chord macOS takes.
    @ViewBuilder
    private var commandSpaceControl: some View {
        if spotlight.launcherUsesCommandSpace, !spotlight.isLauncherBlocked {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("⌘Space opens Blitz")
        } else if !spotlight.launcherUsesCommandSpace {
            Button("Use ⌘Space") { spotlight.useCommandSpace() }
                .controlSize(.small)
                .disabled(spotlight.isWaiting)
        }
    }

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            OnboardingCard {
                OnboardingRow(
                    title: "Accessibility",
                    subtitle:
                        "Allows pasting clipboard items and expanded snippets into active apps.",
                    systemImage: "accessibility", tint: .blue
                ) {
                    statusBadge
                }
            }
            caption("Optional — you can enable this later in Settings › Permissions.")
        }
    }

    private var raycastStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            OnboardingCard {
                OnboardingRow(
                    title: "Raycast Export",
                    subtitle: model.fileSubtitle,
                    systemImage: "doc.badge.gearshape", tint: .orange
                ) {
                    Button("Choose…") { model.chooseFile() }.controlSize(.small)
                }
                OnboardingDivider()
                OnboardingRow(
                    title: "Passphrase",
                    subtitle: "The password you set when exporting from Raycast.",
                    systemImage: "key", tint: .gray
                ) {
                    RevealableSecureField(title: "Passphrase", text: $model.passphrase)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .onSubmit { model.run(core: core) }
                }
            }
            RaycastImportSelection(selection: $model.selection)
                .padding(.horizontal, Theme.Spacing.xs)
            if let status = model.status {
                importStatus(status)
            } else {
                caption("Optional — you can import later in Settings › Backup.")
            }
        }
    }

    /// Resolved through `PaletteTabAction`, so the Tab card names where Tab really goes.
    private var tips: [OnboardingTip] {
        let action = PaletteTabAction.resolve(
            mode: .launcher, aiEnabled: settings.aiEnabled,
            clipboardEnabled: settings.clipboardEnabled)
        return OnboardingTip.all(tab: OnboardingTip.TabDestination(action))
    }

    private var tipsStep: some View {
        let tips = tips
        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            OnboardingCard {
                ForEach(Array(tips.enumerated()), id: \.element) { index, tip in
                    if index > 0 { OnboardingDivider() }
                    OnboardingRow(
                        title: tip.title, subtitle: tip.message,
                        systemImage: Self.symbol(for: tip), tint: Self.tint(for: tip)
                    ) {
                        OnboardingKeycaps(keycaps: tip.keycaps)
                    }
                }
            }
            if tips.contains(where: \.offersAISettings) {
                Button("Turn on AI in Settings › AI") {
                    core.settingsCoordinator.showSettings(tab: .ai)
                }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.horizontal, Theme.Spacing.xs)
            }
        }
    }

    private static func symbol(for tip: OnboardingTip) -> String {
        switch tip {
        case .actions: "command"
        case .aliases: "character.cursor.ibeam"
        case .tab(.quickAI): "sparkles"
        case .tab(.clipboard): "doc.on.clipboard"
        case .tab(.nowhere): "arrow.right.to.line"
        }
    }

    private static func tint(for tip: OnboardingTip) -> Color {
        switch tip {
        case .actions: .blue
        case .aliases: .orange
        case .tab: .purple
        }
    }

    private var doneStep: some View {
        caption("Everything's ready. Hit Get Started to open the launcher.")
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Footer (step dots + navigation)

    private var footer: some View {
        VStack(spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(OnboardingStep.allCases, id: \.self) { page in
                    Circle()
                        .fill(page == step ? Color.primary : Color.primary.opacity(0.2))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
            HStack {
                if let previous = step.previous {
                    Button {
                        step = previous
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if showsSkip {
                    Button("Skip") { advance() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                if step == .raycastImport && model.importing {
                    Button {
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("Importing…")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(true)
                } else {
                    Button(primaryTitle, action: primaryAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(primaryDisabled)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var showsSkip: Bool {
        (step == .accessibility && !accessibilityTrusted)
            || (step == .raycastImport && !model.didImport)
    }

    private var primaryTitle: String {
        switch step {
        case .shortcut, .tips: "Continue"
        case .accessibility: accessibilityTrusted ? "Continue" : "Grant Access"
        case .raycastImport:
            if model.didImport {
                "Continue"
            } else if model.importing {
                "Importing…"
            } else {
                "Import"
            }
        case .done: "Get Started"
        }
    }

    private var primaryDisabled: Bool {
        step == .raycastImport && !model.didImport && !model.canImport
    }

    private func primaryAction() {
        switch step {
        case .accessibility where !accessibilityTrusted:
            Permissions.openAccessibilitySettings()
        case .raycastImport where !model.didImport:
            model.run(core: core)
        case .done:
            core.onboardingCoordinator.finishOnboarding()
        default:
            advance()
        }
    }

    private func advance() {
        step = step.next ?? OnboardingStep.last
    }

    // MARK: - Shared bits

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Theme.Spacing.xs)
    }

    @ViewBuilder
    private func importStatus(_ status: OnboardingModel.ImportStatus) -> some View {
        switch status {
        case .success(let message):
            statusLine(message, systemImage: "checkmark.circle.fill", tint: .green)
        case .failure(let message):
            statusLine(message, systemImage: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    private func statusLine(_ message: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Spacing.xs)
    }

    private var statusBadge: some View {
        HStack(spacing: Theme.Spacing.xs + 1) {
            Image(
                systemName: accessibilityTrusted
                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            Text(accessibilityTrusted ? "Granted" : "Not granted")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(accessibilityTrusted ? Color.green : Color.orange)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            Capsule().fill((accessibilityTrusted ? Color.green : Color.orange).opacity(0.14)))
    }

    // Read the bundle directly: the app icon is generic until LaunchServices registers.
    private static let appIcon: NSImage = {
        if let name = Bundle.main.infoDictionary?["CFBundleIconFile"] as? String,
            let url = Bundle.main.url(forResource: name, withExtension: "icns"),
            let image = NSImage(contentsOf: url)
        {
            return image
        }
        return NSApp.applicationIconImage
    }()
}

/// The import step's state and async call, off the view so the body stays declarative.
@MainActor
@Observable
final class OnboardingModel {
    enum ImportStatus {
        case success(String)
        case failure(String)
    }

    var file: URL?
    var passphrase = ""
    var importing = false
    var status: ImportStatus?
    var selection: RaycastImportOptions = .all
    var isRaycastExport = false

    var canImport: Bool {
        isRaycastExport && !passphrase.isEmpty && !selection.isEmpty && !importing
    }
    var didImport: Bool {
        if case .success = status { return true }
        return false
    }

    var fileSubtitle: String {
        guard let name = file?.lastPathComponent else {
            return "Choose a .rayconfig file exported from Raycast v2.0 or newer."
        }
        return "\(name) — \(isRaycastExport ? "Raycast export" : "not a Raycast export")"
    }

    func chooseFile() {
        guard let url = BackupActions.pickRaycastFile() else { return }
        file = url
        isRaycastExport = BackupActions.isRaycastExport(url)
        status = nil
    }

    func run(core: AppCore) {
        guard canImport, let file else { return }
        importing = true
        status = nil
        Task {
            defer { importing = false }
            do {
                let outcome = try await BackupActions.importRaycast(
                    core: core, file: file, passphrase: passphrase, options: selection)
                status = .success(BackupActions.raycastText(outcome))
                passphrase = ""
            } catch {
                status = .failure(error.localizedDescription)
            }
        }
    }
}
