#!/bin/bash
# Runs after the Vortex Debian package is removed.
#
# See after-install.sh for why shell variables here avoid the braced form.
set -e

APP_DIR="/opt/${sanitizedProductName}"
TARGET="$APP_DIR/${executable}"
# The binary is named after the app id (see linux.executableName); the command
# users type is plain `vortex`.
NAME="vortex"
LINK="/usr/bin/$NAME"

if type update-alternatives >/dev/null 2>&1; then
  update-alternatives --remove "$NAME" "$TARGET" || true
else
  rm -f "$LINK"
fi

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
