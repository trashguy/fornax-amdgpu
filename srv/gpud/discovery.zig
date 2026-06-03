/// AMD IP Discovery table parser.
///
/// Modern AMD GPUs (RDNA 2+) embed an IP Discovery table in VRAM/MMIO
/// that describes the base addresses of all hardware IP blocks (GFX, SDMA,
/// DCN, PSP, etc.). This replaces hardcoded register offsets.
///
/// Reference: drivers/gpu/drm/amd/amdgpu/amdgpu_discovery.c

/// Hardware IP block identifiers.
pub const HwId = enum(u16) {
    gc = 1, // Graphics Core (GFX engine)
    sdma = 2, // System DMA
    dcn = 8, // Display Core Next
    vce = 9, // Video Compression Engine
    vcn = 10, // Video Core Next
    psp = 13, // Platform Security Processor
    smu = 14, // System Management Unit
    nbio = 15, // North Bridge I/O
    mp0 = 16, // Media Processor 0
    mp1 = 17, // Media Processor 1
    thm = 18, // Thermal
    _,

    pub fn name(self: HwId) []const u8 {
        return switch (self) {
            .gc => "GC",
            .sdma => "SDMA",
            .dcn => "DCN",
            .psp => "PSP",
            .smu => "SMU",
            .nbio => "NBIO",
            .vcn => "VCN",
            .mp0 => "MP0",
            .mp1 => "MP1",
            .thm => "THM",
            .vce => "VCE",
            _ => "???",
        };
    }
};

pub const MAX_IPS = 32;
pub const MAX_BASES_PER_IP = 6;

pub const IpEntry = struct {
    hw_id: HwId,
    instance: u8,
    major: u8,
    minor: u8,
    revision: u8,
    base_address: [MAX_BASES_PER_IP]u64,
    num_bases: u8,
};

pub const DiscoveryTable = struct {
    entries: [MAX_IPS]IpEntry,
    count: u8,

    pub fn init() DiscoveryTable {
        return .{
            .entries = [_]IpEntry{.{
                .hw_id = @enumFromInt(0),
                .instance = 0,
                .major = 0,
                .minor = 0,
                .revision = 0,
                .base_address = [_]u64{0} ** MAX_BASES_PER_IP,
                .num_bases = 0,
            }} ** MAX_IPS,
            .count = 0,
        };
    }

    /// Find the first IP block matching a given hardware ID.
    pub fn find(self: *const DiscoveryTable, hw_id: HwId) ?*const IpEntry {
        for (self.entries[0..self.count]) |*entry| {
            if (entry.hw_id == hw_id) return entry;
        }
        return null;
    }

    /// Find the Nth instance of an IP block.
    pub fn findInstance(self: *const DiscoveryTable, hw_id: HwId, instance: u8) ?*const IpEntry {
        for (self.entries[0..self.count]) |*entry| {
            if (entry.hw_id == hw_id and entry.instance == instance) return entry;
        }
        return null;
    }

    /// Get the base address of an IP block (first base).
    pub fn getBase(self: *const DiscoveryTable, hw_id: HwId) ?u64 {
        const entry = self.find(hw_id) orelse return null;
        if (entry.num_bases == 0) return null;
        return entry.base_address[0];
    }
};

/// IP Discovery binary header (from VRAM).
const DISCOVERY_SIG: u32 = 0x49504449; // "IPDI" little-endian

const BinaryHeader = extern struct {
    signature: u32 align(1),
    version: u16 align(1),
    size: u16 align(1),
    checksum: u32 align(1),
    body_size: u32 align(1),
    num_dies: u16 align(1),
    reserved: u16 align(1),
};

const DieHeader = extern struct {
    die_id: u16 align(1),
    num_ips: u16 align(1),
};

const IpStructV3 = extern struct {
    hw_id: u16 align(1),
    instance: u8 align(1),
    num_base_address: u8 align(1),
    major: u8 align(1),
    minor: u8 align(1),
    revision: u8 align(1),
    reserved: u8 align(1),
};

/// MMIO scratch register offsets for locating the IP Discovery table.
/// On many AMD GPUs, scratch registers at a known MMIO offset contain
/// the VRAM offset of the IP Discovery table.
const DISCOVERY_SCRATCH_REG: u64 = 0xD04;
const DISCOVERY_FALLBACK_OFFSET: u64 = 0x0;

/// Parse the IP Discovery table from a mapped VRAM region.
/// `vram_base` is the virtual address of the mapped VRAM BAR.
/// `vram_size` is the total size of the mapped VRAM region.
/// `mmio_base` is the virtual address of the mapped MMIO BAR (for scratch reg).
pub fn parse(vram_base: u64, vram_size: u64, mmio_base: u64) ?DiscoveryTable {
    // Try to read discovery offset from MMIO scratch register
    var table_offset = readDiscoveryOffset(mmio_base);
    if (table_offset == 0 or table_offset >= vram_size) {
        table_offset = DISCOVERY_FALLBACK_OFFSET;
    }

    return parseAtOffset(vram_base, vram_size, table_offset);
}

/// Parse directly at a given VRAM offset (when scratch reg isn't available).
pub fn parseAtOffset(vram_base: u64, vram_size: u64, offset: u64) ?DiscoveryTable {
    if (offset + @sizeOf(BinaryHeader) > vram_size) return null;

    const hdr: *const BinaryHeader = @ptrFromInt(vram_base + offset);

    // Validate signature
    if (hdr.signature != DISCOVERY_SIG) {
        // Try scanning first 64KB for the signature
        return scanForTable(vram_base, @min(vram_size, 0x10000));
    }

    return parseFromHeader(vram_base, vram_size, offset, hdr);
}

fn scanForTable(vram_base: u64, scan_size: u64) ?DiscoveryTable {
    var off: u64 = 0;
    while (off + @sizeOf(BinaryHeader) <= scan_size) : (off += 4) {
        const sig_ptr: *const u32 = @ptrFromInt(vram_base + off);
        if (sig_ptr.* == DISCOVERY_SIG) {
            const hdr: *const BinaryHeader = @ptrFromInt(vram_base + off);
            return parseFromHeader(vram_base, scan_size, off, hdr);
        }
    }
    return null;
}

fn parseFromHeader(vram_base: u64, vram_size: u64, base_offset: u64, hdr: *const BinaryHeader) ?DiscoveryTable {
    var table = DiscoveryTable.init();

    var pos = base_offset + @sizeOf(BinaryHeader);

    var die_idx: u16 = 0;
    while (die_idx < hdr.num_dies) : (die_idx += 1) {
        if (pos + @sizeOf(DieHeader) > vram_size) break;

        const die_hdr: *const DieHeader = @ptrFromInt(vram_base + pos);
        pos += @sizeOf(DieHeader);

        var ip_idx: u16 = 0;
        while (ip_idx < die_hdr.num_ips) : (ip_idx += 1) {
            if (pos + @sizeOf(IpStructV3) > vram_size) break;
            if (table.count >= MAX_IPS) break;

            const ip: *const IpStructV3 = @ptrFromInt(vram_base + pos);
            pos += @sizeOf(IpStructV3);

            var entry = &table.entries[table.count];
            entry.hw_id = @enumFromInt(ip.hw_id);
            entry.instance = ip.instance;
            entry.major = ip.major;
            entry.minor = ip.minor;
            entry.revision = ip.revision;
            entry.num_bases = @min(ip.num_base_address, MAX_BASES_PER_IP);

            // Read base addresses (u32 dword offsets in the binary, convert to byte offsets)
            for (0..entry.num_bases) |bi| {
                if (pos + 4 > vram_size) break;
                const base_ptr: *const u32 = @ptrFromInt(vram_base + pos);
                entry.base_address[bi] = @as(u64, base_ptr.*) * 4;
                pos += 4;
            }

            table.count += 1;
        }
    }

    if (table.count == 0) return null;
    return table;
}

fn readDiscoveryOffset(mmio_base: u64) u64 {
    if (mmio_base == 0) return 0;
    const scratch: *const volatile u32 = @ptrFromInt(mmio_base + DISCOVERY_SCRATCH_REG);
    return @as(u64, scratch.*);
}

/// Hardcoded IP Discovery fallback for Raphael iGPU (device 0x164e).
/// GFX 10.3.7 / PSP 13.0.4. Register bases from Linux yellow_carp_ip_offset.h
/// (Yellow Carp shares the same register layout as Raphael for these IP blocks).
/// Used when VFIO passthrough leaves VRAM empty and the binary table is absent.
/// NOTE: Values are byte offsets (yellow_carp_ip_offset.h dword values * 4).
/// The parsed path does: base_ptr.* * 4 (binary table stores dword offsets).
/// The hardcoded path stores pre-multiplied byte offsets to match.
pub fn hardcodedRaphael() DiscoveryTable {
    var table = DiscoveryTable.init();

    // GC 10.3.7 — Graphics Core
    // base[0]=CP registers, base[1]=RLC/SPI, base[2-3]=other segments
    // base[4]=GFXHUB registers (GCVM_L2, GCMC_VM) — different from CP base on Raphael APU
    // Real IP Discovery: GC bases = [0x16000, 0xdc0000, 0xe00000, 0xe40000, 0x243fc00] (dword indices)
    // GFXHUB byte offset = 0x16000 * 4 = 0x58000
    table.entries[0] = .{
        .hw_id = .gc,
        .instance = 0,
        .major = 10,
        .minor = 3,
        .revision = 7,
        .base_address = .{ 0x00004980, 0x00028000, 0x00030000, 0x0900B000, 0x00058000, 0 },
        .num_bases = 5,
    };

    // SDMA 5.2.7 — System DMA (shares GC base on APU)
    table.entries[1] = .{
        .hw_id = .sdma,
        .instance = 0,
        .major = 5,
        .minor = 2,
        .revision = 7,
        .base_address = .{ 0x00004980, 0x00028000, 0x00030000, 0x0900B000, 0, 0 },
        .num_bases = 4,
    };

    // PSP 13.0.4 — Platform Security Processor (MP0)
    table.entries[2] = .{
        .hw_id = .psp,
        .instance = 0,
        .major = 13,
        .minor = 0,
        .revision = 4,
        .base_address = .{ 0x00058000, 0x03700000, 0x03800000, 0x03900000, 0x090FF000, 0 },
        .num_bases = 5,
    };

    // DCN 3.1.5 — Display Core Next
    table.entries[3] = .{
        .hw_id = .dcn,
        .instance = 0,
        .major = 3,
        .minor = 1,
        .revision = 5,
        .base_address = .{ 0x00000048, 0x00000300, 0x0000D300, 0x00024000, 0x0900F000, 0 },
        .num_bases = 5,
    };

    // VCN 3.1.2 — Video Core Next
    table.entries[4] = .{
        .hw_id = .vcn,
        .instance = 0,
        .major = 3,
        .minor = 1,
        .revision = 2,
        .base_address = .{ 0x0001E000, 0x0001F800, 0x0900C000, 0, 0, 0 },
        .num_bases = 3,
    };

    // NBIO 7.5.1 — North Bridge I/O
    table.entries[5] = .{
        .hw_id = .nbio,
        .instance = 0,
        .major = 7,
        .minor = 5,
        .revision = 1,
        .base_address = .{ 0x00000000, 0x00000050, 0x00003480, 0x00041000, 0, 0 },
        .num_bases = 4,
    };

    // SMU 13.0.4 — System Management Unit (MP1)
    table.entries[6] = .{
        .hw_id = .smu,
        .instance = 0,
        .major = 13,
        .minor = 0,
        .revision = 4,
        .base_address = .{ 0x00058000, 0x03700000, 0x03800000, 0x03900000, 0x090FF000, 0 },
        .num_bases = 5,
    };

    // THM — Thermal
    table.entries[7] = .{
        .hw_id = .thm,
        .instance = 0,
        .major = 13,
        .minor = 0,
        .revision = 4,
        .base_address = .{ 0x00059800, 0x0005A000, 0, 0, 0, 0 },
        .num_bases = 2,
    };

    table.count = 8;
    return table;
}
