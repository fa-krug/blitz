import SwiftUI

/// The standalone camera: a live stage over a footer for a photo, or for the QR code it read.
struct CameraView: View {
    let coordinator: CameraCoordinator

    var body: some View {
        VStack(spacing: 0) {
            CameraStage(feed: coordinator.feed, mirrored: coordinator.mirrored)
                .frame(
                    width: Theme.Size.cameraStage.width,
                    height: Theme.Size.cameraStage.height)
            Group {
                switch coordinator.mode {
                case .photo: photoFooter
                case .scan: scanFooter
                }
            }
            .padding(Theme.Spacing.xl)
        }
        .frame(width: Theme.Size.cameraStage.width)
        .background(Theme.Colors.panelScrim)
        .background(GlassEffectView())
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.dialog, style: .continuous))
    }

    private var isLive: Bool {
        if case .live = coordinator.feed { return true }
        return false
    }

    private var photoFooter: some View {
        HStack(spacing: Theme.Spacing.md) {
            if isLive {
                CameraButton(
                    title: "Mirror", emphasis: coordinator.mirrored ? .primary : .secondary
                ) {
                    coordinator.mirrored.toggle()
                }
                switchCameraButton
            }
            Spacer(minLength: Theme.Spacing.md)
            closeButton
            if isLive {
                CameraButton(title: "Take Photo", keyCap: "↵") { coordinator.takePhoto() }
            }
        }
    }

    private var scanFooter: some View {
        HStack(spacing: Theme.Spacing.md) {
            if let scanned = coordinator.scanned {
                Text(scanned.payload)
                    .font(Theme.Typography.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                closeButton
                if scanned.url != nil {
                    CameraButton(title: "Copy", emphasis: .secondary) { coordinator.copyScanned() }
                    CameraButton(title: "Open", keyCap: "↵") { coordinator.openScanned() }
                } else {
                    CameraButton(title: "Copy", keyCap: "↵") { coordinator.copyScanned() }
                }
            } else {
                if isLive {
                    Text("Point the camera at a QR code")
                        .font(Theme.Typography.rowTrailing)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                    switchCameraButton
                }
                Spacer(minLength: Theme.Spacing.md)
                closeButton
            }
        }
    }

    @ViewBuilder private var switchCameraButton: some View {
        if coordinator.canSwitchCamera {
            CameraButton(title: "Switch Camera", emphasis: .secondary) {
                coordinator.switchCamera()
            }
        }
    }

    private var closeButton: some View {
        CameraButton(title: "Close", keyCap: "esc", emphasis: .secondary) { coordinator.close() }
    }
}
