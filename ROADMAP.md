# Roadmap — RightLayout SergeyZh

Planned work for this fork. Done items move to the release notes.

## Distribution: Developer ID signing, notarization, DMG

**Status:** planned (the Apple Developer account is available).

**Why.** Releases are currently unsigned and shipped as a `.pkg`:

- Gatekeeper blocks both the installer and the app until the user clicks
  "Open Anyway" in System Settings → Privacy & Security.
- Every update is a different binary to macOS, so the Accessibility entry of the
  previous version stays switched on but no longer applies. The `.pkg` exists mostly
  to run `tccutil reset` in `releases/pkg_scripts/postinstall` to work around this.

With a Developer ID signature and notarization the app opens without warnings, and
the Accessibility permission survives updates (macOS ties it to the team's
signature). A plain `.app` in a DMG is then all that is needed.

**Steps.**

1. Create a *Developer ID Application* certificate; export it as `.p12`. Create an
   App Store Connect API key for `notarytool` (or an app-specific password).
   Store them in GitHub secrets (certificate, its password, API key ID, issuer ID,
   key `.p8`).
2. Move the SwiftPM resource bundle out of the `.app` root: `codesign` rejects
   files there ("unsealed contents present in the bundle root"), but
   `releases/build_release.sh` copies `RightLayout_RightLayout.bundle` to it,
   because that is where the generated `Bundle.module` looks. Put it in
   `Contents/Resources` and look it up there instead of through `Bundle.module`.
3. In `releases/build_release.sh`, sign the app with the hardened runtime and a
   secure timestamp: `codesign --force --options runtime --timestamp --sign
   "Developer ID Application: …"`. Don't use `RightLayout/OMFK.entitlements`: it
   enables the App Sandbox, which rules out the keyboard event tap.
4. Build a DMG with the app and a link to `/Applications` (`hdiutil` or
   `create-dmg`), sign it.
5. Notarize and staple: `xcrun notarytool submit … --wait`, then
   `xcrun stapler staple` on the DMG.
6. `.github/workflows/release.yml`: import the certificate into a temporary
   keychain, build, notarize, and upload the DMG instead of the `.pkg`.
7. Remove `pkgbuild` and `releases/pkg_scripts/`. Update the README install
   section and the release notes template (download the DMG, drag to
   Applications).
8. First signed release: the entry left by the unsigned builds is stale once more.
   Say in its release notes to use "Reset Permission" in the permission window, or
   reset it automatically on first launch of that version.
9. Check: `codesign --verify --deep --strict`, `spctl --assess -vv`, a fresh
   download on another Mac opens without warnings, and Accessibility stays granted
   after installing the next version over it.
