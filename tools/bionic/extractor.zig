const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const elf_parser = @import("elf_parser.zig");
const format = @import("format.zig");

pub const ArchTarget = struct {
    zig_arch: []const u8,
    ndk_dir: []const u8,
    zig_dir: []const u8,
    bit_index: u6,
};

pub const TARGETS = [_]ArchTarget{
    .{ .zig_arch = "aarch64", .ndk_dir = "aarch64-linux-android", .zig_dir = "aarch64-linux-android", .bit_index = 0 },
    .{ .zig_arch = "arm", .ndk_dir = "arm-linux-androideabi", .zig_dir = "arm-linux-androideabi", .bit_index = 1 },
    .{ .zig_arch = "x86", .ndk_dir = "i686-linux-android", .zig_dir = "x86-linux-android", .bit_index = 2 },
    .{ .zig_arch = "x86_64", .ndk_dir = "x86_64-linux-android", .zig_dir = "x86_64-linux-android", .bit_index = 3 },
};

pub const MIN_API: u8 = 21;
pub const MAX_API: u8 = 37;

pub const LibraryInfo = struct {
    name: []const u8,
    filename: []const u8,
    introduced_in: u8,
};

pub const SymbolTrajectory = struct {
    // For each target (0..3), for each API level (21..37):
    // index in ver_nodes table, or null if symbol is not present on that target/API
    ver_indices: [TARGETS.len][MAX_API - MIN_API + 1]?u8,
    is_func: bool,
    is_weak: bool,
};

pub const ExtractionStats = struct {
    libc_29_aarch64_sym_count: usize,
    libc_29_aarch64_ver_nodes: usize,
    total_unique_symbols: usize,
    total_inclusions: usize,
    total_libraries: usize,
    abilists_bytes: usize,
};

pub const Extractor = struct {
    allocator: Allocator,
    io: Io,
    sysroot_path: []const u8,
    out_dir: []const u8,

    pub fn init(allocator: Allocator, io: Io, sysroot_path: []const u8, out_dir: []const u8) Extractor {
        return .{
            .allocator = allocator,
            .io = io,
            .sysroot_path = sysroot_path,
            .out_dir = out_dir,
        };
    }

    pub fn run(self: *Extractor) !ExtractionStats {
        const cwd = Io.Dir.cwd();
        const usr_lib_path = try std.fmt.allocPrint(self.allocator, "{s}/usr/lib", .{self.sysroot_path});
        defer self.allocator.free(usr_lib_path);

        // 1. Discover all libraries and their introduction API levels
        std.debug.print("Scanning libraries in sysroot...\n", .{});
        var lib_map = std.StringHashMap(LibraryInfo).init(self.allocator);
        defer lib_map.deinit();

        for (TARGETS) |targ| {
            var api: u8 = MIN_API;
            while (api <= MAX_API) : (api += 1) {
                var dir_path_buf: [512]u8 = undefined;
                const api_dir_path = try std.fmt.bufPrint(&dir_path_buf, "{s}/{s}/{d}", .{ usr_lib_path, targ.ndk_dir, api });
                var api_dir = cwd.openDir(self.io, api_dir_path, .{ .iterate = true }) catch continue;
                defer api_dir.close(self.io);

                var it = api_dir.iterate();
                while (try it.next(self.io)) |entry| {
                    if (!mem.endsWith(u8, entry.name, ".so")) continue;
                    if (mem.eql(u8, entry.name, "libc++.so")) continue; // linker script

                    const filename = try self.allocator.dupe(u8, entry.name);
                    const name = libNameFromFilename(entry.name);
                    const lib_short_name = try self.allocator.dupe(u8, name);

                    const gop = try lib_map.getOrPut(lib_short_name);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{
                            .name = lib_short_name,
                            .filename = filename,
                            .introduced_in = api,
                        };
                    } else {
                        if (api < gop.value_ptr.introduced_in) {
                            gop.value_ptr.introduced_in = api;
                        }
                    }
                }
            }
        }

        // Put c, m, dl first if present, then alphabetical
        var ordered_libs = std.array_list.Managed(LibraryInfo).init(self.allocator);
        defer ordered_libs.deinit();

        const priority = [_][]const u8{ "c", "m", "dl" };
        for (priority) |p_name| {
            if (lib_map.get(p_name)) |info| {
                try ordered_libs.append(info);
            }
        }
        var lib_it = lib_map.valueIterator();
        while (lib_it.next()) |info| {
            var is_pri = false;
            for (priority) |p_name| {
                if (mem.eql(u8, info.name, p_name)) {
                    is_pri = true;
                    break;
                }
            }
            if (!is_pri) {
                try ordered_libs.append(info.*);
            }
        }

        std.debug.print("Found {d} libraries:\n", .{ordered_libs.items.len});
        for (ordered_libs.items) |info| {
            std.debug.print("  {s:22} (lib{s}) -> introduced_in: {d}\n", .{ info.filename, info.name, info.introduced_in });
        }

        // 2. Global version node table
        var ver_nodes_list = std.array_list.Managed([]const u8).init(self.allocator);
        defer ver_nodes_list.deinit();
        var ver_nodes_map = std.StringHashMap(u8).init(self.allocator);
        defer ver_nodes_map.deinit();

        // Index 0 is unversioned/base ("")
        try ver_nodes_list.append("");
        try ver_nodes_map.put("", 0);

        // 3. Symbol database:
        // Key: lib_name ++ ":" ++ sym_name
        var symbol_db: std.array_hash_map.String(SymbolTrajectory) = .empty;
        defer symbol_db.deinit(self.allocator);

        var libc_29_aarch64_sym_count: usize = 0;
        var libc_29_aarch64_ver_nodes: usize = 0;

        std.debug.print("Extracting symbols across all targets and API levels...\n", .{});

        for (TARGETS, 0..) |targ, targ_i| {
            var api: u8 = MIN_API;
            while (api <= MAX_API) : (api += 1) {
                const api_idx = api - MIN_API;

                for (ordered_libs.items) |lib| {
                    if (api < lib.introduced_in) continue;

                    var file_path_buf: [512]u8 = undefined;
                    const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}/{s}/{d}/{s}", .{
                        usr_lib_path, targ.ndk_dir, api, lib.filename,
                    });

                    const bytes = cwd.readFileAlloc(self.io, file_path, self.allocator, .limited(15 * 1024 * 1024)) catch continue;
                    defer self.allocator.free(bytes);

                    var parsed = elf_parser.parseElfSo(self.allocator, bytes) catch |err| {
                        std.debug.print("Warning: Failed to parse ELF {s}: {}\n", .{ file_path, err });
                        continue;
                    };
                    defer parsed.deinit(self.allocator);

                    // If this is libc on aarch64 at API 29, record stats for check
                    if (targ_i == 0 and api == 29 and mem.eql(u8, lib.name, "c")) {
                        libc_29_aarch64_sym_count = parsed.symbols.len;
                        libc_29_aarch64_ver_nodes = parsed.version_nodes.len + 1; // +1 for base node
                    }

                    // Register any newly encountered version nodes
                    for (parsed.version_nodes) |vn| {
                        if (!ver_nodes_map.contains(vn)) {
                            const vn_idx: u8 = @intCast(ver_nodes_list.items.len);
                            const vn_dupe = try self.allocator.dupe(u8, vn);
                            try ver_nodes_list.append(vn_dupe);
                            try ver_nodes_map.put(vn_dupe, vn_idx);
                        }
                    }

                    // Record symbols
                    for (parsed.symbols) |sym| {
                        const vn_idx = ver_nodes_map.get(sym.version_node) orelse 0;
                        const db_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ lib.name, sym.name });

                        const gop = try symbol_db.getOrPut(self.allocator, db_key);
                        if (!gop.found_existing) {
                            var traj = SymbolTrajectory{
                                .ver_indices = undefined,
                                .is_func = sym.is_func,
                                .is_weak = sym.is_weak,
                            };
                            for (0..TARGETS.len) |t_i| {
                                for (0..MAX_API - MIN_API + 1) |a_i| {
                                    traj.ver_indices[t_i][a_i] = null;
                                }
                            }
                            traj.ver_indices[targ_i][api_idx] = vn_idx;
                            gop.value_ptr.* = traj;
                        } else {
                            self.allocator.free(db_key); // already have it
                            gop.value_ptr.ver_indices[targ_i][api_idx] = vn_idx;
                            if (sym.is_func) gop.value_ptr.is_func = true;
                        }
                    }
                }
            }
        }

        std.debug.print("Extracted {d} unique symbols, {d} version nodes.\n", .{
            symbol_db.count(), ver_nodes_list.items.len,
        });

        // 4. Build inclusions array
        std.debug.print("Building inclusion groups...\n", .{});
        var inclusions_list = std.array_list.Managed(format.Inclusion).init(self.allocator);
        defer inclusions_list.deinit();

        const SymGroupEntry = struct {
            lib_index: u8,
            traj: SymbolTrajectory,
        };
        var sym_by_name: std.array_hash_map.String(std.array_list.Managed(SymGroupEntry)) = .empty;
        defer sym_by_name.deinit(self.allocator);

        for (symbol_db.keys(), symbol_db.values()) |db_key, traj| {
            var split_it = mem.splitScalar(u8, db_key, ':');
            const lib_name = split_it.first();
            const sym_name = split_it.rest();

            var lib_idx: u8 = 0;
            for (ordered_libs.items, 0..) |l, idx| {
                if (mem.eql(u8, l.name, lib_name)) {
                    lib_idx = @intCast(idx);
                    break;
                }
            }

            const gop = try sym_by_name.getOrPut(self.allocator, sym_name);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.array_list.Managed(SymGroupEntry).init(self.allocator);
            }
            try gop.value_ptr.append(.{
                .lib_index = lib_idx,
                .traj = traj,
            });
        }

        for (sym_by_name.keys(), sym_by_name.values()) |sym_name, entries| {
            for (entries.items, 0..) |entry, e_idx| {
                const is_last_entry = (e_idx + 1 == entries.items.len);
                const lib_idx = entry.lib_index;
                const traj = entry.traj;

                const TrajSig = [MAX_API - MIN_API + 1]?u8;
                var unique_sigs = std.array_list.Managed(struct {
                    sig: TrajSig,
                    target_mask: u64,
                }).init(self.allocator);
                defer unique_sigs.deinit();

                for (0..TARGETS.len) |t_i| {
                    const sig = traj.ver_indices[t_i];
                    var has_any = false;
                    for (sig) |v| {
                        if (v != null) {
                            has_any = true;
                            break;
                        }
                    }
                    if (!has_any) continue;

                    var found = false;
                    for (unique_sigs.items) |*u| {
                        if (mem.eql(?u8, &u.sig, &sig)) {
                            u.target_mask |= (@as(u64, 1) << @intCast(t_i));
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try unique_sigs.append(.{
                            .sig = sig,
                            .target_mask = (@as(u64, 1) << @intCast(t_i)),
                        });
                    }
                }

                for (unique_sigs.items, 0..) |u, u_idx| {
                    const is_term = is_last_entry and (u_idx + 1 == unique_sigs.items.len);

                    var ver_entries = std.array_list.Managed(format.VerEntry).init(self.allocator);
                    defer ver_entries.deinit();

                    var last_node: ?u8 = null;
                    for (u.sig, 0..) |opt_v, a_idx| {
                        if (opt_v) |v| {
                            const api_level: u8 = @intCast(MIN_API + a_idx);
                            if (last_node == null or last_node.? != v) {
                                try ver_entries.append(.{
                                    .api_level = api_level,
                                    .ver_node_index = v,
                                });
                                last_node = v;
                            }
                        }
                    }

                    if (ver_entries.items.len > 0) {
                        try inclusions_list.append(.{
                            .sym_name = sym_name,
                            .targets_mask = u.target_mask,
                            .lib_index = lib_idx,
                            .is_terminal = is_term,
                            .entries = try ver_entries.toOwnedSlice(),
                        });
                    }
                }
            }
        }

        // 5. Prepare target strings
        var target_names = try self.allocator.alloc([]const u8, TARGETS.len);
        defer self.allocator.free(target_names);
        for (TARGETS, 0..) |t, i| {
            target_names[i] = t.zig_dir;
        }

        // Prepare LibMeta
        var lib_metas = try self.allocator.alloc(format.LibMeta, ordered_libs.items.len);
        defer self.allocator.free(lib_metas);
        for (ordered_libs.items, 0..) |l, i| {
            lib_metas[i] = .{
                .name = l.name,
                .introduced_in = l.introduced_in,
            };
        }

        const abi_data = format.BionicAbiData{
            .libs = lib_metas,
            .ver_nodes = ver_nodes_list.items,
            .targets = target_names,
            .inclusions = inclusions_list.items,
        };

        // 6. Encode binary abilists
        std.debug.print("Encoding binary abilists...\n", .{});
        const abilists_bytes = try format.writeAbilists(self.allocator, abi_data);
        defer self.allocator.free(abilists_bytes);

        // Verify round-trip decoding
        std.debug.print("Verifying binary abilists round-trip...\n", .{});
        const decoded = try format.readAbilists(self.allocator, abilists_bytes);
        if (decoded.inclusions.len != abi_data.inclusions.len) {
            std.debug.print("Error: round-trip inclusion count mismatch: {d} vs {d}\n", .{
                decoded.inclusions.len, abi_data.inclusions.len,
            });
            return error.RoundtripFailed;
        }
        std.debug.print("Round-trip verification passed! ({d} inclusions, {d} bytes)\n", .{
            decoded.inclusions.len, abilists_bytes.len,
        });

        // 7. Copy Headers and CRT startup objects to out_dir
        std.debug.print("Copying public headers and CRT objects to {s}...\n", .{self.out_dir});
        try self.copyHeaders();
        try self.copyCrtObjects();

        // 8. Write abilists, bionic_abi.json, and bionic_summary.txt
        const bionic_dir = try std.fmt.allocPrint(self.allocator, "{s}/lib/libc/bionic", .{self.out_dir});
        defer self.allocator.free(bionic_dir);
        try makePath(cwd, self.io, bionic_dir);

        const abilists_path = try std.fmt.allocPrint(self.allocator, "{s}/abilists", .{bionic_dir});
        defer self.allocator.free(abilists_path);
        try cwd.writeFile(self.io, .{ .sub_path = abilists_path, .data = abilists_bytes });

        try self.writeJsonDump(abi_data);
        try self.writeSummaryReport(ordered_libs.items, libc_29_aarch64_sym_count, libc_29_aarch64_ver_nodes, symbol_db.count(), inclusions_list.items.len, abilists_bytes.len);

        return .{
            .libc_29_aarch64_sym_count = libc_29_aarch64_sym_count,
            .libc_29_aarch64_ver_nodes = libc_29_aarch64_ver_nodes,
            .total_unique_symbols = symbol_db.count(),
            .total_inclusions = inclusions_list.items.len,
            .total_libraries = ordered_libs.items.len,
            .abilists_bytes = abilists_bytes.len,
        };
    }

    fn copyHeaders(self: *Extractor) !void {
        const cwd = Io.Dir.cwd();
        const inc_src_root = try std.fmt.allocPrint(self.allocator, "{s}/usr/include", .{self.sysroot_path});
        defer self.allocator.free(inc_src_root);

        const generic_dst = try std.fmt.allocPrint(self.allocator, "{s}/lib/libc/include/generic-bionic", .{self.out_dir});
        defer self.allocator.free(generic_dst);
        try makePath(cwd, self.io, generic_dst);

        // Copy generic headers: everything in usr/include except arch triples and c++
        var src_dir = try cwd.openDir(self.io, inc_src_root, .{ .iterate = true });
        defer src_dir.close(self.io);

        var it = src_dir.iterate();
        while (try it.next(self.io)) |entry| {
            var is_arch_or_cpp = false;
            if (mem.eql(u8, entry.name, "c++")) is_arch_or_cpp = true;
            for (TARGETS) |t| {
                if (mem.eql(u8, entry.name, t.ndk_dir)) {
                    is_arch_or_cpp = true;
                    break;
                }
            }
            if (mem.eql(u8, entry.name, "riscv64-linux-android")) is_arch_or_cpp = true;
            if (is_arch_or_cpp) continue;

            const item_src = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ inc_src_root, entry.name });
            defer self.allocator.free(item_src);
            const item_dst = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ generic_dst, entry.name });
            defer self.allocator.free(item_dst);

            if (entry.kind == .directory) {
                try copyDirRecursive(cwd, self.io, self.allocator, item_src, item_dst);
            } else {
                try copyFile(cwd, self.io, self.allocator, item_src, item_dst);
            }
        }

        // Copy arch-specific headers: usr/include/<triple>/asm/ -> lib/libc/include/<zig-arch>-linux-android/asm/
        for (TARGETS) |t| {
            const arch_asm_src = try std.fmt.allocPrint(self.allocator, "{s}/{s}/asm", .{ inc_src_root, t.ndk_dir });
            defer self.allocator.free(arch_asm_src);

            const arch_asm_dst = try std.fmt.allocPrint(self.allocator, "{s}/lib/libc/include/{s}/asm", .{
                self.out_dir, t.zig_dir,
            });
            defer self.allocator.free(arch_asm_dst);

            try copyDirRecursive(cwd, self.io, self.allocator, arch_asm_src, arch_asm_dst);
        }
    }

    fn copyCrtObjects(self: *Extractor) !void {
        const cwd = Io.Dir.cwd();
        const usr_lib_root = try std.fmt.allocPrint(self.allocator, "{s}/usr/lib", .{self.sysroot_path});
        defer self.allocator.free(usr_lib_root);

        const crt_names = [_][]const u8{
            "crtbegin_dynamic.o",
            "crtbegin_so.o",
            "crtend_android.o",
            "crtend_so.o",
            "crt_pad_segment.o",
        };

        for (TARGETS) |t| {
            var api: u8 = MIN_API;
            while (api <= MAX_API) : (api += 1) {
                const api_dst_dir = try std.fmt.allocPrint(self.allocator, "{s}/lib/libc/bionic/crt/{s}/{d}", .{
                    self.out_dir, t.zig_dir, api,
                });
                defer self.allocator.free(api_dst_dir);
                try makePath(cwd, self.io, api_dst_dir);

                for (crt_names) |crt_name| {
                    const src_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}/{d}/{s}", .{
                        usr_lib_root, t.ndk_dir, api, crt_name,
                    });
                    defer self.allocator.free(src_path);

                    const dst_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{
                        api_dst_dir, crt_name,
                    });
                    defer self.allocator.free(dst_path);

                    copyFile(cwd, self.io, self.allocator, src_path, dst_path) catch |err| {
                        std.debug.print("Warning: could not copy {s}: {}\n", .{ src_path, err });
                    };
                }

                // crtbegin_static.o: check in api dir first, fallback to triple root
                const static_src_api = try std.fmt.allocPrint(self.allocator, "{s}/{s}/{d}/crtbegin_static.o", .{
                    usr_lib_root, t.ndk_dir, api,
                });
                defer self.allocator.free(static_src_api);

                const static_dst = try std.fmt.allocPrint(self.allocator, "{s}/crtbegin_static.o", .{
                    api_dst_dir,
                });
                defer self.allocator.free(static_dst);

                var copied_static = false;
                if (copyFile(cwd, self.io, self.allocator, static_src_api, static_dst)) {
                    copied_static = true;
                } else |_| {}

                if (!copied_static) {
                    const static_src_root = try std.fmt.allocPrint(self.allocator, "{s}/{s}/crtbegin_static.o", .{
                        usr_lib_root, t.ndk_dir,
                    });
                    defer self.allocator.free(static_src_root);

                    copyFile(cwd, self.io, self.allocator, static_src_root, static_dst) catch |err| {
                        std.debug.print("Warning: could not copy {s}: {}\n", .{ static_src_root, err });
                    };
                }
            }
        }
    }

    fn writeJsonDump(self: *Extractor, abi_data: format.BionicAbiData) !void {
        const cwd = Io.Dir.cwd();
        const json_path = try std.fmt.allocPrint(self.allocator, "{s}/bionic_abi.json", .{self.out_dir});
        defer self.allocator.free(json_path);

        var json_buf = std.array_list.Managed(u8).init(self.allocator);
        defer json_buf.deinit();

        try json_buf.appendSlice("{\n");
        try json_buf.appendSlice("  \"targets\": [\n");
        for (abi_data.targets, 0..) |t, i| {
            try json_buf.print("    \"{s}\"{s}\n", .{ t, if (i + 1 == abi_data.targets.len) "" else "," });
        }
        try json_buf.appendSlice("  ],\n");

        try json_buf.appendSlice("  \"libraries\": [\n");
        for (abi_data.libs, 0..) |l, i| {
            try json_buf.print("    {{\"name\": \"{s}\", \"introduced_in\": {d}}}{s}\n", .{
                l.name, l.introduced_in, if (i + 1 == abi_data.libs.len) "" else ",",
            });
        }
        try json_buf.appendSlice("  ],\n");

        try json_buf.appendSlice("  \"version_nodes\": [\n");
        for (abi_data.ver_nodes, 0..) |vn, i| {
            try json_buf.print("    \"{s}\"{s}\n", .{ vn, if (i + 1 == abi_data.ver_nodes.len) "" else "," });
        }
        try json_buf.appendSlice("  ],\n");

        try json_buf.print("  \"inclusions_count\": {d},\n", .{abi_data.inclusions.len});
        try json_buf.appendSlice("  \"inclusions\": [\n");
        for (abi_data.inclusions, 0..) |inc, i| {
            try json_buf.print("    {{\n      \"symbol\": \"{s}\",\n      \"library\": \"{s}\",\n      \"targets_mask\": {d},\n      \"entries\": [", .{
                inc.sym_name, abi_data.libs[inc.lib_index].name, inc.targets_mask,
            });
            for (inc.entries, 0..) |e, e_idx| {
                const vn = abi_data.ver_nodes[e.ver_node_index];
                try json_buf.print("{{\"api\": {d}, \"version\": \"{s}\"}}{s}", .{
                    e.api_level, vn, if (e_idx + 1 == inc.entries.len) "" else ", ",
                });
            }
            try json_buf.print("]\n    }}{s}\n", .{if (i + 1 == abi_data.inclusions.len) "" else ","});
        }
        try json_buf.appendSlice("  ]\n}\n");

        try cwd.writeFile(self.io, .{ .sub_path = json_path, .data = json_buf.items });
        std.debug.print("Wrote JSON dump to {s} ({d} bytes)\n", .{ json_path, json_buf.items.len });
    }

    fn writeSummaryReport(
        self: *Extractor,
        libs: []const LibraryInfo,
        libc_29_aarch64_syms: usize,
        libc_29_aarch64_nodes: usize,
        total_syms: usize,
        total_inc: usize,
        abilists_sz: usize,
    ) !void {
        const cwd = Io.Dir.cwd();
        const summary_path = try std.fmt.allocPrint(self.allocator, "{s}/bionic_summary.txt", .{self.out_dir});
        defer self.allocator.free(summary_path);

        var buf = std.array_list.Managed(u8).init(self.allocator);
        defer buf.deinit();

        try buf.appendSlice("=======================================================\n");
        try buf.appendSlice("       Android NDK r30 Bionic ABI Extraction Report     \n");
        try buf.appendSlice("=======================================================\n\n");

        try buf.print("libc.so (API 29 aarch64) Defined Symbols: {d}\n", .{libc_29_aarch64_syms});
        try buf.print("libc.so (API 29 aarch64) Version Nodes:   {d}\n", .{libc_29_aarch64_nodes});
        try buf.print("Total Unique Symbols:                     {d}\n", .{total_syms});
        try buf.print("Total Symbol Inclusions:                  {d}\n", .{total_inc});
        try buf.print("Binary abilists Size:                     {d} bytes\n\n", .{abilists_sz});

        try buf.appendSlice("-------------------------------------------------------\n");
        try buf.appendSlice("Library Introduction Table (introduced_in):\n");
        try buf.appendSlice("-------------------------------------------------------\n");
        for (libs) |l| {
            try buf.print("  {s:22} -> API {d:2}\n", .{ l.filename, l.introduced_in });
        }
        try buf.appendSlice("\n");

        try buf.appendSlice("-------------------------------------------------------\n");
        try buf.appendSlice("Key Verification Targets (Expected vs Actual):\n");
        try buf.appendSlice("-------------------------------------------------------\n");
        const checks = [_]struct { name: []const u8, exp: u8 }{
            .{ .name = "libvulkan.so", .exp = 24 },
            .{ .name = "libcamera2ndk.so", .exp = 24 },
            .{ .name = "libsync.so", .exp = 26 },
            .{ .name = "libnativewindow.so", .exp = 26 },
            .{ .name = "libaaudio.so", .exp = 26 },
            .{ .name = "libneuralnetworks.so", .exp = 27 },
            .{ .name = "libbinder_ndk.so", .exp = 29 },
            .{ .name = "libamidi.so", .exp = 29 },
        };

        for (checks) |c| {
            var actual: u8 = 0;
            for (libs) |l| {
                if (mem.eql(u8, l.filename, c.name)) {
                    actual = l.introduced_in;
                    break;
                }
            }
            const status = if (actual == c.exp) "MATCH [OK]" else "MISMATCH [FAIL]";
            try buf.print("  {s:22} expected {d:2}, actual {d:2}  ==>  {s}\n", .{
                c.name, c.exp, actual, status,
            });
        }
        try buf.appendSlice("=======================================================\n");

        try cwd.writeFile(self.io, .{ .sub_path = summary_path, .data = buf.items });
        std.debug.print("Wrote summary report to {s}\n", .{summary_path});
    }
};

fn libNameFromFilename(filename: []const u8) []const u8 {
    var name = filename;
    if (mem.startsWith(u8, name, "lib")) {
        name = name[3..];
    }
    if (mem.endsWith(u8, name, ".so")) {
        name = name[0 .. name.len - 3];
    }
    return name;
}

fn copyFile(cwd: Io.Dir, io: Io, allocator: Allocator, src_path: []const u8, dst_path: []const u8) !void {
    const data = try cwd.readFileAlloc(io, src_path, allocator, .limited(50 * 1024 * 1024));
    defer allocator.free(data);
    try cwd.writeFile(io, .{ .sub_path = dst_path, .data = data });
}

fn copyDirRecursive(cwd: Io.Dir, io: Io, allocator: Allocator, src_dir_path: []const u8, dst_dir_path: []const u8) !void {
    try makePath(cwd, io, dst_dir_path);

    var src_dir = try cwd.openDir(io, src_dir_path, .{ .iterate = true });
    defer src_dir.close(io);

    var it = src_dir.iterate();
    while (try it.next(io)) |entry| {
        const item_src = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_dir_path, entry.name });
        defer allocator.free(item_src);
        const item_dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dst_dir_path, entry.name });
        defer allocator.free(item_dst);

        if (entry.kind == .directory) {
            try copyDirRecursive(cwd, io, allocator, item_src, item_dst);
        } else {
            try copyFile(cwd, io, allocator, item_src, item_dst);
        }
    }
}

fn makePath(cwd: Io.Dir, io: Io, dir_path: []const u8) !void {
    try cwd.createDirPath(io, dir_path);
}
