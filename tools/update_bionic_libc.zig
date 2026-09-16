//! Generates the Bionic (Android) libc data under lib/libc/ from an official
//! Android NDK release archive: headers (generic-bionic/ and per-arch asm/),
//! CRT objects per arch and API level, and the abilists symbol/version table
//! consumed by src/libs/bionic.zig. Same role as update_glibc.zig and friends.
//!
//! Usage (from the zig repo root):
//!   zig run tools/update_bionic_libc.zig -- --sysroot <ndk>/toolchains/llvm/prebuilt/linux-x86_64/sysroot --out-dir out
//!   zig run tools/update_bionic_libc.zig -- --ndk-zip android-ndk-r30-linux.zip --out-dir out
//!   zig run tools/update_bionic_libc.zig -- --download --out-dir out
//! Then copy out/lib/libc/... over lib/libc/.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const extractor = @import("bionic/extractor.zig");

const NDK_URL = "https://dl.google.com/android/repository/android-ndk-r30-linux.zip";
const NDK_EXPECTED_SHA1 = "5107f898313790e449e87eee2183d9a20602dee9";
const NDK_EXPECTED_SIZE: usize = 738633529;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena_alloc = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    const args = try init.minimal.args.toSlice(arena);

    var opt_sysroot: ?[]const u8 = null;
    var opt_ndk_zip: ?[]const u8 = null;
    var opt_out_dir: ?[]const u8 = null;
    var auto_download: bool = false;

    var arg_i: usize = 1;
    while (arg_i < args.len) : (arg_i += 1) {
        const arg = args[arg_i];
        if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (mem.eql(u8, arg, "--sysroot")) {
            arg_i += 1;
            if (arg_i >= args.len) {
                std.debug.print("Error: --sysroot requires a directory path\n", .{});
                return error.InvalidArguments;
            }
            opt_sysroot = args[arg_i];
        } else if (mem.eql(u8, arg, "--ndk-zip")) {
            arg_i += 1;
            if (arg_i >= args.len) {
                std.debug.print("Error: --ndk-zip requires a zip file path\n", .{});
                return error.InvalidArguments;
            }
            opt_ndk_zip = args[arg_i];
        } else if (mem.eql(u8, arg, "--out-dir")) {
            arg_i += 1;
            if (arg_i >= args.len) {
                std.debug.print("Error: --out-dir requires a directory path\n", .{});
                return error.InvalidArguments;
            }
            opt_out_dir = args[arg_i];
        } else if (mem.eql(u8, arg, "--download")) {
            auto_download = true;
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            printUsage();
            return error.InvalidArguments;
        }
    }

    const out_dir = opt_out_dir orelse "out";

    // Determine sysroot path
    var sysroot_path: []const u8 = undefined;
    if (opt_sysroot) |sr| {
        sysroot_path = sr;
    } else if (opt_ndk_zip) |zip_path| {
        sysroot_path = try verifyAndUnpackZip(arena, io, zip_path);
    } else if (auto_download) {
        const downloaded_zip = try downloadNdk(arena, io);
        sysroot_path = try verifyAndUnpackZip(arena, io, downloaded_zip);
    } else {
        std.debug.print("Error: no NDK sysroot given. Use --sysroot <path>, --ndk-zip <path>, or --download.\n", .{});
        printUsage();
        return error.NoSysrootProvided;
    }

    std.debug.print("Starting Android Bionic Extractor...\n", .{});
    std.debug.print("  Sysroot: {s}\n", .{sysroot_path});
    std.debug.print("  Output:  {s}\n\n", .{out_dir});

    var ext = extractor.Extractor.init(arena, io, sysroot_path, out_dir);
    const stats = try ext.run();

    std.debug.print("\n=======================================================\n", .{});
    std.debug.print("                 Extraction Complete!                  \n", .{});
    std.debug.print("=======================================================\n", .{});
    std.debug.print("libc.so (API 29 aarch64) Defined Symbols: {d}\n", .{stats.libc_29_aarch64_sym_count});
    std.debug.print("libc.so (API 29 aarch64) Version Nodes:   {d}\n", .{stats.libc_29_aarch64_ver_nodes});
    std.debug.print("Total Unique Symbols Extracted:           {d}\n", .{stats.total_unique_symbols});
    std.debug.print("Total Inclusions Encoded:                 {d}\n", .{stats.total_inclusions});
    std.debug.print("Total Libraries Processed:                {d}\n", .{stats.total_libraries});
    std.debug.print("Generated Binary abilists Size:           {d} bytes\n", .{stats.abilists_bytes});
    std.debug.print("See {s}/bionic_summary.txt for full table.\n", .{out_dir});
    std.debug.print("=======================================================\n", .{});
}

fn printUsage() void {
    std.debug.print(
        \\update_bionic_libc: generate lib/libc/bionic data from an Android NDK archive
        \\
        \\Usage: zig run tools/update_bionic_libc.zig -- [options]
        \\
        \\Options:
        \\  --sysroot <path>   Path to unpacked NDK sysroot (sysroot directory)
        \\  --ndk-zip <path>   Path to android-ndk-r30-linux.zip (verifies SHA1 & unpacks)
        \\  --download         Download and verify official Android NDK r30 zip
        \\  --out-dir <path>   Output directory (default: "out")
        \\  -h, --help         Print this help message
        \\
    , .{});
}

fn fileExists(io: Io, path: []const u8) bool {
    const cwd = Io.Dir.cwd();
    var f = cwd.openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

fn dirExists(io: Io, path: []const u8) bool {
    const cwd = Io.Dir.cwd();
    var d = cwd.openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

fn verifyAndUnpackZip(allocator: Allocator, io: Io, zip_path: []const u8) ![]const u8 {
    std.debug.print("Verifying NDK zip: {s}...\n", .{zip_path});
    const cwd = Io.Dir.cwd();
    const data = try cwd.readFileAlloc(io, zip_path, allocator, .limited(800 * 1024 * 1024));
    defer allocator.free(data);

    if (data.len != NDK_EXPECTED_SIZE) {
        std.debug.print("Error: Zip file size mismatch! Expected {d} bytes, got {d} bytes.\n", .{
            NDK_EXPECTED_SIZE, data.len,
        });
        return error.ZipVerificationFailed;
    }

    var sha1_digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(data, &sha1_digest, .{});

    const sha1_hex = std.fmt.bytesToHex(sha1_digest, .lower);

    if (!mem.eql(u8, &sha1_hex, NDK_EXPECTED_SHA1)) {
        std.debug.print("Error: SHA1 mismatch! Expected {s}, got {s}\n", .{
            NDK_EXPECTED_SHA1, sha1_hex,
        });
        return error.ZipSha1Mismatch;
    }

    std.debug.print("SHA1 check passed: {s} (size {d} bytes)\n", .{ sha1_hex, data.len });

    const unpack_dir = "ndk-r30-unpacked";
    try cwd.createDirPath(io, unpack_dir);

    std.debug.print("Unpacking sysroot payload...\n", .{});
    var child = try std.process.spawn(io, .{
        .argv = &[_][]const u8{
            "unzip", "-q", "-o", zip_path, "android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64/sysroot/*", "-d", unpack_dir,
        },
    });
    _ = try child.wait(io);

    return try std.fmt.allocPrint(allocator, "{s}/android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64/sysroot", .{unpack_dir});
}

fn downloadNdk(allocator: Allocator, io: Io) ![]const u8 {
    _ = allocator;
    const download_path = "android-ndk-r30-linux.zip";
    std.debug.print("Downloading Android NDK r30 from {s}...\n", .{NDK_URL});

    var child = try std.process.spawn(io, .{
        .argv = &[_][]const u8{
            "curl", "-L", "-o", download_path, NDK_URL,
        },
    });
    const term = try child.wait(io);
    if (!term.success()) {
        return error.DownloadFailed;
    }
    return download_path;
}
