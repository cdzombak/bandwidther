# Codesigning Setup

The GitHub Actions workflow codesigns `Bandwidther.app` using a Developer ID Application certificate before packaging it into the DMG. This document explains the one-time setup required to make it work.

## Prerequisites

- An [Apple Developer Program](https://developer.apple.com/programs/) membership
- A **Developer ID Application** certificate (used for distributing apps outside the Mac App Store)

## Step 1: Create or export the signing certificate

If you don't already have a Developer ID Application certificate:

1. Open Xcode > Settings > Accounts > select your team > Manage Certificates.
2. Click **+** and choose **Developer ID Application**.

To export it as a `.p12` file:

1. Open **Keychain Access**.
2. Find the certificate named "Developer ID Application: Your Name (TEAMID)".
3. Expand it to reveal the private key.
4. Select **both** the certificate and the private key, right-click, and choose **Export 2 items…**
5. Save as a `.p12` file and set a password when prompted.

## Step 2: Get the certificate identity

Run the following to find your signing certificate's SHA-1 fingerprint:

```bash
security find-identity -v -p codesigning
```

Look for the line containing "Developer ID Application". The 40-character hex string at the beginning is the certificate identity you need.

## Step 3: Base64-encode the certificate

```bash
base64 -i YourCertificate.p12 | pbcopy
```

This copies the base64-encoded certificate to your clipboard.

## Step 4: Create an app-specific password for notarization

Release builds are notarized with Apple before being attached to GitHub Releases. This requires an app-specific password:

1. Sign in at [appleid.apple.com](https://appleid.apple.com/).
2. Go to **Sign-In and Security > App-Specific Passwords**.
3. Generate a new password and label it something like "Bandwidther CI Notarization".
4. Copy the generated password.

You will also need your **Apple Developer Team ID**, which you can find at [developer.apple.com/account](https://developer.apple.com/account) under Membership Details.

## Step 5: Configure GitHub repository secrets

Go to the repository's **Settings > Secrets and variables > Actions** and create eight secrets:

**Codesigning (required for all builds):**

| Secret name | Value |
|---|---|
| `DEVID_SIGNING_CERT` | The base64-encoded `.p12` file contents (from step 3) |
| `DEVID_SIGNING_CERT_PASS` | The password you set when exporting the `.p12` |
| `DEVID_SIGNING_CERT_ID` | The 40-character SHA-1 fingerprint (from step 2) |
| `KEYCHAIN_PASS` | A random password for the temporary CI keychain (generate one with `openssl rand -base64 32`) |

**Notarization (required for releases):**

| Secret name | Value |
|---|---|
| `NOTARIZATION_APPLE_ID` | Your Apple ID email |
| `NOTARIZATION_TEAM_ID` | Your Apple Developer Team ID |
| `NOTARIZATION_PASS` | The app-specific password (from step 4) |

**Homebrew tap (required for releases):**

| Secret name | Value |
|---|---|
| `HOMEBREW_TAP_TOKEN` | A GitHub personal access token with `contents: write` permission on `cdzombak/homebrew-oss` |

## What the workflow does

**On every push to main and on tags:**

1. Creates a temporary keychain on the CI runner.
2. Decodes and imports the `.p12` certificate into that keychain.
3. Grants `/usr/bin/codesign` access to the imported key.
4. Signs `Bandwidther.app` with the Developer ID Application certificate, hardened runtime, and a secure timestamp.
5. Verifies the signature.
6. Packages the signed app into the DMG.

**On `v*` tags only (releases):**

7. Notarizes the DMG with Apple via `xcrun notarytool` (submits, waits for approval, and staples the ticket).
8. Creates a GitHub Release with the notarized DMG attached.
9. Generates a Homebrew cask with the DMG's SHA-256 and pushes it to `cdzombak/homebrew-oss`.
