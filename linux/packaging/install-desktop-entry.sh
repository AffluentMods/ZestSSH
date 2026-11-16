#!/bin/sh
# Adds ZestSSH to this user's applications and makes it the app that opens
# zestssh:// links (a host someone shared, a link from the website), from
# wherever this folder was unpacked. Run it once after unpacking, and again
# after moving the folder. It writes one file for this user only
# (~/.local/share/applications/com.affluentlabs.zestssh.desktop) and needs
# no root. To undo it, delete that file.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
if [ ! -x "$here/zestssh" ]; then
  echo "zestssh is not next to this script ($here): run it from the unpacked ZestSSH folder." >&2
  exit 1
fi

apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
entry="$apps/com.affluentlabs.zestssh.desktop"
mkdir -p "$apps"

# Exec ends in %u: a link opened is handed to zestssh, which gives it to the
# ZestSSH already running (one per session) or starts with it.
cat > "$entry" <<EOF
[Desktop Entry]
Type=Application
Name=ZestSSH
Comment=The Fresh SSH Client
Exec="$here/zestssh" %u
Icon=$here/data/flutter_assets/assets/ZestSSH.png
Terminal=false
Categories=Network;RemoteAccess;
MimeType=x-scheme-handler/zestssh;
StartupWMClass=com.affluentlabs.zestssh
EOF

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$apps" >/dev/null 2>&1 || true
fi
if command -v xdg-mime >/dev/null 2>&1; then
  xdg-mime default com.affluentlabs.zestssh.desktop x-scheme-handler/zestssh
  echo "ZestSSH is in your applications and opens zestssh:// links ($entry)."
else
  echo "ZestSSH is in your applications ($entry). xdg-mime was not found, so zestssh:// links may not open it until your desktop reads the entry again."
fi
