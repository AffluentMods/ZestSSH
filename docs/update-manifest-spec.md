# The update manifest

How a ZestSSH computer app learns of a newer release and installs it, and
what it trusts on the way. The full account, with every check, is the header
of `lib/services/update_manifest.dart`; this page is the short form for
whoever serves the manifest or builds the app.

(This page described the first updater until 4.0: an unsigned manifest and a
button that opened the download page. That updater is gone since 3.0.)

## Who checks

Only the release's own builds for Windows, macOS and Linux that were not
installed from a store. Phones and tablets never check (their stores update
them), and neither does a store build on a computer
(`UpdateCheckService.checksOn`). A community build has no manifest address
and no key, so it asks nobody (`updaterSetUp`).

## What is served

One static file, the same for everyone:

```
GET https://zestssh.com/app/latest.json
```

at most 64 KB of JSON, answered within 6 seconds. The app sends nothing about
the device with the request: no version, no id.

```json
{
  "version": "4.0.0",
  "build": 310,
  "url": "https://zestssh.com/download",
  "notes": "One or two lines about the release.",
  "critical": false,
  "platforms": {
    "windows": {"url": "https://zestssh.com/downloads/ZestSSH-4.0.0-Setup.exe", "sha256": "<64 hex digits>", "size": 22123456},
    "linux": {"url": "https://zestssh.com/downloads/ZestSSH-4.0.0-linux-x64.tar.gz", "sha256": "<64 hex digits>", "size": 31234567},
    "macos": {"url": "https://zestssh.com/downloads/ZestSSH-4.0.0.dmg", "sha256": "<64 hex digits>", "size": 41234567}
  },
  "signature": "<base64 Ed25519 signature>"
}
```

| Field | Meaning |
|---|---|
| `version` | The release's version. The app offers it only where it is higher than the running one; of the same version, only a higher `build`. |
| `build` | The build number, compared where the versions are equal. |
| `url` | The download page, opened where the app cannot install by itself. |
| `notes` | A line or two shown with the offer. |
| `critical` | `true` shows the offer more prominently. Nothing is ever installed without the person's yes. |
| `platforms` | For each computer platform: the file, its SHA-256 and its size in bytes. |
| `signature` | The release key's signature over everything else. |

## The signature

The manifest is signed when a release is made, by the website's release
script, with the release key (Ed25519). The private half is not in any
repository. The public half is compiled into the app
(`kUpdateSigningPublicKeys`; a second key can be added a release before a key
is replaced).

What is signed: the UTF-8 bytes of the line `ZestSSH update manifest v1`
and a line feed (`kUpdateSignaturePrefix`), followed by the manifest's
canonical JSON: every key but `signature`, object keys sorted at every level,
no white space, whole numbers only (`canonicalManifestBytes`). The app writes
those bytes again from the values it parsed and checks the signature over
them, so what was checked is what is used.

## What the app refuses

Before anything is downloaded:

- a manifest that names a newer version and is not signed, or whose
  signature does not verify with one of the app's keys (error ZS-1902);
- a package whose address is not `https` on the download host under
  `/downloads/`, or has a user name or a port in it; a `sha256` that is not
  64 hexadecimal digits; a `size` that is not a whole number in range
  (`UpdatePackage.parse`);
- a version that is not higher than the running one. There is no downgrade:
  an old signed manifest served again reads as "up to date".

After the download: a file whose size or SHA-256 is not what the signed
manifest names (ZS-1903). The download follows no redirect to another host.

## How often, and what the person sees

The app checks at most once in six hours, and once more when the person asks
in Settings. A newer release is offered in a banner with its notes; a banner
that was closed stays closed for that version. Where the check fails (no
answer, a file that is too large or is not JSON) nothing is shown by the
automatic check, and the check asked for by hand says that it could not
check.

## What this does not cover

- Whoever holds the release key can sign an update every app would install.
  The key is kept offline for that reason.
- Whoever can block or answer for the manifest's address can keep an app
  from hearing of a release, or keep serving an older signed manifest that is
  still newer than the running copy. They cannot make the app install
  anything the release key did not sign.
- Of the installers only the Mac's is code-signed (a Developer ID signature,
  notarized by Apple, since 3.4.0). The Windows setup carries no Authenticode
  signature yet, so SmartScreen warns of it, and the Linux tar.gz none (the
  .deb and .rpm come from repositories signed with the project's package
  key). There the manifest's signature and hash are what the app trusts.

## A test build

A build may be compiled to read its manifest from another address
(`ZEST_UPDATE_MANIFEST_URL`), chosen at compile time and never while it
runs. Every check above applies to it unchanged.
