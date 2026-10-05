# Signing

Blitz is always signed with a **stable identity**. Keeping the _same_ identity on every build is what
makes macOS remember the Accessibility permission across rebuilds and updates — ad-hoc signing
changes every build and macOS forgets the grant. There are two:

- **local builds** (§1) sign with a self-signed `Blitz Self-Signed` identity in your login keychain,
  and
- **releases** (§2) sign with the team's **Developer ID Application** certificate (team
  `HS26J3YA63`) and are notarized and stapled. The certificate and the notary API key live only in
  GitHub secrets the release workflow reads.

What the updater trusts is [below](#what-the-updater-trusts).

## 1. Create the `Blitz Self-Signed` identity (once)

Run these in a terminal. They generate a self-signed code-signing certificate and import it into your
login keychain:

```sh
# Generate a self-signed code-signing cert (10-year, codeSigning use).
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout /tmp/tc-key.pem -out /tmp/tc-cert.pem \
  -subj "/CN=Blitz Self-Signed" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# Bundle it as a .p12 (the non-empty password keeps `security import` happy).
openssl pkcs12 -export -inkey /tmp/tc-key.pem -in /tmp/tc-cert.pem \
  -name "Blitz Self-Signed" -out /tmp/tc.p12 -passout pass:blitz

# Import into the login keychain so codesign can use it without prompting.
security import /tmp/tc.p12 -k ~/Library/Keychains/login.keychain-db \
  -P blitz -A -T /usr/bin/codesign

rm -f /tmp/tc-key.pem /tmp/tc-cert.pem /tmp/tc.p12
```

Verify it's there:

```sh
security find-identity -p codesigning | grep "Blitz Self-Signed"
```

Now local builds (Xcode, VS Code F5, `xcodebuild`) sign with it, and you grant Accessibility once.

## 2. Give the release workflow its secrets (once)

Five GitHub secrets, set with `gh` (authed with admin on the repo). Without them the workflow stops
at the step that needs them.

1. **The Developer ID certificate.** In Keychain Access, under *login › My Certificates*, export
   `Developer ID Application: Sascha Krug (HS26J3YA63)` — certificate and private key together — as
   a `.p12` with a password.
2. **The notary API key.** In App Store Connect, *Users and Access › Integrations › App Store
   Connect API › Team Keys*, generate a key with **Developer** access and download its
   `AuthKey_<key-id>.p8` (Apple offers the download once). The issuer ID is shown above the key list.
3. **Upload them.** The script imports the `.p12` the way the release job does, asks Apple's notary
   service to accept the key, and only then sets all five secrets:

   ```sh
   ./Scripts/set-release-secrets.sh DeveloperID.p12 AuthKey_<key-id>.p8 <issuer-id>
   ```

Delete both files afterwards, or keep them only in a password manager.

**Renewing the certificate** is a fresh export and another run of the script. The updater and users'
Accessibility grants pin the team, not the certificate, so nothing else changes. An expired
certificate fails the release at the build step; builds it already signed stay valid, because they
carry a secure timestamp.

## Hardened runtime

**Release only**, on both targets: `ENABLE_HARDENED_RUNTIME: YES`, which notarization requires. Debug
must stay without it — hardened runtime turns on library validation, and Xcode's
`Blitz Dev.debug.dylib` is refused at launch because a self-signed identity carries no Team ID for
the loader to match. The flag is not part of the designated requirement, so turning it on costs no
Accessibility grant. Each entitlement in `Blitz/Blitz.entitlements` earns its place:

| Entitlement | Without it |
| --- | --- |
| `com.apple.security.cs.allow-jit` | JavaScriptCore cannot JIT, and every extension command runs on the interpreter |
| `com.apple.security.automation.apple-events` | Every Apple event is refused with `-1743` and no prompt — Get Info, the Finder selection an extension reads, and the System Events–driven system actions all die silently |
| `com.apple.security.device.camera` | The camera prompt never appears and access resolves as denied |
| `com.apple.security.personal-information.calendars` | `requestFullAccessToEvents()` returns `false` in milliseconds with no dialog, and Blitz never appears under System Settings › Calendars |

**A usage string is not enough under the hardened runtime.** `tccd` checks the matching entitlement
*before* it prompts, and without it logs "requires entitlement … but it is missing" and denies on the
spot — no dialog, no error, status still `.notDetermined`. A grant saved before the hardened runtime
arrived keeps working, since `tccd` does not re-check it, which is why this surfaces only on fresh
installs. Adding a protected resource therefore means adding its usage string *and* its entitlement.

`RESOURCE_ENTITLEMENTS` in `Scripts/verify-signature.sh` maps every protected resource's usage string
to its entitlement, including resources Blitz does not use. That grants nothing — only
`Blitz.entitlements` does, and a row whose usage string `Info.plist` doesn't declare is skipped. It
is there so a future feature that adds the usage string but forgets the entitlement fails the release
instead of shipping a prompt that can never appear.

Nothing else is needed: the only `dlopen` is Apple's own IOBluetooth, so library validation is left
on, and `node`, `ray` and shell commands are separate processes it never reaches. Bluetooth has no
hardened-runtime entitlement.

`./Scripts/verify-signature.sh <path-to-.app>` asserts all of this — the runtime flag on the app *and*
on `Contents/Helpers/ClipboardTextHelper`, an intact nested seal, no `get-task-allow`, and an
entitlement for every usage string `Info.plist` declares. The release job runs it before packaging:
a nested binary missing the runtime flag is the most common notarization rejection, and a usage string
missing its entitlement ships a permission that can never be granted.

## What the updater trusts

`BundleSignature` accepts a staged bundle only when its seal validates, nested helper included, and
it satisfies the Developer ID requirement for team `HS26J3YA63`. The release workflow checks the
built app against that same string, read straight from `BundleSignature.swift`, before notarizing.

The requirement pins the team rather than the certificate, so a Developer ID renewal strands nobody.
It deliberately omits the `notarized` keyword — that resolves a ticket through `syspolicyd` or the
network, and the updater verifies in a cache directory Gatekeeper has never assessed, so an offline
Mac would refuse a bundle the chain already proves is ours.

Every self-signed release already shipped this requirement, so each installed copy updates to a
Developer ID build on its own. That first update changes the app's designated requirement, which the
existing Accessibility and Input Monitoring grants no longer match, so both are granted once more;
after that, renewals and updates keep them.

## Quarantine (separate from signing)

macOS quarantines anything downloaded from the internet. A release is notarized with its ticket
stapled into the bundle, so Gatekeeper opens a quarantined copy after its usual one-time
confirmation, with no "unverified developer" block and no network lookup.

Updates never touch it: an archive Blitz downloads itself is not quarantined.
