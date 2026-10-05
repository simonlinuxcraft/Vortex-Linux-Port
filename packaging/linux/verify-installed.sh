#!/usr/bin/env bash
#
# Verifies an installed Vortex Debian package on the machine it runs on.
#
# Checks the things that silently break Vortex on Linux even when the package
# installs fine: bundled helpers that lost their exec bit, native modules whose
# runpath points at the build machine, shared libraries that do not resolve on
# this distribution, a glibc floor above what the system has, and a startup
# crash.
#
# Environment:
#   EXPECT_FOMOD_NATIVE  "true" if the native FOMOD installer must load here
#                        (glibc 2.38 or newer), "false" if it must not, unset
#                        to only report.
#   APP_DIR              install location, defaults to /opt/Vortex
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/Vortex}"
UNPACKED="$APP_DIR/resources/app.asar.unpacked"
FAILED=0

pass() { echo "  ok   $*"; }
warn() { echo "  warn $*"; }
fail() { echo "  FAIL $*"; FAILED=1; }

system_glibc="$(getconf GNU_LIBC_VERSION | awk '{print $2}')"
echo "== system =="
echo "  $(. /etc/os-release && echo "$PRETTY_NAME"), glibc $system_glibc"

echo "== launcher =="
BIN="$(readlink -f /usr/bin/vortex 2>/dev/null || true)"
if [ -n "$BIN" ] && [ -x "$BIN" ]; then
  pass "/usr/bin/vortex -> $BIN"
else
  fail "/usr/bin/vortex missing or dangling"
fi
if [ -u "$APP_DIR/chrome-sandbox" ] && [ "$(stat -c %U "$APP_DIR/chrome-sandbox")" = root ]; then
  pass "chrome-sandbox is setuid root"
else
  fail "chrome-sandbox is not setuid root; Electron will refuse to start"
fi

echo "== desktop entry =="
# protocolRegistration/linux/nxm.ts registers this id as the nxm:// handler; a
# package that ships its entry under any other name leaves download links dead.
entry=/usr/share/applications/com.nexusmods.vortex.desktop
if [ ! -f "$entry" ]; then
  fail "$entry missing; nxm:// links from the browser would go nowhere"
else
  grep -q '^MimeType=.*x-scheme-handler/nxm;' "$entry" \
    && pass "com.nexusmods.vortex.desktop handles x-scheme-handler/nxm" \
    || fail "$entry does not declare x-scheme-handler/nxm"
  exec_bin="$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$entry" | tr -d '"')"
  [ "$(readlink -f "$exec_bin")" = "$BIN" ] \
    && pass "Exec points at the installed binary" \
    || fail "Exec=$exec_bin does not point at $BIN"
  if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$entry" && pass "desktop entry validates" || fail "desktop entry does not validate"
  fi
fi

echo "== icons =="
# electron-builder derives the hicolor size directory from the icon file name;
# a name without a size ends up in hicolor/0x0, which no icon theme looks at.
icons="$(find /usr/share/icons/hicolor -path '*/apps/com.nexusmods.vortex.png' 2>/dev/null | sort)"
if echo "$icons" | grep -q '/0x0/'; then
  fail "icon installed under hicolor/0x0, menus will show a generic icon"
elif [ -z "$icons" ]; then
  fail "no com.nexusmods.vortex icon in the hicolor theme"
else
  pass "icon sizes: $(echo "$icons" | sed 's|.*/hicolor/\([^/]*\)/.*|\1|' | tr '\n' ' ')"
fi

# Every x86-64 ELF object shipped in the package.
mapfile -t elfs < <(find "$APP_DIR" -type f -size +1k \
  -exec sh -c 'head -c4 "$1" | grep -q "ELF" && echo "$1"' _ {} \; \
  | while read -r f; do readelf -h "$f" 2>/dev/null | grep -q X86-64 && echo "$f"; done)

echo "== runpaths =="
leaked=0
for f in "${elfs[@]}"; do
  rp="$(readelf -d "$f" 2>/dev/null | sed -n 's/.*R\(UN\)\?PATH.*\[\(.*\)\]/\2/p')"
  [ -z "$rp" ] && continue
  IFS=: read -ra parts <<< "$rp"
  for p in "${parts[@]}"; do
    case "$p" in
      '$ORIGIN'*|"$APP_DIR"*) ;;
      *) fail "${f#$APP_DIR/} has runpath $p from the build machine"; leaked=1 ;;
    esac
  done
done
[ "$leaked" -eq 0 ] && pass "no runpath points outside the package"

echo "== glibc floor =="
# Same exclusions as packaging/linux/after-pack.cjs: the native FOMOD prebuild
# (Vortex falls back to the IPC installer) and @parcel/watcher (only loaded
# lazily by sass watch mode).
floor=""
for f in "${elfs[@]}"; do
  case "$f" in
    */ModInstaller.Native.so|*/modinstaller.node|*/@parcel/watcher/*) continue ;;
  esac
  v="$(objdump -p "$f" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1 || true)"
  [ -z "$v" ] && continue
  floor="$(printf '%s\n%s\n' "$floor" "$v" | sed '/^$/d' | sort -V | tail -1)"
done
echo "  package needs glibc $floor"
if [ "$(printf '%s\n%s\n' "$floor" "$system_glibc" | sort -V | tail -1)" = "$system_glibc" ]; then
  pass "system glibc $system_glibc satisfies $floor"
else
  fail "system glibc $system_glibc is older than the $floor the package needs"
fi
if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W vortex >/dev/null 2>&1; then
  declared="$(dpkg-query -W -f='${Depends}' vortex | sed -n 's/.*libc6 (>= \([0-9.]*\)).*/\1/p')"
  if [ -z "$declared" ]; then
    fail "the package does not declare a libc6 floor"
  elif [ "$(printf '%s\n%s\n' "$declared" "$floor" | sort -V | tail -1)" = "$declared" ]; then
    pass "Depends declares libc6 (>= $declared)"
  else
    fail "Depends declares libc6 (>= $declared) but the binaries need $floor"
  fi
fi

echo "== shared libraries =="
unresolved=0
for f in "${elfs[@]}"; do
  # musl prebuilds are never loaded on a glibc system; node-gyp-build picks
  # the prebuild by libc.
  case "$f" in
    */ModInstaller.Native.so|*/modinstaller.node|*/@parcel/watcher/*|*musl*) continue ;;
  esac
  missing="$(ldd "$f" 2>&1 | grep -E 'not found' || true)"
  if [ -n "$missing" ]; then
    fail "${f#$APP_DIR/}: $(echo "$missing" | tr -s ' \t\n' ' ')"
    unresolved=1
  fi
done
[ "$unresolved" -eq 0 ] && pass "every library the package links against resolves"

echo "== bundled 7-Zip =="
sevenzip="$UNPACKED/node_modules/7z-bin/linux/7zzs"
if [ -x "$sevenzip" ]; then
  tmp="$(mktemp -d)"
  echo "vortex" > "$tmp/probe.txt"
  if "$sevenzip" a -bd "$tmp/probe.7z" "$tmp/probe.txt" >/dev/null \
     && "$sevenzip" x -bd -o"$tmp/out" "$tmp/probe.7z" >/dev/null \
     && cmp -s "$tmp/probe.txt" "$tmp/out/probe.txt"; then
    pass "7zzs packs and extracts an archive"
  else
    fail "7zzs is present but cannot round-trip an archive"
  fi
  rm -rf "$tmp"
else
  fail "bundled 7-Zip missing or not executable at ${sevenzip#$APP_DIR/}; no mod can be installed"
fi

echo "== native FOMOD installer =="
fomod_out="$(ELECTRON_RUN_AS_NODE=1 "$BIN" -e '
  const m = require(process.argv[1]);
  const r = m.NativeModInstaller.testSupported(["fomod/ModuleConfig.xml"], ["XmlScript"]);
  console.log(r.supported ? "supported" : "unsupported");
' "$APP_DIR/resources/app.asar/node_modules/@nexusmods/fomod-installer-native" 2>&1 || true)"
if [ "$fomod_out" = "supported" ]; then
  state=loads
else
  state=fails
fi
case "${EXPECT_FOMOD_NATIVE:-}:$state" in
  true:loads)  pass "native FOMOD installer loads and recognises a FOMOD archive" ;;
  false:fails) pass "native FOMOD installer does not load here, as expected; Vortex uses the IPC installer" ;;
  :loads)      pass "native FOMOD installer loads" ;;
  :fails)      warn "native FOMOD installer does not load: $(echo "$fomod_out" | head -2 | tr '\n' ' ')" ;;
  *)           fail "native FOMOD installer $state, expected ${EXPECT_FOMOD_NATIVE}: $(echo "$fomod_out" | head -2 | tr '\n' ' ')" ;;
esac

echo "== startup =="
# A real start, not --version: the window, the renderer, the extension
# loader and the state store all have to come up. Vortex staying alive for the
# whole window counts as success; exiting early does not.
home="$(mktemp -d)"
args=()
if [ "$(id -u)" -eq 0 ]; then
  warn "running as root, Chromium needs --no-sandbox; the setuid sandbox is not exercised"
  args+=(--no-sandbox)
fi
set +e
HOME="$home" XDG_CONFIG_HOME="$home/.config" timeout 60 \
  xvfb-run -a /usr/bin/vortex "${args[@]}" > "$home/stdout.log" 2>&1
status=$?
set -e
if [ "$status" -eq 124 ]; then
  pass "Vortex was still running after 60 seconds"
else
  fail "Vortex exited after start with status $status"
  tail -20 "$home/stdout.log" | sed 's/^/       /'
fi
if grep -qE "error while loading shared libraries|GLIBC_[0-9.]+' not found" "$home/stdout.log"; then
  fail "loader errors during startup:"
  grep -E "error while loading shared libraries|not found" "$home/stdout.log" | head -5 | sed 's/^/       /'
fi
rm -rf "$home"

echo
if [ "$FAILED" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "PASSED"
