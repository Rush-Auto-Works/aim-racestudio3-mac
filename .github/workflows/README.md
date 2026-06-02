# Release workflow — `release-dmg.yml`

Builds, codesigns, **notarizes + staples**, and releases `RaceStudio 3.dmg`.

## Why a macOS runner (not Ubicloud)

The DMG needs Apple-only tooling (`osacompile`, `codesign`, `hdiutil`, `notarytool`, `iconutil`,
`sips`). None exist on Linux, so the org's Ubicloud (Ubuntu) runners can't build it. The workflow
uses GitHub-hosted **`macos-14`** (free minutes on a public repo). To self-host on a Mac instead,
change `runs-on:` to your runner's labels.

## Trigger

- **Push a tag** `vX.Y.Z` → builds + notarizes + creates/updates a GitHub Release with the DMG.
- **Run manually** (Actions → release-dmg → Run workflow) → builds + uploads the DMG as a
  workflow artifact only (no Release).

## Required secrets

Settings → Secrets and variables → Actions → *New repository secret*:

| Secret | What it is |
|--------|-----------|
| `DEVELOPER_ID_CERT_P12` | base64 of your **Developer ID Application** cert exported as `.p12` (incl. private key) |
| `DEVELOPER_ID_CERT_PASSWORD` | the password you set when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | any throwaway string (names the ephemeral build keychain) |
| `APPLE_ID` | your Apple ID email |
| `APPLE_TEAM_ID` | `HYBSCYDCMB` |
| `APPLE_APP_PASSWORD` | an **app-specific password** from account.apple.com → Sign-In & Security |

Optional:

| Secret | What it is |
|--------|-----------|
| `CODESIGN_IDENTITY` | full identity name; defaults to `Developer ID Application: Samuel Reed (HYBSCYDCMB)` |
| `RS3_LOGO_B64` | base64 of the colored RS3 icon PNG (AiM's mark, gitignored). Omit → icon falls back to the Rush logo. |

### Exporting the cert to a base64 `.p12`

1. **Keychain Access** → *login* → *My Certificates* → find **Developer ID Application: …**.
2. Right-click → **Export** → `.p12`, set a password (→ `DEVELOPER_ID_CERT_PASSWORD`).
3. Encode and store it:
   ```sh
   base64 -i DeveloperID.p12 | pbcopy        # paste into the DEVELOPER_ID_CERT_P12 secret
   ```

Set them from the CLI if you prefer:
```sh
gh secret set DEVELOPER_ID_CERT_P12      -R Rush-Auto-Works/aim-racestudio3-mac < <(base64 -i DeveloperID.p12)
gh secret set DEVELOPER_ID_CERT_PASSWORD -R Rush-Auto-Works/aim-racestudio3-mac
gh secret set KEYCHAIN_PASSWORD          -R Rush-Auto-Works/aim-racestudio3-mac
gh secret set APPLE_ID                   -R Rush-Auto-Works/aim-racestudio3-mac
gh secret set APPLE_TEAM_ID --body HYBSCYDCMB -R Rush-Auto-Works/aim-racestudio3-mac
gh secret set APPLE_APP_PASSWORD         -R Rush-Auto-Works/aim-racestudio3-mac
# optional RS3 icon:
gh secret set RS3_LOGO_B64 -R Rush-Auto-Works/aim-racestudio3-mac < <(base64 -i "RaceStudio3_logo_colored.png")
```

## Cut a release

```sh
git tag v1.0.0 && git push origin v1.0.0
```

## Note on the first run

The hardened-runtime + notarization path for the **bundled Wine** is new (every Wine Mach-O is
signed individually with the JIT/unsigned-memory entitlements, then submitted to `notarytool`).
This is how Whisky/CrossOver ship Wine, but the first notarization submission may surface a binary
Apple wants signed differently — read the `notarytool` log in the run and iterate if so.
