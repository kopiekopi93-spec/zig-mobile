const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const mem = std.mem;
const process = std.process;
const assert = std.debug.assert;
const fatal = std.process.fatal;
const info = std.log.info;
const Allocator = std.mem.Allocator;
const OsTag = std.Target.Os.Tag;

const Arch = enum {
    aarch64,
    x86_64,
};

const Abi = enum {
    none,
    simulator,
};

const OsVer = enum(u32) {
    catalina = 10,
    big_sur = 11,
    monterey = 12,
    ventura = 13,
    sonoma = 14,
    sequoia = 15,
    tahoe = 26,
    golden_gate = 27,
    _,
};

const Target = struct {
    arch: Arch,
    os: OsTag = .macos,
    os_ver: OsVer,
    abi: Abi = .none,

    fn name(self: Target, allocator: Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{
            @tagName(self.arch),
            @tagName(self.os),
            @tagName(self.abi),
        });
    }

    fn fullName(self: Target, allocator: Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}-{s}.{d}-{s}", .{
            @tagName(self.arch),
            @tagName(self.os),
            @backingInt(self.os_ver),
            @tagName(self.abi),
        });
    }
};

const headers_source_prefix: []const u8 = "headers";

const usage =
    \\fetch_them_macos_headers [options] [cc args]
    \\
    \\Options:
    \\  --sysroot     Path to Apple SDK (macOS / iOS / iOS Simulator)
    \\  --os          Target OS: macos (default) or ios
    \\  --simulator   Fetch iOS simulator headers in addition to device (same --sysroot)
    \\  --simulator-only  Fetch only iOS simulator headers, skip device (use with the
    \\                    iPhoneSimulator.sdk --sysroot, separate from the device SDK)
    \\
    \\General Options:
    \\-h, --help                    Print this help and exit
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var argv = std.array_list.Managed([]const u8).init(arena);
    var sysroot: ?[]const u8 = null;
    var target_os: OsTag = .macos;
    var include_simulator: bool = false;
    var simulator_only: bool = false;

    var args_iter = ArgsIterator{ .args = args[1..] };
    while (args_iter.next()) |arg| {
        if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
            return info(usage, .{});
        } else if (mem.eql(u8, arg, "--sysroot")) {
            sysroot = args_iter.nextOrFatal();
        } else if (mem.eql(u8, arg, "--os")) {
            const os_str = args_iter.nextOrFatal();
            if (mem.eql(u8, os_str, "macos")) {
                target_os = .macos;
            } else if (mem.eql(u8, os_str, "ios")) {
                target_os = .ios;
            } else {
                fatal("unsupported OS '{s}', expected 'macos' or 'ios'", .{os_str});
            }
        } else if (mem.eql(u8, arg, "--simulator")) {
            include_simulator = true;
        } else if (mem.eql(u8, arg, "--simulator-only")) {
            simulator_only = true;
        } else try argv.append(arg);
    }

    const sysroot_path = sysroot orelse blk: {
        const target = try std.zig.system.resolveTargetQuery(io, .{ .os_tag = target_os });
        break :blk std.zig.system.darwin.getSdk(arena, io, &target) orelse
            fatal("no SDK found; you can provide one explicitly with '--sysroot' flag", .{});
    };

    var sdk_dir = try Dir.cwd().openDir(io, sysroot_path, .{});
    defer sdk_dir.close(io);
    const sdk_info = try sdk_dir.readFileAlloc(io, "SDKSettings.json", arena, .limited(std.math.maxInt(u32)));

    const parsed_json = try std.json.parseFromSlice(struct {
        DefaultProperties: struct {
            MACOSX_DEPLOYMENT_TARGET: ?[]const u8 = null,
            IPHONEOS_DEPLOYMENT_TARGET: ?[]const u8 = null,
        },
    }, arena, sdk_info, .{ .ignore_unknown_fields = true });

    const raw_ver = switch (target_os) {
        .macos => parsed_json.value.DefaultProperties.MACOSX_DEPLOYMENT_TARGET orelse
            fatal("MACOSX_DEPLOYMENT_TARGET not found in SDKSettings.json", .{}),
        .ios => parsed_json.value.DefaultProperties.IPHONEOS_DEPLOYMENT_TARGET orelse
            fatal("IPHONEOS_DEPLOYMENT_TARGET not found in SDKSettings.json", .{}),
        else => fatal("unsupported OS: {s}", .{@tagName(target_os)}),
    };

    const version = Version.parse(raw_ver) orelse
        fatal("don't know how to parse SDK version: {s}", .{raw_ver});
    const os_ver: OsVer = @fromBackingInt(@intCast(version.major));
    info("found SDK deployment target {s} {f} aka '{t}'", .{ @tagName(target_os), version, os_ver });

    const tmp_dir: Io.Dir = .cwd();

    if (target_os == .macos) {
        for (&[_]Arch{ .aarch64, .x86_64 }) |arch| {
            const target: Target = .{
                .arch = arch,
                .os = .macos,
                .os_ver = os_ver,
                .abi = .none,
            };
            try fetchTarget(arena, io, argv.items, sysroot_path, target, version, tmp_dir);
        }
    } else if (target_os == .ios) {
        // iOS Device (aarch64). Requires the `iPhoneOS.sdk` sysroot (`xcrun --sdk iphoneos
        // --show-sdk-path`) — do NOT pass the simulator sysroot here, they are different SDKs.
        if (!simulator_only) {
            const device_target: Target = .{
                .arch = .aarch64,
                .os = .ios,
                .os_ver = os_ver,
                .abi = .none,
            };
            try fetchTarget(arena, io, argv.items, sysroot_path, device_target, version, tmp_dir);
        }

        // iOS Simulator (aarch64 + x86_64). Requires the `iPhoneSimulator.sdk` sysroot
        // (`xcrun --sdk iphonesimulator --show-sdk-path`) — pass `--sysroot` pointing at that
        // SDK together with `--simulator` (or `--simulator-only` to skip the device fetch
        // above in the same invocation).
        if (include_simulator or simulator_only) {
            for (&[_]Arch{ .aarch64, .x86_64 }) |arch| {
                const sim_target: Target = .{
                    .arch = arch,
                    .os = .ios,
                    .os_ver = os_ver,
                    .abi = .simulator,
                };
                try fetchTarget(arena, io, argv.items, sysroot_path, sim_target, version, tmp_dir);
            }
        }
    }
}

fn fetchTarget(
    arena: Allocator,
    io: Io,
    args: []const []const u8,
    sysroot: []const u8,
    target: Target,
    ver: Version,
    tmp_dir: Io.Dir,
) !void {
    const tmp_filename = "apple-headers";
    const headers_list_filename = "apple-headers.o.d";
    const tmp_path = try tmp_dir.realPathFileAlloc(io, ".", arena);
    const tmp_file_path = try Dir.path.join(arena, &[_][]const u8{ tmp_path, tmp_filename });
    const headers_list_path = try Dir.path.join(arena, &[_][]const u8{ tmp_path, headers_list_filename });

    const min_ver_flag = switch (target.os) {
        .macos => try std.fmt.allocPrint(arena, "-mmacosx-version-min={d}.{d}", .{ ver.major, ver.minor }),
        .ios => switch (target.abi) {
            .simulator => try std.fmt.allocPrint(arena, "-mios-simulator-version-min={d}.{d}", .{ ver.major, ver.minor }),
            .none => try std.fmt.allocPrint(arena, "-miphoneos-version-min={d}.{d}", .{ ver.major, ver.minor }),
        },
        else => return error.UnsupportedOs,
    };

    var cc_argv = std.array_list.Managed([]const u8).init(arena);
    try cc_argv.appendSlice(&[_][]const u8{
        "cc",
        "-arch",
        switch (target.arch) {
            .x86_64 => "x86_64",
            .aarch64 => "arm64",
        },
        min_ver_flag,
        "-isysroot",
        sysroot,
        "-iwithsysroot",
        "/usr/include",
        "-o",
        tmp_file_path,
        "macos-headers.c",
        "-MD",
        "-MV",
        "-MF",
        headers_list_path,
    });
    try cc_argv.appendSlice(args);

    const res = try std.process.run(arena, io, .{ .argv = cc_argv.items });

    if (res.stderr.len != 0) {
        std.log.err("{s}", .{res.stderr});
    }

    // Read in the contents of `apple-headers.o.d`
    const headers_list_file = try tmp_dir.openFile(io, headers_list_filename, .{});
    defer headers_list_file.close(io);

    var headers_dir = Dir.cwd().openDir(io, headers_source_prefix, .{}) catch |err| switch (err) {
        error.FileNotFound,
        error.NotDir,
        => fatal("path '{s}' not found or not a directory. Did you accidentally delete it?", .{
            headers_source_prefix,
        }),
        else => return err,
    };
    defer headers_dir.close(io);

    const dest_path = try target.fullName(arena);
    try headers_dir.deleteTree(io, dest_path);

    var dest_dir = try headers_dir.createDirPathOpen(io, dest_path, .{});
    var dirs = std.StringHashMap(Dir).init(arena);
    try dirs.putNoClobber(".", dest_dir);

    var headers_list_file_reader = headers_list_file.reader(io, &.{});
    const headers_list_str = try headers_list_file_reader.interface.allocRemaining(arena, .unlimited);
    const prefix = "/usr/include";

    var it = mem.splitScalar(u8, headers_list_str, '\n');
    while (it.next()) |line| {
        if (mem.findLast(u8, line, "clang") != null) continue;
        if (mem.findLast(u8, line, prefix[0..])) |idx| {
            const out_rel_path = line[idx + prefix.len + 1 ..];
            const out_rel_path_stripped = mem.trim(u8, out_rel_path, " \\");
            const dirname = Dir.path.dirname(out_rel_path_stripped) orelse ".";
            const maybe_dir = try dirs.getOrPut(dirname);
            if (!maybe_dir.found_existing) {
                maybe_dir.value_ptr.* = try dest_dir.createDirPathOpen(io, dirname, .{});
            }
            const basename = Dir.path.basename(out_rel_path_stripped);

            const line_stripped = mem.trim(u8, line, " \\");
            const abs_dirname = Dir.path.dirname(line_stripped).?;
            var orig_subdir = try Dir.cwd().openDir(io, abs_dirname, .{});
            defer orig_subdir.close(io);

            try orig_subdir.copyFile(basename, maybe_dir.value_ptr.*, basename, io, .{});
        }
    }

    var dir_it = dirs.iterator();
    while (dir_it.next()) |entry| {
        entry.value_ptr.close(io);
    }
}

const ArgsIterator = struct {
    args: []const []const u8,
    i: usize = 0,

    fn next(it: *@This()) ?[]const u8 {
        if (it.i >= it.args.len) {
            return null;
        }
        defer it.i += 1;
        return it.args[it.i];
    }

    fn nextOrFatal(it: *@This()) []const u8 {
        const arg = it.next() orelse fatal("expected parameter after '{s}'", .{it.args[it.i - 1]});
        return arg;
    }
};

const Version = struct {
    major: u16,
    minor: u8,
    patch: u8,

    fn parse(raw: []const u8) ?Version {
        var parsed: [3]u16 = @splat(0);
        var count: usize = 0;
        var it = std.mem.splitAny(u8, raw, ".");
        while (it.next()) |comp| {
            if (count >= 3) return null;
            parsed[count] = std.fmt.parseInt(u16, comp, 10) catch return null;
            count += 1;
        }
        if (count == 0) return null;
        const major = parsed[0];
        const minor = std.math.cast(u8, parsed[1]) orelse return null;
        const patch = std.math.cast(u8, parsed[2]) orelse return null;
        return .{ .major = major, .minor = minor, .patch = patch };
    }

    pub fn format(
        v: Version,
        writer: *Io.Writer,
    ) Io.Writer.Error!void {
        try writer.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
    }
};
