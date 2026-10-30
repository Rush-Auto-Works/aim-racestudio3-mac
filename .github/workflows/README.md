# Release workflow — `release-dmg.yml`

Builds, codesigns, **notarizes + staples**, and releases `RaceStudio3-<version>-<rev>.dmg` and a
matching `.pkg`. `weekly-rs3-update.yml` checks AiM's download page every Monday, bumps the pin,
tags the release and dispatches this workflow.

## Why a macOS runner (not Ubicloud)

The DMG needs Apple-only tooling (`osacompile`, `codesign`, `hdiutil`, `notarytool`, `iconutil`,
`sips`). None exist on Linux, so the org's Ubicloud (Ubuntu) runners can't build it. The workflow
uses GitHub-hosted **`macos-15`** (free minutes on a public repo). To self-host on a Mac instead,
change `runs-on:` to your runner's labels.

## Trigger

- **Push a tag** `v<RS3 version>-<pkg rev>` (for example `v3.84.04-1`) → builds + notarizes +
  creates/updates a GitHub Release with the DMG and the `.pkg`. A failed tag build opens an issue.
- **Run manually** (Actions → release-dmg → Run workflow) → builds + uploads the DMG and `.pkg` as
  a workflow artifact only (no Release). Dispatched on a tag ref, it publishes that tag.

## Required secrets

Settings → Secrets and variables → Actions → *New repository secret*:

| Secret | What it is |
|--------|-----------|
| `DEVELOPER_ID_CERT_P12` | base64 of your **Developer ID Application** cert exported as `.p12` (incl. private key) |
| `DEVELOPER_ID_CERT_PASSWORD` | the password you set when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | any throwaway string (names the ephemeral build keychain) |
| `ASC_KEY_P8` | base64 of your **App Store Connect API key** (`AuthKey_XXXX.p8`) |
| `ASC_KEY_ID` | the key id — the `XXXX` in `AuthKey_XXXX.p8` |
| `ASC_ISSUER_ID` | the **Issuer ID** (UUID) at App Store Connect → Users and Access → Integrations → Keys |

> Notarization uses an **App Store Connect API key** (created at appstoreconnect.apple.com →
> Users and Access → Integrations → Keys → **+**). It avoids account.apple.com entirely and is the
> recommended CI credential. The workflow only passes the three `ASC_*` secrets to the build.

Optional:

| Secret | What it is |
|--------|-----------|
| `CODESIGN_IDENTITY` | full identity name; defaults to `Developer ID Application: Samuel Reed (HYBSCYDCMB)` |
| `RS3_LOGO_B64` | base64 of the colored RS3 icon PNG (AiM's mark, gitignored). Omit → icon falls back to the Rush logo. |
| `DEVELOPER_ID_INSTALLER_CERT_P12` | base64 of your **Developer ID Installer** cert (`.p12`). Signs and notarizes the `.pkg`; without it the `.pkg` ships unsigned. |
| `DEVELOPER_ID_INSTALLER_CERT_PASSWORD` | the password you set when exporting that `.p12` |

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
gh secret set ASC_KEY_P8   -R Rush-Auto-Works/aim-racestudio3-mac < <(base64 -i AuthKey_XXXX.p8)
gh secret set ASC_KEY_ID --body XXXX                 -R Rush-Auto-Works/aim-racestudio3-mac
gh secret set ASC_ISSUER_ID --body '<issuer-uuid>'   -R Rush-Auto-Works/aim-racestudio3-mac
# optional RS3 icon:
gh secret set RS3_LOGO_B64 -R Rush-Auto-Works/aim-racestudio3-mac < <(base64 -i "RaceStudio3_logo_colored.png")
```

## Cut a release

The weekly updater does this when AiM ships a new RaceStudio 3. To release by hand, run the
`/update-racestudio3` skill (`.claude/skills/update-racestudio3/SKILL.md`), or copy `tag=` from
`bash installer/build/check-rs3-update.sh` and push it:

```sh
git tag -a v3.84.04-1 -m "RaceStudio 3 3.84.04" && git push origin v3.84.04-1
```

## Note on the first run

The hardened-runtime + notarization path for the **bundled Wine** is new (every Wine Mach-O is
signed individually with the JIT/unsigned-memory entitlements, then submitted to `notarytool`).
This is how Whisky/CrossOver ship Wine, but the first notarization submission may surface a binary
Apple wants signed differently — read the `notarytool` log in the run and iterate if so.
