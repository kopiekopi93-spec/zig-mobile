const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const ParsedSymbol = struct {
    name: []const u8,
    version_node: []const u8, // "" if unversioned or base
    is_func: bool,
    is_weak: bool,
};

pub const ElfParseResult = struct {
    symbols: []ParsedSymbol,
    version_nodes: [][]const u8,

    pub fn deinit(self: *ElfParseResult, allocator: Allocator) void {
        allocator.free(self.symbols);
        allocator.free(self.version_nodes);
    }
};

pub fn parseElfSo(allocator: Allocator, bytes: []const u8) !ElfParseResult {
    var reader = std.Io.Reader.fixed(bytes);
    const hdr = try std.elf.Header.read(&reader);

    var sh_it = std.elf.SectionHeaderBufferIterator{
        .is_64 = hdr.is_64,
        .endian = hdr.endian,
        .shnum = hdr.shnum,
        .shoff = hdr.shoff,
        .buf = bytes,
    };

    var dynsym_shdr: ?std.elf.Elf64_Shdr = null;
    var versym_shdr: ?std.elf.Elf64_Shdr = null;
    var verdef_shdr: ?std.elf.Elf64_Shdr = null;

    var sh_index: usize = 0;
    while (try sh_it.next()) |sh| : (sh_index += 1) {
        if (sh.sh_type == @backingInt(std.elf.SHT.DYNSYM)) {
            dynsym_shdr = sh;
        } else if (sh.sh_type == @backingInt(std.elf.SHT.GNU_VERSYM)) {
            versym_shdr = sh;
        } else if (sh.sh_type == @backingInt(std.elf.SHT.GNU_VERDEF)) {
            verdef_shdr = sh;
        }
    }

    if (dynsym_shdr == null) {
        return error.NoDynsymSection;
    }

    const dynsym = dynsym_shdr.?;
    const dynstr = try getSectionHeader(bytes, hdr, dynsym.sh_link);
    if (dynstr.sh_offset + dynstr.sh_size > bytes.len) return error.SectionOutOfBounds;
    const dynstr_buf = bytes[dynstr.sh_offset .. dynstr.sh_offset + dynstr.sh_size];

    // Parse VERDEF section
    var version_map = std.AutoHashMap(u16, []const u8).init(allocator);
    defer version_map.deinit();

    var ver_node_list = std.array_list.Managed([]const u8).init(allocator);
    defer ver_node_list.deinit();

    if (verdef_shdr) |vd| {
        if (vd.sh_offset + vd.sh_size <= bytes.len) {
            const vd_buf = bytes[vd.sh_offset .. vd.sh_offset + vd.sh_size];
            var offset: usize = 0;
            var i: usize = 0;
            while (i < vd.sh_info) : (i += 1) {
                if (offset + @sizeOf(std.elf.Verdef) > vd_buf.len) break;
                var r = std.Io.Reader.fixed(vd_buf[offset..]);
                const verdef = try r.takeStruct(std.elf.Verdef, hdr.endian);
                const aux_offset = offset + verdef.aux;
                if (aux_offset + @sizeOf(std.elf.Verdaux) <= vd_buf.len) {
                    var aux_r = std.Io.Reader.fixed(vd_buf[aux_offset..]);
                    const verdaux = try aux_r.takeStruct(std.elf.Verdaux, hdr.endian);
                    if (verdaux.name < dynstr_buf.len) {
                        const name = mem.sliceTo(dynstr_buf[verdaux.name..], 0);
                        const is_base = (verdef.flags & 1) != 0;
                        const stored_name = if (is_base) "" else name;
                        try version_map.put(@intFromEnum(verdef.ndx), stored_name);
                        if (!is_base and name.len > 0) {
                            try ver_node_list.append(name);
                        }
                    }
                }
                if (verdef.next == 0) break;
                offset += verdef.next;
            }
        }
    }

    const versym_buf = if (versym_shdr) |vs|
        if (vs.sh_offset + vs.sh_size <= bytes.len) bytes[vs.sh_offset .. vs.sh_offset + vs.sh_size] else null
    else
        null;

    const sym_entry_size: usize = if (hdr.is_64) @sizeOf(std.elf.Elf64_Sym) else @sizeOf(std.elf.Elf32_Sym);
    const num_syms = dynsym.sh_size / sym_entry_size;

    var symbols = std.array_list.Managed(ParsedSymbol).init(allocator);
    defer symbols.deinit();

    var sym_i: usize = 0;
    while (sym_i < num_syms) : (sym_i += 1) {
        const sym_offset = dynsym.sh_offset + sym_i * sym_entry_size;
        if (sym_offset + sym_entry_size > bytes.len) break;

        var r = std.Io.Reader.fixed(bytes[sym_offset..]);
        var name_idx: u32 = 0;
        var st_shndx: u16 = 0;
        var st_type_val: u4 = 0;
        var st_bind_val: u4 = 0;

        if (hdr.is_64) {
            const s = try r.takeStruct(std.elf.Elf64_Sym, hdr.endian);
            name_idx = s.st_name;
            st_shndx = s.st_shndx;
            st_type_val = s.st_type();
            st_bind_val = s.st_bind();
        } else {
            const s = try r.takeStruct(std.elf.Elf32_Sym, hdr.endian);
            name_idx = s.st_name;
            st_shndx = s.st_shndx;
            st_type_val = s.st_type();
            st_bind_val = s.st_bind();
        }

        // Skip undefined symbols
        if (st_shndx == 0) continue;
        if (name_idx >= dynstr_buf.len) continue;

        const sym_name = mem.sliceTo(dynstr_buf[name_idx..], 0);
        if (sym_name.len == 0) continue;

        // Skip mapping symbols ($x, $d, $a, $t)
        if (sym_name.len == 2 and sym_name[0] == '$') {
            if (sym_name[1] == 'x' or sym_name[1] == 'd' or sym_name[1] == 'a' or sym_name[1] == 't') {
                continue;
            }
        }

        var ver_name: []const u8 = "";
        if (versym_buf) |vs_b| {
            if ((sym_i + 1) * 2 <= vs_b.len) {
                var vs_r = std.Io.Reader.fixed(vs_b[sym_i * 2 ..]);
                const raw_ndx = try vs_r.takeInt(u16, hdr.endian);
                const ndx = raw_ndx & 0x7fff;
                if (version_map.get(ndx)) |vn| {
                    ver_name = vn;
                }
            }
        }

        const is_func = (st_type_val == 2); // STT_FUNC
        const is_weak = (st_bind_val == 2); // STB_WEAK

        try symbols.append(.{
            .name = sym_name,
            .version_node = ver_name,
            .is_func = is_func,
            .is_weak = is_weak,
        });
    }

    return .{
        .symbols = try symbols.toOwnedSlice(),
        .version_nodes = try ver_node_list.toOwnedSlice(),
    };
}

fn getSectionHeader(buf: []const u8, hdr: std.elf.Header, index: usize) !std.elf.Elf64_Shdr {
    var sh_it = std.elf.SectionHeaderBufferIterator{
        .is_64 = hdr.is_64,
        .endian = hdr.endian,
        .shnum = hdr.shnum,
        .shoff = hdr.shoff,
        .buf = buf,
    };
    var i: usize = 0;
    while (try sh_it.next()) |sh| : (i += 1) {
        if (i == index) return sh;
    }
    return error.SectionNotFound;
}
