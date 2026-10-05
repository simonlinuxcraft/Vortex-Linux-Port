#!/bin/bash
# Runs after the Vortex Debian package is unpacked and configured.
#
# electron-builder expands placeholders in this file before embedding it in the
# package. It scans for a dollar sign followed by a braced name, and aborts the
# build with "Macro ... is not defined" for any name it does not know. That scan
# covers comments too, so every shell variable here is written without braces
# and no brace-form example appears anywhere in this file.
set -e

APP_DIR="/opt/${sanitizedProductName}"
TARGET="$APP_DIR/${executable}"
# The binary is named after the app id (see linux.executableName); the command
# users type is plain `vortex`.
NAME="vortex"
LINK="/usr/bin/$NAME"

# Expose the launcher as /usr/bin/vortex. update-alternatives keeps the link
# manageable when several mod managers or builds are installed side by side.
if type update-alternatives >/dev/null 2>&1; then
  if [ -L "$LINK" ] && [ -e "$LINK" ] && [ "$(readlink "$LINK")" != "/etc/alternatives/$NAME" ]; then
    rm -f "$LINK"
  fi
  update-alternatives --install "$LINK" "$NAME" "$TARGET" 100 || ln -sf "$TARGET" "$LINK"
else
  ln -sf "$TARGET" "$LINK"
fi

# Electron's SUID sandbox helper must be owned by root and mode 4755, otherwise
# Electron refuses to start unless --no-sandbox is passed. dpkg does not
# preserve the setuid bit from the archive on every configuration path, so set
# it explicitly here.
if [ -f "$APP_DIR/chrome-sandbox" ]; then
  chown root:root "$APP_DIR/chrome-sandbox" || true
  chmod 4755 "$APP_DIR/chrome-sandbox" || true
fi

# Refresh the desktop caches so the menu entry, the icon and the nxm:// scheme
# handler are picked up without requiring a re-login.
if type update-mime-database >/dev/null 2>&1; then
  update-mime-database /usr/share/mime || true
fi

if type update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications || true
fi

if type gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache --quiet /usr/share/icons/hicolor || true
fi

exit 0
