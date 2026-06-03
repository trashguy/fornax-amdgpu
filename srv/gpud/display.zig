/// Display engine abstraction.
///
/// Provides a common interface over DCN 3.x (RDNA 2) and DCN 4.x (RDNA 4)
/// display engines. Initially delegates to the GOP/UEFI framebuffer until
/// full DCN bring-up is implemented in Phase G6c.
const fx = @import("fornax");
const discovery = @import("discovery.zig");

const out = fx.io.Writer.stdout;

pub const DisplayBackend = enum {
    none,
    gop, // UEFI GOP framebuffer (passthrough)
    dcn3, // DCN 3.x (RDNA 2) — Phase G6c
    dcn4, // DCN 4.x (RDNA 4) — Phase G6d
};

pub const DisplayState = struct {
    backend: DisplayBackend,
    fb_virt: u64,
    fb_phys: u64,
    fb_size: u64,
    width: u32,
    height: u32,
    stride: u32,
    is_bgr: bool,

    pub fn initGop() ?DisplayState {
        // Read GOP framebuffer info from kernel
        var buf: [128]u8 = undefined;
        const fd = fx.open("/dev/fbinfo");
        if (fd < 0) return null;
        const n = fx.read(fd, &buf);
        _ = fx.close(fd);
        if (n <= 0) return null;

        const data = buf[0..@intCast(n)];

        // Parse space-separated tokens: "<phys_hex> <width> <height> <stride> <bpp> [format]"
        var tokens: [6][]const u8 = undefined;
        var tok_count: usize = 0;
        var pos: usize = 0;
        while (pos < data.len and tok_count < 6) {
            while (pos < data.len and (data[pos] == ' ' or data[pos] == '\n')) : (pos += 1) {}
            const tok_start = pos;
            while (pos < data.len and data[pos] != ' ' and data[pos] != '\n') : (pos += 1) {}
            if (pos > tok_start) {
                tokens[tok_count] = data[tok_start..pos];
                tok_count += 1;
            }
        }
        if (tok_count < 5) return null;

        const phys = parseHex(tokens[0]) orelse return null;
        const width = parseDec(tokens[1]) orelse return null;
        const height = parseDec(tokens[2]) orelse return null;
        const stride = parseDec(tokens[3]) orelse return null;
        if (width == 0 or height == 0) return null;

        const is_bgr = tok_count >= 6 and tokens[5].len >= 3 and
            tokens[5][0] == 'b' and tokens[5][1] == 'g' and tokens[5][2] == 'r';

        const size = @as(u64, stride) * @as(u64, height) * 4;
        const virt = fx.mmap_device(phys, size, 0x1); // write-combining
        if (virt == 0) return null;

        return DisplayState{
            .backend = .gop,
            .fb_virt = virt,
            .fb_phys = phys,
            .fb_size = size,
            .width = width,
            .height = height,
            .stride = stride,
            .is_bgr = is_bgr,
        };
    }

    /// Read pixels from framebuffer.
    pub fn readFb(self: *const DisplayState, offset: u64, buf: []u8) usize {
        if (offset >= self.fb_size) return 0;
        const available = self.fb_size - offset;
        const to_copy = @min(available, buf.len);
        const src: [*]const u8 = @ptrFromInt(self.fb_virt + offset);
        @memcpy(buf[0..to_copy], src[0..to_copy]);
        return to_copy;
    }

    /// Write pixels to framebuffer.
    pub fn writeFb(self: *const DisplayState, offset: u64, data: []const u8) usize {
        if (offset >= self.fb_size) return 0;
        const available = self.fb_size - offset;
        const to_write = @min(available, data.len);
        const dst: [*]u8 = @ptrFromInt(self.fb_virt + offset);
        @memcpy(dst[0..to_write], data[0..to_write]);
        return to_write;
    }

    /// Get framebuffer size in bytes.
    pub fn fbSize(self: *const DisplayState) u64 {
        return self.fb_size;
    }

    /// Format info string.
    pub fn getInfo(self: *const DisplayState, buf: []u8) usize {
        var pos: usize = 0;

        const backend_str = switch (self.backend) {
            .none => "display: none\n",
            .gop => "display: gop\n",
            .dcn3 => "display: dcn3\n",
            .dcn4 => "display: dcn4\n",
        };
        pos += copyStr(buf[pos..], backend_str);
        pos += fmtField(buf[pos..], "width: ", self.width);
        pos += fmtField(buf[pos..], "height: ", self.height);
        pos += fmtField(buf[pos..], "stride: ", self.stride);
        pos += fmtField(buf[pos..], "bpp: ", 32);
        return pos;
    }
};

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

fn parseDec(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var result: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        result = result * 10 + @as(u32, c - '0');
    }
    return result;
}

fn copyStr(buf: []u8, s: []const u8) usize {
    const len = @min(s.len, buf.len);
    @memcpy(buf[0..len], s[0..len]);
    return len;
}

fn fmtField(buf: []u8, label: []const u8, val: u32) usize {
    var pos: usize = 0;
    if (pos + label.len >= buf.len) return 0;
    @memcpy(buf[pos..][0..label.len], label);
    pos += label.len;
    pos += fmtDec(buf[pos..], val);
    if (pos < buf.len) {
        buf[pos] = '\n';
        pos += 1;
    }
    return pos;
}

fn fmtDec(buf: []u8, val: u32) usize {
    if (val == 0) {
        if (buf.len > 0) buf[0] = '0';
        return 1;
    }
    var tmp: [10]u8 = undefined;
    var n: usize = 0;
    var v = val;
    while (v != 0) : (n += 1) {
        tmp[n] = @truncate((v % 10) + '0');
        v /= 10;
    }
    if (n > buf.len) return 0;
    for (0..n) |j| {
        buf[j] = tmp[n - 1 - j];
    }
    return n;
}
