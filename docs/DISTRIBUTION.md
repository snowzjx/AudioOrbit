# Developer ID and GitHub release setup

AudioOrbit is distributed directly as a Developer ID-signed and Apple-notarized ZIP. It is not submitted to the Mac App Store. The release bundle identifier is `me.snowzjx.AudioOrbit` and the Apple Developer Team ID is `A47Y4XPLXR`.

Apple requires a Developer ID Application signature, Hardened Runtime, a secure timestamp and notarization for newly distributed macOS software. AudioOrbit does not currently use capabilities that require a Developer ID provisioning profile.

## 1. Apple account setup

1. Confirm the Apple Developer Program membership is active.
2. In **Certificates, Identifiers & Profiles**, optionally register the explicit App ID `me.snowzjx.AudioOrbit`. This is recommended for a stable product identity and future capabilities, although the current direct build does not need a provisioning profile.
3. Confirm Keychain Access contains `Developer ID Application: Junxue ZHANG (A47Y4XPLXR)` with its private key.
4. Confirm that you have a **team** App Store Connect API key, its Key ID, its Issuer ID and the downloaded `AuthKey_<KEY_ID>.p8` private key. AudioOrbit uses this key for notarization; no app-specific password is required. Individual App Store Connect API keys cannot authenticate `notarytool`.

Changing from the old development bundle identifier causes macOS to treat AudioOrbit as a new app. Remove any old AudioOrbit entries from **Privacy & Security → Accessibility** and **Screen & System Audio Recording**, then grant the new signed build access once.

## 2. Store local notarization credentials

Run this command in Terminal, replacing the three placeholders with the existing team-key values used for RelatedWorks:

```sh
xcrun notarytool store-credentials AudioOrbit-Notary \
  --key "/secure/path/AuthKey_YOUR_KEY_ID.p8" \
  --key-id "YOUR_KEY_ID" \
  --issuer "YOUR_ISSUER_UUID"
```

`notarytool` validates the API key before saving the credentials in Keychain. Keep the `.p8` file private and outside the repository. Apple permits downloading a private key only once; if the existing file was lost, revoke that key and create a new team key in **App Store Connect → Users and Access → Integrations → Team Keys**.

## 3. Build and notarize locally

From the repository root:

```sh
AUDIOORBIT_VERSION=0.1.0 scripts/build-release.sh
scripts/notarize-release.sh
```

The final artifacts are:

- `build/AudioOrbit.zip` — contains the stapled application.
- `build/AudioOrbit.zip.sha256` — checksum for the public download.
- `build/notary-result.json` — Apple submission result for release evidence.

The scripts verify the signature, notarization ticket and Gatekeeper assessment. Always install the ZIP on a separate account or Mac before publishing it.

## 4. Configure GitHub Actions secrets

Export only the Developer ID Application certificate and its private key from Keychain Access as a password-protected `.p12`. Add these repository Actions secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Base64 text of the exported Developer ID `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | Password chosen while exporting the `.p12` |
| `MACOS_TEAM_ID` | `A47Y4XPLXR` |
| `APPSTORE_API_KEY_P8` | Base64 text of the team App Store Connect `.p8` key |
| `APPSTORE_API_KEY_ID` | Team API Key ID |
| `APPSTORE_API_ISSUER_ID` | Team API Issuer ID |

Create the base64 value locally:

```sh
base64 -i DeveloperIDApplication.p12 | pbcopy
```

Paste the clipboard into the `MACOS_CERTIFICATE_P12` secret. Encode the API key the same way and paste that value into `APPSTORE_API_KEY_P8`:

```sh
base64 -i AuthKey_YOUR_KEY_ID.p8 | pbcopy
```

Securely delete temporary certificate exports when they are no longer needed. Keep the original API key in secure storage. GitHub's automatically generated `GITHUB_TOKEN` creates the release; no personal access token is required.

## 5. Publish a GitHub release

After the release commit is on the intended branch, create and push a semantic version tag:

```sh
git tag -a v0.1.0 -m "AudioOrbit 0.1.0"
git push origin v0.1.0
```

The tagged workflow runs all tests, archives and signs the app, submits it to Apple, prints the notarization log on rejection, staples the accepted ticket, runs Gatekeeper verification and creates the GitHub Release with the final ZIP and checksum.

GitHub Releases follow repository visibility. The current AudioOrbit repository is public, so its release ZIP and checksum will be publicly downloadable. If the repository is made private later, only users with repository access will be able to download them.

## 6. Release evidence

Keep the workflow URL, tag, commit, SHA-256 checksum and Apple submission ID with the completed `RELEASE_CHECKLIST.md`. Never commit certificates, private keys, Apple credentials, exported support reports or notarization authentication files.
