# Releasing Tempo

Tempo ships from GitHub. Colleagues install with `install.sh`; installed copies update through
Sparkle. The design is in `docs/superpowers/specs/2026-10-01-distribution-and-updates-design.md`.

## One-time setup

1. Build once so the Sparkle tools exist: `swift build`.
2. First setup only (already done for this repository: `SU_PUBLIC_ED_KEY` is set). Create the EdDSA
   key pair in your login Keychain and print the public key. On a new Mac, do not run this step:
   restore the key instead (see "Restore the key").

   ```sh
   GK="$(find .build/artifacts -type f -name generate_keys | head -1)"
   "$GK"        # creates the key when none exists
   "$GK" -p     # prints the public key
   ```

   The public key is the constant `SU_PUBLIC_ED_KEY` in `scripts/build-app.sh`.
3. Export the private key and keep it in two more places. Never commit it. Run both blocks in the
   repository root, in the same Terminal window as step 2.

   ```sh
   "$GK" -x "$TMPDIR/sparkle-private.key"
   gh secret set SPARKLE_PRIVATE_KEY --repo NoeFabris/tempo < "$TMPDIR/sparkle-private.key"
   pbcopy < "$TMPDIR/sparkle-private.key"
   ```

   Paste the clipboard into the password manager. Then clear the clipboard and delete the file:

   ```sh
   pbcopy < /dev/null
   rm "$TMPDIR/sparkle-private.key"
   ```

   If a clipboard history tool is installed, delete the entry there too.

   Without the private key no update can be signed. Key rotation needs a Developer ID, so a lost
   key means colleagues reinstall with the one-line command.
4. Optional housekeeping: `security delete-identity -c "Tempo Local Signing"` removes the stale
   self-signed identity from the earlier approach.

## Release a version

1. Everything is committed on `main` and the CI workflow is green.
2. `git tag v1.2.0 && git push origin main v1.2.0`
3. The Release workflow builds, signs and publishes: https://github.com/NoeFabris/tempo/releases
4. Installed copies see the update within a day. **Settings › Check for updates…** checks at once.

Versions are `MAJOR.MINOR.PATCH` and must increase. No pre-release tags. Never move or delete a
published tag.

## Fallback: release from this Mac

After step 2 above, when GitHub Actions is unavailable: `VERSION=1.2.0 scripts/release.sh`.
The key comes from the Keychain (allow access when asked). `DRY_RUN=1` does everything except the
GitHub release and leaves `feed/` for inspection.

## Restore the key

Use this on a new Mac, after a lost Keychain, or when the Actions secret is gone. Run it in the
repository root, in one Terminal window; on a new Mac, run `swift build` first (step 1 of One-time
setup) so that `generate_keys` exists. Copy the private key from the password manager first.

```sh
GK="$(find .build/artifacts -type f -name generate_keys | head -1)"
pbpaste > "$TMPDIR/sparkle-private.key"
"$GK" -f "$TMPDIR/sparkle-private.key"     # imports the key into the login Keychain
"$GK" -p                                   # must print the value of SU_PUBLIC_ED_KEY in scripts/build-app.sh
gh secret set SPARKLE_PRIVATE_KEY --repo NoeFabris/tempo < "$TMPDIR/sparkle-private.key"   # only if the secret is lost
pbcopy < /dev/null
rm "$TMPDIR/sparkle-private.key"
```

Never change `SU_PUBLIC_ED_KEY`. Installed copies accept only updates signed with the matching
private key. A new key pair means that every colleague must reinstall with the one-line command.

## Troubleshooting

- "The update is improperly signed and could not be validated": generic Sparkle text. Open Console
  and filter for "Sparkle". Usual causes: a stale cached archive, or an item signed with another key.
- The Release workflow fails before the release exists (for example in `swift test` or the build): the
  runner's Xcode may differ from yours. The CI workflow builds the same configuration on every push to
  `main`, so check it first. Select another Xcode on the image if needed.
- A Release run failed and no release exists for the tag: for a temporary error, re-run the failed job
  (Actions › the run › Re-run jobs). For a code fix, delete the unpublished tag
  (`git push origin :refs/tags/v1.2.0` and `git tag -d v1.2.0`), commit the fix, and tag again, or tag
  the next PATCH number. A tag that has a published release is never moved or deleted.
- A colleague sees a Gatekeeper dialog: the zip came from a browser. Use the install command.
- Two copies of Tempo: delete `/Applications/Tempo.app`; the installer uses `~/Applications`.

## Later: Developer ID

See §11 of the design spec. Keep the EdDSA key; add inside-out signing with the hardened runtime,
notarisation and stapling to `scripts/build-app.sh`.
