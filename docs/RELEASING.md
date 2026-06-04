# Releasing BigEdit

BigEdit is distributed as a **signed, notarized DMG** built by GitHub Actions
(`.github/workflows/release.yml`). A notarized build installs and opens on any
Mac without the Gatekeeper "unidentified developer" warning.

- **Bundle identifier:** `io.maendeleo.BigEdit`
- **Architecture:** Apple Silicon (arm64) only
- **Notarization auth:** App Store Connect API key
- **Minimum macOS:** 13.0

## One-time setup: GitHub secrets

The release workflow needs five repository secrets
(**Settings → Secrets and variables → Actions → New repository secret**).

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_CERT_P12_BASE64` | Your *Developer ID Application* certificate + private key, exported as a `.p12`, then base64-encoded. |
| `DEVELOPER_ID_CERT_PASSWORD` | The password you set when exporting the `.p12`. |
| `APP_STORE_CONNECT_KEY_ID` | The Key ID of your App Store Connect API key. |
| `APP_STORE_CONNECT_ISSUER_ID` | The Issuer ID shown above the keys list in App Store Connect. |
| `APP_STORE_CONNECT_PRIVATE_KEY` | The full contents of the `AuthKey_XXXX.p8` file (paste the text, including the `-----BEGIN/END PRIVATE KEY-----` lines). |

### Exporting the Developer ID certificate (`.p12`)

1. In **Keychain Access**, find your **Developer ID Application: …** certificate
   (it must have its private key — expand the disclosure triangle to confirm).
2. Right-click the certificate → **Export…** → save as `DeveloperID.p12`,
   and set an export password. Use that password for
   `DEVELOPER_ID_CERT_PASSWORD`.
3. Base64-encode it for the secret value:
   ```sh
   base64 -i DeveloperID.p12 | pbcopy
   ```
   Paste the clipboard into `DEVELOPER_ID_CERT_P12_BASE64`.

> If you don't yet have the certificate: in the Apple Developer portal create a
> **Developer ID Application** certificate (Certificates → +), download it,
> double-click to add it to Keychain Access, then export as above.

### Creating the App Store Connect API key (`.p8`)

1. Go to <https://appstoreconnect.apple.com> → **Users and Access → Integrations
   → App Store Connect API**.
2. Create a key with the **Developer** role (sufficient for notarization).
3. Note the **Key ID** (`APP_STORE_CONNECT_KEY_ID`) and the **Issuer ID**
   (`APP_STORE_CONNECT_ISSUER_ID`).
4. Download the `AuthKey_XXXXXXXX.p8` (Apple lets you download it **once**).
   Paste its full text into `APP_STORE_CONNECT_PRIVATE_KEY`.

## Cutting a release

1. Make sure `main` is green (the **CI** workflow runs build + tests).
2. Tag the commit and push the tag:
   ```sh
   git tag v1.2.3
   git push origin v1.2.3
   ```
3. The **Release** workflow then:
   - runs the tests,
   - builds the arm64 app and signs it with the hardened runtime,
   - packages a DMG (with an `/Applications` drag-install shortcut) and signs it,
   - submits the DMG to Apple's notary service and waits for the result,
   - staples the notarization ticket,
   - creates a GitHub Release named **BigEdit 1.2.3** with the
     `BigEdit-1.2.3.dmg` attached and auto-generated notes.

The marketing version comes from the tag (`v1.2.3` → `1.2.3`); the build number
is the workflow run number (monotonically increasing, as Apple requires).

### Dry run without publishing

Trigger **Release** manually from the **Actions** tab (workflow_dispatch),
optionally entering a version. It builds, signs, and notarizes, then uploads the
DMG as a **build artifact** instead of creating a public Release — handy for
verifying the signing pipeline end-to-end.

## Building locally

```sh
# Unsigned bundle (normal local development):
./make-app.sh && open BigEdit.app

# Signed bundle + DMG (needs your Developer ID in the login keychain):
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./make-app.sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/make-dmg.sh
```

Find your exact identity string with:
```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

## Verifying a built DMG

```sh
xcrun stapler validate BigEdit-1.2.3.dmg          # ticket is stapled
spctl -a -t open --context context:primary-signal -vvv BigEdit-1.2.3.dmg
codesign --verify --strict --verbose=2 /Volumes/BigEdit/BigEdit.app
```
