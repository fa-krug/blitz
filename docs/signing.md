# Signing

Blitz is signed with **stable self-signed identities** called `Blitz Self-Signed`. Keeping the
_same_ identity on every build is what makes macOS remember the Accessibility permission across
rebuilds and updates — ad-hoc signing changes every build and macOS forgets the grant. It is also
what the updater checks before it installs a release.

There are two, with the same name and separate keys:

- **your local one** (§1), in your login keychain, for dev builds, and
- **the release one** (§2), which lives only in two GitHub secrets the release workflow imports.

Releases are not notarized. How a later switch to Developer ID works is [below](#the-developer-id-migration).

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

## 2. Create the release identity (once)

Run on any machine with `openssl` and `gh` (authed with admin on the repo). Nothing touches a
keychain, so it works over SSH too:

```sh
mkdir -p ~/blitz-signing && chmod 700 ~/blitz-signing && cd ~/blitz-signing && \
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout key.pem -out cert.pem \
  -subj "/CN=Blitz Self-Signed" -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" && \
openssl rand -base64 24 | tr -d '\n' > password.txt && \
openssl pkcs12 -export -inkey key.pem -in cert.pem -name "Blitz Self-Signed" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
  -out release.p12 -passout file:password.txt && rm key.pem cert.pem && \
base64 < release.p12 | tr -d '\n' | gh secret set SIGNING_P12_BASE64 --repo fa-krug/blitz && \
gh secret set SIGNING_P12_PASSWORD --repo fa-krug/blitz < password.txt
```

The 3DES/SHA-1 bundle is deliberate: it is the PKCS#12 flavour every macOS `security import` reads.

**Keep `~/blitz-signing/` backed up** (a password manager is fine). Every installed copy trusts
only this identity: if it is lost and replaced, the updater refuses the next release, and every user
has to download it by hand and grant Accessibility again.

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

## The Developer ID migration

`BundleSignature` already accepts a bundle signed under Apple's Developer ID chain by team
`HS26J3YA63`, even though releases are self-signed. That is deliberate: the updater compares
signatures before it installs, so the code that trusts the new identity has to reach users *before*
the first build carrying it. Until then it accepts the running app's own leaf, which is how every
self-signed release installs.

The requirement pins the team rather than the certificate, so a Developer ID renewal strands nobody.
It deliberately omits the `notarized` keyword — that resolves a ticket through `syspolicyd` or the
network, and the updater verifies in a cache directory Gatekeeper has never assessed, so an offline
Mac would refuse a bundle the chain already proves is ours.

Switching means signing and notarizing in `release.yml` with the Developer ID certificate and an
App Store Connect API key; `project.yml` keeps signing local builds with `Blitz Self-Signed`.

## Quarantine (separate from signing)

macOS quarantines anything downloaded from the internet, and Gatekeeper blocks a self-signed app
with an "unverified developer" warning. The first copy is cleared once by hand:

```sh
xattr -dr com.apple.quarantine /Applications/Blitz.app
```

Updates never need it: an archive Blitz downloads itself is not quarantined.
