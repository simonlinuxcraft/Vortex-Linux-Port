# Linux packaging

Vortex builds two native Linux artifacts from the same payload:

| Artifact         | File                               | Built by                         |
| ---------------- | ---------------------------------- | -------------------------------- |
| Debian package   | `dist/vortex_<version>_amd64.deb`  | electron-builder `deb` target    |
| Portable archive | `dist/vortex-<version>-x64.tar.gz` | electron-builder `tar.gz` target |

The Arch recipe in `packaging/linux/PKGBUILD` consumes the tarball, so all
three distribution paths ship an identical payload.

## Building

```bash
pnpm install
pnpm -F "@vortex/main" version 2.6.2 --no-git-tag-version --no-git-checks --allow-same-version
pnpm package:nosign
git restore src/main/package.json
```

Run it from the repo root. `src/main/package.json` carries the placeholder
version `1.0.0`, and electron-builder writes the version straight into the
control file, so it has to be injected first.

Build requirements beyond Node and pnpm: the .NET 9 SDK (for
`tools/dotnetprobe`), a C/C++ toolchain, the fontconfig headers (for
`font-scanner`), and `patchelf` and `objdump` (for
`packaging/linux/after-pack.cjs`; `objdump` comes with binutils, which
`build-essential` pulls in).
On Debian and Ubuntu:

```bash
sudo apt install build-essential libfontconfig1-dev patchelf
```

If `pnpm install` fails in a native module with errors such as
`'EXTERN_C_START' does not name a type`, node-gyp compiled against a
half-written header cache: several native modules download the Node headers
in parallel into the same directory. Run `npx node-gyp install` once and
repeat the install.

CI does all of this through `.github/workflows/package-linux.yml`, which can
be started manually from the Actions tab. It builds once on Ubuntu 22.04,
installs and starts the package on Ubuntu 22.04 and 24.04, and uploads both
artifacts.

## The glibc and libstdc++ floor

Native modules link against the glibc and the libstdc++ of the machine that
built them, and will not load on a system with older ones. This is what
governs how many distributions a given package actually reaches.

The floor is therefore not written into the configuration by hand.
`packaging/linux/after-pack.cjs` reads the symbol versions every shipped
x86-64 binary requires (the same information `dpkg-shlibdeps` uses for regular
Debian packages) and prepends `libc6 (>= ...)` and `libstdc++6 (>= ...)` to the
deb's `Depends`. apt then refuses the package on a system that is too old,
instead of installing something that crashes on start. The build log shows the
result:

```
• runtime floor glibc 2.34, GLIBCXX 3.4.31 -> libc6 (>= 2.34), libstdc++6 (>= 13.1)
```

That line is from a build on Ubuntu 24.04. GCC 13 there compiles `leveldown`
(Vortex's state store) against `GLIBCXX_3.4.31`, so the package needs GCC 13's
libstdc++, which Ubuntu 22.04 and Debian 12 do not have. The CI workflow builds
on Ubuntu 22.04 for that reason: GCC 11 and glibc 2.35 keep the floor low
enough for both.

Two shipped components are left out of the calculation because Vortex does
not depend on them loading:

- `@nexusmods/fomod-installer-native` ships `ModInstaller.Native.so` as a
  prebuilt .NET NativeAOT library that requires glibc 2.38, solely because of
  the `fmod` and `fmodf` symbol versions. Vortex registers the native FOMOD
  installer at priority 10 and the IPC FOMOD installer at priority 20, and
  `VortexModTester.create` returns null when the native module fails to load,
  so Vortex falls back to the IPC installer. That one needs a .NET 9 runtime.
- `@parcel/watcher` arrives through `sass` and `@tailwindcss/cli`. `sass` only
  loads it lazily for watch mode and tolerates it failing to load; Vortex only
  calls `sass.compile`.

Reach of a package built on Ubuntu 22.04, as CI does:

| Distribution                  | glibc   | Vortex | Native FOMOD                  |
| ----------------------------- | ------- | ------ | ----------------------------- |
| Ubuntu 24.04 and newer        | 2.39+   | yes    | yes, no .NET needed           |
| Debian 13 (trixie)            | 2.41    | yes    | yes, no .NET needed           |
| Fedora 39 and newer           | 2.38+   | yes    | yes, no .NET needed           |
| Arch, openSUSE Tumbleweed     | current | yes    | yes, no .NET needed           |
| Ubuntu 22.04                  | 2.35    | yes    | no, IPC fallback needs .NET 9 |
| Debian 12 (bookworm)          | 2.36    | yes    | no, IPC fallback needs .NET 9 |
| Debian 11, Ubuntu 20.04       | 2.31    | no     | no                            |
| Alpine and other musl systems | musl    | no     | no                            |

A package built on Ubuntu 24.04 or newer drops the two rows for Ubuntu 22.04
and Debian 12. `packaging/linux/verify-installed.sh` reports the effective
floor of an installed package and checks it against what `Depends` declares.

## What the Debian package contains

`FpmTarget` and `LinuxTargetHelper` in `app-builder-lib` decide these paths,
not this repo.

```
/opt/Vortex/                                     application payload
/opt/Vortex/com.nexusmods.vortex                 launcher binary
/opt/Vortex/chrome-sandbox                       Electron SUID sandbox helper
/usr/bin/vortex                                  symlink, via update-alternatives
/usr/share/applications/com.nexusmods.vortex.desktop
                                                 launcher entry, handles nxm://
/usr/share/icons/hicolor/<size>/apps/com.nexusmods.vortex.png   16 to 256 px
```

The directory under `/opt` uses the product name (`Vortex`). The binary, the
desktop entry and the icons use `linux.executableName`, which is the app id
`com.nexusmods.vortex`; see the configuration notes for why. The command is
`vortex`.

## What is bundled rather than depended on

`7z-bin` ships a static Linux binary (`linux/7zzs`) with the executable bit set
in git, and `asarUnpack` keeps `node_modules/7z-bin` outside the asar. 7-Zip
therefore needs no system package. Every archive extraction in Vortex goes
through it, so `verify-installed.sh` packs and extracts a test archive with
the installed copy.

`quickbms-support` downloads `quickbms_4gb_files.exe` from
`aluigi.altervista.org` at build time and spawns it directly. That is a
Windows binary; on Linux it only runs if Wine is registered with binfmt_misc.

## Configuration notes

Everything below is in `src/main/electron-builder.config.json` or
`src/main/package.json` and exists for a concrete reason. Removing any of it
breaks the build or the package.

**`deb.depends` is set explicitly.** electron-builder 24.13.3 defaults to
`gconf2`, `gconf-service`, `libnotify4`, `libappindicator1`, `libxtst6` and
`libnss3`. The first two were dropped from Debian after buster and
`libappindicator1` is gone from Ubuntu 22.04 onward, so a package built with
the defaults is uninstallable on any current distribution while still missing
most libraries Electron links against. The list uses alternatives such as
`libgtk-3-0 | libgtk-3-0t64` so that one package covers both sides of the
64-bit `time_t` transition, and is cross-checked against the library set that
`.github/workflows/e2e.yml` installs to run Electron on Linux runners.

**`deb.packageName` is pinned to `vortex`.** `prepare-dist-package.mjs` renames
the package to `Vortex`, and electron-builder derives the Debian package name
from it. dpkg only accepts lowercase names.

**`homepage` in `src/main/package.json` is required.** electron-builder's
`FpmTarget.computeFpmMetaInfoOptions` aborts with "Please specify project
homepage" when neither `homepage` nor a GitHub `repository` is set. The Windows
target never reaches that check. Only `homepage` is set: adding `repository`
would also make electron-builder infer a GitHub publish provider for the deb.

**Windows-only `extraResources` live under `win`.** Platform-specific
`extraResources` are appended to the top-level list rather than replacing it
(see `getFileMatchers` in `app-builder-lib/out/fileMatcher.js`), so the NSIS
payload would otherwise be copied into the Linux packages.

**`asarUnpack` includes `**/_.so`.** The dynamic linker cannot load a shared
library from inside `app.asar`. `modinstaller.node`needs`ModInstaller.Native.so`next to it at runtime; unpacking only`\*\*/_.node`
left the library inside the archive.

**`afterPack` rewrites build-machine runpaths and declares the floor.** `fomod-installer-native`'s
`binding.gyp` links with `-Wl,-rpath,<(module_root_dir)`, an absolute path into
the build machine's `node_modules`. The package works on the machine that
built it and fails everywhere else with "cannot open shared object file".
`packaging/linux/after-pack.cjs` rewrites every absolute runpath under
`app.asar.unpacked` to `$ORIGIN` before the deb and tarball are created. The
same hook computes the `libc6` and `libstdc++6` entries described above. It
has to edit the `deb.depends` array in place, because `FpmTarget` copies the
deb options before packing; that relies on the pinned electron-builder
24.13.3.

**The FOMOD library in the package root is excluded.** `install.js` copies
`ModInstaller.Native.so` into the package root for linking, and node-gyp's
`copies` step also places it beside `modinstaller.node`, which is the copy
that is loaded. The root copy is the Linux twin of the `.dll` that was already
excluded for Windows.

**`linux.executableName` is the app id, `com.nexusmods.vortex`.**
`protocolRegistration/linux/nxm.ts` registers `com.nexusmods.vortex.desktop` as
the `nxm://` handler for every packaged build, the AppStream metadata in
`flatpak/` names the same desktop id as its launchable, and the Flatpak uses it
as its app id. electron-builder 24.13.3 names the desktop entry and the icons
after the executable with no separate setting, so with the executable called
`vortex` the package shipped `vortex.desktop`, `xdg-settings` failed with
status 2 (file not found), and download links from the Nexus Mods website did
nothing. `after-install.sh` still provides `/usr/bin/vortex`.

**`linux.icon` points at `packaging/linux/icons/`.** electron-builder takes
the icon size from the file name. With the single `assets/images/vortex.png`
it found none and installed the icon under `hicolor/0x0/apps/`, a directory the
icon theme specification does not define, so menus showed a generic icon. The
six PNGs in `packaging/linux/icons/` are the sizes embedded in
`assets/images/vortex.ico`; the small ones are drawn for their size rather than
scaled down.

**`linux.publish` is `null`.** With no publish setting, electron-builder
guesses GitHub as the provider, cannot find a repository, writes a half
configured `app-update.yml` and `package-type` into the package anyway, and
then crashes in `updateInfoBuilder.computeChannelNames` on the null result,
after both artifacts are already on disk. An explicit `null` turns update
metadata off for Linux.

**`linux.category` is `Game;` alone.** `Game` and `Utility` are both
freedesktop main categories, and listing both makes the entry appear twice in
the application menu.

**`linux.maintainer` is the package maintainer, `linux.vendor` the vendor.**
The Debian control file wants `Name <address>` in `Maintainer`, and
electron-builder copies the maintainer into `Vendor` unless a vendor is set.
Vortex itself comes from Black Tree Gaming, so that stays the vendor; the
packages are maintained by simonlinuxcraft.

## Maintainer scripts

`packaging/linux/after-install.sh` and `after-remove.sh` replace
electron-builder's defaults. They keep the original behaviour (the
`update-alternatives` symlink, the setuid bit on `chrome-sandbox`, the MIME and
desktop database refresh) and add an icon cache refresh.

One trap: electron-builder runs these files through a template replacer that
scans for a dollar sign followed by a braced name and aborts the build with
"Macro ... is not defined" for anything it does not recognise. The scan covers
comments. Every shell variable in those scripts is therefore written without
braces, and no brace-form example appears in them.

## Verification

Two scripts, for two different questions.

`packaging/linux/verify-deb-metadata.sh` checks the packaging without a build.
It reads the real configuration, expands the maintainer scripts exactly as
electron-builder would, builds a package from a stub payload with `dpkg-deb`
and inspects the result. It catches invalid package names, broken dependency
syntax, unresolvable macros and desktop entry errors in seconds.
`EMIT_SMOKETEST=1` additionally writes `dist/vortex-deb-smoketest_0.0.0_amd64.deb`,
which carries the real dependency list and no application, for checking that
dependencies resolve on a target distribution.

`packaging/linux/verify-installed.sh` checks a real, installed package on the
machine it runs on: the setuid sandbox, runpaths that leak the build machine,
the effective glibc floor against the system's, unresolved shared libraries, a
7-Zip round trip with the bundled binary, whether the native FOMOD installer
loads and recognises a FOMOD archive, and a 60 second start under `xvfb`.
Set `EXPECT_FOMOD_NATIVE=true` or `false` to turn the FOMOD check into an
assertion.

## Open points

**The auto-updater is off for Linux.** `linux.publish` is `null`, so the
package carries no `app-update.yml` and no `package-type`, and
`electron-updater` falls back to its AppImage updater, which stays inactive
outside an AppImage. Updates have to come from wherever the package is
distributed (a GitHub release, an apt repository, the AUR).

**arm64 is not built.** Only `amd64` is produced. Adding it means an arm64
runner and native modules compiled for that architecture.
