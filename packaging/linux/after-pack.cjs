// electron-builder afterPack hook for Linux builds.
//
// Runs after the app directory is assembled and before the deb and tar.gz are
// created, so both artifacts get what it changes. It does two things.
//
// 1. Rewrite build-machine runpaths.
//    Native modules compiled by node-gyp can carry a RUNPATH that points into
//    the build machine's node_modules. fomod-installer-native is the case that
//    matters: its binding.gyp links modinstaller.node against
//    ModInstaller.Native.so with `-Wl,-rpath,<(module_root_dir)`. On the build
//    machine that path exists, so everything works there; on a user's machine
//    it does not, and every FOMOD install fails with "cannot open shared
//    object file". Rewriting such entries to $ORIGIN makes each library look
//    next to itself, which is where node-gyp's `copies` step put it.
//
// 2. Declare the real glibc and libstdc++ floor.
//    Native modules link against the glibc and libstdc++ of the machine that
//    built them. A package built on Ubuntu 24.04 needs GCC 13's libstdc++ for
//    leveldown, and leveldown is Vortex's state store; without it nothing
//    starts. Like dpkg-shlibdeps does for regular Debian packages, this reads
//    the symbol versions the shipped binaries require and adds matching
//    `libc6` and `libstdc++6` entries to the deb's Depends, so apt refuses the
//    package on a system that is too old instead of installing something that
//    crashes on start.

const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

// Shipped, but never on the path that decides whether Vortex runs:
//  - The native FOMOD installer is a prebuilt that needs glibc 2.38. When it
//    cannot load, Vortex falls back to the IPC FOMOD installer.
//  - @parcel/watcher comes in through sass and @tailwindcss/cli. sass loads it
//    lazily for watch mode only and tolerates it failing to load; Vortex only
//    calls sass.compile.
const OUTSIDE_FLOOR = [
    /[\\/]ModInstaller\.Native\.so$/,
    /[\\/]modinstaller\.node$/,
    /[\\/]@parcel[\\/]watcher[\\/]/,
];

// First GCC release that provides each GLIBCXX symbol version. Debian and
// Ubuntu version libstdc++6 by the GCC release it comes from.
const GLIBCXX_TO_GCC = {
    "3.4.29": "11",
    "3.4.30": "12",
    "3.4.31": "13.1",
    "3.4.32": "13.2",
    "3.4.33": "14",
    "3.4.34": "15",
};

function run(cmd, args) {
    return execFileSync(cmd, args, {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
        maxBuffer: 64 * 1024 * 1024,
    }).trim();
}

function requireTool(cmd, pkg) {
    try {
        run(cmd, ["--version"]);
    } catch {
        throw new Error(`${cmd} is required to package Vortex for Linux (install ${pkg})`);
    }
}

// x86-64 ELF objects only: the tree also carries Windows, macOS, arm and musl
// prebuilds that are never loaded on this target.
function isX64Elf(file) {
    const fd = fs.openSync(file, "r");
    try {
        const head = Buffer.alloc(20);
        if (fs.readSync(fd, head, 0, 20, 0) < 20) return false;
        return head.readUInt32BE(0) === 0x7f454c46 && head.readUInt16LE(18) === 0x3e;
    } finally {
        fs.closeSync(fd);
    }
}

function walk(dir, out = []) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) {
            walk(full, out);
        } else if (entry.isFile() && isX64Elf(full)) {
            out.push(full);
        }
    }
    return out;
}

function compareVersions(a, b) {
    const pa = a.split(".").map(Number);
    const pb = b.split(".").map(Number);
    for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
        const d = (pa[i] ?? 0) - (pb[i] ?? 0);
        if (d !== 0) return d;
    }
    return 0;
}

function maxVersion(a, b) {
    if (a == null) return b;
    if (b == null) return a;
    return compareVersions(a, b) >= 0 ? a : b;
}

// The version references an object needs, read from its .gnu.version_r table.
function requiredVersions(file) {
    let dump;
    try {
        dump = run("objdump", ["-p", file]);
    } catch {
        return { glibc: null, glibcxx: null };
    }
    let glibc = null;
    let glibcxx = null;
    for (const m of dump.matchAll(/\b(GLIBCXX|GLIBC)_([0-9.]+)\b/g)) {
        if (m[1] === "GLIBC") glibc = maxVersion(glibc, m[2]);
        else glibcxx = maxVersion(glibcxx, m[2]);
    }
    return { glibc, glibcxx };
}

function fixRunpaths(context, files) {
    const unpacked = path.join(context.appOutDir, "resources", "app.asar.unpacked");
    for (const file of files) {
        if (!file.startsWith(unpacked)) continue;
        let runpath;
        try {
            runpath = run("patchelf", ["--print-rpath", file]);
        } catch {
            // Statically linked, such as the bundled 7zzs: no dynamic section.
            continue;
        }
        const entries = runpath.split(":").filter((e) => e.length > 0);
        if (!entries.some((e) => path.isAbsolute(e))) continue;
        run("patchelf", ["--set-rpath", "$ORIGIN", file]);
        console.log(
            `  • fixed runpath ${path.relative(context.appOutDir, file)}: ${runpath} -> $ORIGIN`,
        );
    }
}

function declareRuntimeFloor(context, files) {
    let glibc = null;
    let glibcxx = null;
    for (const file of files) {
        if (OUTSIDE_FLOOR.some((re) => re.test(file))) continue;
        const req = requiredVersions(file);
        glibc = maxVersion(glibc, req.glibc);
        glibcxx = maxVersion(glibcxx, req.glibcxx);
    }

    const floor = [];
    if (glibc != null) floor.push(`libc6 (>= ${glibc})`);
    const gcc = glibcxx != null ? GLIBCXX_TO_GCC[glibcxx] : null;
    if (glibcxx != null && gcc == null && compareVersions(glibcxx, "3.4.34") > 0) {
        throw new Error(`no GCC release known for GLIBCXX_${glibcxx}; extend GLIBCXX_TO_GCC`);
    }
    if (gcc != null) floor.push(`libstdc++6 (>= ${gcc})`);
    console.log(
        `  • runtime floor glibc ${glibc ?? "-"}, GLIBCXX ${glibcxx ?? "-"} -> ${floor.join(", ") || "none"}`,
    );

    // FpmTarget copied the deb options when it was constructed, before packing,
    // but its copy still points at this same array. Editing the array in place
    // is the one way the computed floor reaches fpm. electron-builder is pinned
    // to 24.13.3, which this relies on.
    const depends = context.packager.config.deb?.depends;
    if (!Array.isArray(depends)) {
        throw new Error("deb.depends must be an array in electron-builder.config.json");
    }
    const kept = depends.filter((d) => !/^(libc6|libstdc\+\+6)\b/.test(d));
    depends.splice(0, depends.length, ...floor, ...kept);
}

exports.default = async function afterPack(context) {
    if (context.electronPlatformName !== "linux") {
        return;
    }

    requireTool("patchelf", "patchelf");
    requireTool("objdump", "binutils");

    const files = walk(context.appOutDir);
    fixRunpaths(context, files);
    declareRuntimeFloor(context, files);
};
