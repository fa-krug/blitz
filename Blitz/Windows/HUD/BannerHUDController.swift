import AppKit
import SwiftUI

/// A done thing with one way to it or back from it, offered only until the banner fades.
@MainActor
final class BannerHUDController {
    private let presenter: HUDPresenter
    private let settings: AppSettings
    /// Set once its action runs, so the pointer leaving cannot revive a banner that is fading.
    private var isClosing = false

    init(settings: AppSettings) {
        self.settings = settings
        presenter = HUDPresenter(
            anchor: .edgeInset(Theme.Size.hudEdgeOffset),
            dwell: Theme.Duration.bannerHUD,
            screen: { settings.openOnCursorScreen ? .underCursor : .primary })
    }

    func show(
        title: String, detail: String, symbol: String, actionTitle: String,
        action: @escaping () -> Void
    ) {
        isClosing = false
        let banner = BannerHUDView(
            title: title, detail: detail, symbol: symbol, actionTitle: actionTitle,
            onAction: { [weak self] in
                self?.isClosing = true
                self?.presenter.dismiss()
                action()
            },
            onHover: { [weak self] hovering in
                guard let self, !isClosing else { return }
                // Reading it, or reaching for its button, must not race the fade.
                if hovering { presenter.hold() } else { presenter.extend() }
            })
        presenter.show(banner.environment(\.metrics, metrics), interactive: true)
    }

    func dismiss() {
        presenter.dismiss()
    }

    private var metrics: InterfaceMetrics { settings.interfaceSize.metrics }
}
