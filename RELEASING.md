# Releasing Tabby With Sparkle

This guide explains how Tabby signs Sparkle updates and which local tools are available.

## Mental Model

Sparkle update trust has two halves:

- `SUPublicEDKey` in `TabbyInfo.plist` is the public trust anchor shipped inside the app.
- The private Ed25519 key signs each release artifact before the appcast is published.

Sparkle downloads the appcast, reads the update enclosure's `sparkle:edSignature`, downloads the
artifact, and verifies that signature with the public key embedded in the installed app. If the
artifact is unsigned, signed by the wrong key, or modified after signing, Sparkle rejects it.

## Current Configuration

Tabby's Sparkle settings live in `TabbyInfo.plist`:

- `SUFeedURL`: `https://fujacob.github.io/tabby/appcast.xml`
- `SUPublicEDKey`: `efJeZNfUISOs6npbxI2MLLe7sBB5tT/sVnTk9t/qBSY=`

That public key is safe to commit. The matching private key is secret and must never be committed.

## Available Sparkle Tools

After Xcode resolves the Sparkle Swift package, the tools are available in DerivedData. On this
machine they are currently located at:

- `~/Library/Developer/Xcode/DerivedData/tabby-bjuhrhutqnwwjrbkuugwtoosmmqx/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`
- `~/Library/Developer/Xcode/DerivedData/tabby-bjuhrhutqnwwjrbkuugwtoosmmqx/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update`
- `~/Library/Developer/Xcode/DerivedData/tabby-bjuhrhutqnwwjrbkuugwtoosmmqx/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast`

DerivedData folder names can change. To find the tools again, run:

```sh
find "$HOME/Library/Developer/Xcode/DerivedData" -type f \
  \( -name generate_keys -o -name sign_update -o -name generate_appcast \) -print
```

## Key Generation

Use Sparkle's `generate_keys` tool to create or look up the Ed25519 key pair:

```sh
"$HOME/Library/Developer/Xcode/DerivedData/tabby-bjuhrhutqnwwjrbkuugwtoosmmqx/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
```

What this does:

- Creates a private key in your macOS Keychain if one does not already exist.
- Reuses the existing private key if one already exists for the selected account.
- Prints the public key value that belongs in `SUPublicEDKey`.

To print the public key later without generating a new key:

```sh
"$HOME/Library/Developer/Xcode/DerivedData/tabby-bjuhrhutqnwwjrbkuugwtoosmmqx/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys" -p
```

For organization-specific signing, prefer an explicit account name:

```sh
"$HOME/Library/Developer/Xcode/DerivedData/tabby-bjuhrhutqnwwjrbkuugwtoosmmqx/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys" --account tabby-release
```

If you use a non-default account, pass the same `--account` value to `sign_update` when signing.

## Private Key Storage

The private key is equivalent to release authority for Tabby updates.

Recommended storage:

- Keep the primary private key in a restricted password manager or offline secret store.
- Limit access to release owners only.
- Do not commit exported private key files.
- Do not paste private key material into issue comments, PRs, logs, or shell history.

To export the private key for backup or transfer:

```sh
"$HOME/Library/Developer/Xcode/DerivedData/tabby-bjuhrhutqnwwjrbkuugwtoosmmqx/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys" -x /secure/path/tabby-sparkle-private-key.txt
```

To import it on another release machine:

```sh
"$HOME/Library/Developer/Xcode/DerivedData/tabby-bjuhrhutqnwwjrbkuugwtoosmmqx/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys" -f /secure/path/tabby-sparkle-private-key.txt
```

## Signing A Release

Tabby's appcast is rendered by `scripts/generate_appcast.py`. The script finds `sign_update`,
signs the release DMG, and writes the generated `sparkle:edSignature` into `build/appcast.xml`.

Example:

```sh
python3 scripts/generate_appcast.py \
  --release-version 1.0.0 \
  --build-number 100 \
  --archive /path/to/notarized/Tabby.dmg \
  --output build/appcast.xml
```

The generated appcast is based on `scripts/appcast.template.xml`. Its `<enclosure>` must include:

- `url`: where Sparkle downloads the release artifact
- `sparkle:edSignature`: the Ed25519 signature from `sign_update`
- `length`: the signed artifact byte length
- `type`: the artifact MIME type

Publish the signed appcast to the URL configured by `SUFeedURL`.

## Checking The Signature Values

Before publishing, rerun `sign_update` against the exact DMG you plan to publish:

```sh
"$HOME/Library/Developer/Xcode/DerivedData/tabby-bjuhrhutqnwwjrbkuugwtoosmmqx/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" /path/to/notarized/Tabby.dmg
```

The output should include `sparkle:edSignature="..."` and `length="..."`. Those values must match
the generated appcast. If the DMG changes after signing, regenerate the appcast because the old
signature no longer represents the artifact bytes.

For an end-to-end app check, launch a build with Sparkle configured and test against the published
appcast. Unsigned or mis-signed updates should be rejected by Sparkle before installation.

## Key Rotation Warning

Do not regenerate the Sparkle key casually after users have installed a public build.

Existing installed apps trust the `SUPublicEDKey` they already contain. If a future update is signed
with a different private key, those installed apps will reject it. Rotate only with a deliberate
migration plan.
