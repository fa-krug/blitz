# Release

How a build reaches a user. The local development loop is in [development.md](development.md);
the signing identities are in [signing.md](signing.md).

## Every push to `main` is a release

`.github/workflows/release.yml` runs on every push to `main` that touches more than Markdown or
`docs/`. One job on a `macos-26` runner:

1. **Version.** `MAJOR.MINOR` comes from `MARKETING_VERSION` in `project.yml`; the patch is the
   workflow's run number, so each release is strictly newer than the last and the updater offers
   it. `CURRENT_PROJECT_VERSION` is the run number too. Bump `MAJOR.MINOR` in `project.yml` when a
   release deserves it.
2. **Sign.** The release identity from `SIGNING_P12_BASE64` / `SIGNING_P12_PASSWORD` is imported into
   a throwaway keychain. It is the same `Blitz Self-Signed` identity every release, which keeps the
   Accessibility grant alive and is what the updater trusts.
3. **Build** a universal (`arm64 x86_64`) Release `Blitz.app`, and assert both slices on the app and
   on `Contents/Helpers/ClipboardTextHelper`.
4. **`Scripts/verify-signature.sh`** asserts the hardened runtime on both binaries, an intact seal,
   no `get-task-allow`, and an entitlement for every usage string.
5. **Package** `Blitz-Universal-<version>.zip` with `ditto -c -k --keepParent --sequesterRsrc` — the
   only zip that keeps the code signature verifiable.
6. **Publish** a GitHub Release `v<version>` with that zip and GitHub's generated changelog.

The in-app updater reads those releases directly; see [features/updates.md](features/updates.md).
There is one channel: no beta, no DMG, no Homebrew cask.

## One-time setup

Two secrets, created by the one command in [signing.md §2](signing.md#2-create-the-release-identity-once):
`SIGNING_P12_BASE64` and `SIGNING_P12_PASSWORD`. Without them the workflow stops at the signing step.

## Not notarized

Releases are self-signed, so a downloaded copy is quarantined and Gatekeeper refuses it until the
flag is cleared once: `xattr -dr com.apple.quarantine /Applications/Blitz.app`. Updates installed by
the app never need it. The updater already trusts Developer ID builds from team `HS26J3YA63`, so
notarizing later is a change to `release.yml` alone — see
[signing.md](signing.md#the-developer-id-migration).

## Pull request review

CodeRabbit reviews every PR against `.coderabbit.yaml`: it runs SwiftLint with `.swiftlint.yml`,
annotates the diff and applies the pre-merge checks. It is a reviewer, not a gate — it neither runs
the harnesses nor builds the app, so the whole bar in [testing.md](testing.md#definition-of-done) is
run locally before a PR is opened.
