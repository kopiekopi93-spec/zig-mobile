const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;

pub const LibMeta = struct {
    name: []const u8,
    introduced_in: u8,
};

pub const VerEntry = struct {
    api_level: u8,
    ver_node_index: u8,
};

pub const Inclusion = struct {
    sym_name: []const u8,
    targets_mask: u64,
    lib_index: u8,
    is_terminal: bool,
    entries: []const VerEntry,
};

pub const BionicAbiData = struct {
    libs: []const LibMeta,
    ver_nodes: []const []const u8,
    targets: []const []const u8,
    inclusions: []const Inclusion,
};

/// Serializes Bionic ABI metadata into the compact binary abilists format.
pub fn writeAbilists(allocator: Allocator, abi_data: BionicAbiData) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    // 1. Libs
    try out.append(@intCast(abi_data.libs.len));
    for (abi_data.libs) |lib| {
        try out.appendSlice(lib.name);
        try out.append(0);
        try out.append(lib.introduced_in);
    }

    // 2. Version Nodes
    try out.append(@intCast(abi_data.ver_nodes.len));
    for (abi_data.ver_nodes) |ver_node| {
        try out.appendSlice(ver_node);
        try out.append(0);
    }

    // 3. Targets
    try out.append(@intCast(abi_data.targets.len));
    for (abi_data.targets) |targ| {
        try out.appendSlice(targ);
        try out.append(0);
    }

    // 4. Inclusions count
    const inc_count: u16 = @intCast(abi_data.inclusions.len);
    var count_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &count_buf, inc_count, .little);
    try out.appendSlice(&count_buf);

    // 5. Inclusions
    var prev_terminal: bool = true;
    for (abi_data.inclusions) |inc| {
        if (prev_terminal) {
            try out.appendSlice(inc.sym_name);
            try out.append(0);
        }

        // LEB128 for targets mask
        var t = inc.targets_mask;
        while (true) {
            var byte: u8 = @intCast(t & 0x7f);
            t >>= 7;
            if (t != 0) {
                byte |= 0x80;
                try out.append(byte);
            } else {
                try out.append(byte);
                break;
            }
        }

        // lib_index + is_terminal in MSB
        var lib_byte = inc.lib_index & 0x7f;
        if (inc.is_terminal) {
            lib_byte |= 0x80;
        }
        try out.append(lib_byte);

        // Version entries
        for (inc.entries, 0..) |entry, i| {
            const is_last = (i + 1 == inc.entries.len);
            var api_byte = entry.api_level & 0x7f;
            if (is_last) {
                api_byte |= 0x80;
            }
            try out.append(api_byte);
            try out.append(entry.ver_node_index);
        }

        prev_terminal = inc.is_terminal;
    }

    return try out.toOwnedSlice();
}

/// Decodes binary abilists for verification and testing.
pub fn readAbilists(allocator: Allocator, contents: []const u8) !BionicAbiData {
    var reader = Io.Reader.fixed(contents);

    // 1. Libs
    const libs_len = try reader.takeByte();
    var libs = try allocator.alloc(LibMeta, libs_len);
    var i: usize = 0;
    while (i < libs_len) : (i += 1) {
        var name_buf = std.array_list.Managed(u8).init(allocator);
        defer name_buf.deinit();
        while (true) {
            const b = try reader.takeByte();
            if (b == 0) break;
            try name_buf.append(b);
        } // skip null terminator
        const intro = try reader.takeByte();
        libs[i] = .{
            .name = try name_buf.toOwnedSlice(),
            .introduced_in = intro,
        };
    }

    // 2. Version Nodes
    const ver_len = try reader.takeByte();
    var ver_nodes = try allocator.alloc([]const u8, ver_len);
    i = 0;
    while (i < ver_len) : (i += 1) {
        var name_buf = std.array_list.Managed(u8).init(allocator);
        defer name_buf.deinit();
        while (true) {
            const b = try reader.takeByte();
            if (b == 0) break;
            try name_buf.append(b);
        }
        ver_nodes[i] = try name_buf.toOwnedSlice();
    }

    // 3. Targets
    const targ_len = try reader.takeByte();
    var targets = try allocator.alloc([]const u8, targ_len);
    i = 0;
    while (i < targ_len) : (i += 1) {
        var name_buf = std.array_list.Managed(u8).init(allocator);
        defer name_buf.deinit();
        while (true) {
            const b = try reader.takeByte();
            if (b == 0) break;
            try name_buf.append(b);
        }
        targets[i] = try name_buf.toOwnedSlice();
    }

    // 4. Inclusions
    const inclusions_count = try reader.takeInt(u16, .little);
    var inclusions = try allocator.alloc(Inclusion, inclusions_count);

    var current_sym_name: []const u8 = "";
    var inc_i: usize = 0;
    while (inc_i < inclusions_count) : (inc_i += 1) {
        if (current_sym_name.len == 0) {
            var name_buf = std.array_list.Managed(u8).init(allocator);
            defer name_buf.deinit();
            while (true) {
                const b = try reader.takeByte();
                if (b == 0) break;
                try name_buf.append(b);
            }
            current_sym_name = try name_buf.toOwnedSlice();
        }

        const targets_mask = try reader.takeLeb128(u64);
        const lib_byte = try reader.takeByte();
        const is_terminal = (lib_byte & 0x80) != 0;
        const lib_index = lib_byte & 0x7f;

        var entries = std.array_list.Managed(VerEntry).init(allocator);
        defer entries.deinit();

        while (true) {
            const api_byte = try reader.takeByte();
            const is_last = (api_byte & 0x80) != 0;
            const api_level = api_byte & 0x7f;
            const ver_node_idx = try reader.takeByte();

            try entries.append(.{
                .api_level = api_level,
                .ver_node_index = ver_node_idx,
            });

            if (is_last) break;
        }

        inclusions[inc_i] = .{
            .sym_name = current_sym_name,
            .targets_mask = targets_mask,
            .lib_index = lib_index,
            .is_terminal = is_terminal,
            .entries = try entries.toOwnedSlice(),
        };

        if (is_terminal) {
            current_sym_name = "";
        }
    }

    return .{
        .libs = libs,
        .ver_nodes = ver_nodes,
        .targets = targets,
        .inclusions = inclusions,
    };
}

test "abilists binary encoding round-trip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const libs = [_]LibMeta{
        .{ .name = "c", .introduced_in = 21 },
        .{ .name = "m", .introduced_in = 21 },
        .{ .name = "vulkan", .introduced_in = 24 },
    };
    const ver_nodes = [_][]const u8{
        "",
        "LIBC",
        "LIBC_N",
        "LIBC_P",
    };
    const targets = [_][]const u8{
        "aarch64-linux-android",
        "arm-linux-androideabi",
        "x86-linux-android",
        "x86_64-linux-android",
    };
    const entries1 = [_]VerEntry{
        .{ .api_level = 21, .ver_node_index = 1 },
        .{ .api_level = 28, .ver_node_index = 3 },
    };
    const inclusions = [_]Inclusion{
        .{
            .sym_name = "printf",
            .targets_mask = 0b1111,
            .lib_index = 0,
            .is_terminal = true,
            .entries = &entries1,
        },
    };

    const abi_data = BionicAbiData{
        .libs = &libs,
        .ver_nodes = &ver_nodes,
        .targets = &targets,
        .inclusions = &inclusions,
    };

    const encoded = try writeAbilists(allocator, abi_data);
    defer allocator.free(encoded);

    const decoded = try readAbilists(allocator, encoded);
    defer {
        for (decoded.libs) |l| allocator.free(l.name);
        allocator.free(decoded.libs);
        for (decoded.ver_nodes) |vn| allocator.free(vn);
        allocator.free(decoded.ver_nodes);
        for (decoded.targets) |t| allocator.free(t);
        allocator.free(decoded.targets);
        for (decoded.inclusions) |inc| {
            allocator.free(inc.sym_name);
            allocator.free(inc.entries);
        }
        allocator.free(decoded.inclusions);
    }

    try testing.expectEqual(abi_data.libs.len, decoded.libs.len);
    try testing.expectEqualStrings("c", decoded.libs[0].name);
    try testing.expectEqual(@as(u8, 21), decoded.libs[0].introduced_in);
    try testing.expectEqual(abi_data.ver_nodes.len, decoded.ver_nodes.len);
    try testing.expectEqualStrings("LIBC_P", decoded.ver_nodes[3]);
    try testing.expectEqual(abi_data.inclusions.len, decoded.inclusions.len);
    try testing.expectEqualStrings("printf", decoded.inclusions[0].sym_name);
    try testing.expectEqual(@as(u64, 0b1111), decoded.inclusions[0].targets_mask);
    try testing.expectEqual(@as(u8, 0), decoded.inclusions[0].lib_index);
    try testing.expectEqual(true, decoded.inclusions[0].is_terminal);
    try testing.expectEqual(@as(usize, 2), decoded.inclusions[0].entries.len);
    try testing.expectEqual(@as(u8, 28), decoded.inclusions[0].entries[1].api_level);
    try testing.expectEqual(@as(u8, 3), decoded.inclusions[0].entries[1].ver_node_index);
}
