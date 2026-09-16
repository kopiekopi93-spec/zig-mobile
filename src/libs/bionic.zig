const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mem = std.mem;
const log = std.log;
const path = std.Io.Dir.path;
const assert = std.debug.assert;
const Version = std.SemanticVersion;
const Path = std.Build.Cache.Path;

const Compilation = @import("../Compilation.zig");
const build_options = @import("build_options");
const trace = @import("../tracy.zig").trace;
const Cache = std.Build.Cache;
const Module = @import("../Module.zig");
const link = @import("../link.zig");

pub const Lib = struct {
    name: []const u8,
    introduced_in: u8,
};

pub const Target = struct {
    arch: std.Target.Cpu.Arch,
    os: std.Target.Os.Tag,
    abi: std.Target.Abi,
};

pub const ABI = struct {
    all_libs: []const Lib,
    all_ver_nodes: []const []const u8,
    all_targets: []const Target,
    inclusions: []const u8,
    arena_state: std.heap.ArenaAllocator.State,

    pub fn destroy(abi: *ABI, gpa: Allocator) void {
        abi.arena_state.promote(gpa).deinit();
    }
};

pub const libs = [_]Lib{
    .{ .name = "c", .introduced_in = 21 },
    .{ .name = "m", .introduced_in = 21 },
    .{ .name = "dl", .introduced_in = 21 },
    .{ .name = "android", .introduced_in = 21 },
    .{ .name = "binder_ndk", .introduced_in = 29 },
    .{ .name = "aaudio", .introduced_in = 26 },
    .{ .name = "mediandk", .introduced_in = 21 },
    .{ .name = "EGL", .introduced_in = 21 },
    .{ .name = "amidi", .introduced_in = 29 },
    .{ .name = "stdc++", .introduced_in = 21 },
    .{ .name = "OpenMAXAL", .introduced_in = 21 },
    .{ .name = "z", .introduced_in = 21 },
    .{ .name = "vulkan", .introduced_in = 24 },
    .{ .name = "sync", .introduced_in = 26 },
    .{ .name = "OpenSLES", .introduced_in = 21 },
    .{ .name = "jnigraphics", .introduced_in = 21 },
    .{ .name = "neuralnetworks", .introduced_in = 27 },
    .{ .name = "GLESv3", .introduced_in = 21 },
    .{ .name = "log", .introduced_in = 21 },
    .{ .name = "GLESv1_CM", .introduced_in = 21 },
    .{ .name = "nativehelper", .introduced_in = 31 },
    .{ .name = "GLESv2", .introduced_in = 21 },
    .{ .name = "camera2ndk", .introduced_in = 24 },
    .{ .name = "nativewindow", .introduced_in = 26 },
    .{ .name = "icu", .introduced_in = 31 },
};

pub const LoadMetaDataError = error{
    ZigInstallationCorrupt,
    OutOfMemory,
};

pub const abilists_path = "libc" ++ path.sep_str ++ "bionic" ++ path.sep_str ++ "abilists";
pub const abilists_max_size = 800 * 1024;

pub fn loadMetaData(gpa: Allocator, contents: []const u8) LoadMetaDataError!*ABI {
    const tracy = trace(@src());
    defer tracy.end();

    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var index: usize = 0;

    // 1. Libs
    if (index >= contents.len) return error.ZigInstallationCorrupt;
    const libs_len = contents[index];
    index += 1;

    const parsed_libs = try arena.alloc(Lib, libs_len);
    var lib_i: u8 = 0;
    while (lib_i < libs_len) : (lib_i += 1) {
        const lib_name = mem.sliceTo(contents[index..], 0);
        index += lib_name.len + 1;
        if (index >= contents.len) return error.ZigInstallationCorrupt;
        const intro = contents[index];
        index += 1;

        if (lib_i >= libs.len or !mem.eql(u8, libs[lib_i].name, lib_name)) {
            log.err("libc" ++ path.sep_str ++ "bionic" ++ path.sep_str ++
                "abilists: invalid library name or index ({d}): {s}", .{ lib_i, lib_name });
            return error.ZigInstallationCorrupt;
        }
        parsed_libs[lib_i] = .{
            .name = lib_name,
            .introduced_in = intro,
        };
    }

    // 2. Version nodes
    if (index >= contents.len) return error.ZigInstallationCorrupt;
    const ver_len = contents[index];
    index += 1;

    const ver_nodes = try arena.alloc([]const u8, ver_len);
    var ver_i: u8 = 0;
    while (ver_i < ver_len) : (ver_i += 1) {
        const node_name = mem.sliceTo(contents[index..], 0);
        index += node_name.len + 1;
        ver_nodes[ver_i] = node_name;
    }

    // 3. Targets
    if (index >= contents.len) return error.ZigInstallationCorrupt;
    const targets_len = contents[index];
    index += 1;

    const targets = try arena.alloc(Target, targets_len);
    var targ_i: u8 = 0;
    while (targ_i < targets_len) : (targ_i += 1) {
        const target_name = mem.sliceTo(contents[index..], 0);
        index += target_name.len + 1;

        var component_it = mem.tokenizeScalar(u8, target_name, '-');
        const arch_name = component_it.next() orelse {
            log.err("bionic abilists: expected arch name", .{});
            return error.ZigInstallationCorrupt;
        };
        const os_name = component_it.next() orelse {
            log.err("bionic abilists: expected OS name", .{});
            return error.ZigInstallationCorrupt;
        };
        const abi_name = component_it.next() orelse {
            log.err("bionic abilists: expected ABI name", .{});
            return error.ZigInstallationCorrupt;
        };
        const arch_tag = std.meta.stringToEnum(std.Target.Cpu.Arch, arch_name) orelse {
            log.err("bionic abilists: unrecognized arch: {s}", .{arch_name});
            return error.ZigInstallationCorrupt;
        };
        if (!mem.eql(u8, os_name, "linux")) {
            log.err("bionic abilists: expected OS linux, found {s}", .{os_name});
            return error.ZigInstallationCorrupt;
        }
        const abi_tag = std.meta.stringToEnum(std.Target.Abi, abi_name) orelse {
            log.err("bionic abilists: unrecognized ABI: {s}", .{abi_name});
            return error.ZigInstallationCorrupt;
        };

        targets[targ_i] = .{
            .arch = arch_tag,
            .os = .linux,
            .abi = abi_tag,
        };
    }

    const abi = try arena.create(ABI);
    abi.* = .{
        .all_libs = parsed_libs,
        .all_ver_nodes = ver_nodes,
        .all_targets = targets,
        .inclusions = contents[index..],
        .arena_state = arena_allocator.state,
    };
    return abi;
}

pub const CrtFile = enum {
    crtbegin_dynamic_o,
    crtbegin_so_o,
    crtbegin_static_o,
    crtend_android_o,
    crtend_so_o,
    // Not queued by default anywhere below: matches real Clang, which only links this in
    // behind an explicit `-fandroid-pad-segment` (default off; see
    // clang/lib/Driver/ToolChains/Gnu.cpp). Kept available here for a future opt-in flag.
    crt_pad_segment_o,
};

pub fn buildCrtFile(comp: *Compilation, crt_file: CrtFile, prog_node: std.Progress.Node) anyerror!void {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = comp.gpa;
    const io = comp.io;
    const target = comp.getTarget();

    // Out-of-range API levels are rejected earlier by std.zig.target.canBuildLibC.
    const api = target.os.version_range.linux.android;
    assert(api >= std.zig.target.android_api_min and api <= std.zig.target.android_api_max);

    const target_dir = switch (target.cpu.arch) {
        .aarch64, .aarch64_be => "aarch64-linux-android",
        .arm, .armeb, .thumb, .thumbeb => "arm-linux-androideabi",
        .x86 => "x86-linux-android",
        .x86_64 => "x86_64-linux-android",
        else => return error.UnsupportedArch,
    };

    const filename = switch (crt_file) {
        .crtbegin_dynamic_o => "crtbegin_dynamic.o",
        .crtbegin_so_o => "crtbegin_so.o",
        .crtbegin_static_o => "crtbegin_static.o",
        .crtend_android_o => "crtend_android.o",
        .crtend_so_o => "crtend_so.o",
        .crt_pad_segment_o => "crt_pad_segment.o",
    };

    const s = path.sep_str;
    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var cache: Cache = .{
        .gpa = gpa,
        .io = io,
        .manifest_dir = try comp.dirs.global_cache.handle.createDirPathOpen(io, "h", .{}),
        .cwd = comp.dirs.cwd,
    };
    cache.addPrefix(.{ .path = null, .handle = Io.Dir.cwd() });
    cache.addPrefix(comp.dirs.zig_lib);
    cache.addPrefix(comp.dirs.global_cache);
    defer cache.manifest_dir.close(io);

    var man = cache.obtain();
    defer man.deinit();
    man.hash.addBytes(build_options.version);
    man.hash.add(target.cpu.arch);
    man.hash.add(target.abi);
    man.hash.add(api);
    man.hash.addBytes(filename);

    const src_sub_path = try std.fmt.allocPrint(arena, "libc" ++ s ++ "bionic" ++ s ++ "crt" ++ s ++ "{s}" ++ s ++ "{d}" ++ s ++ "{s}", .{
        target_dir, api, filename,
    });

    const src_file_idx = try man.addFilePath(.{
        .root_dir = comp.dirs.zig_lib,
        .sub_path = src_sub_path,
    }, 1024 * 1024);

    if (try man.hit(prog_node)) {
        const digest = man.final();
        const sub_path = try path.join(gpa, &.{ "o", &digest, filename });
        errdefer gpa.free(sub_path);

        comp.mutex.lockUncancelable(io);
        defer comp.mutex.unlock(io);
        try comp.crt_files.ensureUnusedCapacity(gpa, 1);
        const duped_key = try gpa.dupe(u8, filename);
        errdefer gpa.free(duped_key);
        comp.crt_files.putAssumeCapacityNoClobber(duped_key, .{
            .full_object_path = .{
                .root_dir = comp.dirs.global_cache,
                .sub_path = sub_path,
            },
            .lock = man.toOwnedLock(),
        });
        return;
    }

    const digest = man.final();
    const o_sub_path = try path.join(arena, &[_][]const u8{ "o", &digest });
    var o_dir = try comp.dirs.global_cache.handle.createDirPathOpen(io, o_sub_path, .{});
    defer o_dir.close(io);

    const src_bytes = man.files.keys()[src_file_idx].contents.?;
    try o_dir.writeFile(io, .{ .sub_path = filename, .data = src_bytes });

    try man.writeManifest();

    const sub_path = try path.join(gpa, &.{ "o", &digest, filename });
    errdefer gpa.free(sub_path);

    comp.mutex.lockUncancelable(io);
    defer comp.mutex.unlock(io);
    try comp.crt_files.ensureUnusedCapacity(gpa, 1);
    const duped_key = try gpa.dupe(u8, filename);
    errdefer gpa.free(duped_key);
    comp.crt_files.putAssumeCapacityNoClobber(duped_key, .{
        .full_object_path = .{
            .root_dir = comp.dirs.global_cache,
            .sub_path = sub_path,
        },
        .lock = man.toOwnedLock(),
    });
}

pub const BuiltSharedObjects = struct {
    lock: Cache.Lock,
    dir_path: Path,

    pub fn deinit(self: *BuiltSharedObjects, gpa: Allocator, io: Io) void {
        self.lock.release(io);
        gpa.free(self.dir_path.sub_path);
        self.* = undefined;
    }
};

const all_map_basename = "all.map";

fn wordDirective(target: *const std.Target) []const u8 {
    return if (target.ptrBitWidth() == 64) ".quad" else ".long";
}

pub fn buildSharedObjects(comp: *Compilation, prog_node: std.Progress.Node) anyerror!void {
    const tracy = trace(@src());
    defer tracy.end();

    if (!build_options.have_llvm) {
        return error.ZigCompilerNotBuiltWithLLVMExtensions;
    }

    const gpa = comp.gpa;
    const io = comp.io;

    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const target = comp.getTarget();
    const target_api = target.os.version_range.linux.android;

    var cache: Cache = .{
        .gpa = gpa,
        .io = io,
        .manifest_dir = try comp.dirs.global_cache.handle.createDirPathOpen(io, "h", .{}),
        .cwd = comp.dirs.cwd,
    };
    cache.addPrefix(.{ .path = null, .handle = Io.Dir.cwd() });
    cache.addPrefix(comp.dirs.zig_lib);
    cache.addPrefix(comp.dirs.global_cache);
    defer cache.manifest_dir.close(io);

    var man = cache.obtain();
    defer man.deinit();
    man.hash.addBytes(build_options.version);
    man.hash.add(target.cpu.arch);
    man.hash.add(target.abi);
    man.hash.add(target_api);

    const abilists_index = try man.addFilePath(.{
        .root_dir = comp.dirs.zig_lib,
        .sub_path = abilists_path,
    }, abilists_max_size);

    if (try man.hit(prog_node)) {
        const digest = man.final();

        return queueSharedObjects(comp, .{
            .lock = man.toOwnedLock(),
            .dir_path = .{
                .root_dir = comp.dirs.global_cache,
                .sub_path = try gpa.dupe(u8, "o" ++ path.sep_str ++ digest),
            },
        });
    }

    const digest = man.final();
    const o_sub_path = try path.join(arena, &[_][]const u8{ "o", &digest });

    var o_directory: Cache.Directory = .{
        .handle = try comp.dirs.global_cache.handle.createDirPathOpen(io, o_sub_path, .{}),
        .path = try comp.dirs.global_cache.join(arena, &.{o_sub_path}),
    };
    defer o_directory.handle.close(io);

    const abilists_contents = man.files.keys()[abilists_index].contents.?;
    const metadata = try loadMetaData(gpa, abilists_contents);
    defer metadata.destroy(gpa);

    const target_targ_index = for (metadata.all_targets, 0..) |targ, i| {
        if (targ.arch == target.cpu.arch and
            targ.os == target.os.tag and
            targ.abi == target.abi)
        {
            break i;
        }
    } else {
        unreachable;
    };

    // Generate all.map
    {
        var map_contents = std.array_list.Managed(u8).init(arena);
        for (metadata.all_ver_nodes) |ver_node| {
            if (ver_node.len == 0) continue;
            try map_contents.print("{s} {{ }};\n", .{ver_node});
        }
        try o_directory.handle.writeFile(io, .{ .sub_path = all_map_basename, .data = map_contents.items });
        map_contents.deinit();
    }

    var stubs_asm = std.array_list.Managed(u8).init(gpa);
    defer stubs_asm.deinit();

    const Entry = struct {
        api_level: u8,
        ver_node_idx: u8,
    };

    for (libs, 0..) |lib, lib_i| {
        if (target_api < lib.introduced_in) continue;

        stubs_asm.shrinkRetainingCapacity(0);
        try stubs_asm.appendSlice(".text\n");

        var sym_i: usize = 0;
        var sym_name_buf: Io.Writer.Allocating = .init(arena);
        var opt_symbol_name: ?[]const u8 = null;
        var entries_buf: [32]Entry = undefined;
        var entries_len: usize = 0;

        var versions_written: std.array_hash_map.Auto(u8, void) = .empty;

        var inc_reader: Io.Reader = .fixed(metadata.inclusions);
        const inclusions_count = try inc_reader.takeInt(u16, .little);

        while (sym_i < inclusions_count) : (sym_i += 1) {
            const sym_name = opt_symbol_name orelse n: {
                sym_name_buf.clearRetainingCapacity();
                _ = try inc_reader.streamDelimiter(&sym_name_buf.writer, 0);
                assert(inc_reader.buffered()[0] == 0);
                inc_reader.toss(1);

                opt_symbol_name = sym_name_buf.written();
                entries_len = 0;

                break :n sym_name_buf.written();
            };

            const targets_mask = try inc_reader.takeLeb128(u64);
            const lib_byte = try inc_reader.takeByte();

            const is_terminal = (lib_byte & 0x80) != 0;
            const lib_index = lib_byte & 0x7f;

            if (is_terminal) {
                opt_symbol_name = null;
            }

            const ok_lib_and_target = (lib_index == lib_i) and
                ((targets_mask & (@as(u64, 1) << @as(u6, @intCast(target_targ_index)))) != 0);

            while (true) {
                const api_byte = try inc_reader.takeByte();
                const is_last = (api_byte & 0x80) != 0;
                const api_level = api_byte & 0x7f;
                const ver_node_idx = try inc_reader.takeByte();

                if (ok_lib_and_target and api_level <= target_api) {
                    if (entries_len < entries_buf.len) {
                        entries_buf[entries_len] = .{
                            .api_level = api_level,
                            .ver_node_idx = ver_node_idx,
                        };
                        entries_len += 1;
                    }
                }
                if (is_last) break;
            }

            if (!is_terminal) continue;
            if (entries_len == 0) continue;

            // Find default version (highest api_level <= target_api)
            var chosen_def_ver_idx: ?u8 = null;
            var max_api: u8 = 0;
            for (entries_buf[0..entries_len]) |e| {
                if (chosen_def_ver_idx == null or e.api_level >= max_api) {
                    chosen_def_ver_idx = e.ver_node_idx;
                    max_api = e.api_level;
                }
            }

            versions_written.clearRetainingCapacity();
            try versions_written.ensureTotalCapacity(arena, entries_len);

            for (entries_buf[0..entries_len]) |e| {
                if (versions_written.getOrPutAssumeCapacity(e.ver_node_idx).found_existing) continue;

                const ver_node_name = metadata.all_ver_nodes[e.ver_node_idx];
                const want_default = (chosen_def_ver_idx != null and e.ver_node_idx == chosen_def_ver_idx.?);
                const at_sign_str = if (want_default) "@@" else "@";

                if (ver_node_name.len == 0) {
                    try stubs_asm.print(
                        \\.balign {d}
                        \\.globl {s}
                        \\.type {s}, %function
                        \\{s}: {s} 0
                        \\
                    , .{
                        target.ptrBitWidth() / 8,
                        sym_name,
                        sym_name,
                        sym_name,
                        wordDirective(target),
                    });
                } else {
                    const sym_plus_ver = try std.fmt.allocPrint(arena, "{s}_{s}", .{ sym_name, ver_node_name });
                    try stubs_asm.print(
                        \\.balign {d}
                        \\.globl {s}
                        \\.type {s}, %function
                        \\.symver {s}, {s}{s}{s}, remove
                        \\{s}: {s} 0
                        \\
                    , .{
                        target.ptrBitWidth() / 8,
                        sym_plus_ver,
                        sym_plus_ver,
                        sym_plus_ver,
                        sym_name,
                        at_sign_str,
                        ver_node_name,
                        sym_plus_ver,
                        wordDirective(target),
                    });
                }
            }
        }

        var lib_name_buf: [64]u8 = undefined;
        const asm_file_basename = std.mem.print(&lib_name_buf, "{s}.s", .{lib.name}) catch unreachable;
        try o_directory.handle.writeFile(io, .{ .sub_path = asm_file_basename, .data = stubs_asm.items });
        try buildSharedLib(comp, arena, o_directory, asm_file_basename, lib, prog_node);
    }

    man.writeManifest() catch |err| {
        log.warn("failed to write cache manifest for bionic stubs: {s}", .{@errorName(err)});
    };

    return queueSharedObjects(comp, .{
        .lock = man.toOwnedLock(),
        .dir_path = .{
            .root_dir = comp.dirs.global_cache,
            .sub_path = try gpa.dupe(u8, "o" ++ path.sep_str ++ digest),
        },
    });
}

fn queueSharedObjects(comp: *Compilation, so_files: BuiltSharedObjects) std.Io.Cancelable!void {
    const io = comp.io;
    const target = comp.getTarget();
    const target_api = target.os.version_range.linux.android;

    assert(comp.bionic_so_files == null);
    comp.bionic_so_files = so_files;

    var task_buffer: [libs.len]link.PrelinkTask = undefined;
    var task_buffer_i: usize = 0;

    {
        comp.mutex.lockUncancelable(io);
        defer comp.mutex.unlock(io);

        for (libs) |lib| {
            if (target_api < lib.introduced_in) continue;
            const so_path: Path = .{
                .root_dir = so_files.dir_path.root_dir,
                .sub_path = std.fmt.allocPrint(comp.arena, "{s}{c}lib{s}.so", .{
                    so_files.dir_path.sub_path, path.sep, lib.name,
                }) catch return comp.setAllocFailure(),
            };
            task_buffer[task_buffer_i] = .{ .load_dso = so_path };
            task_buffer_i += 1;
        }
    }

    try comp.queuePrelinkTasks(task_buffer[0..task_buffer_i]);
}

fn buildSharedLib(
    comp: *Compilation,
    arena: Allocator,
    bin_directory: Cache.Directory,
    asm_file_basename: []const u8,
    lib: Lib,
    prog_node: std.Progress.Node,
) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const io = comp.io;
    const basename = try std.fmt.allocPrint(arena, "lib{s}.so", .{lib.name});
    const soname = basename;

    const optimize_mode = comp.compilerRtOptMode();
    const strip = comp.compilerRtStrip();
    const config = try Compilation.Config.resolve(.{
        .output_mode = .Lib,
        .link_mode = .dynamic,
        .resolved_target = comp.root_mod.resolved_target,
        .is_test = false,
        .have_zcu = false,
        .emit_bin = true,
        .root_optimize_mode = optimize_mode,
        .root_strip = strip,
        .link_libc = false,
    });

    const root_mod = try Module.create(arena, .{
        .paths = .{
            .root = .zig_lib_root,
            .root_src_path = "",
        },
        .fully_qualified_name = "root",
        .inherited = .{
            .resolved_target = comp.root_mod.resolved_target,
            .strip = strip,
            .stack_check = false,
            .stack_protector = 0,
            .sanitize_c = .off,
            .sanitize_thread = false,
            .red_zone = comp.root_mod.red_zone,
            .omit_frame_pointer = comp.root_mod.omit_frame_pointer,
            .valgrind = false,
            .optimize_mode = optimize_mode,
        },
        .global = config,
        .cc_argv = &.{},
        .parent = null,
    });

    const c_source_files = [1]Compilation.CSourceFile{
        .{
            .src_path = try path.join(arena, &.{ bin_directory.path.?, asm_file_basename }),
            .owner = root_mod,
        },
    };

    const misc_task: Compilation.MiscTask = .@"bionic shared object";

    var sub_create_diag: Compilation.CreateDiagnostic = undefined;
    const sub_compilation = Compilation.create(comp.gpa, arena, io, &sub_create_diag, .{
        .thread_limit = comp.thread_limit,
        .dirs = comp.dirs.withoutLocalCache(),
        .self_exe_path = comp.self_exe_path,
        .cache_mode = .none,
        .config = config,
        .root_mod = root_mod,
        .root_name = lib.name,
        .libc_installation = comp.libc_installation,
        .emit_bin = .{ .yes_path = try bin_directory.join(arena, &.{basename}) },
        .verbose_cc = comp.verbose_cc,
        .verbose_link = comp.verbose_link,
        .verbose_air = comp.verbose_air,
        .verbose_llvm_ir = comp.verbose_llvm_ir,
        .verbose_llvm_bc = comp.verbose_llvm_bc,
        .verbose_llvm_cpu_features = comp.verbose_llvm_cpu_features,
        .clang_passthrough_mode = comp.clang_passthrough_mode,
        .version_script = .{
            .root_dir = bin_directory,
            .sub_path = all_map_basename,
        },
        .soname = soname,
        .c_source_files = &c_source_files,
        .skip_linker_dependencies = true,
        .environ_map = comp.environ_map,
    }) catch |err| switch (err) {
        error.CreateFail => {
            comp.lockAndSetMiscFailure(misc_task, "sub-compilation of {t} failed: {f}", .{ misc_task, sub_create_diag });
            return error.AlreadyReported;
        },
        else => |e| return e,
    };
    defer sub_compilation.destroy();

    try comp.updateSubCompilation(sub_compilation, misc_task, prog_node);
}
