# OS / brand icons (31)

The 31 host-card logos: Ubuntu, Debian, Fedora, CentOS, Alpine, Arch, openSUSE, NixOS, Kali, Linux Mint, Pop!_OS, macOS, Windows, FreeBSD, Proxmox, TrueNAS, Unraid, VMware ESXi, Raspberry Pi OS, Home Assistant, Docker, RHEL, Rocky, AlmaLinux, Manjaro, SLES, Gentoo, Void, Parrot, OpenBSD, NetBSD.

These aren't hand-drawn. Each one uses the brand's real shape from Simple Icons (https://simpleicons.org, SVG data licensed CC0). That replaces the ten two-letter monograms with the actual marks.

## Building them
```
npm i -D simple-icons
node icons/brand-os/build-brand-icons.mjs                    # fill="currentColor" (app tints white)
ICON_COLOR=#FFFFFF node icons/brand-os/build-brand-icons.mjs # or bake in white
```
- Output goes to `icons/brand-os/svg/<id>.svg`, plus `index.json` with the brand hex for an optional colored mode.
- Every file is 24×24 with a 2px inset, so the filled logos sit at the same visual weight as the stroked line icons in `icons/host/`.
- The `id` values match the app's existing keys, so the card lookup doesn't change.
- If a slug isn't in the installed version, the script logs it and uses the generic line icon from `manifest.json` → `fallback`. Microsoft brands (Windows) have been removed from some Simple Icons versions. If the log lists Windows, keep the fallback or get the logo from Microsoft's official brand assets.

## Trademarks
The logos belong to their owners. Using them to label a user's own hosts is fine. Keep them out of ZestSSH store screenshots and marketing.
