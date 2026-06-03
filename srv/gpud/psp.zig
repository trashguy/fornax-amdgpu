/// AMD PSP (Platform Security Processor) bootloader mailbox protocol.
///
/// The PSP is an ARM Cortex-A5 embedded in AMD GPUs that manages firmware
/// loading, security, and hardware initialization. Communication during
/// boot uses C2PMSG (CPU-to-PSP message) registers at the MP0 IP base.
///
/// For PSP 13.0.4 (Raphael), the bootloader uses "unified firmware" (TOC)
/// mode: a single small TOC blob configures the PSP, which has SOS in ROM.
/// Older PSP versions (13.0.0) load SOS/SysDrv as separate firmware blobs.
///
/// Reference: drivers/gpu/drm/amd/amdgpu/psp_v13_0.c, mp_13_0_0_offset.h
const fx = @import("fornax");
const discovery = @import("discovery.zig");
const memory = @import("memory.zig");

const out = fx.io.Writer.stdout;

// C2PMSG register byte offsets from the PSP (MP0) IP base.
// Source: mp/mp_13_0_2_offset.h (PSP 13.0.x register map)
// Byte offset = dword register index * 4.
const C2PMSG_35: u64 = 0x0263 * 4; // 0x098C — bootloader command & status
const C2PMSG_36: u64 = 0x0264 * 4; // 0x0990 — firmware physical address (>> 20)

// PSP ring buffer registers for v13.0 (different from older v3.1/v11.0!)
// v13.0 uses C2PMSG_101-104 for ring control, C2PMSG_67 for write pointer.
// Reference: psp_v13_0_ring_create / psp_v13_0_ring_stop in psp_v13_0.c
const C2PMSG_67: u64 = 0x0283 * 4; // 0x0A0C — write pointer (ring entry index)
const C2PMSG_101: u64 = 0x0305 * 4; // 0x0C14 — ring create / destroy flag (v13.0)
const C2PMSG_102: u64 = 0x0306 * 4; // 0x0C18 — ring base address low
const C2PMSG_103: u64 = 0x0307 * 4; // 0x0C1C — ring base address high
const C2PMSG_104: u64 = 0x0308 * 4; // 0x0C20 — ring size (in bytes)

// SOL (Sign Of Life) register — non-zero when SOS is already loaded.
// Reference: psp_v13_0_is_sos_alive() in psp_v13_0.c
const C2PMSG_81: u64 = 0x0291 * 4; // 0x0A44

// PSP bootloader command IDs (from amdgpu_psp.h)
const PSP_BL_LOAD_SYSDRV: u32 = 0x10000;
const PSP_BL_LOAD_SOSDRV: u32 = 0x20000;
const PSP_BL_LOAD_KEY_DB: u32 = 0x80000;
const PSP_BL_LOAD_TOC: u32 = 0x70000; // unified firmware (Raphael+)

// Bootloader ready bit
const PSP_BL_READY: u32 = 0x80000000;

// Timeout: ~10 seconds (10M iterations of MMIO poll)
const PSP_TIMEOUT_ITERS: u32 = 10_000_000;

// PSP firmware type IDs in v2.0 SOS header
const FW_TYPE_PSP_SOS: u32 = 2;
const FW_TYPE_PSP_SYS_DRV: u32 = 3;
const FW_TYPE_PSP_KDB: u32 = 4;

// PSP ring buffer constants.
// The ring contains psp_gfx_rb_frame entries (64 bytes each) that POINT to
// a separate command buffer. This is an indirect ring, not inline commands.
const PSP_RING_SIZE: u32 = 0x1000; // 4KB ring buffer
const PSP_RB_FRAME_SIZE: u32 = 64; // sizeof(psp_gfx_rb_frame) = 16 dwords
const PSP_RB_FRAME_DWORDS: u32 = PSP_RB_FRAME_SIZE / 4;
const PSP_RING_NUM_ENTRIES: u32 = PSP_RING_SIZE / PSP_RB_FRAME_SIZE; // 64 entries
const PSP_CMD_BUF_SIZE: u32 = 0x1000; // 4KB command buffer (psp_gfx_cmd_resp)
// Ring commands (from psp_gfx_if.h). NO bit 31 — PSP sets bit 31 as ack.
// Reference: psp_v13_0_ring_create, psp_v13_0_ring_stop
const PSP_RING_CREATE_KM: u32 = 0x00020000; // GFX_CTRL_CMD_ID_INIT_GPCOM_RING (KM=2 << 16)
const PSP_RING_DESTROY: u32 = 0x00030000; // GFX_CTRL_CMD_ID_DESTROY_RINGS
const PSP_RING_POLL_ITERS: u32 = 5_000_000;

// PSP ring command IDs (from psp_gfx_cmd_id in amdgpu_psp.h)
const GFX_CMD_ID_LOAD_TA: u32 = 1;
const GFX_CMD_ID_UNLOAD_TA: u32 = 2;
const GFX_CMD_ID_LOAD_ASD: u32 = 4;
const GFX_CMD_ID_LOAD_IP_FW: u32 = 6;
const GFX_CMD_ID_AUTOLOAD_RLC: u32 = 11;

// DMA alignment: PSP bootloader address register uses phys >> 20
const DMA_ALIGNMENT: u32 = 1 << 20; // 1MB

// IP firmware type IDs for post-SOS ring commands.
// Reference: enum psp_gfx_fw_type in psp_gfx_if.h (Linux kernel)
pub const FW_TYPE_CP_ME: u32 = 1;
pub const FW_TYPE_CP_PFP: u32 = 2;
pub const FW_TYPE_CP_CE: u32 = 3;
pub const FW_TYPE_CP_MEC: u32 = 4;
pub const FW_TYPE_CP_MEC_ME1: u32 = 5; // MEC1 jump table
pub const FW_TYPE_CP_MEC_ME2: u32 = 6;
pub const FW_TYPE_RLC_V: u32 = 7;
pub const FW_TYPE_RLC_G: u32 = 8;
pub const FW_TYPE_SDMA0: u32 = 9;
pub const FW_TYPE_SDMA1: u32 = 10;
pub const FW_TYPE_DMCU_ERAM: u32 = 11;
pub const FW_TYPE_DMCU_ISR: u32 = 12;
pub const FW_TYPE_VCN: u32 = 13;
pub const FW_TYPE_UVD: u32 = 14;
pub const FW_TYPE_VCE: u32 = 15;
pub const FW_TYPE_ISP: u32 = 16;
pub const FW_TYPE_ACP: u32 = 17;
pub const FW_TYPE_SMU: u32 = 18;
pub const FW_TYPE_MMSCH: u32 = 19;
pub const FW_TYPE_RLC_RESTORE_LIST_GPM_MEM: u32 = 20;
pub const FW_TYPE_RLC_RESTORE_LIST_SRM_MEM: u32 = 21;
pub const FW_TYPE_RLC_RESTORE_LIST_SRM_CNTL: u32 = 22;
pub const FW_TYPE_RLC_IRAM: u32 = 26;
pub const FW_TYPE_RLC_DRAM_BOOT: u32 = 48;
pub const FW_TYPE_DMCUB: u32 = 51;
pub const FW_TYPE_MES: u32 = 33;

pub const PspError = enum {
    ok,
    timeout,
    mailbox_error,
    firmware_not_found,
    firmware_parse_error,
    dma_alloc_failed,
    no_psp_block,
};

pub const PspState = struct {
    mmio_base: u64, // virtual address of MMIO BAR
    psp_base: u64, // PSP IP register base (byte offset from MMIO)
    psp_major: u8,
    psp_minor: u8,
    psp_revision: u8,
    sos_loaded: bool,
    // PSP ring buffer state (initialized after SOS/TOC loads)
    ring_buf: ?memory.DmaBuffer, // ring of psp_gfx_rb_frame entries
    cmd_buf: ?memory.DmaBuffer, // 4KB command buffer (psp_gfx_cmd_resp)
    fence_buf: ?memory.DmaBuffer, // fence DMA: PSP writes u32 here
    ring_wptr: u32, // write pointer (entry index, wraps at NUM_ENTRIES)
    fence_value: u32, // monotonically increasing fence sequence
    ring_initialized: bool,

    pub fn init(mmio_base: u64, psp_entry: *const discovery.IpEntry) PspState {
        return .{
            .mmio_base = mmio_base,
            .psp_base = psp_entry.base_address[0],
            .psp_major = psp_entry.major,
            .psp_minor = psp_entry.minor,
            .psp_revision = psp_entry.revision,
            .sos_loaded = false,
            .ring_buf = null,
            .cmd_buf = null,
            .fence_buf = null,
            .ring_wptr = 0,
            .fence_value = 0,
            .ring_initialized = false,
        };
    }

    /// Bootstrap PSP firmware. Detects whether to use unified (TOC) or
    /// legacy (SOS) loading based on PSP version.
    pub fn bootstrap(self: *PspState) PspError {
        const main = @import("main.zig");
        out.puts("psp: bootstrapping v");
        main.fmtDecPrint(@as(u64, self.psp_major));
        out.puts(".");
        main.fmtDecPrint(@as(u64, self.psp_minor));
        out.puts(".");
        main.fmtDecPrint(@as(u64, self.psp_revision));
        out.puts("\n");

        const base = self.mmio_base + self.psp_base;

        // Probe MMIO BAR to check which offsets respond
        out.puts("psp: MMIO probe:\n");
        const probes = [_]struct { off: u64, name: []const u8 }{
            .{ .off = 0x0, .name = "NBIO[0]" },
            .{ .off = 0xD04, .name = "disc_scratch" },
            .{ .off = self.psp_base, .name = "PSP_base" },
            .{ .off = self.psp_base + C2PMSG_35, .name = "C2PMSG_35" },
            .{ .off = self.psp_base + C2PMSG_36, .name = "C2PMSG_36" },
            .{ .off = self.psp_base + C2PMSG_101, .name = "C2PMSG_101" },
            .{ .off = self.psp_base + C2PMSG_81, .name = "C2PMSG_81(SOL)" },
        };
        for (probes) |p| {
            const val = readReg(self.mmio_base + p.off);
            out.puts("  mmio+");
            main.fmtHexPrint(p.off);
            out.puts(" (");
            out.puts(p.name);
            out.puts(") = ");
            main.fmtHexPrint(val);
            out.puts("\n");
        }

        // Check if SOS is already running (e.g. after VFIO passthrough
        // where the host amdgpu driver already loaded SOS/TOC).
        // Reference: psp_v13_0_is_sos_alive() — C2PMSG_81 (SOL) != 0.
        const sol = readReg(base + C2PMSG_81);
        if (sol != 0) {
            out.puts("psp: SOS already alive (SOL=");
            main.fmtHexPrint(sol);
            out.puts("), skipping bootloader\n");
            self.sos_loaded = true;
            return .ok;
        }

        // Check for all-ones on C2PMSG_35 (dead BAR or post-bootloader state)
        const c2p35 = readReg(base + C2PMSG_35);
        if (c2p35 == 0xFFFFFFFF) {
            writeReg(base + C2PMSG_35, 0);
            const verify = readReg(base + C2PMSG_35);
            if (verify == 0xFFFFFFFF) {
                out.puts("psp: C2PMSG_35 not writable and SOL=0 — MMIO BAR may be dead\n");
                return .mailbox_error;
            }
        }

        // SOL=0 and bootloader not signaling ready.
        // After VFIO passthrough (host amdgpu unbind → psp_hw_fini), the PSP
        // bootloader is halted but the PSP hardware is still powered. Try
        // creating a ring directly — PSP may respond to ring commands even
        // when the bootloader mailbox (C2PMSG_35) is inactive.
        out.puts("psp: SOL=0, trying direct ring creation...\n");
        const ring_err = self.ringInitQuick();
        if (ring_err == .ok) {
            out.puts("psp: ring created without bootloader — PSP alive\n");
            self.sos_loaded = true;
            return .ok;
        }
        out.puts("psp: direct ring failed, trying bootloader (short wait)...\n");

        // Short bootloader wait — if PSP were alive, it would respond quickly
        const result = self.waitBootloaderShort();
        if (result != .ok) {
            out.puts("psp: PSP offline (post-VFIO unbind, no FLR available)\n");
            return result;
        }
        out.puts("psp: bootloader ready (C2PMSG_35=");
        main.fmtHexPrint(readReg(base + C2PMSG_35));
        out.puts(")\n");

        // PSP 13.0.1/3/4/5/8 use unified firmware (TOC) — SOS is in ROM.
        // Older variants (13.0.0) load SOS separately.
        if (self.useUnifiedFirmware()) {
            return self.bootstrapUnified();
        } else {
            return self.bootstrapLegacy();
        }
    }

    /// Load GFX/SDMA/SMU firmware via PSP ring buffer (post-SOS/TOC).
    ///
    /// After the PSP bootloader loads SOS (or TOC for unified), further
    /// firmware loading goes through a shared-memory ring buffer protocol.
    /// The ring contains psp_gfx_rb_frame entries (24 bytes) that point
    /// to a separate command buffer. The driver fills a command buffer,
    /// writes a ring frame pointing to it, advances the write pointer
    /// via C2PMSG_67, and polls a fence DMA location for completion.
    ///
    /// Reference: psp_cmd_submit_buf() in amdgpu_psp.c
    pub fn loadIpFirmware(self: *PspState, fw_type: u32, fw_data: []const u8) PspError {
        const main = @import("main.zig");

        if (!self.sos_loaded) return .no_psp_block;

        // Initialize ring on first use
        if (!self.ring_initialized) {
            const ring_err = self.ringInit();
            if (ring_err != .ok) return ring_err;
        }

        // Copy firmware to a DMA buffer the PSP can read
        var fw_dma = memory.dmaAlloc(@intCast(fw_data.len)) orelse return .dma_alloc_failed;
        defer memory.dmaFree(&fw_dma);
        @memcpy(fw_dma.virt[0..fw_data.len], fw_data);

        out.puts("psp: ring submit LOAD_IP_FW type=");
        main.fmtDecPrint(fw_type);
        out.puts(" size=");
        main.fmtDecPrint(fw_data.len);
        out.puts("\n");

        return self.ringSubmitLoadIpFw(fw_type, memory.physAddr(&fw_dma), @intCast(fw_data.len));
    }

    // --- PSP ring buffer protocol ---
    //
    // The PSP ring is an indirect ring: each entry is a psp_gfx_rb_frame
    // (64 bytes = 16 dwords) that points to a separate command buffer.
    //
    // Ring frame layout (psp_gfx_rb_frame, 64 bytes):
    //   +0x00: u32  cmd_buf_addr_lo    (phys addr of command buffer)
    //   +0x04: u32  cmd_buf_addr_hi
    //   +0x08: u32  cmd_buf_size       (4096 = PSP_CMD_BUF_SIZE)
    //   +0x0C: u32  fence_addr_lo      (phys addr of fence DMA)
    //   +0x10: u32  fence_addr_hi
    //   +0x14: u32  fence_value        (expected value after completion)
    //   +0x18: u32  sid_lo             (RBI only, 0 for GPCOM)
    //   +0x1C: u32  sid_hi
    //   +0x20: u8   vmid, u8 frame_type, u16 reserved
    //   +0x24: u32[7] reserved (must be 0)
    //
    // Command buffer layout (psp_gfx_cmd_resp):
    //   +0x00: u32  buf_size           (0)
    //   +0x04: u32  buf_version        (0)
    //   +0x08: u32  cmd_id             (GFX_CMD_ID_LOAD_IP_FW = 6)
    //   +0x0C: u32  resp_buf_addr_lo   (0)
    //   +0x10: u32  resp_buf_addr_hi   (0)
    //   +0x14: u32  resp_offset        (0)
    //   +0x18: u32  resp_buf_size      (0)
    //   +0x1C: u32  fw_phy_addr_lo     (cmd union: LOAD_IP_FW)
    //   +0x20: u32  fw_phy_addr_hi
    //   +0x24: u32  fw_size
    //   +0x28: u32  fw_type            (GFX_FW_TYPE_*)

    /// Allocate DMA buffers, destroy any stale ring, and create a new one.
    fn ringInit(self: *PspState) PspError {
        const main = @import("main.zig");
        const base = self.mmio_base + self.psp_base;

        // Allocate ring DMA buffer (4KB, holds 64 rb_frame entries)
        self.ring_buf = memory.dmaAlloc(PSP_RING_SIZE) orelse return .dma_alloc_failed;

        // Allocate command DMA buffer (4KB, reused for each command)
        self.cmd_buf = memory.dmaAlloc(PSP_CMD_BUF_SIZE) orelse {
            memory.dmaFree(&self.ring_buf.?);
            self.ring_buf = null;
            return .dma_alloc_failed;
        };

        // Allocate fence DMA buffer (4KB page, first u32 is fence value)
        self.fence_buf = memory.dmaAlloc(4096) orelse {
            memory.dmaFree(&self.ring_buf.?);
            memory.dmaFree(&self.cmd_buf.?);
            self.ring_buf = null;
            self.cmd_buf = null;
            return .dma_alloc_failed;
        };

        // Zero fence
        const fence_ptr: *volatile u32 = @ptrCast(@alignCast(self.fence_buf.?.virt));
        fence_ptr.* = 0;
        self.fence_value = 0;

        const ring_phys = memory.physAddr(&self.ring_buf.?);

        out.puts("psp: ring init phys=");
        main.fmtHexPrint(ring_phys);
        out.puts(" cmd=");
        main.fmtHexPrint(memory.physAddr(&self.cmd_buf.?));
        out.puts(" fence=");
        main.fmtHexPrint(memory.physAddr(&self.fence_buf.?));
        out.puts("\n");

        // Destroy any existing ring (left over from host driver / previous boot).
        // PSP v13.0 uses C2PMSG_101 for ring control (not C2PMSG_64).
        // Reference: psp_v13_0_ring_stop — GFX_CTRL_CMD_ID_DESTROY_RINGS, mdelay(20).
        out.puts("psp: ring destroy (C2PMSG_101=");
        main.fmtHexPrint(readReg(base + C2PMSG_101));
        out.puts(")\n");
        writeReg(base + C2PMSG_101, PSP_RING_DESTROY);
        busyDelay();
        // Wait for PSP to acknowledge (bit 31 = GFX_FLAG_RESPONSE)
        var d: u32 = 0;
        while (d < PSP_RING_POLL_ITERS) : (d += 1) {
            if (readReg(base + C2PMSG_101) & 0x80000000 != 0) break;
        }
        out.puts("psp: after destroy C2PMSG_101=");
        main.fmtHexPrint(readReg(base + C2PMSG_101));
        out.puts("\n");

        // Write ring base address (raw physical, split into lo/hi u32).
        // PSP v13.0 uses C2PMSG_102/103/104 for ring params.
        // Reference: psp_v13_0_ring_create — lower/upper_32_bits(ring_mem_mc_addr).
        writeReg(base + C2PMSG_102, @truncate(ring_phys));
        writeReg(base + C2PMSG_103, @truncate(ring_phys >> 32));
        writeReg(base + C2PMSG_104, PSP_RING_SIZE);
        // Create GPCOM ring (PSP_RING_TYPE__KM = 2)
        writeReg(base + C2PMSG_101, PSP_RING_CREATE_KM);

        // Delay ~20ms then wait for bit 31 (GFX_FLAG_RESPONSE).
        busyDelay();
        var i: u32 = 0;
        while (i < PSP_RING_POLL_ITERS) : (i += 1) {
            if (readReg(base + C2PMSG_101) & 0x80000000 != 0) break;
        }
        if (i == PSP_RING_POLL_ITERS) {
            out.puts("psp: ring create timeout (C2PMSG_101=");
            main.fmtHexPrint(readReg(base + C2PMSG_101));
            out.puts(")\n");
            self.ringCleanup();
            return .timeout;
        }
        out.puts("psp: ring create ack C2PMSG_101=");
        main.fmtHexPrint(readReg(base + C2PMSG_101));
        out.puts("\n");

        // Read initial write pointer from PSP
        self.ring_wptr = 0;
        self.ring_initialized = true;
        out.puts("psp: ring created\n");
        return .ok;
    }

    /// Submit a LOAD_IP_FW command through the PSP ring.
    fn ringSubmitLoadIpFw(self: *PspState, fw_type: u32, fw_phys: u64, fw_size: u32) PspError {
        const ring_dma = self.ring_buf orelse return .no_psp_block;
        const cmd_dma = self.cmd_buf orelse return .no_psp_block;
        const fence_dma = self.fence_buf orelse return .no_psp_block;

        const cmd_phys = memory.physAddr(&cmd_dma);
        const fence_phys = memory.physAddr(&fence_dma);

        // Fill command buffer (psp_gfx_cmd_resp) — zero first, then set fields
        @memset(cmd_dma.virt[0..PSP_CMD_BUF_SIZE], 0);
        const cmd: [*]u8 = cmd_dma.virt;
        writeU32(cmd + 0x08, GFX_CMD_ID_LOAD_IP_FW); // cmd_id
        writeU32(cmd + 0x1C, @truncate(fw_phys)); // fw_phy_addr_lo (cmd union offset)
        writeU32(cmd + 0x20, @truncate(fw_phys >> 32)); // fw_phy_addr_hi
        writeU32(cmd + 0x24, fw_size); // fw_size
        writeU32(cmd + 0x28, fw_type); // fw_type

        // Advance fence value
        self.fence_value += 1;

        // Fill ring frame at current write pointer
        const frame_offset = (self.ring_wptr % PSP_RING_NUM_ENTRIES) * PSP_RB_FRAME_SIZE;
        const frame: [*]u8 = ring_dma.virt + frame_offset;
        writeU32(frame + 0x00, @truncate(cmd_phys)); // cmd_buf_addr_lo
        writeU32(frame + 0x04, @truncate(cmd_phys >> 32)); // cmd_buf_addr_hi
        writeU32(frame + 0x08, PSP_CMD_BUF_SIZE); // cmd_buf_size
        writeU32(frame + 0x0C, @truncate(fence_phys)); // fence_addr_lo
        writeU32(frame + 0x10, @truncate(fence_phys >> 32)); // fence_addr_hi
        writeU32(frame + 0x14, self.fence_value); // fence_value

        // Advance write pointer and notify PSP
        self.ring_wptr = (self.ring_wptr + 1) % PSP_RING_NUM_ENTRIES;
        const base = self.mmio_base + self.psp_base;
        // C2PMSG_67 = write pointer as dword offset into ring
        writeReg(base + C2PMSG_67, self.ring_wptr * PSP_RB_FRAME_DWORDS);

        // Poll fence DMA for completion
        const fence_ptr: *const volatile u32 = @ptrCast(@alignCast(fence_dma.virt));
        var i: u32 = 0;
        while (i < PSP_RING_POLL_ITERS) : (i += 1) {
            if (fence_ptr.* >= self.fence_value) break;
        }
        if (i == PSP_RING_POLL_ITERS) {
            const main = @import("main.zig");
            out.puts("psp: ring cmd timeout (fence=");
            main.fmtHexPrint(fence_ptr.*);
            out.puts(" expected=");
            main.fmtDecPrint(self.fence_value);
            out.puts(")\n");
            return .timeout;
        }

        // Check PSP response status (at offset 0x40 in cmd buffer)
        const resp_status = readU32Mem(cmd + 0x40);
        if (resp_status != 0) {
            const main = @import("main.zig");
            out.puts("psp: LOAD_IP_FW resp=");
            main.fmtHexPrint(resp_status);
            out.puts(" type=");
            main.fmtDecPrint(fw_type);
            out.puts("\n");
        }

        return .ok;
    }

    /// Trigger RLC autoload via PSP ring.
    /// RLC autoload initializes hardware blocks (GFXHUB, L2, aperture, etc.)
    /// using the firmware previously loaded via loadIpFirmware().
    /// Reference: psp_rlc_autoload() in amdgpu_psp.c
    pub fn rlcAutoload(self: *PspState) PspError {
        if (!self.sos_loaded) return .no_psp_block;

        if (!self.ring_initialized) {
            const ring_err = self.ringInit();
            if (ring_err != .ok) return ring_err;
        }

        out.puts("psp: ring submit AUTOLOAD_RLC\n");
        return self.ringSubmitSimple(GFX_CMD_ID_AUTOLOAD_RLC);
    }

    /// Submit a simple PSP ring command (no payload data).
    fn ringSubmitSimple(self: *PspState, cmd_id: u32) PspError {
        const ring_dma = self.ring_buf orelse return .no_psp_block;
        const cmd_dma = self.cmd_buf orelse return .no_psp_block;
        const fence_dma = self.fence_buf orelse return .no_psp_block;

        const cmd_phys = memory.physAddr(&cmd_dma);
        const fence_phys = memory.physAddr(&fence_dma);

        // Fill command buffer — just the command ID
        @memset(cmd_dma.virt[0..PSP_CMD_BUF_SIZE], 0);
        writeU32(cmd_dma.virt + 0x08, cmd_id);

        // Advance fence
        self.fence_value += 1;

        // Fill ring frame
        const frame_offset = (self.ring_wptr % PSP_RING_NUM_ENTRIES) * PSP_RB_FRAME_SIZE;
        const frame: [*]u8 = ring_dma.virt + frame_offset;
        writeU32(frame + 0x00, @truncate(cmd_phys));
        writeU32(frame + 0x04, @truncate(cmd_phys >> 32));
        writeU32(frame + 0x08, PSP_CMD_BUF_SIZE);
        writeU32(frame + 0x0C, @truncate(fence_phys));
        writeU32(frame + 0x10, @truncate(fence_phys >> 32));
        writeU32(frame + 0x14, self.fence_value);

        // Advance wptr and notify PSP
        self.ring_wptr = (self.ring_wptr + 1) % PSP_RING_NUM_ENTRIES;
        writeReg(self.mmio_base + self.psp_base + C2PMSG_67, self.ring_wptr * PSP_RB_FRAME_DWORDS);

        // Poll fence
        const fence_ptr: *const volatile u32 = @ptrCast(@alignCast(fence_dma.virt));
        var i: u32 = 0;
        while (i < PSP_RING_POLL_ITERS) : (i += 1) {
            if (fence_ptr.* >= self.fence_value) break;
        }
        if (i == PSP_RING_POLL_ITERS) {
            const main = @import("main.zig");
            out.puts("psp: AUTOLOAD_RLC timeout (fence=");
            main.fmtHexPrint(fence_ptr.*);
            out.puts(")\n");
            return .timeout;
        }

        // Check PSP response status (at offset 0x40 in cmd buffer)
        const resp_status = readU32Mem(cmd_dma.virt + 0x40);
        if (resp_status != 0) {
            const main = @import("main.zig");
            out.puts("psp: cmd resp=");
            main.fmtHexPrint(resp_status);
            out.puts(" cmd_id=");
            main.fmtDecPrint(cmd_id);
            out.puts("\n");
        }

        return .ok;
    }

    /// Quick ring init with short timeouts (for probing PSP liveness).
    fn ringInitQuick(self: *PspState) PspError {
        const main = @import("main.zig");
        const base = self.mmio_base + self.psp_base;
        const quick_iters: u32 = 500_000; // ~0.5s instead of ~5s

        self.ring_buf = memory.dmaAlloc(PSP_RING_SIZE) orelse return .dma_alloc_failed;
        self.cmd_buf = memory.dmaAlloc(PSP_CMD_BUF_SIZE) orelse {
            memory.dmaFree(&self.ring_buf.?);
            self.ring_buf = null;
            return .dma_alloc_failed;
        };
        self.fence_buf = memory.dmaAlloc(4096) orelse {
            memory.dmaFree(&self.ring_buf.?);
            memory.dmaFree(&self.cmd_buf.?);
            self.ring_buf = null;
            self.cmd_buf = null;
            return .dma_alloc_failed;
        };

        const fence_ptr: *volatile u32 = @ptrCast(@alignCast(self.fence_buf.?.virt));
        fence_ptr.* = 0;
        self.fence_value = 0;

        const ring_phys = memory.physAddr(&self.ring_buf.?);

        // Quick destroy (short timeout)
        writeReg(base + C2PMSG_101, PSP_RING_DESTROY);
        busyDelay();
        var d: u32 = 0;
        while (d < quick_iters) : (d += 1) {
            if (readReg(base + C2PMSG_101) & 0x80000000 != 0) break;
        }
        out.puts("psp: quick destroy C2PMSG_101=");
        main.fmtHexPrint(readReg(base + C2PMSG_101));
        out.puts("\n");

        // Quick create
        writeReg(base + C2PMSG_102, @truncate(ring_phys));
        writeReg(base + C2PMSG_103, @truncate(ring_phys >> 32));
        writeReg(base + C2PMSG_104, PSP_RING_SIZE);
        writeReg(base + C2PMSG_101, PSP_RING_CREATE_KM);
        busyDelay();

        var i: u32 = 0;
        while (i < quick_iters) : (i += 1) {
            if (readReg(base + C2PMSG_101) & 0x80000000 != 0) break;
        }
        if (i == quick_iters) {
            out.puts("psp: quick ring create timeout\n");
            self.ringCleanup();
            return .timeout;
        }

        self.ring_wptr = 0;
        self.ring_initialized = true;
        return .ok;
    }

    /// Short bootloader wait (~1s instead of ~100s).
    fn waitBootloaderShort(self: *PspState) PspError {
        const addr = self.mmio_base + self.psp_base + C2PMSG_35;
        var i: u32 = 0;
        while (i < 1_000_000) : (i += 1) {
            if (readReg(addr) & PSP_BL_READY != 0) return .ok;
        }
        return .timeout;
    }

    fn ringCleanup(self: *PspState) void {
        if (self.ring_buf) |*buf| memory.dmaFree(buf);
        if (self.cmd_buf) |*buf| memory.dmaFree(buf);
        if (self.fence_buf) |*buf| memory.dmaFree(buf);
        self.ring_buf = null;
        self.cmd_buf = null;
        self.fence_buf = null;
        self.ring_initialized = false;
    }

    // --- Unified firmware (TOC) path ---

    fn useUnifiedFirmware(self: *PspState) bool {
        // Match Linux: PSP 13.0.{1,3,4,5,8} set bootloader_uni_fu_supported
        if (self.psp_major == 13 and self.psp_minor == 0) {
            return switch (self.psp_revision) {
                1, 3, 4, 5, 8 => true,
                else => false,
            };
        }
        // PSP 14+ likely also unified, but not yet tested
        return false;
    }

    fn bootstrapUnified(self: *PspState) PspError {
        // Read TOC firmware
        const chip = chipPrefix(self.psp_major, self.psp_minor, self.psp_revision);
        const n = readFirmware(chip.tocName(), &fw_buf);
        if (n == 0) {
            out.puts("psp: TOC firmware not found\n");
            return .firmware_not_found;
        }

        // Parse common header to find the payload
        const payload = parseFirmwarePayload(fw_buf[0..n]) orelse {
            out.puts("psp: failed to parse TOC header\n");
            return .firmware_parse_error;
        };

        const main = @import("main.zig");
        out.puts("psp: loading TOC (");
        main.fmtDecPrint(payload.size);
        out.puts(" bytes)\n");

        // Load via bootloader mailbox
        const result = self.loadBlob(PSP_BL_LOAD_TOC, fw_buf[payload.offset..][0..payload.size]);
        if (result != .ok) {
            out.puts("psp: TOC load failed: ");
            printError(result);
            return result;
        }

        self.sos_loaded = true;
        out.puts("psp: TOC loaded, PSP ready\n");
        return .ok;
    }

    // --- Legacy SOS path (PSP 13.0.0 etc.) ---

    fn bootstrapLegacy(self: *PspState) PspError {
        const chip = chipPrefix(self.psp_major, self.psp_minor, self.psp_revision);
        const n = readFirmware(chip.sosName(), &fw_buf);
        if (n == 0) return .firmware_not_found;

        const fw = parseSosFirmware(fw_buf[0..n]) orelse {
            out.puts("psp: failed to parse SOS firmware header\n");
            return .firmware_parse_error;
        };

        const main = @import("main.zig");
        out.puts("psp: SOS firmware: sos=");
        main.fmtHexPrint(fw.sos_size);
        if (fw.sys_drv_size > 0) {
            out.puts(" sysdrv=");
            main.fmtHexPrint(fw.sys_drv_size);
        }
        out.puts("\n");

        // Load KDB if present
        if (fw.kdb_size > 0) {
            const r = self.loadBlob(PSP_BL_LOAD_KEY_DB, fw_buf[fw.kdb_offset..][0..fw.kdb_size]);
            if (r != .ok) out.puts("psp: KDB load failed (non-fatal)\n");
        }

        // Load SysDrv if present
        if (fw.sys_drv_size > 0) {
            const r = self.loadBlob(PSP_BL_LOAD_SYSDRV, fw_buf[fw.sys_drv_offset..][0..fw.sys_drv_size]);
            if (r != .ok) {
                out.puts("psp: SysDrv load failed\n");
                return r;
            }
        }

        // Load SOS
        const result = self.loadBlob(PSP_BL_LOAD_SOSDRV, fw_buf[fw.sos_offset..][0..fw.sos_size]);
        if (result != .ok) {
            out.puts("psp: SOS load failed\n");
            return result;
        }

        self.sos_loaded = true;
        out.puts("psp: SOS loaded\n");
        return .ok;
    }

    // --- Common bootloader mailbox ---

    fn loadBlob(self: *PspState, cmd: u32, data: []const u8) PspError {
        const ready = self.waitBootloaderReady();
        if (ready != .ok) return ready;

        var dma_buf = memory.dmaAlloc(@intCast(data.len)) orelse return .dma_alloc_failed;
        defer memory.dmaFree(&dma_buf);

        @memcpy(dma_buf.virt[0..data.len], data);

        const phys = memory.physAddr(&dma_buf);
        if (phys & (DMA_ALIGNMENT - 1) != 0) {
            out.puts("psp: WARNING: DMA buffer not 1MB-aligned\n");
        }

        const base = self.mmio_base + self.psp_base;

        // Write firmware physical address (>> 20) to C2PMSG_36
        writeReg(base + C2PMSG_36, @truncate(phys >> 20));

        // Clear C2PMSG_35 then write command — PSP detects the new
        // command when it sees a value without bit 31 set.
        writeReg(base + C2PMSG_35, 0);

        // Write command to C2PMSG_35
        writeReg(base + C2PMSG_35, cmd);

        // Wait for PSP to set bit 31 (completion)
        return self.waitBootloaderReady();
    }

    fn waitBootloaderReady(self: *PspState) PspError {
        const addr = self.mmio_base + self.psp_base + C2PMSG_35;
        // Linux psp_v13_0_wait_for_bootloader: only checks bit 31 (ready).
        // Lower bits contain command/status, not error codes.
        var retry: u32 = 0;
        while (retry < 10) : (retry += 1) {
            var i: u32 = 0;
            while (i < PSP_TIMEOUT_ITERS) : (i += 1) {
                const val = readReg(addr);
                if (val & PSP_BL_READY != 0) {
                    return .ok;
                }
            }
        }
        return .timeout;
    }

    // Shared firmware read buffer (BSS, not stack — firmware can be >256KB)
    var fw_buf: [524288]u8 linksection(".bss") = undefined;
};

// --- Firmware chip name mapping ---

const ChipPrefix = struct {
    buf: [32]u8,
    len: u8,

    fn tocName(self: *const ChipPrefix) []const u8 {
        const base = self.buf[0..self.len];
        // "psp_13_0_4_toc.bin"
        var name_buf: [48]u8 = undefined;
        @memcpy(name_buf[0..base.len], base);
        const suffix = "_toc.bin";
        @memcpy(name_buf[base.len..][0..suffix.len], suffix);
        // Return from persistent static
        return persistName(name_buf[0 .. base.len + suffix.len]);
    }

    fn sosName(self: *const ChipPrefix) []const u8 {
        const base = self.buf[0..self.len];
        var name_buf: [48]u8 = undefined;
        @memcpy(name_buf[0..base.len], base);
        const suffix = "_sos.bin";
        @memcpy(name_buf[base.len..][0..suffix.len], suffix);
        return persistName(name_buf[0 .. base.len + suffix.len]);
    }

    // Static buffer to hold the name across the function return
    var persist: [48]u8 = undefined;
    fn persistName(src: []const u8) []const u8 {
        @memcpy(persist[0..src.len], src);
        return persist[0..src.len];
    }
};

fn chipPrefix(major: u8, minor: u8, revision: u8) ChipPrefix {
    // Build "psp_MM_mm_rr" string
    var p = ChipPrefix{ .buf = undefined, .len = 0 };
    const prefix = "psp_";
    @memcpy(p.buf[0..prefix.len], prefix);
    p.len = prefix.len;
    p.len += fmtDec(p.buf[p.len..], major);
    p.buf[p.len] = '_';
    p.len += 1;
    p.len += fmtDec(p.buf[p.len..], minor);
    p.buf[p.len] = '_';
    p.len += 1;
    p.len += fmtDec(p.buf[p.len..], revision);
    return p;
}

fn fmtDec(buf: []u8, val: u8) u8 {
    if (val == 0) {
        buf[0] = '0';
        return 1;
    }
    var tmp: [3]u8 = undefined;
    var n: u8 = 0;
    var v = val;
    while (v != 0) : (n += 1) {
        tmp[n] = '0' + @as(u8, @truncate(v % 10));
        v /= 10;
    }
    for (0..n) |i| buf[i] = tmp[n - 1 - @as(u8, @truncate(i))];
    return n;
}

// --- Firmware header parsing ---

pub const FirmwarePayload = struct {
    offset: u32, // byte offset from start of file
    size: u32,
};

/// Parse a common firmware header to extract the payload location.
pub fn parseFirmwarePayload(data: []const u8) ?FirmwarePayload {
    if (data.len < 32) return null;
    const ucode_size = readU32(data[0x14..0x18]);
    const ucode_offset = readU32(data[0x18..0x1C]);
    if (ucode_offset == 0 or ucode_size == 0) return null;
    if (ucode_offset + ucode_size > data.len) return null;
    return .{ .offset = ucode_offset, .size = ucode_size };
}

const SosFirmware = struct {
    sos_offset: u32,
    sos_size: u32,
    sys_drv_offset: u32,
    sys_drv_size: u32,
    kdb_offset: u32,
    kdb_size: u32,
};

fn parseSosFirmware(data: []const u8) ?SosFirmware {
    if (data.len < 32) return null;

    const header_size = readU32(data[4..8]);
    const header_major = readU16(data[8..10]);
    const ucode_array_offset = readU32(data[0x18..0x1C]);
    if (ucode_array_offset == 0 or ucode_array_offset >= data.len) return null;

    var fw = SosFirmware{
        .sos_offset = 0, .sos_size = 0,
        .sys_drv_offset = 0, .sys_drv_size = 0,
        .kdb_offset = 0, .kdb_size = 0,
    };

    if (header_major >= 2) {
        if (header_size < 36 or data.len < 36) return null;
        const bin_count = readU32(data[0x20..0x24]);
        if (bin_count > 16) return null;

        var desc_off: usize = 0x24;
        var i: u32 = 0;
        while (i < bin_count) : (i += 1) {
            if (desc_off + 16 > data.len) break;
            const fw_type = readU32(data[desc_off..][0..4]);
            const comp_offset = readU32(data[desc_off + 8 ..][0..4]);
            const comp_size = readU32(data[desc_off + 12 ..][0..4]);
            const abs_offset = ucode_array_offset + comp_offset;
            if (abs_offset + comp_size > data.len) { desc_off += 16; continue; }

            switch (fw_type) {
                FW_TYPE_PSP_SOS => { fw.sos_offset = abs_offset; fw.sos_size = comp_size; },
                FW_TYPE_PSP_SYS_DRV => { fw.sys_drv_offset = abs_offset; fw.sys_drv_size = comp_size; },
                FW_TYPE_PSP_KDB => { fw.kdb_offset = abs_offset; fw.kdb_size = comp_size; },
                else => {},
            }
            desc_off += 16;
        }
    } else {
        if (data.len < 44) return null;
        fw.sos_offset = ucode_array_offset + readU32(data[0x24..0x28]);
        fw.sos_size = readU32(data[0x28..0x2C]);
    }

    if (fw.sos_size == 0) return null;
    return fw;
}

fn readU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn readU16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

// --- Firmware file loading ---

fn readFirmware(name: []const u8, buf: []u8) usize {
    var path_buf: [64]u8 = undefined;
    const prefix = "/lib/firmware/amdgpu/";
    if (prefix.len + name.len >= path_buf.len) return 0;
    @memcpy(path_buf[0..prefix.len], prefix);
    @memcpy(path_buf[prefix.len..][0..name.len], name);
    const path = path_buf[0 .. prefix.len + name.len];

    out.puts("psp: opening ");
    out.puts(path);
    out.puts("\n");
    const fd = fx.open(path);
    if (fd < 0) {
        out.puts("psp: open failed\n");
        return 0;
    }
    defer _ = fx.close(fd);

    var total: usize = 0;
    while (total < buf.len) {
        const n = fx.read(fd, buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return total;
}

fn printError(err: PspError) void {
    out.puts(switch (err) {
        .ok => "ok",
        .timeout => "timeout",
        .mailbox_error => "mailbox_error",
        .firmware_not_found => "firmware_not_found",
        .firmware_parse_error => "firmware_parse_error",
        .dma_alloc_failed => "dma_alloc_failed",
        .no_psp_block => "no_psp_block",
    });
    out.puts("\n");
}

// --- Memory helpers (for command buffer writes) ---

fn writeU32(ptr: [*]u8, val: u32) void {
    ptr[0] = @truncate(val);
    ptr[1] = @truncate(val >> 8);
    ptr[2] = @truncate(val >> 16);
    ptr[3] = @truncate(val >> 24);
}

fn readU32Mem(ptr: [*]const u8) u32 {
    return @as(u32, ptr[0]) |
        (@as(u32, ptr[1]) << 8) |
        (@as(u32, ptr[2]) << 16) |
        (@as(u32, ptr[3]) << 24);
}

// --- MMIO helpers (with indirect access for registers beyond BAR) ---

const mmio = @import("mmio.zig");

fn writeReg(addr: u64, val: u32) void {
    mmio.write(addr, val);
}

fn readReg(addr: u64) u32 {
    return mmio.read(addr);
}

/// Busy-wait ~20ms (matches Linux mdelay(20) in PSP ring protocol).
fn busyDelay() void {
    var n: u32 = 0;
    while (n < 2_000_000) : (n += 1) {
        asm volatile ("pause");
    }
}
