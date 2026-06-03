/// AMD GPU server for Fornax OS (v4: correct GRBM_SOFT_RESET bits + post-reset writes).
///
/// Replaces the core gpud with an AMD-capable version that supports
/// RDNA 2 (GFX 10.3) and RDNA 4 (GFX 12) GPUs. Falls back to GOP
/// framebuffer if no AMD GPU is found or initialization fails.
///
/// Serves /dev/gpu/ctl and /dev/gpu/fb0 via IPC.
const fx = @import("fornax");
const discovery = @import("discovery.zig");
const psp = @import("psp.zig");
const display = @import("display.zig");
const gfx10 = @import("backends/gfx10.zig");
const mmio = @import("mmio.zig");

const out = fx.io.Writer.stdout;

const SERVER_FD = 3;
const MAX_HANDLES = 16;

const Backend = enum { none, gop_only, amd_rdna2, amd_rdna4 };

var backend: Backend = .none;

// AMD GPU state (valid when backend is amd_*)
var ip_table: discovery.DiscoveryTable = discovery.DiscoveryTable.init();
var psp_state: psp.PspState = undefined;
var gfx10_state: gfx10.Gfx10State = undefined;
var display_state: display.DisplayState = undefined;
var display_valid: bool = false;
var gfx_valid: bool = false;

// --- PCI scanning ---

const AmdPciInfo = struct {
    bus: u8,
    slot: u8,
    func: u8,
    vendor: u16,
    device: u16,
    bar0_base: u64,
    bar0_size: u64,
    bar2_base: u64,
    bar2_size: u64,
    bar5_base: u64,
    bar5_size: u64,
};

/// Scan /dev/pci for AMD display controller (vendor 0x1002, class 03:00).
fn scanForAmdGpu() ?AmdPciInfo {
    var buf: [8192]u8 = undefined;
    const pci_fd = fx.open("/dev/pci");
    if (pci_fd < 0) return null;
    const n = fx.read(pci_fd, &buf);
    _ = fx.close(pci_fd);
    if (n <= 0) return null;

    const data = buf[0..@intCast(n)];
    var i: usize = 0;

    while (i < data.len) {
        var eol = i;
        while (eol < data.len and data[eol] != '\n') : (eol += 1) {}
        const line = data[i..eol];
        i = eol + 1;

        // Format: "BB:SS.F VVVV:DDDD CC:SS:PP [sizes] [bases] ..."
        if (line.len < 26) continue;
        if (line[12] != ':') continue;

        const vendor = parseHex(line[8..12]) orelse continue;
        const device = parseHex(line[13..17]) orelse continue;

        // Check vendor = AMD (0x1002) and class = display (03)
        if (vendor != 0x1002) continue;
        const class_code = parseHex(line[18..20]) orelse continue;
        if (class_code != 0x03) continue;

        // Parse BDF
        const bdf_bus = parseHex(line[0..2]) orelse continue;
        const bdf_slot = parseHex(line[3..5]) orelse continue;
        const bdf_func: u8 = if (line[6] >= '0' and line[6] <= '7') line[6] - '0' else continue;

        // Parse BAR sizes bracket
        const sz_open = indexOf(line, 25, '[') orelse continue;
        const sz_close = indexOf(line, sz_open + 1, ']') orelse continue;
        var bar_sizes: [6]u64 = .{ 0, 0, 0, 0, 0, 0 };
        _ = parseBracketTokens(line[sz_open + 1 .. sz_close], &bar_sizes);

        // Parse BAR bases bracket
        var bar_bases: [6]u64 = .{ 0, 0, 0, 0, 0, 0 };
        if (sz_close + 2 < line.len and line[sz_close + 1] == ' ' and line[sz_close + 2] == '[') {
            const b_close = indexOf(line, sz_close + 3, ']') orelse continue;
            _ = parseBracketTokens(line[sz_close + 3 .. b_close], &bar_bases);
        } else continue;

        return AmdPciInfo{
            .bus = @truncate(bdf_bus),
            .slot = @truncate(bdf_slot),
            .func = bdf_func,
            .vendor = @truncate(vendor),
            .device = @truncate(device),
            .bar0_base = bar_bases[0],
            .bar0_size = bar_sizes[0],
            .bar2_base = bar_bases[2],
            .bar2_size = bar_sizes[2],
            .bar5_base = bar_bases[5],
            .bar5_size = bar_sizes[5],
        };
    }
    return null;
}

// --- AMD GPU initialization ---

fn initAmdGpu(info: *const AmdPciInfo) bool {
    out.puts("amdgpu: found AMD GPU ");
    fmtHexPrint(info.device);
    out.puts(" at ");
    fmtHexPrint(info.bus);
    out.puts(":");
    fmtHexPrint(info.slot);
    out.puts(".");
    fmtDecPrint(info.func);
    out.puts("\n");

    // Map MMIO BAR (BAR 5 for register access, or BAR 0 for some iGPUs)
    var mmio_base: u64 = 0;
    var mmio_size: u64 = 0;
    if (info.bar5_base != 0 and info.bar5_size != 0) {
        mmio_size = info.bar5_size;
        mmio_base = fx.mmap_device(info.bar5_base, mmio_size, 0x0); // uncached
    } else if (info.bar0_base != 0 and info.bar0_size != 0) {
        // Some iGPUs expose registers through BAR 0
        mmio_size = info.bar0_size;
        mmio_base = fx.mmap_device(info.bar0_base, mmio_size, 0x0);
    }
    if (mmio_base == 0) {
        out.puts("amdgpu: failed to map MMIO BAR\n");
        return false;
    }
    out.puts("amdgpu: MMIO phys=");
    fmtHexPrint(if (info.bar5_base != 0) info.bar5_base else info.bar0_base);
    out.puts(" size=");
    fmtHexPrint(mmio_size);
    out.puts(" virt=");
    fmtHexPrint(mmio_base);
    out.puts("\n");

    // Map VRAM/aperture BAR (BAR 0) with write-combining
    var vram_base: u64 = 0;
    var vram_size: u64 = 0;
    if (info.bar0_base != 0 and info.bar0_size != 0 and info.bar5_base != 0) {
        vram_size = info.bar0_size;
        // Use huge pages for large VRAM BARs
        const flags: u64 = if (vram_size >= 0x200000) 0x3 else 0x1; // WC + huge
        vram_base = fx.mmap_device(info.bar0_base, vram_size, flags);
        if (vram_base == 0) {
            out.puts("amdgpu: failed to map VRAM BAR\n");
            // Non-fatal for iGPU (UMA)
        } else {
            out.puts("amdgpu: VRAM phys=");
            fmtHexPrint(info.bar0_base);
            out.puts(" size=");
            fmtHexPrint(vram_size);
            out.puts(" virt=");
            fmtHexPrint(vram_base);
            out.puts("\n");
        }
    }

    // Map doorbell BAR (BAR 2)
    var doorbell_base: u64 = 0;
    if (info.bar2_base != 0 and info.bar2_size != 0) {
        doorbell_base = fx.mmap_device(info.bar2_base, info.bar2_size, 0x0);
        if (doorbell_base != 0) {
            out.puts("amdgpu: doorbell phys=");
            fmtHexPrint(info.bar2_base);
            out.puts(" virt=");
            fmtHexPrint(doorbell_base);
            out.puts("\n");
        }
    }

    out.puts("amdgpu: reading discovery scratch at ");
    fmtHexPrint(mmio_base + 0xD04);
    out.puts("\n");

    // Parse IP Discovery table
    const table = discovery.parse(
        if (vram_base != 0) vram_base else mmio_base,
        if (vram_base != 0) vram_size else mmio_size,
        mmio_base,
    ) orelse blk: {
        // VFIO passthrough leaves VRAM empty — use hardcoded fallback
        if (info.device == 0x164e) {
            out.puts("amdgpu: using hardcoded Raphael (0x164e) IP table\n");
            break :blk discovery.hardcodedRaphael();
        }
        out.puts("amdgpu: IP Discovery table not found\n");
        return false;
    };
    ip_table = table;
    out.puts("amdgpu: IP Discovery: ");
    fmtDecPrint(ip_table.count);
    out.puts(" IP blocks\n");

    // Print discovered IP blocks
    for (ip_table.entries[0..ip_table.count]) |*entry| {
        out.puts("  ");
        out.puts(entry.hw_id.name());
        out.puts(" v");
        fmtDecPrint(entry.major);
        out.puts(".");
        fmtDecPrint(entry.minor);
        out.puts(".");
        fmtDecPrint(entry.revision);
        out.puts("\n");
    }

    // Initialize MMIO indirect access (for registers beyond BAR window)
    const nbio_entry = ip_table.find(.nbio);
    const nbio_base1: u64 = if (nbio_entry) |n| (if (n.num_bases > 1) n.base_address[1] else 0) else 0;
    mmio.init(mmio_base, mmio_size, nbio_base1);

    // Initialize PSP
    const psp_entry = ip_table.find(.psp) orelse {
        out.puts("amdgpu: no PSP block in IP Discovery\n");
        return false;
    };
    psp_state = psp.PspState.init(mmio_base, psp_entry);

    const psp_result = psp_state.bootstrap();
    const psp_alive = (psp_result == .ok);

    if (!psp_alive) {
        out.puts("amdgpu: PSP offline — will attempt GFX init without firmware reload\n");
    }

    // Detect GFX generation and initialize backend
    const gc_entry = ip_table.find(.gc);
    if (gc_entry) |gc| {
        if (gc.major >= 12) {
            out.puts("amdgpu: GFX 12 detected (RDNA 4) — not yet supported\n");
            backend = .amd_rdna4;
        } else if (gc.major >= 10) {
            var state = gfx10.Gfx10State.init(mmio_base, &ip_table, doorbell_base) orelse {
                out.puts("amdgpu: GFX 10 init failed\n");
                return false;
            };

            if (psp_alive) {
                // Normal path: load firmware via PSP, then bring up GFX
                if (state.bringUp(&psp_state)) {
                    gfx10_state = state;
                    gfx_valid = true;
                    backend = .amd_rdna2;
                } else {
                    state.deinit();
                    return false;
                }
            } else {
                // PSP dead (VFIO APU without FLR). Try SMU power-up,
                // then attempt GFX init with already-loaded firmware.
                if (state.bringUpWithoutPsp()) {
                    gfx10_state = state;
                    gfx_valid = true;
                    backend = .amd_rdna2;
                } else {
                    state.deinit();
                    return false;
                }
            }
        }
    }

    return true;
}

// --- Handle management ---

const Handle = struct {
    file_idx: u8, // 0 = ctl, 1 = fb0
    active: bool,
};

var handles: [MAX_HANDLES]Handle = [_]Handle{.{ .file_idx = 0, .active = false }} ** MAX_HANDLES;

var msg: fx.IpcMessage linksection(".bss") = undefined;
var reply: fx.IpcMessage linksection(".bss") = undefined;

fn allocHandle(file_idx: u8) ?u32 {
    for (&handles, 0..) |*h, i| {
        if (!h.active) {
            h.* = .{ .file_idx = file_idx, .active = true };
            return @intCast(i + 1); // +1: handle 0 is reserved (kernel treats 0 as "no handle")
        }
    }
    return null;
}

fn freeHandle(id: u32) void {
    if (id == 0) return;
    const idx = id - 1;
    if (idx < MAX_HANDLES) handles[@intCast(idx)].active = false;
}

fn getHandle(id: u32) ?*Handle {
    if (id == 0) return null;
    const idx = id - 1;
    if (idx >= MAX_HANDLES) return null;
    const h = &handles[@intCast(idx)];
    if (!h.active) return null;
    return h;
}

// --- IPC helpers ---

fn writeU32LE(buf: *[4]u8, val: u32) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
}

fn readU32LE(buf: *const [4]u8) u32 {
    return @as(u32, buf[0]) |
        (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16) |
        (@as(u32, buf[3]) << 24);
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

// --- IPC dispatch ---

fn handleOpen(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    const path = req.data[0..req.data_len];

    const file_idx: u8 = if (strEql(path, "ctl"))
        0
    else if (strEql(path, "fb0"))
        1
    else {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    const handle = allocHandle(file_idx) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    resp.* = fx.IpcMessage.init(fx.R_OK);
    writeU32LE(resp.data[0..4], handle);
    resp.data_len = 4;
}

fn handleRead(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 12) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    const handle_id = readU32LE(req.data[0..4]);
    const offset = readU32LE(req.data[4..8]);
    const count = readU32LE(req.data[8..12]);

    const h = getHandle(handle_id) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    resp.* = fx.IpcMessage.init(fx.R_OK);

    if (h.file_idx == 0) {
        // ctl: return info string
        const max = @min(count, 4096);
        const n = getCtlInfo(resp.data[0..max]);

        if (offset >= n) {
            resp.data_len = 0;
        } else {
            const available = n - offset;
            const to_copy: u32 = @intCast(@min(available, max));
            if (offset > 0) {
                var j: u32 = 0;
                while (j < to_copy) : (j += 1) {
                    resp.data[j] = resp.data[offset + j];
                }
            }
            resp.data_len = to_copy;
        }
    } else {
        // fb0: read pixels
        const max = @min(count, 16384);
        const n: u32 = if (display_valid)
            @intCast(display_state.readFb(@as(u64, offset), resp.data[0..max]))
        else
            0;
        resp.data_len = n;
    }
}

fn handleWrite(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 4) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    const handle_id = readU32LE(req.data[0..4]);
    const h = getHandle(handle_id) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    if (h.file_idx == 0) {
        // ctl: parse commands
        handleCtlWrite(req.data[4..req.data_len], resp);
    } else {
        // fb0: write pixel data [handle:4][offset:4][pixels...]
        if (req.data_len < 8) {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        }
        const offset = readU32LE(req.data[4..8]);
        const pixel_data = req.data[8..req.data_len];
        const n: u32 = if (display_valid)
            @intCast(display_state.writeFb(@as(u64, offset), pixel_data))
        else
            0;
        resp.* = fx.IpcMessage.init(fx.R_OK);
        writeU32LE(resp.data[0..4], n);
        resp.data_len = 4;
    }
}

fn handleCtlWrite(cmd_data: []const u8, resp: *fx.IpcMessage) void {
    _ = cmd_data;
    // TODO: mode setting, power management commands
    resp.* = fx.IpcMessage.init(fx.R_ERROR);
}

fn handleClose(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 4) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }
    freeHandle(readU32LE(req.data[0..4]));
    resp.* = fx.IpcMessage.init(fx.R_OK);
    resp.data_len = 0;
}

fn handleStat(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 4) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    const handle_id = readU32LE(req.data[0..4]);
    const h = getHandle(handle_id) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    resp.* = fx.IpcMessage.init(fx.R_OK);
    @memset(resp.data[0..64], 0);

    if (h.file_idx == 0) {
        writeU32LE(resp.data[0..4], 512);
    } else {
        const size: u32 = if (display_valid)
            @intCast(@min(display_state.fbSize(), 0xFFFFFFFF))
        else
            0;
        writeU32LE(resp.data[0..4], size);
    }
    writeU32LE(resp.data[4..8], 0); // file_type = regular
    resp.data_len = 64;
}

// --- Info formatting ---

fn getCtlInfo(buf: []u8) u32 {
    var pos: usize = 0;

    const backend_str = switch (backend) {
        .none => "backend: none\n",
        .gop_only => "backend: gop\n",
        .amd_rdna2 => "backend: amd-rdna2\n",
        .amd_rdna4 => "backend: amd-rdna4\n",
    };
    pos += copyStr(buf[pos..], backend_str);

    if (display_valid) {
        pos += display_state.getInfo(buf[pos..]);
    }

    if (gfx_valid) {
        pos += gfx10_state.getInfo(buf[pos..]);
    }

    return @intCast(pos);
}

fn copyStr(buf: []u8, s: []const u8) usize {
    const len = @min(s.len, buf.len);
    @memcpy(buf[0..len], s[0..len]);
    return len;
}

// --- Entry point ---

export fn _start() noreturn {
    out.puts("gpud: AMD GPU server starting\n");

    // 1. Try AMD GPU
    if (scanForAmdGpu()) |info| {
        if (initAmdGpu(&info)) {
            out.puts("gpud: AMD GPU initialized\n");
        } else {
            out.puts("gpud: AMD GPU init failed, falling back to GOP\n");
        }
    }

    // 2. Fall back to GOP display if no AMD display yet
    if (!display_valid) {
        if (display.DisplayState.initGop()) |ds| {
            display_state = ds;
            display_valid = true;
            if (backend == .none) backend = .gop_only;
            out.puts("gpud: GOP framebuffer active\n");
        }
    }

    if (backend == .none and !display_valid) {
        out.puts("gpud: no GPU backend available\n");
    }

    // Server loop
    while (true) {
        const rc = fx.ipc_recv(SERVER_FD, &msg);
        if (rc < 0) {
            _ = fx.write(2, "gpud: ipc_recv error\n");
            continue;
        }

        switch (msg.tag) {
            fx.T_OPEN => handleOpen(&msg, &reply),
            fx.T_READ => handleRead(&msg, &reply),
            fx.T_WRITE => handleWrite(&msg, &reply),
            fx.T_CLOSE => handleClose(&msg, &reply),
            fx.T_STAT => handleStat(&msg, &reply),
            else => {
                reply = fx.IpcMessage.init(fx.R_ERROR);
            },
        }

        _ = fx.ipc_reply(SERVER_FD, &reply);
    }
}

// --- Parsing helpers ---

fn parseHex(s: []const u8) ?u64 {
    if (s.len == 0 or s.len > 16) return null;
    var result: u64 = 0;
    for (s) |c| {
        const d: u64 = if (c >= '0' and c <= '9')
            c - '0'
        else if (c >= 'a' and c <= 'f')
            c - 'a' + 10
        else if (c >= 'A' and c <= 'F')
            c - 'A' + 10
        else
            return null;
        result = (result << 4) | d;
    }
    return result;
}

fn indexOf(data: []const u8, start: usize, needle: u8) ?usize {
    var i = start;
    while (i < data.len) : (i += 1) {
        if (data[i] == needle) return i;
    }
    return null;
}

fn parseBracketTokens(data: []const u8, values: []u64) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < data.len and count < values.len) {
        while (pos < data.len and data[pos] == ' ') : (pos += 1) {}
        const tok_start = pos;
        while (pos < data.len and data[pos] != ' ' and data[pos] != ']') : (pos += 1) {}
        if (pos > tok_start) {
            values[count] = parseHex(data[tok_start..pos]) orelse 0;
            count += 1;
        }
        if (pos < data.len and data[pos] == ']') break;
    }
    return count;
}

// --- Print helpers ---

pub fn fmtHexPrint(val: u64) void {
    var buf: [16]u8 = undefined;
    var n: usize = 0;
    var v = val;
    if (v == 0) {
        out.puts("0");
        return;
    }
    while (v != 0) : (n += 1) {
        const digit: u8 = @truncate(v & 0xF);
        buf[n] = if (digit < 10) '0' + digit else 'a' + digit - 10;
        v >>= 4;
    }
    var rev: [16]u8 = undefined;
    for (0..n) |j| rev[j] = buf[n - 1 - j];
    out.puts(rev[0..n]);
}

pub fn fmtDecPrint(val: u64) void {
    if (val == 0) {
        out.puts("0");
        return;
    }
    var buf: [20]u8 = undefined;
    var n: usize = 0;
    var v = val;
    while (v != 0) : (n += 1) {
        buf[n] = @truncate((v % 10) + '0');
        v /= 10;
    }
    var rev: [20]u8 = undefined;
    for (0..n) |j| rev[j] = buf[n - 1 - j];
    out.puts(rev[0..n]);
}
