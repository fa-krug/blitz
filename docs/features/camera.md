# Camera

One camera, two surfaces. `Open Camera` is a launcher command that puts a live preview on screen,
mirrors it, switches between the Mac's cameras and copies a photo to the clipboard; `Scan QR Code`
opens the same panel to read a QR code and copy or open what it says. Calendar's pre-meeting preview
is the other surface, and it rides the same session, panel and stage — the join-specific controller
and footer are all that stay in [calendar.md](calendar.md).

## Invariants

- **Nothing runs until the command is run.** `CameraCoordinator` is `lazy` on `AppCore`, and
  `CameraSession.init` stores a `Purpose` and touches nothing else — no device, no discovery session,
  no TCC read. The camera permission prompt is raised by `start()`, from the gesture that asked for
  it, and never on launch.
- **The camera settles before the panel opens, and stops after it closes.** `start()` resolves access
  and blocks on `startRunning` first, then hands a settled `Feed` up — so the first frame is live
  video rather than a stage swapped out from under the user, and the TCC prompt never takes key from
  a panel already up. `stop()` runs from the fade-out's completion, so the camera light never
  outlives the panel but is never torn down under a visible one either. It also drops the
  `AVCaptureSession`, so every open builds its own: a reused session with no output of its own — the
  preview's — restarts to a black stage.
- **Escape, click-away and the shot all end the same way.** Every route goes through
  `CameraCoordinator.close()`, which drops the panel and stops the session. Taking a photo closes
  too — the command is done, so the camera goes out with it rather than idling for a second shot.
- **System UI is not a click away.** `CameraPanel` owns click-away for both surfaces and reports it
  as the same `.cancel` as Esc. Losing key counts, unless the window under the pointer sits at the
  Dock's level or above — the menu bar, what it drops down, the Dock — so reframing a video effect
  from Control Center keeps the feed live. The test is a window-server hit test, not screen
  geometry, so a display arranged above another or an auto-hidden menu bar cannot fool it. No
  further `resignKey` follows, so a global and a local mouse-down monitor wait for the next click
  outside the panel and system UI; they go once the panel is key again or leaves the screen.
  Running the command again hands key back to such a panel instead of doing nothing.
- **The preview and the photo are mirrored together.** Mirroring is `isVideoMirrored` on a connection
  — the preview layer's, and the photo output's at capture time — never a `scaleEffect` on the view,
  which would hand back a photo that is not what the user framed.
- **A photo reaches the clipboard as PNG.** The camera's own encoding is decoded and re-encoded off
  main, because `ClipboardManager` records `.png` and `.tiff` and nothing else.
- **A scan reads codes in the app process, one frame at a time.** `QRCodeMonitor` runs Vision's
  `DetectBarcodesRequest` on a frame only when no read is in flight, and drops every frame that
  arrives meanwhile. This is not the clipboard's text recognition, which leaves the process because
  it batches over a whole history: a scan is one small request per frame, only while the panel is up.
- **A scanned payload is never acted on unasked.** The footer shows it and waits; ↵ opens it when
  some app on the Mac claims its URL scheme and copies it otherwise. A `WIFI:` or plain-text code
  parses as a URL but has no handler, so it only ever offers Copy.
- **`AVCaptureSession` is not `Sendable`, and only `CaptureBox` crosses that line.** The blocking
  calls — `startRunning`, `stopRunning`, and the begin/commit around a device swap — run in
  `Task.detached` behind that one `@unchecked Sendable` box, which is private to `CameraSession.swift`.

## How it is put together

| Piece | Holds |
| --- | --- |
| `Service/CameraSession.swift` | access, start/stop, device cycling, the photo, and the box |
| `Service/QRCodeMonitor.swift` | the scan's frame delegate: one Vision read at a time, payloads out |
| `UI/CameraCoordinator.swift` | the standalone panel's lifecycle and mode, mirror state, the clipboard write |
| `UI/CameraView.swift` | the standalone surface: stage over a photo or a scan footer |
| `UI/CameraStage.swift` | the shared stage — the hosted preview layer, or why there is no video |
| `UI/CameraPanel.swift` | the shared borderless panel: ↵, Esc, click-away, cursor-screen centring |
| `UI/CameraButton.swift` | both footers' button: `ModalActionButtonStyle` plus a key-cap tooltip |

`Purpose` is the session's one knob. `.preview` is the cheap one Calendar takes — a `.medium` preset
and no output. `.capture` raises the preset to `.photo` and adds an `AVCapturePhotoOutput`, which is
the whole cost of being able to take a photo, and it is paid only by the command that does. `.scan`
takes `.high`, enough pixels for a code held at arm's length, and adds an `AVCaptureVideoDataOutput`
that discards late frames and feeds a `QRCodeMonitor`. The monitor hands each reader a fresh
`codes()` stream, because a cancelled `for await` ends its stream for good — a scan reopened inside
the fade reuses the running session but never the stream the closed panel cancelled.

`CameraCoordinator` keeps one session per mode — `.photo` on the `.capture` session, `.scan` on the
`.scan` one — because a purpose is fixed when the session is configured. `close()` stops the session
the closing panel used once the fade ends, unless a panel opened meanwhile is on that same session —
so switching mode inside the fade cannot leave a camera running, nor stop one under a live panel. The
newest code read wins: aiming at a second one replaces the first without reopening.

`CameraCoordinator` is `@Observable` and the view reads it directly, so toggling Mirror re-renders
through Observation rather than through a hand-reassigned `rootView`. `mirrored` lives on the
coordinator rather than in `AppSettings`: it is remembered for the launch, and a display preference
that grants nothing is not worth a settings key or a line in a backup.

With no video, the stage is an `EmptyResults` under `video.slash`. `.denied` adds **Open Privacy
Settings** (`Permissions.openCameraSettings`) — `start()` has already asked, so only Settings can undo
it — and `.noCamera` offers nothing, since no click fixes it. Opening Settings takes key, so the panel
closes behind it as it would on any click-away.

Switching cameras swaps the input inside one `beginConfiguration`/`commitConfiguration` while the
session keeps running, so the stage never blanks. The next open starts on the camera switched to,
unless it has been unplugged since. `Switch Camera` only appears when
`hasMultipleDevices` says the discovery session found more than one.

## Where it is reachable from

The launcher, as `CommandID.openCamera` and `CommandID.scanQRCode` — so each takes aliases and a
global shortcut like any other command, and hides with the `Command` category. It has no Settings pane and no enable switch: there
is nothing to configure and nothing to leave running.
