# Releasing CodeCat

Four commands, in order. Each one depends on the one before it, so
`make release` runs all of them.

```bash
make app        # dist/CodeCat.app, ad-hoc signed. Local use only.
make sign       # the same bundle, Developer ID + hardened runtime
make notarize   # + Apple's notary service, + stapled ticket
make release    # + a signed, notarised dist/CodeCat-<version>.dmg
```

`make app` needs nothing set up. Everything from `make sign` onwards needs an
Apple Developer account, and that is the one part of this that cannot be
automated.

## One-time setup

### 1. A Developer ID Application certificate

Create it in the Apple Developer portal (Certificates → **Developer ID
Application**) and install it in your login keychain. Confirm it is there:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

You want a line like
`A3EA…B801 "Developer ID Application: Your Name (T9N3G9LHXL)"`. The Makefile
finds it by that substring rather than by hash, on purpose: certificates are
reissued yearly, and a hard-coded fingerprint would turn `make release` into a
mystery failure twelve months later. Override it if you have several:

```bash
make sign SIGN_ID="Developer ID Application: Your Name (TEAMID)"
```

The ten characters in brackets are your **team ID**. You need them again below.

**The first `codesign` run of a session opens a keychain dialog** asking whether
`codesign` may use the private key. Answer "Always Allow" unless you want it on
every build. Until you answer it, `make sign` simply waits.

### 2. A notarisation keychain profile

`notarytool` never sees your Apple ID password — it wants an **app-specific
password**, which you generate at [appleid.apple.com](https://appleid.apple.com)
under Sign-In and Security → App-Specific Passwords.

```bash
xcrun notarytool store-credentials codecat \
    --apple-id you@example.com \
    --team-id TEAMID \
    --password xxxx-xxxx-xxxx-xxxx
```

`codecat` is the profile name the Makefile passes to every `notarytool` call.
Change it with `make notarize NOTARY_PROFILE=other-name`. Check it works:

```bash
xcrun notarytool history --keychain-profile codecat
```

An error reading *No Keychain password item found for profile* means this step
has not been done.

### Environment summary

| What | Where it comes from | Makefile variable |
| --- | --- | --- |
| Signing identity | login keychain, matched by substring | `SIGN_ID` |
| Notary credentials | keychain profile from `store-credentials` | `NOTARY_PROFILE` |
| Marketing version | `Resources/Info.plist`, edited by hand | `VERSION` |
| Build number | `git rev-list --count HEAD` | `BUILD` |

No environment variables and no secrets in the repository. Both credentials live
in the keychain of whoever builds the release.

## Cutting a release

1. **Bump the version.** `CFBundleShortVersionString` in `Resources/Info.plist`
   is a human decision, not a function of the commit log, so it is edited by
   hand. `CFBundleVersion` is derived from the commit count, which is what makes
   two builds of the same version distinguishable — in Finder, in a crash
   report, and in the menu-bar item that prints both.
2. **Update `CHANGELOG.md`.**
3. `swift test` — all of it, not a filter.
4. `make release`.
5. **Run [verification-checklist.md](verification-checklist.md)**, item 34 in
   particular: it is the only real test of the Apple-events entitlement, and it
   needs a second Mac.
6. Tag and push:
   ```bash
   git tag -a v0.3.0 -m "CodeCat 0.3.0"
   git push origin master --tags
   ```
7. Create the GitHub release and attach `dist/CodeCat-0.3.0.dmg`.

## What each step actually does, and why

**`make sign` signs `codecat-hook` first, separately, then the bundle.** The hook
is a second executable in `Contents/MacOS`; signing the bundle does not give it a
signature of its own, and the notary service rejects a bundle like that. The
order matters in the other direction too: the bundle signature seals its
contents, so touching anything inside afterwards breaks it. This is also why the
skins, the icon and the `.lproj` directories are copied in during `make bundle`,
before any signing happens.

**Hardened runtime needs an entitlement here.** Notarisation requires
`--options runtime`, and hardened runtime revokes the right to send Apple events
— which breaks jump-to-session with `errAEEventNotPermitted (-1743)` no matter
what the user allowed in System Settings. `Resources/CodeCat.entitlements` gives
it back. None of this is visible in an ad-hoc build, which has no hardened
runtime at all, so `make sign` asserts that the entitlement really landed *in the
signature* rather than merely existing in a file.

**`make sign` also asserts `TeamIdentifier` is set.** `codesign --verify` says
"valid" about an ad-hoc signature too, so verification alone does not catch the
one mistake this target exists to prevent.

**Notarisation staples a ticket into the bundle.** `notarytool` accepts a
container, so a `.zip` is submitted; `stapler` writes the resulting ticket into
the `.app` itself. Without stapling, a downloaded copy would be checked online
and would refuse to open on a machine with no network.

**`make release` builds the DMG from a staging folder**, not straight from the
bundle: the folder also holds a symlink to `/Applications` and a
`.VolumeIcon.icns`, so the disk image is the familiar drag-to-install window.
The volume-icon flag is set with `SetFile`, which ships with Xcode; if it is
missing the image still builds, with a default icon, and says so.

**The last check is the only one that answers the real question.** Everything
before it inspects a signature. `spctl -a -t exec` on the app and
`spctl -a -t open` on the image ask Gatekeeper itself whether it would let a
downloaded copy run, and both must report `source=Notarized Developer ID`.

## When it fails

| Symptom | Cause |
| --- | --- |
| `make sign` hangs with no output | The keychain dialog is waiting for an answer behind another window. |
| `ОШИБКА: не найден сертификат Developer ID Application` | No such certificate in the keychain — step 1. |
| `ОШИБКА: TeamIdentifier не проставлен` | `SIGN_ID` matched an *Apple Development* certificate instead. Pass it explicitly. |
| `ОШИБКА: entitlement на Apple events не попал в подпись` | `Resources/CodeCat.entitlements` was moved or emptied. Jump-to-session would break in the shipped build. |
| `No Keychain password item found for profile` | Step 2 has not been done, or `NOTARY_PROFILE` names a different profile. |
| Notary status `Invalid` | `xcrun notarytool log <submission-id> --keychain-profile codecat` prints exactly which file failed and why. |
| App opens locally but not on another Mac | Almost always a missing staple. `xcrun stapler validate dist/CodeCat.app`. |

## No account, no release

If you do not have an Apple Developer account, `make app` still produces a
working bundle for your own machine. Two consequences to be honest about in that
case, both visible immediately:

- Every reinstall changes the ad-hoc signature, and macOS ties the automation
  permission to the signature — so it is requested again after every rebuild.
  `tccutil reset AppleEvents com.codecat.app` clears the old grant.
- On any other Mac, Gatekeeper will not open the bundle without the user
  explicitly bypassing quarantine.
