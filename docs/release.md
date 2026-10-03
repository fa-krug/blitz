# Release

How a build reaches a user. The local development loop is in [development.md](development.md);
the local signing identity is in [signing.md](signing.md). This is the same pipeline Pointa uses.

## Every push to `main` is a release

`.github/workflows/release.yml` runs on every push to `main` that touches more than Markdown or
`docs/`. One job on a `macos-26` runner:

1. **Build number.** `CFBundleVersion` is the workflow's run number, stamped into `Blitz/Info.plist`.
   Sparkle orders updates by it, so it only ever grows. The marketing version is `MARKETING_VERSION`
   in `project.yml` — bump it there when a release deserves a new one.
2. **Token.** `UPDATE_FEED_TOKEN` is written into `BlitzUpdateFeedToken` in `Info.plist`; it is what
   lets the shipped app download the private zip (see [features/updates.md](features/updates.md)).
3. **Archive and export** with the Developer ID identity of team `HS26J3YA63`, hardened runtime on,
   through `Scripts/developer-id-export-options.plist`.
4. **`Scripts/verify-signature.sh`** asserts the runtime flag on the app and on
   `Contents/Helpers/ClipboardTextHelper`, an intact seal, and an entitlement for every usage string.
5. **Notarize and staple** with an App Store Connect API key.
6. **Package** `Blitz-<build>.zip` with `ditto -c -k --keepParent --sequesterRsrc` — the only zip that
   keeps the code signature verifiable.
7. **Sign the update** with Sparkle 1.27.3's `sign_update` and the EdDSA private key.
8. **Publish.** The zip alone is force-pushed to this repo's `update-feed` branch, so the binary stays
   private. `Scripts/update-appcast.py` writes a one-item `appcast.xml` whose enclosure is the
   Contents API URL of that zip, and it is pushed to the public `fa-krug/blitz-updates` repo over SSH.
9. **GitHub Release** `build-<build>` with the zip attached, for a first install by hand.

There is a single channel; no beta, no DMG, no Homebrew cask. `Scripts/update-appcast-test.py`
covers the appcast writer: `python3 Scripts/update-appcast-test.py`.

## One-time setup

| Secret on this repo | What it is |
| --- | --- |
| `DEVELOPER_ID_CERT_P12` | base64 of the Developer ID Application `.p12` |
| `DEVELOPER_ID_CERT_PASSWORD` | its password |
| `AC_API_KEY_ID`, `AC_API_ISSUER_ID` | App Store Connect API key for `notarytool` |
| `AC_API_KEY_P8` | base64 of that key's `.p8` |
| `SPARKLE_ED_PRIVATE_KEY` | the EdDSA private key matching `SUPublicEDKey` in `Info.plist` |
| `UPDATE_FEED_TOKEN` | fine-grained PAT, **Contents: read-only** on this repo alone |
| `APPCAST_DEPLOY_KEY` | private half of a deploy key with write access on `fa-krug/blitz-updates` |

The public `fa-krug/blitz-updates` repo needs a `main` branch to push to. `SUPublicEDKey` is
Pointa's, so the same `SPARKLE_ED_PRIVATE_KEY` secret works for both apps; to give Blitz its own,
run Sparkle's `generate_keys`, replace the key in `Info.plist` and set the new private key.

The token ships inside every copy of the app, which is why it must be read-only and scoped to this
one repository.

## Pull request review

CodeRabbit reviews every PR against `.coderabbit.yaml`: it runs SwiftLint with `.swiftlint.yml`,
annotates the diff and applies the pre-merge checks. It is a reviewer, not a gate — it neither runs
the harnesses nor builds the app, so the whole bar in [testing.md](testing.md#definition-of-done) is
run locally before a PR is opened.
