#!/usr/bin/env bash
#
# Verifies the Debian packaging metadata without running a full Electron build.
#
# A complete `pnpm package:nosign` needs the Electron binary and every native
# module, which takes a long time and does not work on a machine that cannot
# reach GitHub. Most packaging mistakes, though, live in the metadata: an
# invalid package name, dependencies that do not resolve on the target
# distribution, a maintainer script that fails to expand or is not valid shell.
#
# This script reads the real electron-builder configuration, reproduces the
# layout and control fields that electron-builder's FpmTarget would produce,
# builds a package from a stub payload with dpkg-deb, and inspects the result.
#
# It does NOT verify that Vortex runs. It verifies that the package around it
# is well formed.
#
# Usage: packaging/linux/verify-deb-metadata.sh [--keep]
#        EMIT_SMOKETEST=1 packaging/linux/verify-deb-metadata.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="$REPO_ROOT/src/main/electron-builder.config.json"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

WORK="$(mktemp -d)"
cleanup() {
  if [ "$KEEP" -eq 1 ]; then
    echo "staging kept at $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok   $*"; }

cfg() {
  python3 - "$CONFIG" "$1" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
value = eval(sys.argv[2], {"cfg": cfg})
print(", ".join(value) if isinstance(value, list) else value)
PY
}

# electron-builder derives these from the config and from the package name that
# prepare-dist-package.mjs writes into the deployed package.json.
PRODUCT_NAME="Vortex"
VERSION="${VORTEX_VERSION:-9.9.9}"
ARCH="amd64"

PKG_NAME="$(cfg 'cfg["deb"]["packageName"]')"
EXECUTABLE="$(cfg 'cfg["linux"]["executableName"]')"
CATEGORY="$(cfg 'cfg["linux"]["category"]')"
PKG_CATEGORY="$(cfg 'cfg["deb"]["packageCategory"]')"
PRIORITY="$(cfg 'cfg["deb"]["priority"]')"
MAINTAINER="$(cfg 'cfg["deb"].get("maintainer") or cfg["linux"]["maintainer"]')"
VENDOR="$(cfg 'cfg["deb"].get("vendor") or cfg["linux"].get("vendor") or cfg["linux"]["maintainer"]')"
DESCRIPTION="$(cfg 'cfg["linux"]["description"]')"
SYNOPSIS="$(cfg 'cfg["linux"]["synopsis"]')"
DEPENDS="$(cfg 'cfg["deb"]["depends"]')"
RECOMMENDS="$(cfg 'cfg["deb"].get("recommends", [])')"
MIME_TYPES="$(cfg '";".join(cfg["linux"].get("mimeTypes", [])) + ";"')"
DESKTOP_EXTRA="$(cfg '"\n".join("%s=%s" % kv for kv in cfg["linux"].get("desktop", {}).items())')"
HOMEPAGE="$(python3 -c "
import json, sys
print(json.load(open(sys.argv[1])).get('homepage', ''))" "$REPO_ROOT/src/main/package.json")"

echo "== configuration =="
echo "  package     $PKG_NAME"
echo "  executable  $EXECUTABLE"
echo "  version     $VERSION"

# ---------------------------------------------------------------------------
# 1. electron-builder refuses to build deb/rpm without a project homepage.
# ---------------------------------------------------------------------------
echo "== metadata preconditions =="
[ -n "$HOMEPAGE" ] || fail "src/main/package.json has no homepage; FpmTarget aborts with 'Please specify project homepage'"
pass "homepage is set ($HOMEPAGE)"

# Debian policy: package names are lowercase alphanumerics plus + - .
[[ "$PKG_NAME" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || fail "package name '$PKG_NAME' is not a valid Debian package name"
pass "package name is Debian-legal"

# Maintainer must be "Name <address>"; a trailing comment breaks some tooling.
if [[ "$MAINTAINER" =~ ^[^\<]+\<[^\>]+\>$ ]]; then
  pass "maintainer field is 'Name <address>'"
else
  echo "  warn Maintainer '$MAINTAINER' is not exactly 'Name <address>'"
fi

# ---------------------------------------------------------------------------
# 2. Expand the maintainer scripts the way electron-builder does.
#    Its replacer throws on any braced name it does not know, so an accidental
#    shell variable in brace form is a build failure, not a runtime bug.
# ---------------------------------------------------------------------------
echo "== maintainer scripts =="
mkdir -p "$WORK/pkg/DEBIAN"
for script in after-install:postinst after-remove:postrm; do
  src="${script%%:*}"
  dest="${script##*:}"
  python3 - "$REPO_ROOT/packaging/linux/$src.sh" "$WORK/pkg/DEBIAN/$dest" \
           "$EXECUTABLE" "$PRODUCT_NAME" <<'PY'
import re, sys
src, dest, executable, product = sys.argv[1:5]
macros = {
    "executable": executable,
    "sanitizedProductName": product,
    "productFilename": product,
}
missing = []
def repl(m):
    if m.group(1) in macros:
        return macros[m.group(1)]
    missing.append(m.group(1))
    return m.group(0)
out = re.sub(r"\$\{([a-zA-Z]+)\}", repl, open(src).read())
if missing:
    sys.exit("unresolved macros in %s: %s (electron-builder would abort)"
             % (src, ", ".join(sorted(set(missing)))))
open(dest, "w").write(out)
PY
  chmod 755 "$WORK/pkg/DEBIAN/$dest"
  bash -n "$WORK/pkg/DEBIAN/$dest" || fail "$src.sh is not valid bash after expansion"
  if grep -q '\${' "$WORK/pkg/DEBIAN/$dest"; then
    fail "$src.sh still contains a braced placeholder after expansion"
  fi
  pass "$src.sh expands cleanly and parses as bash"
done

# ---------------------------------------------------------------------------
# 3. Reproduce the payload layout from FpmTarget / LinuxTargetHelper.
# ---------------------------------------------------------------------------
echo "== payload layout =="
APP_DIR="$WORK/pkg/opt/$PRODUCT_NAME"
mkdir -p "$APP_DIR" \
         "$WORK/pkg/usr/share/applications" \
         "$WORK/pkg/usr/share/icons/hicolor/256x256/apps" \
         "$WORK/pkg/usr/share/mime/packages"

printf '#!/bin/sh\necho "stub payload, not the real Vortex binary"\n' > "$APP_DIR/$EXECUTABLE"
chmod 755 "$APP_DIR/$EXECUTABLE"
printf 'stub\n' > "$APP_DIR/chrome-sandbox"
chmod 4755 "$APP_DIR/chrome-sandbox"
cp "$REPO_ROOT/assets/images/vortex.png" \
   "$WORK/pkg/usr/share/icons/hicolor/256x256/apps/$EXECUTABLE.png"

# Mirrors LinuxTargetHelper.computeDesktopEntry, including the %U that makes
# the browser hand the nxm:// URL to the application.
{
  echo "[Desktop Entry]"
  echo "Name=$PRODUCT_NAME"
  echo "Exec=/opt/$PRODUCT_NAME/$EXECUTABLE %U"
  echo "Terminal=false"
  echo "Type=Application"
  echo "Icon=$EXECUTABLE"
  echo "StartupWMClass=$PRODUCT_NAME"
  [ -n "$DESKTOP_EXTRA" ] && echo "$DESKTOP_EXTRA"
  echo "Comment=$DESCRIPTION"
  echo "MimeType=$MIME_TYPES"
  echo "Categories=$CATEGORY"
} > "$WORK/pkg/usr/share/applications/$EXECUTABLE.desktop"
pass "payload tree built"

# ---------------------------------------------------------------------------
# 4. Control file with the dependencies from the configuration.
# ---------------------------------------------------------------------------
{
  echo "Package: $PKG_NAME"
  echo "Version: $VERSION"
  echo "License: GPL-3.0-only"
  echo "Vendor: $VENDOR"
  echo "Architecture: $ARCH"
  echo "Maintainer: $MAINTAINER"
  echo "Installed-Size: $(du -sk "$WORK/pkg" | cut -f1)"
  echo "Depends: $DEPENDS"
  [ -n "$RECOMMENDS" ] && echo "Recommends: $RECOMMENDS"
  echo "Section: $PKG_CATEGORY"
  echo "Priority: $PRIORITY"
  echo "Homepage: $HOMEPAGE"
  echo "Description: $SYNOPSIS"
  echo " $DESCRIPTION"
} > "$WORK/pkg/DEBIAN/control"

# ---------------------------------------------------------------------------
# 5. Build and inspect.
# ---------------------------------------------------------------------------
echo "== dpkg-deb build =="
DEB="$WORK/${PKG_NAME}_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$WORK/pkg" "$DEB" >/dev/null \
  || fail "dpkg-deb rejected the package"
pass "dpkg-deb built $(basename "$DEB")"

echo "== control fields =="
dpkg-deb -f "$DEB" | sed 's/^/  /'

echo "== dependency syntax =="
python3 - "$DEB" <<'PY'
import re, subprocess, sys
field = subprocess.run(["dpkg-deb", "-f", sys.argv[1], "Depends"],
                       capture_output=True, text=True).stdout.strip()
atom = re.compile(r"^[a-z0-9][a-z0-9+.-]+(\s*\([<>=]+\s*[^)]+\))?$")
bad = [alt.strip() for dep in field.split(",") for alt in dep.split("|")
       if not atom.match(alt.strip())]
if bad:
    sys.exit("malformed dependency atoms: %s" % bad)
print("  ok   %d dependency clauses parse"
      % len([d for d in field.split(",") if d.strip()]))
PY

echo "== contents =="
dpkg-deb -c "$DEB" | awk '{print "  " $1, $6}' | head -20

echo "== setuid bit on chrome-sandbox =="
if dpkg-deb -c "$DEB" | grep chrome-sandbox | grep -q '^-rws'; then
  pass "chrome-sandbox ships setuid"
else
  echo "  warn chrome-sandbox is not setuid in the archive; postinst sets it"
fi

echo "== desktop entry =="
dpkg-deb --fsys-tarfile "$DEB" | tar -xO ./usr/share/applications/"$EXECUTABLE".desktop > "$WORK/check.desktop"
sed 's/^/  /' "$WORK/check.desktop"
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$WORK/check.desktop" || fail "desktop entry does not validate"
  pass "desktop entry validates"
else
  echo "  skip desktop-file-validate not installed"
fi

echo "== extraction =="
ROOTFS="$WORK/rootfs"
mkdir -p "$ROOTFS"
dpkg-deb -x "$DEB" "$ROOTFS"
[ -x "$ROOTFS/opt/$PRODUCT_NAME/$EXECUTABLE" ] || fail "payload binary missing or not executable"
pass "package extracts with the expected layout"

echo
echo "PASSED: Debian metadata is well formed."

# ---------------------------------------------------------------------------
# 6. Optional: emit a smoke-test package.
#
# Same dependency list and same maintainer-script logic as the real package,
# but under its own name and its own paths so it can never be mistaken for
# Vortex or shadow a real installation. Install it on a target distribution to
# check that every dependency resolves and that the postinst runs clean.
# ---------------------------------------------------------------------------
if [ "${EMIT_SMOKETEST:-0}" = "1" ]; then
  echo "== smoke-test package =="
  SMOKE_NAME="vortex-deb-smoketest"
  SMOKE="$WORK/smoke"
  mkdir -p "$SMOKE/DEBIAN" "$SMOKE/opt/$SMOKE_NAME" \
           "$SMOKE/usr/share/applications" \
           "$SMOKE/usr/share/icons/hicolor/256x256/apps"

  cat > "$SMOKE/opt/$SMOKE_NAME/$SMOKE_NAME" <<'STUB'
#!/bin/sh
echo "This is the Vortex packaging smoke test, not Vortex."
echo "Remove it with: sudo apt purge vortex-deb-smoketest"
STUB
  chmod 755 "$SMOKE/opt/$SMOKE_NAME/$SMOKE_NAME"
  printf 'stub\n' > "$SMOKE/opt/$SMOKE_NAME/chrome-sandbox"
  chmod 4755 "$SMOKE/opt/$SMOKE_NAME/chrome-sandbox"
  cp "$REPO_ROOT/assets/images/vortex.png" \
     "$SMOKE/usr/share/icons/hicolor/256x256/apps/$SMOKE_NAME.png"

  # Pointed at a test-only scheme so it cannot steal nxm:// from a real manager.
  cat > "$SMOKE/usr/share/applications/$SMOKE_NAME.desktop" <<STUBDESK
[Desktop Entry]
Name=Vortex packaging smoke test
Comment=Verifies Debian dependencies and desktop integration. Not Vortex.
Exec=/opt/$SMOKE_NAME/$SMOKE_NAME
Icon=$SMOKE_NAME
Terminal=true
Type=Application
Categories=Game;
MimeType=x-scheme-handler/nxm-smoketest;
STUBDESK

  for f in postinst postrm; do
    sed -e "s|/opt/Vortex|/opt/$SMOKE_NAME|g" \
        -e "s|/$EXECUTABLE\"|/$SMOKE_NAME\"|g" \
        -e "s|\"vortex\"|\"$SMOKE_NAME\"|g" \
        "$WORK/pkg/DEBIAN/$f" > "$SMOKE/DEBIAN/$f"
    chmod 755 "$SMOKE/DEBIAN/$f"
    bash -n "$SMOKE/DEBIAN/$f"
  done

  {
    echo "Package: $SMOKE_NAME"
    echo "Version: 0.0.0"
    echo "Architecture: $ARCH"
    echo "Maintainer: $MAINTAINER"
    echo "Installed-Size: $(du -sk "$SMOKE" | cut -f1)"
    echo "Depends: $DEPENDS"
    [ -n "$RECOMMENDS" ] && echo "Recommends: $RECOMMENDS"
    echo "Section: $PKG_CATEGORY"
    echo "Priority: $PRIORITY"
    echo "Homepage: $HOMEPAGE"
    echo "Description: Dependency and desktop-integration smoke test for Vortex"
    echo " Contains no application code. It carries the exact dependency list of"
    echo " the real Vortex package so that dependency resolution and the"
    echo " maintainer scripts can be checked on a target distribution."
  } > "$SMOKE/DEBIAN/control"

  mkdir -p "$REPO_ROOT/dist"
  OUT="$REPO_ROOT/dist/${SMOKE_NAME}_0.0.0_${ARCH}.deb"
  dpkg-deb --root-owner-group --build "$SMOKE" "$OUT" >/dev/null
  pass "wrote $OUT"
fi
