//! Build, package, deploy and run native webOS TV applications.
//!
//! The TV is armv7-a with a SOFT-FLOAT EABI (`arm-linux-gnueabi`, NOT gnueabihf)
//! and glibc 2.35; we target glibc 2.31 so binaries stay forward-compatible.
//! -mcpu is set so the FPU is actually used -- see docs/device.md, this is an
//! ABI choice, not software float emulation.
//! All device libraries are dlopen'd at runtime, so nothing here needs a sysroot.
//!
//!   zig build                        build every app into zig-out/bin
//!   zig build run   -Dapp=wlbox      deploy one app and run it on the TV
//!   zig build deploy                 scp every app to $WEBOS_TMP
//!   zig build package -Dapp=wlbox    build an installable .ipk
//!   zig build install-app -Dapp=wlbox    package, push and install via luna
//!   zig build info                   show the resolved .env settings
//!
//! SSH details come from .env (see .env.example), which is sourced by the shell
//! steps below -- it is already KEY=VALUE, so no parser is needed here.
const std = @import("std");

/// `fbflash` pokes /dev/fb0 with raw syscalls and needs no libc, so it links
/// fully static. The others need libc purely for dlopen.
const App = struct { name: []const u8, src: []const u8, libc: bool, shaders: bool = false };

const apps = [_]App{
    .{ .name = "fbflash", .src = "src/fbflash.zig", .libc = false },
    .{ .name = "wlinfo", .src = "src/wlinfo.zig", .libc = true },
    .{ .name = "wlbox", .src = "src/wlbox.zig", .libc = true },
    .{ .name = "vkinfo", .src = "src/vkinfo.zig", .libc = true },
    .{ .name = "fptest", .src = "src/fptest.zig", .libc = true },
    .{ .name = "inputlog", .src = "src/inputlog.zig", .libc = true },
    .{ .name = "glinfo", .src = "src/glinfo.zig", .libc = true },
    .{ .name = "gltri", .src = "src/gltri.zig", .libc = true, .shaders = true },
};

/// Sourced by every remote step. Defaults keep a fresh clone working.
const env_preamble =
    \\[ -f .env ] && . ./.env
    \\HOST=${WEBOS_HOST:-10.10.8.63}; USER_=${WEBOS_USER:-root}
    \\TMP=${WEBOS_TMP:-/tmp}; APPDIR=${WEBOS_APPDIR:-/media/developer/apps/usr/palm/applications}
    \\T="$USER_@$HOST"
    \\
;

pub fn build(b: *std.Build) void {
    // Default to the TV's ABI; -Dtarget= still overrides for host testing.
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .arm,
            .os_tag = .linux,
            .abi = .gnueabi,
            .glibc_version = .{ .major = 2, .minor = 31, .patch = 0 },
            // Cortex-A55 has VFPv4/NEON. Without this, a generic armv7 CPU model
            // makes LLVM emit real software-float calls -- which WOULD be slow.
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a55 },
        },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });
    const selected = b.option([]const u8, "app", "Which app for run/package/install-app") orelse "wlbox";

    var exes = std.StringHashMap(*std.Build.Step.Compile).init(b.allocator);
    for (apps) |app| {
        const exe = b.addExecutable(.{
            .name = app.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(app.src),
                .target = target,
                .optimize = optimize,
                .link_libc = app.libc,
            }),
        });
        addAssets(b, exe, app);
        b.installArtifact(exe);
        exes.put(app.name, exe) catch @panic("OOM");
    }

    var chosen_app = apps[0];
    for (apps) |a| if (std.mem.eql(u8, a.name, selected)) {
        chosen_app = a;
    };

    const chosen = exes.get(selected) orelse {
        std.debug.print("unknown -Dapp={s}; known:", .{selected});
        for (apps) |a| std.debug.print(" {s}", .{a.name});
        std.debug.print("\n", .{});
        @panic("unknown app");
    };

    // ---- info ----
    const info = sh(b, env_preamble ++
        \\echo "host=$HOST user=$USER_ tmp=$TMP"
        \\echo "appdir=$APPDIR"
        \\echo "app=$1"
    , &.{selected});
    b.step("info", "Show resolved .env settings").dependOn(&info.step);

    // ---- deploy: every app to $WEBOS_TMP ----
    const deploy = sh(b, env_preamble ++
        \\shift
        \\scp -q "$@" "$T:$TMP/"
        \\echo "deployed to $T:$TMP/"
    , &.{"deploy"});
    for (apps) |app| deploy.addFileArg(exes.get(app.name).?.getEmittedBin());
    b.step("deploy", "scp all apps to the TV's temp dir").dependOn(&deploy.step);

    // ---- run: deploy one app, then execute it with the compositor's env ----
    // A Wayland client needs LSM's environment; an SSH session does not have it.
    const run = sh(b, env_preamble ++
        \\app="$1"; bin="$2"
        \\# An interactive app outlives an interrupted ssh session and then holds
        \\# the binary open, so scp fails with a bare "Failure". Clear it first.
        \\ssh "$T" "killall '$app' 2>/dev/null; true"
        \\scp -q "$bin" "$T:$TMP/$app"
        \\exec ssh "$T" "XDG_RUNTIME_DIR=/tmp/xdg WAYLAND_DISPLAY=wayland-0 $TMP/$app"
    , &.{selected});
    run.addFileArg(chosen.getEmittedBin());
    // Interactive apps print as they go; without this the build swallows it all
    // and only replays it if the command fails.
    run.stdio = .inherit;
    b.step("run", "Deploy and run -Dapp on the TV").dependOn(&run.step);

    // ---- run-host: same source, this machine's compositor ----
    // The Wayland shim picks xdg_wm_base when wl_webos_shell is absent, so the
    // TV app runs as a normal window here. Develop locally, deploy when it works.
    const host_exe = b.addExecutable(.{
        .name = selected,
        // Zig 0.16's self-hosted x86_64 backend miscompiles @memset over a
        // large global slice here (a later `i % 2` reads back wrong). The ARM
        // build goes through LLVM anyway; pin the host build to it too.
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path(chosen_app.src),
            .target = b.resolveTargetQuery(.{}),
            .optimize = optimize,
            .link_libc = chosen_app.libc,
        }),
    });
    addAssets(b, host_exe, chosen_app);
    const run_host = b.addRunArtifact(host_exe);
    b.step("run-host", "Build -Dapp for this PC and run it locally").dependOn(&run_host.step);

    // ---- package: a real .ipk ----
    const pkg = sh(b, ipk_script, &.{selected});
    pkg.addFileArg(chosen.getEmittedBin());
    pkg.addArg(b.pathFromRoot("appinfo.json"));
    pkg.addArg(b.pathFromRoot("zig-out"));
    const pkg_step = b.step("package", "Build an installable .ipk for -Dapp");
    pkg_step.dependOn(&pkg.step);

    // ---- launch: start the installed app through SAM ----
    const launch = sh(b, env_preamble ++
        \\id=$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1")
        \\ssh "$T" "luna-send -n 1 -f luna://com.webos.applicationManager/launch '{\"id\":\"$id\"}'"
    , &.{b.pathFromRoot("appinfo.json")});
    b.step("launch", "Launch the installed app on the TV").dependOn(&launch.step);

    // ---- install-app ----
    const inst = sh(b, env_preamble ++ install_script, &.{b.pathFromRoot("zig-out")});
    inst.step.dependOn(pkg_step);
    b.step("install-app", "Package, push and install -Dapp on the TV").dependOn(&inst.step);
}

/// Every app gets the font and the compiled shaders as embeddable modules.
/// Unused ones cost nothing: an @embedFile nobody references is not emitted.
fn addAssets(b: *std.Build, exe: *std.Build.Step.Compile, app: App) void {
    exe.root_module.addAnonymousImport("font", .{ .root_source_file = b.path("assets/font8x16.bin") });
    if (!app.shaders) return; // don't make every app wait on slangc
    for (shaders) |sh_| {
        exe.root_module.addAnonymousImport(sh_.import, .{ .root_source_file = slangc(b, sh_) });
    }
}

const Shader = struct {
    import: []const u8,
    src: []const u8,
    entry: []const u8,
    /// Slang's name for the stage, then glslang's.
    stage: []const u8,
    short: []const u8,
};

const shaders = [_]Shader{
    .{ .import = "tri_vs", .src = "src/shaders/tri.slang", .entry = "vsMain", .stage = "vertex", .short = "vert" },
    .{ .import = "tri_fs", .src = "src/shaders/tri.slang", .entry = "fsMain", .stage = "fragment", .short = "frag" },
    .{ .import = "text_vs", .src = "src/shaders/text.slang", .entry = "vsText", .stage = "vertex", .short = "vert" },
    .{ .import = "text_fs", .src = "src/shaders/text.slang", .entry = "fsText", .stage = "fragment", .short = "frag" },
};

/// Compile one Slang entry point to GLSL ES. Slang only emits desktop GLSL
/// (there is no ESSL profile), so the header is rewritten: `#version 450` and
/// the two `layout(row_major)` defaults are GLSL 4.x-only, and ES insists on
/// explicit default precision. The body needs no changes, as long as the
/// shaders avoid the constructs Slang lowers to Vulkan-only GLSL --
/// see docs/opengl.md.
fn slangc(b: *std.Build, s: Shader) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{ "sh", "-c", slang_script, "--" });
    run.addFileArg(b.path(s.src));
    run.addArgs(&.{ s.stage, s.entry, s.short });
    return run.addOutputFileArg(b.fmt("{s}.glsl", .{s.import}));
}

const slang_script =
    \\set -e
    \\src="$1"; stage="$2"; entry="$3"; short="$4"; out="$5"
    \\command -v slangc >/dev/null || { echo "slangc not found; see README" >&2; exit 1; }
    \\tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
    \\slangc "$src" -target glsl -stage "$stage" -entry "$entry" -o "$tmp"
    \\sed -e '1s|.*|#version 320 es\nprecision highp float;\nprecision highp int;|' \
    \\    -e '/^layout(row_major) uniform;$/d' -e '/^layout(row_major) buffer;$/d' \
    \\    "$tmp" > "$out"
    \\if command -v glslangValidator >/dev/null; then glslangValidator -S "$short" "$out" >/dev/null; fi
;

fn sh(b: *std.Build, script: []const u8, args: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "sh", "-c", script, "--" });
    for (args) |a| run.addArg(a);
    run.has_side_effects = true;
    return run;
}

/// Assembles a webOS .ipk. `ares-package` would do this, but it drags in the
/// whole webOS SDK for what is two tarballs and an ar archive.
///
/// Three details matter, all learned by diffing against a real webosbrew .ipk
/// (org.webosbrew.hbchannel); getting any of them wrong fails the install with
/// a bare `errorCode: -15` at the "ipk parsing" stage:
///   1. ar member names must NOT carry GNU ar's trailing "/" terminator, so the
///      archive is written by hand rather than with `ar`.
///   2. tar paths must be "usr/palm/..." with no leading "./".
///   3. the control tarball holds "control", not "./control".
const ipk_script =
    \\set -e
    \\app="$1"; bin="$2"; appinfo="$3"; out="$4"
    \\id=$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$appinfo")
    \\ver=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$appinfo")
    \\[ -n "$id" ] && [ -n "$ver" ] || { echo "appinfo.json: missing id/version" >&2; exit 1; }
    \\work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
    \\mkdir -p "$work/data/usr/palm/applications/$id" "$work/control"
    \\sed "s/\"main\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"main\": \"$app\"/" "$appinfo" \
    \\  > "$work/data/usr/palm/applications/$id/appinfo.json"
    \\install -m 755 "$bin" "$work/data/usr/palm/applications/$id/$app"
    \\for extra in icon.png largeIcon.png splash.png; do
    \\  [ -f "assets/$extra" ] && cp "assets/$extra" "$work/data/usr/palm/applications/$id/" || true
    \\done
    \\size=$(du -ks "$work/data" | cut -f1)
    \\cat > "$work/control/control" <<CTL
    \\Package: $id
    \\Version: $ver
    \\Section: misc
    \\Priority: optional
    \\Architecture: arm
    \\Installed-Size: $size
    \\Maintainer: N/A <nobody@example.com>
    \\Description: This is a webOS application.
    \\webOS-Package-Format-Version: 2
    \\webOS-Packager-Version: x.y.x
    \\CTL
    \\printf '2.0\n' > "$work/debian-binary"
    \\# No leading "./" in either tarball.
    \\( cd "$work/data" && tar czf ../data.tar.gz usr )
    \\( cd "$work/control" && tar czf ../control.tar.gz control )
    \\mkdir -p "$out"
    \\ipk="$out/${id}_${ver}_arm.ipk"
    \\now=$(date +%s)
    \\printf '!<arch>\n' > "$ipk"
    \\for m in debian-binary control.tar.gz data.tar.gz; do
    \\  sz=$(wc -c < "$work/$m")
    \\  printf '%-16s%-12d%-6d%-6d%-8s%-10d`\n' "$m" "$now" 0 0 100644 "$sz" >> "$ipk"
    \\  cat "$work/$m" >> "$ipk"
    \\  if [ $((sz % 2)) -eq 1 ]; then printf '\n' >> "$ipk"; fi
    \\done
    \\echo "packaged $ipk"
;

/// luna-send is silent over SSH but still performs the install, so verify by
/// listing the installed directory afterwards rather than trusting its output.
const install_script =
    \\out="$1"
    \\ipk=$(ls -t "$out"/*.ipk 2>/dev/null | head -1)
    \\[ -n "$ipk" ] || { echo "no .ipk in $out; run: zig build package" >&2; exit 1; }
    \\base=$(basename "$ipk"); id=$(echo "$base" | sed 's/_[^_]*_arm\.ipk$//')
    \\scp -q "$ipk" "$T:$TMP/$base"
    \\ssh "$T" "timeout 60 luna-send -i -f luna://com.webos.appInstallService/dev/install '{\"id\":\"$id\",\"ipkUrl\":\"$TMP/$base\",\"subscribe\":true}' 2>&1 | grep -oE '\"(state|reason)\": \"[^\"]*\"' | tail -4; echo '--- installed files:'; ls -la $APPDIR/$id 2>&1 | head"
    \\echo "installed $id (from $base)"
;
