/// RDNA 2 (GFX 10.3) backend — legacy Command Processor.
///
/// Initializes GFX and SDMA engines via PSP firmware loading,
/// sets up the legacy CP ring buffer, and provides command submission.
///
/// Reference: drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c
const fx = @import("fornax");
const discovery = @import("../discovery.zig");
const memory = @import("../memory.zig");
const psp = @import("../psp.zig");
const ring = @import("../ring.zig");
const fence = @import("../fence.zig");

const out = fx.io.Writer.stdout;

// GFX 10.3 CP register byte offsets (relative to GC base).
// Source: gc_10_3_0_offset.h dword offsets × 4.
const CP_ME_CNTL: u64 = 0x0f56 * 4; // 0x3D58
const CP_RB_WPTR_DELAY: u64 = 0x0f61 * 4; // 0x3D84
const CP_RB0_BASE: u64 = 0x1de0 * 4; // 0x7780
const CP_RB0_CNTL: u64 = 0x1de1 * 4; // 0x7784
const CP_RB0_RPTR_ADDR: u64 = 0x1de3 * 4; // 0x778C
const CP_RB0_RPTR_ADDR_HI: u64 = 0x1de4 * 4; // 0x7790
const CP_DEVICE_ID: u64 = 0x1deb * 4; // 0x77AC
const CP_RB_VMID: u64 = 0x1df1 * 4; // 0x77C4
const CP_RB0_WPTR: u64 = 0x1df4 * 4; // 0x77D0
const CP_RB0_WPTR_HI: u64 = 0x1df5 * 4; // 0x77D4
const CP_RB_DOORBELL_RANGE_LOWER: u64 = 0x1dfa * 4; // 0x77E8
const CP_RB_DOORBELL_RANGE_UPPER: u64 = 0x1dfb * 4; // 0x77EC
const CP_MAX_CONTEXT: u64 = 0x1e4e * 4; // 0x7938
const CP_RB0_BASE_HI: u64 = 0x1e51 * 4; // 0x7944
const CP_RB0_RPTR: u64 = 0x1de2 * 4; // 0x7788
const CP_RB_DOORBELL_CONTROL: u64 = 0x1e8d * 4; // 0x7A34
const CP_RB_DOORBELL_CONTROL_EN: u32 = 1 << 28; // DOORBELL_EN bit
const CP_RB_ACTIVE: u64 = 0x1f40 * 4; // 0x7D00

// RLC (Run List Controller) registers (BASE_IDX=1)
const RLC_CNTL: u64 = 0x4c00 * 4; // 0x13000
const RLC_CNTL_RLC_ENABLE_F32: u32 = 1 << 0;
const RLC_GPM_GENERAL_3: u64 = 0x4c53 * 4; // autoload status (BASE_IDX=1)
const RLC_GPM_GENERAL_4: u64 = 0x4c54 * 4;
// RLCG indirect register access via SCRATCH registers (BASE_IDX=0!)
// Source: gc_10_3_0_offset.h regSCRATCH_REG0-3 (NOT GPM_SCRATCH_ADDR/DATA at 0x4c60!)
const SCRATCH_REG0: u64 = 0x2040 * 4; // 0x8100 — read-back value
const SCRATCH_REG2: u64 = 0x2042 * 4; // 0x8108 — write value
const SCRATCH_REG3: u64 = 0x2043 * 4; // 0x810C — offset | flags
const RLC_SPARE_INT: u64 = 0x4ca0 * 4; // trigger RLC interrupt
const RLCG_GC_WRITE: u32 = 0x80000000; // flag: GC register write
// Clock gating override (BASE_IDX=1) — setting bits forces clocks ON
const RLC_CGTT_MGCG_OVERRIDE: u64 = 0x4c48 * 4;
// NBIO: BIF Frame Buffer enable (BASE_IDX=2)
// Enables GPU read/write access to system memory (required for DMA).
const BIF_FB_EN: u64 = 0x0100 * 4; // dword 0x0100 relative to NBIO base[2]
const BIF_FB_EN_READ: u32 = 1 << 0;
const BIF_FB_EN_WRITE: u32 = 1 << 1;

// SMU (MP1) mailbox registers — dword offsets from MP1/SMU base[0]
// smu_v13_0_4 uses: msg=C2PMSG_66, param=C2PMSG_82, resp=C2PMSG_90
// Reference: smu_v13_0_4.c smu_v13_0_4_set_smu_mailbox_registers()
const MP1_C2PMSG_66: u64 = 0x0282 * 4; // message register
const MP1_C2PMSG_82: u64 = 0x0292 * 4; // parameter register
const MP1_C2PMSG_90: u64 = 0x029A * 4; // response register
const MP1_C2PMSG_93: u64 = 0x029D * 4; // firmware status

// PPSMC message IDs for smu_v13_0_4 (ppsmc_v13_0_4.h)
const PPSMC_MSG_TestMessage: u32 = 0x01;
const PPSMC_MSG_GetSmuVersion: u32 = 0x02;
const PPSMC_MSG_EnableGfxOff: u32 = 0x04;
const PPSMC_MSG_DisableGfxOff: u32 = 0x05;
const PPSMC_MSG_PowerUpGfx: u32 = 0x06;

// GFXHUB registers — GFX engine memory controller (CP, shaders).
// These are in the GC register space (BASE_IDX=0), unlike MMHUB which is separate.
// Source: gc_10_3_0_offset.h
const GCMC_VM_SYSTEM_APERTURE_LOW_ADDR: u64 = 0x157c * 4;
const GCMC_VM_SYSTEM_APERTURE_HIGH_ADDR: u64 = 0x157d * 4;
const GCMC_VM_FB_LOCATION_BASE: u64 = 0x1578 * 4;
const GCMC_VM_FB_LOCATION_TOP: u64 = 0x1579 * 4;
const GCMC_VM_AGP_BOT: u64 = 0x157a * 4;
const GCMC_VM_AGP_TOP: u64 = 0x157b * 4;
const GCVM_CONTEXT0_CNTL: u64 = 0x1580 * 4;
const GCVM_CONTEXT0_CNTL_ENABLE: u32 = 1 << 0;
const GCVM_CONTEXT1_CNTL: u64 = 0x1581 * 4;
const GCMC_VM_MX_L1_TLB_CNTL: u64 = 0x157e * 4;
const GCVM_L2_CNTL: u64 = 0x1590 * 4;
const GCVM_L2_CGTT_CLK_CTRL: u64 = 0x15b4 * 4; // L2 clock gating control
// VM TLB invalidation engine 17 (last engine, least likely to conflict)
const GCVM_INVALIDATE_ENG17_REQ: u64 = 0x15b8 * 4;
const GCVM_INVALIDATE_ENG17_ACK: u64 = 0x15b9 * 4;
const GCVM_L2_PROTECTION_FAULT_STATUS: u64 = 0x158d * 4;
const GCVM_L2_PROTECTION_FAULT_ADDR_LO32: u64 = 0x158e * 4;
const GCVM_L2_PROTECTION_FAULT_ADDR_HI32: u64 = 0x158f * 4;
const GCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_LO32: u64 = 0x15c4 * 4;
const GCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_HI32: u64 = 0x15c5 * 4;
const GCVM_CONTEXT0_PAGE_TABLE_START_ADDR_LO32: u64 = 0x15c6 * 4;
const GCVM_CONTEXT0_PAGE_TABLE_START_ADDR_HI32: u64 = 0x15c7 * 4;
const GCVM_CONTEXT0_PAGE_TABLE_END_ADDR_LO32: u64 = 0x15c8 * 4;
const GCVM_CONTEXT0_PAGE_TABLE_END_ADDR_HI32: u64 = 0x15c9 * 4;

// PTE flags (amdgpu_vm.h)
const PTE_VALID: u64 = 1 << 0;
const PTE_SYSTEM: u64 = 1 << 1;
const PTE_SNOOPED: u64 = 1 << 2;
const PTE_READABLE: u64 = 1 << 5;
const PTE_WRITEABLE: u64 = 1 << 6;
const PTE_FLAGS: u64 = PTE_VALID | PTE_SYSTEM | PTE_SNOOPED | PTE_READABLE | PTE_WRITEABLE;

// GRBM register for GFX status
const GRBM_STATUS: u64 = 0x0da4 * 4; // 0x3690
const GRBM_SOFT_RESET: u64 = 0x0da8 * 4; // 0x36A0
const GRBM_SOFT_RESET_CP: u32 = 1 << 0; // SOFT_RESET_CP bit
const GRBM_SOFT_RESET_GFX: u32 = 1 << 16; // SOFT_RESET_GFX bit (pipeline: TA/SX/SPI/PA/SC/DB/CB/VGT)
const GRBM_SOFT_RESET_CPF: u32 = 1 << 17; // SOFT_RESET_CPF (Command Processor Frontend = PFP)
const GRBM_SOFT_RESET_CPC: u32 = 1 << 18; // SOFT_RESET_CPC (Command Processor Compute)
const GRBM_SOFT_RESET_CPG: u32 = 1 << 19; // SOFT_RESET_CPG (Command Processor Graphics = ME)
const GRBM_SOFT_RESET_EA: u32 = 1 << 22; // SOFT_RESET_EA (Efficiency Arbiter — memory path)

// CP stall/busy status (BASE_IDX=0)
const CP_STALLED_STAT1: u64 = 0x1e01 * 4;
const CP_STALLED_STAT2: u64 = 0x1e02 * 4;
const CP_STALLED_STAT3: u64 = 0x1e03 * 4;
const CP_BUSY_STAT: u64 = 0x1e04 * 4;

// CP_ME_CNTL halt bits (gc_10_3_0_sh_mask.h)
const CP_ME_CNTL_CE_HALT: u32 = 1 << 24;
const CP_ME_CNTL_PFP_HALT: u32 = 1 << 26;
const CP_ME_CNTL_ME_HALT: u32 = 1 << 28;
const CP_ME_CNTL_ALL_HALT: u32 = CP_ME_CNTL_CE_HALT | CP_ME_CNTL_PFP_HALT | CP_ME_CNTL_ME_HALT;

pub const Gfx10State = struct {
    mmio_base: u64,
    gc_base: u64, // GC base_address[0] — CP registers (BASE_IDX=0)
    gc_base1: u64, // GC base_address[1] — RLC/SPI registers (BASE_IDX=1)
    gfxhub_base: u64, // GFXHUB register base — may differ from gc_base on APUs
    sdma_base: u64,
    nbio_base2: u64, // NBIO base_address[2] — BIF registers
    smu_base: u64, // SMU/MP1 base_address[0] — mailbox registers
    doorbell_base: u64,
    gfx_ring: ring.Ring,
    fence_pool: fence.FencePool,
    initialized: bool,
    // IP version info for firmware naming
    gc_major: u8,
    gc_minor: u8,
    gc_revision: u8,
    sdma_major: u8,
    sdma_minor: u8,
    sdma_revision: u8,

    pub fn init(mmio_base: u64, table: *const discovery.DiscoveryTable, doorbell_base: u64) ?Gfx10State {
        const gc_entry = table.find(.gc) orelse return null;
        const sdma_entry = table.find(.sdma);
        const nbio_entry = table.find(.nbio);
        const smu_entry = table.find(.smu);

        var gfx_ring = ring.Ring.init(.gfx) orelse return null;
        const fence_pool = fence.FencePool.init() orelse {
            gfx_ring.deinit();
            return null;
        };

        // GFXHUB registers (GCVM_L2, GCMC_VM) live at a different base than
        // CP registers on Raphael APUs. Use base_address[4] if present (stores
        // the GFXHUB byte offset), otherwise fall back to gc_base.
        const gfxhub = if (gc_entry.num_bases > 4 and gc_entry.base_address[4] != 0)
            gc_entry.base_address[4]
        else
            gc_entry.base_address[0];

        return Gfx10State{
            .mmio_base = mmio_base,
            .gc_base = gc_entry.base_address[0],
            .gc_base1 = if (gc_entry.num_bases > 1) gc_entry.base_address[1] else gc_entry.base_address[0],
            .gfxhub_base = gfxhub,
            .sdma_base = if (sdma_entry) |s| s.base_address[0] else 0,
            .nbio_base2 = if (nbio_entry) |n| (if (n.num_bases > 2) n.base_address[2] else 0) else 0,
            .smu_base = if (smu_entry) |s| s.base_address[0] else 0,
            .doorbell_base = doorbell_base,
            .gfx_ring = gfx_ring,
            .fence_pool = fence_pool,
            .initialized = false,
            .gc_major = gc_entry.major,
            .gc_minor = gc_entry.minor,
            .gc_revision = gc_entry.revision,
            .sdma_major = if (sdma_entry) |s| s.major else 0,
            .sdma_minor = if (sdma_entry) |s| s.minor else 0,
            .sdma_revision = if (sdma_entry) |s| s.revision else 0,
        };
    }

    pub fn deinit(self: *Gfx10State) void {
        self.gfx_ring.deinit();
        self.fence_pool.deinit();
        self.initialized = false;
    }

    /// Load GFX and SDMA firmware via PSP, then set up the CP ring.
    pub fn bringUp(self: *Gfx10State, psp_state: *psp.PspState) bool {
        const main = @import("../main.zig");
        const base1 = self.mmio_base + self.gc_base1;

        // Check if RLC autoload already completed (e.g. from UEFI/host boot).
        // GPM_GENERAL_3 bits indicate which blocks finished init.
        const g3 = readReg(base1 + RLC_GPM_GENERAL_3);
        const g4 = readReg(base1 + RLC_GPM_GENERAL_4);
        out.puts("gfx10: RLC_GPM_GEN3=");
        main.fmtHexPrint(g3);
        out.puts(" GEN4=");
        main.fmtHexPrint(g4);
        out.puts("\n");

        // Always do full firmware load — stale GPM_GENERAL values from
        // a previous boot don't mean the RLC firmware is functional.
        out.puts("gfx10: loading firmware...\n");

        // Stop RLC if running (clean state for reload)
        if (readReg(base1 + RLC_CNTL) & RLC_CNTL_RLC_ENABLE_F32 != 0) {
            writeReg(base1 + RLC_CNTL, 0);
            var d: u32 = 0;
            while (d < 100_000) : (d += 1) asm volatile ("pause");
        }

        // Clear autoload status so we can detect fresh completion
        writeReg(base1 + RLC_GPM_GENERAL_3, 0);
        writeReg(base1 + RLC_GPM_GENERAL_4, 0);

        if (!self.loadGfxFirmware(psp_state)) {
            out.puts("gfx10: GFX firmware load failed\n");
            return false;
        }
        out.puts("gfx10: GFX firmware loaded\n");

        if (self.sdma_base != 0) {
            if (!self.loadSdmaFirmware(psp_state)) {
                out.puts("gfx10: SDMA firmware load failed (non-fatal)\n");
            } else {
                out.puts("gfx10: SDMA firmware loaded\n");
            }
        }

        if (psp_state.rlcAutoload() != .ok) {
            out.puts("gfx10: RLC autoload failed (non-fatal)\n");
        } else {
            out.puts("gfx10: RLC autoload triggered\n");
        }

        self.waitForAutoload();

        // Ensure RLC is running (needed for RLCG indirect writes)
        const rlc_cntl = readReg(base1 + RLC_CNTL);
        if ((rlc_cntl & RLC_CNTL_RLC_ENABLE_F32) == 0) {
            writeReg(base1 + RLC_CNTL, RLC_CNTL_RLC_ENABLE_F32);
            out.puts("gfx10: RLC started\n");
            // Brief delay for RLC to become ready
            var delay: u32 = 0;
            while (delay < 100_000) : (delay += 1) {
                asm volatile ("pause");
            }
        }

        // Program GFXHUB aperture + L2 via RLCG
        self.setupSystemAperture();

        // Set up CP ring buffer
        if (!self.setupCpRing()) {
            out.puts("gfx10: CP ring setup failed\n");
            return false;
        }
        out.puts("gfx10: CP ring ready\n");

        // Test with NOP submission
        if (!self.testNop()) {
            out.puts("gfx10: NOP test failed\n");
            return false;
        }
        out.puts("gfx10: NOP test passed\n");

        self.initialized = true;
        return true;
    }

    /// Attempt GFX bring-up without PSP (VFIO APU without FLR).
    /// After host amdgpu unbind, firmware may already be loaded in GPU SRAM.
    /// Try: SMU power-up → check GFX alive → GFXHUB init → CP ring → NOP.
    pub fn bringUpWithoutPsp(self: *Gfx10State) bool {
        const main = @import("../main.zig");
        const base = self.mmio_base + self.gc_base;
        const base1 = self.mmio_base + self.gc_base1;
        // GFXHUB registers: use FLAT offsets (no base). The IP Discovery base
        // (0x58000) maps to a read-only alias on Raphael APU — writes are
        // silently dropped. Flat offsets (reg_dword * 4) are the writable path.
        const hub = self.mmio_base;

        // 1. Check current GFX state
        const grbm = readReg(base + GRBM_STATUS);
        const rlc = readReg(base1 + RLC_CNTL);
        out.puts("gfx10: no-PSP probe: GRBM=");
        main.fmtHexPrint(grbm);
        out.puts(" RLC_CNTL=");
        main.fmtHexPrint(rlc);
        out.puts("\n");
        out.puts("gfx10: gc_base=");
        main.fmtHexPrint(@as(u32, @truncate(self.gc_base)));
        out.puts(" gfxhub_base=");
        main.fmtHexPrint(@as(u32, @truncate(self.gfxhub_base)));
        // Check GFXHUB accessibility at the hub base
        out.puts(" hub_L2=");
        main.fmtHexPrint(readReg(hub + GCVM_L2_CNTL));
        out.puts("\n");

        // 2. Check autoload status (may have values from host init)
        const g3 = readReg(base1 + RLC_GPM_GENERAL_3);
        const g4 = readReg(base1 + RLC_GPM_GENERAL_4);
        out.puts("gfx10: GPM_GEN3=");
        main.fmtHexPrint(g3);
        out.puts(" GEN4=");
        main.fmtHexPrint(g4);
        out.puts("\n");

        if (grbm == 0 and rlc == 0 and g3 == 0) {
            out.puts("gfx10: GFX completely powered off — cannot init without PSP+SMU\n");
            return false;
        }

        out.puts("gfx10: GFX block responsive, attempting init with existing firmware\n");

        // 3. Skip SMU and BIF_FB_EN — these are SoC-wide shared resources.
        //    Writing to MP1 mailbox or NBIO BIF from a VFIO guest crashes the
        //    host dGPU through the shared SMN interconnect.
        //    DEPTH=1 page table mode works without SMU power-up or BIF_FB_EN.
        const smu_ok = false;
        out.puts("gfx10: skipping SMU/BIF (VFIO safe mode)\n");

        // 3a. Read page table base from host (still configured in GFXHUB)
        {
            const pt_base_lo = readReg(base + GCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_LO32);
            const pt_base_hi = readReg(base + GCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_HI32);
            const pt_start_lo = readReg(base + GCVM_CONTEXT0_PAGE_TABLE_START_ADDR_LO32);
            const pt_end_lo = readReg(base + GCVM_CONTEXT0_PAGE_TABLE_END_ADDR_LO32);
            out.puts("gfx10: PT_BASE=");
            main.fmtHexPrint(pt_base_hi);
            out.puts(":");
            main.fmtHexPrint(pt_base_lo);
            out.puts(" START=");
            main.fmtHexPrint(pt_start_lo);
            out.puts(" END=");
            main.fmtHexPrint(pt_end_lo);
            out.puts("\n");
        }

        // 4. Probe writable addresses for GFXHUB registers.
        //    On Raphael APU, BAR5 has multiple register windows:
        //    - flat (no base): writable for L1/L2 but not MC aperture
        //    - gc_base (0x4980): writable for CP/GRBM
        //    - gfxhub_base (0x58000): read-only alias
        //    Test SYS_HI and CTX0 at flat and gc_base to find writable path.
        {
            const mm = self.mmio_base;
            // Test SYS_HI write at flat vs gc_base
            out.puts("gfx10: SYS_HI probe: flat=");
            main.fmtHexPrint(readReg(mm + GCMC_VM_SYSTEM_APERTURE_HIGH_ADDR));
            out.puts(" gc=");
            main.fmtHexPrint(readReg(base + GCMC_VM_SYSTEM_APERTURE_HIGH_ADDR));
            out.puts("\n");

            writeReg(mm + GCMC_VM_SYSTEM_APERTURE_HIGH_ADDR, 0x2000);
            out.puts("gfx10: SYS_HI flat write 0x2000: flat=");
            main.fmtHexPrint(readReg(mm + GCMC_VM_SYSTEM_APERTURE_HIGH_ADDR));
            out.puts(" gc=");
            main.fmtHexPrint(readReg(base + GCMC_VM_SYSTEM_APERTURE_HIGH_ADDR));
            out.puts("\n");

            writeReg(base + GCMC_VM_SYSTEM_APERTURE_HIGH_ADDR, 0x2000);
            out.puts("gfx10: SYS_HI gc write 0x2000: flat=");
            main.fmtHexPrint(readReg(mm + GCMC_VM_SYSTEM_APERTURE_HIGH_ADDR));
            out.puts(" gc=");
            main.fmtHexPrint(readReg(base + GCMC_VM_SYSTEM_APERTURE_HIGH_ADDR));
            out.puts("\n");

            // Test CTX0 write at flat vs gc_base
            out.puts("gfx10: CTX0 probe: flat=");
            main.fmtHexPrint(readReg(mm + GCVM_CONTEXT0_CNTL));
            out.puts(" gc=");
            main.fmtHexPrint(readReg(base + GCVM_CONTEXT0_CNTL));
            out.puts("\n");

            writeReg(base + GCVM_CONTEXT0_CNTL, 1);
            out.puts("gfx10: CTX0 gc write 1: flat=");
            main.fmtHexPrint(readReg(mm + GCVM_CONTEXT0_CNTL));
            out.puts(" gc=");
            main.fmtHexPrint(readReg(base + GCVM_CONTEXT0_CNTL));
            out.puts("\n");

            // Test L1 at correct offset (0x157e) and L2
            out.puts("gfx10: L1(0x157e): flat=");
            main.fmtHexPrint(readReg(mm + GCMC_VM_MX_L1_TLB_CNTL));
            out.puts(" gc=");
            main.fmtHexPrint(readReg(base + GCMC_VM_MX_L1_TLB_CNTL));

            // Test L1 write at gc_base
            const l1_test: u32 = (1 << 0) | (3 << 3) | (1 << 6); // 0x59
            writeReg(base + GCMC_VM_MX_L1_TLB_CNTL, l1_test);
            out.puts(" gc_write=");
            main.fmtHexPrint(readReg(base + GCMC_VM_MX_L1_TLB_CNTL));

            out.puts(" L2: flat=");
            main.fmtHexPrint(readReg(mm + GCVM_L2_CNTL));
            out.puts("\n");
        }

        // 5. Try RLCG indirect writes (RLC must be running).
        //    After host amdgpu init, RLC firmware is still loaded (GPM_GEN3 != 0).
        //    RLCG can access power-gated GFXHUB registers that direct MMIO cannot.
        if (g3 != 0) {
            out.puts("gfx10: RLC firmware present, trying RLCG for GFXHUB...\n");

            // Ensure RLC is enabled
            if ((readReg(base1 + RLC_CNTL) & RLC_CNTL_RLC_ENABLE_F32) == 0) {
                writeReg(base1 + RLC_CNTL, RLC_CNTL_RLC_ENABLE_F32);
                busyWait(500_000); // give RLC time to start
                out.puts("gfx10: RLC enabled, CNTL=");
                main.fmtHexPrint(readReg(base1 + RLC_CNTL));
                out.puts("\n");
            }

            // Clear stale RLCG state (SCRATCH regs are BASE_IDX=0 → gc_base)
            const stale_s3 = readReg(base + SCRATCH_REG3);
            if (stale_s3 & RLCG_GC_WRITE != 0) {
                writeReg(base + SCRATCH_REG3, 0);
            }

            // DEPTH=1 page table mode: Host module set CTX0 with DEPTH=1.
            // SYS_HI, END, L2, L1 are PSP-write-protected (stuck at 0).
            // With DEPTH=1 and START=0, END=0, only GPU VA page 0 is valid.
            // We map the ring buffer physical page as PTE[0] so the CP can
            // DMA from GPU VA 0.
            const gc_base_dw: u32 = @truncate(self.gc_base >> 2);

            // Skip aperture/L2 writes — they're PSP-protected and silently dropped.
            // Host vfio-apu-reset module already configured CTX0=0x403 (ENABLE|DEPTH=1|RETRY).

            // 5.1 Set up single-PTE page table for DEPTH=1 mode.
            //     PTE[0] maps GPU VA page 0 → ring buffer physical page.
            {
                // Allocate 4KB page table (512 PTEs, only PTE[0] used)
                if (memory.dmaAlloc(4096)) |pt_buf| {
                    const pt_ptr: [*]volatile u64 = @ptrCast(@alignCast(pt_buf.virt));
                    // Clear all PTEs
                    for (0..512) |i| {
                        pt_ptr[i] = 0;
                    }
                    // PTE[0] = ring buffer physical page | flags
                    const ring_phys = self.gfx_ring.ringPhysAddr();
                    const ring_page = ring_phys & ~@as(u64, 0xFFF);
                    pt_ptr[0] = ring_page | PTE_FLAGS;

                    out.puts("gfx10: DEPTH=1 PT alloc phys=");
                    main.fmtHexPrint(@as(u32, @truncate(pt_buf.phys >> 32)));
                    out.puts(":");
                    main.fmtHexPrint(@as(u32, @truncate(pt_buf.phys)));
                    out.puts(" PTE[0]=ring@");
                    main.fmtHexPrint(@as(u32, @truncate(ring_page)));
                    out.puts("\n");

                    // Write PT_BASE via RLCG (confirmed writable)
                    const pt_base_val: u64 = pt_buf.phys >> 12;
                    const pt_base_lo: u32 = @truncate(pt_base_val);
                    const pt_base_hi: u32 = @truncate(pt_base_val >> 32);
                    var pt_rlcg: u32 = 0;
                    if (self.rlcgWrite(gc_base_dw + 0x15c4, pt_base_lo)) pt_rlcg += 1;
                    if (self.rlcgWrite(gc_base_dw + 0x15c5, pt_base_hi)) pt_rlcg += 1;
                    // START=0 (already 0, confirmed writable)
                    if (self.rlcgWrite(gc_base_dw + 0x15c6, 0)) pt_rlcg += 1;
                    if (self.rlcgWrite(gc_base_dw + 0x15c7, 0)) pt_rlcg += 1;
                    // END=0 is stuck (PSP-protected) — but that's fine:
                    // range [0,0] = page 0 = our ring buffer page

                    // Also write PT_BASE directly
                    writeReg(base + GCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_LO32, pt_base_lo);
                    writeReg(base + GCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_HI32, pt_base_hi);

                    // Readback
                    const rb_lo = readReg(base + GCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_LO32);
                    out.puts("gfx10: PT_BASE RLCG=");
                    main.fmtHexPrint(pt_rlcg);
                    out.puts("/4 readback=");
                    main.fmtHexPrint(rb_lo);
                    out.puts(if (rb_lo == pt_base_lo) " MATCH" else " MISMATCH");
                    out.puts("\n");

                    // Re-assert CTX0 with DEPTH=1 via RLCG
                    // (ENABLE=1, DEPTH=1 in bits 3:1, RETRY=1 in bit 10)
                    const ctx0_depth1: u32 = (1 << 0) | (1 << 1) | (1 << 10); // 0x403
                    _ = self.rlcgWrite(gc_base_dw + 0x1580, ctx0_depth1);
                    writeReg(base + GCVM_CONTEXT0_CNTL, ctx0_depth1);
                    const ctx0_rb = readReg(base + GCVM_CONTEXT0_CNTL);
                    out.puts("gfx10: CTX0=");
                    main.fmtHexPrint(ctx0_rb);
                    out.puts(if (ctx0_rb & 3 == 3) " DEPTH=1 OK\n" else " DEPTH check\n");

                    // VM TLB invalidation — flush stale entries
                    {
                        const inv_req: u32 = (1 << 0) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 21) | (1 << 22) | (1 << 23);
                        writeReg(hub + GCVM_INVALIDATE_ENG17_REQ, inv_req);
                        var inv_wait2: u32 = 0;
                        var inv_ok2 = false;
                        while (inv_wait2 < 500_000) : (inv_wait2 += 1) {
                            if (readReg(hub + GCVM_INVALIDATE_ENG17_ACK) & 1 != 0) {
                                inv_ok2 = true;
                                break;
                            }
                            asm volatile ("pause");
                        }
                        if (!inv_ok2) {
                            writeReg(base + GCVM_INVALIDATE_ENG17_REQ, inv_req);
                            inv_wait2 = 0;
                            while (inv_wait2 < 500_000) : (inv_wait2 += 1) {
                                if (readReg(base + GCVM_INVALIDATE_ENG17_ACK) & 1 != 0) {
                                    inv_ok2 = true;
                                    break;
                                }
                                asm volatile ("pause");
                            }
                        }
                        out.puts("gfx10: VM TLB inv: ");
                        out.puts(if (inv_ok2) "ACK\n" else "TIMEOUT\n");
                    }
                } else {
                    out.puts("gfx10: page table alloc failed\n");
                }
            }
        }

        // MC aperture writes (FB_LOC, SYS_HI, AGP, L2, L1) are PSP-protected
        // on Raphael and silently dropped. DEPTH=1 mode bypasses the need for
        // system aperture configuration entirely — the page table handles translation.

        // Re-assert CTX0 with DEPTH=1 (host module already set this, but confirm)
        const ctx0_depth1_val: u32 = (1 << 0) | (1 << 1) | (1 << 10); // 0x403
        writeReg(base + GCVM_CONTEXT0_CNTL, ctx0_depth1_val);

        // Diagnostic readback
        out.puts("gfx10: GFXHUB: CTX0=");
        main.fmtHexPrint(readReg(base + GCVM_CONTEXT0_CNTL));
        out.puts(" PT_BASE=");
        main.fmtHexPrint(readReg(base + GCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_LO32));
        out.puts(if (smu_ok) " SMU ok" else " SMU dead");
        out.puts("\n");

        // 11. Restart RLC (CP stays halted — setupCpRing will unhalt)
        out.puts("gfx10: restarting RLC...\n");
        writeReg(base1 + RLC_CNTL, RLC_CNTL_RLC_ENABLE_F32);
        busyWait(200_000);

        // 12. Set up CP ring (includes halt, soft reset, config, unhalt)
        if (!self.setupCpRing()) {
            out.puts("gfx10: CP ring setup failed\n");
            return false;
        }
        out.puts("gfx10: CP ring ready\n");

        // 14. Test with NOP
        if (!self.testNop()) {
            out.puts("gfx10: NOP test failed\n");
            return false;
        }
        out.puts("gfx10: NOP test passed!\n");

        self.initialized = true;
        return true;
    }

    /// Submit a NOP packet and verify ring advancement.
    pub fn testNop(self: *Gfx10State) bool {
        const main = @import("../main.zig");
        const base = self.mmio_base + self.gc_base;
        const hub = self.mmio_base; // flat offsets for GFXHUB

        // Clear stale L2 fault status before test
        writeReg(hub + GCVM_L2_PROTECTION_FAULT_STATUS, 0);

        // Diagnostic: dump CP state before submission
        out.puts("gfx10: CP_ME_CNTL=");
        main.fmtHexPrint(readReg(base + CP_ME_CNTL));
        out.puts(" GRBM_STATUS=");
        main.fmtHexPrint(readReg(base + GRBM_STATUS));
        out.puts("\n");
        out.puts("gfx10: ring_phys=");
        main.fmtHexPrint(self.gfx_ring.ringPhysAddr());
        out.puts(" rptr_phys=");
        main.fmtHexPrint(self.gfx_ring.rptrPhysAddr());
        out.puts("\n");
        out.puts("gfx10: CP_RB0_BASE=");
        main.fmtHexPrint(readReg(base + CP_RB0_BASE));
        out.puts(" CP_RB0_CNTL=");
        main.fmtHexPrint(readReg(base + CP_RB0_CNTL));
        out.puts(" CP_RB_ACTIVE=");
        main.fmtHexPrint(readReg(base + CP_RB_ACTIVE));
        out.puts("\n");
        out.puts("gfx10: CP_RB_DB_CTRL=");
        main.fmtHexPrint(readReg(base + CP_RB_DOORBELL_CONTROL));
        out.puts(" CP_RB0_RPTR(mmio)=");
        main.fmtHexPrint(readReg(base + CP_RB0_RPTR));
        out.puts("\n");
        // CP stall diagnostics
        out.puts("gfx10: STALL1=");
        main.fmtHexPrint(readReg(base + CP_STALLED_STAT1));
        out.puts(" STALL2=");
        main.fmtHexPrint(readReg(base + CP_STALLED_STAT2));
        out.puts(" STALL3=");
        main.fmtHexPrint(readReg(base + CP_STALLED_STAT3));
        out.puts(" BUSY=");
        main.fmtHexPrint(readReg(base + CP_BUSY_STAT));
        out.puts("\n");
        // GFXHUB state — confirm our config is in place
        // CTX0/L1 readable at gc_base, L2 at flat
        // Also read from gfxhub alias (0x58000) for actual HW values
        out.puts("gfx10: GFXHUB: CTX0=");
        main.fmtHexPrint(readReg(base + GCVM_CONTEXT0_CNTL));
        out.puts(" L1=");
        main.fmtHexPrint(readReg(base + GCMC_VM_MX_L1_TLB_CNTL));
        out.puts(" L2=");
        main.fmtHexPrint(readReg(hub + GCVM_L2_CNTL));
        out.puts("\n");
        // Note: gfxhub_base (0x58000) is actually PSP/MP0 register space,
        // NOT a GFXHUB alias. We cannot read actual GFXHUB SYS_HI/L1 values.
        // PT_BASE/START/END — verify GART config survived CP reset
        out.puts("gfx10: PT_BASE=");
        main.fmtHexPrint(readReg(base + GCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_LO32));
        out.puts(" START=");
        main.fmtHexPrint(readReg(base + GCVM_CONTEXT0_PAGE_TABLE_START_ADDR_LO32));
        out.puts(" END=");
        main.fmtHexPrint(readReg(base + GCVM_CONTEXT0_PAGE_TABLE_END_ADDR_LO32));
        out.puts("\n");

        const wptr_before = self.gfx_ring.wptr;
        if (!self.gfx_ring.writeNop()) return false;

        // Verify NOP was written to ring buffer (CPU-side read)
        const ring_base: [*]volatile u32 = @ptrCast(@alignCast(self.gfx_ring.ring_buf.virt));
        out.puts("gfx10: ring[0]=");
        main.fmtHexPrint(ring_base[0]);
        out.puts(" (expect NOP=c0001000)\n");

        self.gfx_ring.commit();

        // Diagnostic: check wptr was written
        out.puts("gfx10: wptr_before=");
        main.fmtHexPrint(wptr_before);
        out.puts(" wptr_after=");
        main.fmtHexPrint(self.gfx_ring.wptr);
        out.puts(" CP_RB0_WPTR=");
        main.fmtHexPrint(readReg(base + CP_RB0_WPTR));
        out.puts(" rptr(mmio)=");
        main.fmtHexPrint(readReg(base + CP_RB0_RPTR));
        out.puts("\n");

        // Poll RPTR from MMIO register (DMA writeback may not work with DEPTH=1)
        const target_wptr = wptr_before + 1;
        var ok = false;
        var poll_i: u32 = 0;
        while (poll_i < 1_000_000) : (poll_i += 1) {
            if (readReg(base + CP_RB0_RPTR) == target_wptr) {
                ok = true;
                break;
            }
        }

        // Diagnostic: final rptr after wait
        out.puts("gfx10: after wait rptr(mmio)=");
        main.fmtHexPrint(readReg(base + CP_RB0_RPTR));
        out.puts(" CP_RB0_WPTR=");
        main.fmtHexPrint(readReg(base + CP_RB0_WPTR));
        out.puts(" STALL1=");
        main.fmtHexPrint(readReg(base + CP_STALLED_STAT1));
        out.puts(" BUSY=");
        main.fmtHexPrint(readReg(base + CP_BUSY_STAT));
        out.puts(" GRBM=");
        main.fmtHexPrint(readReg(base + GRBM_STATUS));
        out.puts("\n");

        // Check for L2 protection faults after NOP
        const fault = readReg(hub + GCVM_L2_PROTECTION_FAULT_STATUS);
        if (fault != 0) {
            const fault_lo = readReg(hub + GCVM_L2_PROTECTION_FAULT_ADDR_LO32);
            const fault_hi = readReg(hub + GCVM_L2_PROTECTION_FAULT_ADDR_HI32);
            out.puts("gfx10: L2 FAULT status=");
            main.fmtHexPrint(fault);
            out.puts(" addr_hi=");
            main.fmtHexPrint(fault_hi);
            out.puts(" addr_lo=");
            main.fmtHexPrint(fault_lo);
            // Decode: bits 3:0=VMID, bit 5=RW(1=write), bits 11:7=client
            out.puts(" vmid=");
            main.fmtHexPrint(fault & 0xF);
            out.puts(if (fault & (1 << 5) != 0) " WRITE" else " READ");
            out.puts("\n");
        }

        return ok;
    }

    /// Get GFX engine status from GRBM register.
    pub fn isIdle(self: *const Gfx10State) bool {
        const status = readReg(self.mmio_base + self.gc_base + GRBM_STATUS);
        // Check GUI_ACTIVE bit (bit 31)
        return (status & (1 << 31)) == 0;
    }

    /// Format status info into buffer.
    pub fn getInfo(self: *const Gfx10State, buf: []u8) usize {
        const info = if (self.initialized) "gfx: ready\n" else "gfx: not initialized\n";
        const len = @min(info.len, buf.len);
        @memcpy(buf[0..len], info[0..len]);
        return len;
    }

    // --- Internal ---

    // Shared firmware read buffer (BSS, not stack — firmware can be >256KB)
    var gfx_fw_buf: [524288]u8 linksection(".bss") = undefined;

    fn loadGfxFirmware(self: *Gfx10State, psp_state: *psp.PspState) bool {
        const main = @import("../main.zig");

        // Load PFP, ME via PSP
        const suffixes = [_]struct { suffix: []const u8, fw_type: u32 }{
            .{ .suffix = "_pfp.bin", .fw_type = psp.FW_TYPE_CP_PFP },
            .{ .suffix = "_me.bin", .fw_type = psp.FW_TYPE_CP_ME },
        };

        for (suffixes) |s| {
            const name = fmtFwName("gc", self.gc_major, self.gc_minor, self.gc_revision, s.suffix);
            const n = readFirmware(name, &gfx_fw_buf);
            if (n == 0) {
                out.puts("gfx10: missing ");
                out.puts(name);
                out.puts("\n");
                continue;
            }
            const payload = psp.parseFirmwarePayload(gfx_fw_buf[0..n]);
            const fw_data = if (payload) |p|
                gfx_fw_buf[p.offset..][0..p.size]
            else
                gfx_fw_buf[0..n];
            if (psp_state.loadIpFirmware(s.fw_type, fw_data) != .ok) {
                out.puts("gfx10: PSP load failed for ");
                out.puts(name);
                out.puts("\n");
                return false;
            }
        }

        // Load MEC + MEC jump table (type 4 + type 5)
        {
            const name = fmtFwName("gc", self.gc_major, self.gc_minor, self.gc_revision, "_mec.bin");
            const n = readFirmware(name, &gfx_fw_buf);
            if (n == 0) {
                out.puts("gfx10: missing ");
                out.puts(name);
                out.puts("\n");
            } else {
                const payload = psp.parseFirmwarePayload(gfx_fw_buf[0..n]);
                const fw_data = if (payload) |p|
                    gfx_fw_buf[p.offset..][0..p.size]
                else
                    gfx_fw_buf[0..n];
                if (psp_state.loadIpFirmware(psp.FW_TYPE_CP_MEC, fw_data) != .ok) {
                    out.puts("gfx10: PSP MEC load failed\n");
                    return false;
                }

                // MEC jump table (gfx_firmware_header_v1_0: jt_offset at +0x24, jt_size at +0x28)
                if (n >= 0x2C) {
                    const data = gfx_fw_buf[0..n];
                    const ucode_off = rdU32(data, 0x18);
                    const jt_off_dw = rdU32(data, 0x24);
                    const jt_sz_dw = rdU32(data, 0x28);
                    if (jt_sz_dw > 0) {
                        const jt_off = ucode_off + jt_off_dw * 4;
                        const jt_sz = jt_sz_dw * 4;
                        if (jt_off + jt_sz <= n) {
                            out.puts("gfx10: MEC JT off=");
                            main.fmtHexPrint(jt_off);
                            out.puts(" sz=");
                            main.fmtDecPrint(jt_sz);
                            out.puts("\n");
                            _ = psp_state.loadIpFirmware(psp.FW_TYPE_CP_MEC_ME1, data[jt_off..][0..jt_sz]);
                        }
                    }
                }
            }
        }

        // Load RLC firmware (multi-section: RLC_G + DRAM + GPM + SRM)
        const rlc_name = fmtFwName("gc", self.gc_major, self.gc_minor, self.gc_revision, "_rlc.bin");
        const rlc_n = readFirmware(rlc_name, &gfx_fw_buf);
        if (rlc_n == 0) {
            out.puts("gfx10: missing RLC firmware\n");
            return false;
        }

        // Main RLC_G ucode (from common header)
        const rlc_payload = psp.parseFirmwarePayload(gfx_fw_buf[0..rlc_n]);
        const rlc_data = if (rlc_payload) |p|
            gfx_fw_buf[p.offset..][0..p.size]
        else
            gfx_fw_buf[0..rlc_n];
        if (psp_state.loadIpFirmware(psp.FW_TYPE_RLC_G, rlc_data) != .ok) {
            out.puts("gfx10: PSP load RLC_G failed\n");
            return false;
        }

        // Parse v2.1/v2.2 header for sub-sections.
        // CORRECT struct layout (from Linux amdgpu_ucode.h):
        //   common_firmware_header: 32 bytes (0x00-0x1F)
        //   v2_0: 5 fields (0x20-0x33) — includes master_pkt_description_offset
        //   v2_1: 12 reg_list fields (0x34-0x63) + 12 save_restore fields (0x64-0x93)
        //   v2_2: 4 IRAM/DRAM fields (0x94-0xA3)
        const hdr_end: u32 = if (rlc_payload) |p| @intCast(p.offset) else 256;

        if (rlc_n >= 0x94) {
            const data = gfx_fw_buf[0..rlc_n];

            // v2.1: save/restore lists (correct offsets with master_pkt_desc at 0x30)
            const cntl_sz = rdU32(data, 0x6C);
            const cntl_off = rdU32(data, 0x70);
            const gpm_sz = rdU32(data, 0x7C);
            const gpm_off = rdU32(data, 0x80);
            const srm_sz = rdU32(data, 0x8C);
            const srm_off = rdU32(data, 0x90);

            // CNTL (type 22)
            if (cntl_sz > 0 and cntl_off + cntl_sz <= rlc_n) {
                _ = psp_state.loadIpFirmware(psp.FW_TYPE_RLC_RESTORE_LIST_SRM_CNTL, data[cntl_off..][0..cntl_sz]);
            }
            // GPM (type 20)
            if (gpm_sz > 0 and gpm_off + gpm_sz <= rlc_n) {
                _ = psp_state.loadIpFirmware(psp.FW_TYPE_RLC_RESTORE_LIST_GPM_MEM, data[gpm_off..][0..gpm_sz]);
            }
            // SRM (type 21)
            if (srm_sz > 0 and srm_off + srm_sz <= rlc_n) {
                _ = psp_state.loadIpFirmware(psp.FW_TYPE_RLC_RESTORE_LIST_SRM_MEM, data[srm_off..][0..srm_sz]);
            }
        }

        // Parse v2.2 header for IRAM/DRAM (correct offsets: 0x94-0xA3)
        if (rlc_n >= 0xA4) {
            const data = gfx_fw_buf[0..rlc_n];
            const iram_sz = rdU32(data, 0x94);
            const iram_off = rdU32(data, 0x98);
            const dram_sz = rdU32(data, 0x9C);
            const dram_off = rdU32(data, 0xA0);

            // IRAM (type 26)
            if (iram_sz > 1 and iram_off >= hdr_end and iram_off + iram_sz <= rlc_n) {
                out.puts("gfx10: RLC IRAM off=");
                main.fmtHexPrint(iram_off);
                out.puts(" sz=");
                main.fmtDecPrint(iram_sz);
                out.puts("\n");
                _ = psp_state.loadIpFirmware(psp.FW_TYPE_RLC_IRAM, data[iram_off..][0..iram_sz]);
            }
            // DRAM (type 48)
            if (dram_sz > 1 and dram_off >= hdr_end and dram_off + dram_sz <= rlc_n) {
                out.puts("gfx10: RLC DRAM off=");
                main.fmtHexPrint(dram_off);
                out.puts(" sz=");
                main.fmtDecPrint(dram_sz);
                out.puts("\n");
                _ = psp_state.loadIpFirmware(psp.FW_TYPE_RLC_DRAM_BOOT, data[dram_off..][0..dram_sz]);
            }
        }

        return true;
    }

    fn loadSdmaFirmware(self: *Gfx10State, psp_state: *psp.PspState) bool {
        const name = fmtFwName("sdma", self.sdma_major, self.sdma_minor, self.sdma_revision, ".bin");
        const n = readFirmware(name, &gfx_fw_buf);
        if (n == 0) {
            out.puts("gfx10: missing ");
            out.puts(name);
            out.puts("\n");
            return false;
        }

        const payload = psp.parseFirmwarePayload(gfx_fw_buf[0..n]);
        const fw_data = if (payload) |p|
            gfx_fw_buf[p.offset..][0..p.size]
        else
            gfx_fw_buf[0..n];

        return psp_state.loadIpFirmware(psp.FW_TYPE_SDMA0, fw_data) == .ok;
    }

    /// Configure GFXHUB for CP DMA access to system RAM.
    fn setupSystemAperture(self: *Gfx10State) void {
        const main = @import("../main.zig");
        const hub = self.mmio_base; // flat offsets — L2/MC writes
        const base = self.mmio_base + self.gc_base; // gc_base — CTX0/L1 writes

        // 1. BIF_FB_EN skipped — NBIO is SoC-shared, writes crash host dGPU

        // 2. Diagnose RLCG: verify scratch registers are accessible (BASE_IDX=0 = flat)
        out.puts("gfx10: RLCG diag: SCRATCH2=");
        main.fmtHexPrint(readReg(hub + SCRATCH_REG2));
        out.puts(" SCRATCH3=");
        main.fmtHexPrint(readReg(hub + SCRATCH_REG3));
        writeReg(hub + SCRATCH_REG2, 0xCAFEBABE);
        out.puts(" write_test=");
        main.fmtHexPrint(readReg(hub + SCRATCH_REG2));
        out.puts("\n");

        // 3. Direct MMIO write for MC/L2 registers (flat offsets)
        out.puts("gfx10: direct MMIO writes:\n");

        // MC registers are hardware-protected on Raphael, write anyway
        writeReg(hub + GCMC_VM_SYSTEM_APERTURE_HIGH_ADDR, 0x2000);
        out.puts("  SYS_HI: write 0x2000, read=");
        main.fmtHexPrint(readReg(hub + GCMC_VM_SYSTEM_APERTURE_HIGH_ADDR));
        out.puts("\n");

        writeReg(hub + GCMC_VM_FB_LOCATION_BASE, 0);
        out.puts("  FB_BASE: write 0, read=");
        main.fmtHexPrint(readReg(hub + GCMC_VM_FB_LOCATION_BASE));
        out.puts("\n");

        const l2_val: u32 = (1 << 0) | (1 << 9) | (1 << 10) | (7 << 15) | (1 << 19);
        writeReg(hub + GCVM_L2_CNTL, l2_val);
        out.puts("  L2_CNTL: write ");
        main.fmtHexPrint(l2_val);
        out.puts(", read=");
        main.fmtHexPrint(readReg(hub + GCVM_L2_CNTL));
        out.puts("\n");

        writeReg(hub + GCVM_L2_CGTT_CLK_CTRL, 0);
        out.puts("  L2_CLK_CTRL: write 0, read=");
        main.fmtHexPrint(readReg(hub + GCVM_L2_CGTT_CLK_CTRL));
        out.puts("\n");

        // 4. Enable L1 TLB with SYSTEM_ACCESS_MODE=3 (physical bypass)
        //    Write at gc_base — confirmed writable for GCVM regs on Raphael
        const l1_val: u32 = (1 << 0) | (3 << 3) | (1 << 6);
        writeReg(base + GCMC_VM_MX_L1_TLB_CNTL, l1_val);

        // 5. Enable VMID 0 context — writable at gc_base (not flat)
        writeReg(base + GCVM_CONTEXT0_CNTL, 1);
        out.puts("gfx10: CTX0_CNTL=");
        main.fmtHexPrint(readReg(base + GCVM_CONTEXT0_CNTL));
        out.puts(" L1=");
        main.fmtHexPrint(readReg(base + GCMC_VM_MX_L1_TLB_CNTL));
        out.puts("\n");
    }

    /// Send a message to the SMU via MP1 mailbox.
    /// Protocol matches Linux smu_cmn_send_smc_msg():
    ///   1. Clear resp register (set to 0)
    ///   2. Write parameter
    ///   3. Write message (triggers SMU)
    ///   4. Poll resp for non-zero (1 = success)
    fn smuSendMsg(self: *Gfx10State, msg: u32, param: u32) u32 {
        if (self.smu_base == 0) return 0;
        const smu = self.mmio_base + self.smu_base;

        // 1. Clear response register
        writeReg(smu + MP1_C2PMSG_90, 0);

        // 2. Write parameter
        writeReg(smu + MP1_C2PMSG_82, param);

        // 3. Write message (triggers SMU processing)
        writeReg(smu + MP1_C2PMSG_66, msg);

        // 4. Poll for response (1 = success, other non-zero = error)
        var i: u32 = 0;
        while (i < 10_000_000) : (i += 1) {
            const resp = readReg(smu + MP1_C2PMSG_90);
            if (resp != 0) return resp;
            asm volatile ("pause");
        }
        return 0; // timeout
    }

    /// Power up GFX blocks via SMU. Must be called before GFXHUB init.
    /// Returns true if SMU responded successfully.
    fn smuPowerUpGfx(self: *Gfx10State) bool {
        const main = @import("../main.zig");

        if (self.smu_base == 0) {
            out.puts("gfx10: SMU base not found\n");
            return false;
        }

        // Check SMU firmware status
        const smu = self.mmio_base + self.smu_base;
        const fw_status = readReg(smu + MP1_C2PMSG_93);
        out.puts("gfx10: SMU fw_status=");
        main.fmtHexPrint(fw_status);

        // Read current mailbox state
        const resp = readReg(smu + MP1_C2PMSG_90);
        const msg_reg = readReg(smu + MP1_C2PMSG_66);
        out.puts(" resp=");
        main.fmtHexPrint(resp);
        out.puts(" msg=");
        main.fmtHexPrint(msg_reg);
        out.puts("\n");

        // Test message first (msg 0x01) — verifies SMU is alive
        out.puts("gfx10: SMU TestMsg=");
        var r = self.smuSendMsg(PPSMC_MSG_TestMessage, 0);
        main.fmtHexPrint(r);

        // GetSmuVersion (msg 0x02) — read back from param reg
        out.puts(" GetVer=");
        r = self.smuSendMsg(PPSMC_MSG_GetSmuVersion, 0);
        main.fmtHexPrint(r);
        if (r == 1) {
            const ver = readReg(smu + MP1_C2PMSG_82);
            out.puts(" ver=");
            main.fmtHexPrint(ver);
        }
        out.puts("\n");

        if (r == 0) {
            out.puts("gfx10: SMU not responding\n");
            return false;
        }

        // Disable GfxOff (prevent power gating)
        out.puts("gfx10: SMU DisableGfxOff=");
        r = self.smuSendMsg(PPSMC_MSG_DisableGfxOff, 0);
        main.fmtHexPrint(r);

        // Power up GFX blocks
        out.puts(" PowerUpGfx=");
        r = self.smuSendMsg(PPSMC_MSG_PowerUpGfx, 0);
        main.fmtHexPrint(r);
        out.puts("\n");

        return r == 1;
    }

    fn setupL2Cache(self: *Gfx10State) void {
        _ = self;
    }

    /// Write a GC register via RLCG (RLC Guard) indirect protocol.
    /// Used for registers in clock-gated blocks that are inaccessible via direct MMIO.
    /// Reference: gfx_v10_0_rlcg_rw() in drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c
    fn rlcgWrite(self: *const Gfx10State, dword_offset: u32, value: u32) bool {
        // SCRATCH_REG0-3: BASE_IDX=0 → need gc_base added (gc_10_3_0_offset.h).
        const base = self.mmio_base + self.gc_base;
        // RLC_SPARE_INT is BASE_IDX=1 (gc segment 1 = gc_base1)
        const base1 = self.mmio_base + self.gc_base1;
        const s2_addr = base + SCRATCH_REG2;
        const s3_addr = base + SCRATCH_REG3;
        const si_addr = base1 + RLC_SPARE_INT;

        // 1. Write value to SCRATCH_REG2
        writeReg(s2_addr, value);

        // 2. Write (dword_offset | WRITE_FLAG) to SCRATCH_REG3
        writeReg(s3_addr, dword_offset | RLCG_GC_WRITE);

        // 3. Trigger RLC interrupt
        writeReg(si_addr, 1);

        // 4. Wait for RLC to process (bit 31 of SCRATCH_REG3 clears when done)
        var i: u32 = 0;
        while (i < 500_000) : (i += 1) {
            if ((readReg(s3_addr) & RLCG_GC_WRITE) == 0) return true;
            asm volatile ("pause");
        }
        return false; // timeout
    }

    /// Wait for RLC autoload to complete.
    /// After PSP triggers autoload, the RLC firmware initializes hardware blocks.
    /// RLC_GPM_GENERAL_3 bits indicate which blocks have completed.
    /// Reference: gfx_v10_0_wait_for_rlc_autoload_complete()
    fn waitForAutoload(self: *Gfx10State) void {
        const main = @import("../main.zig");
        const base = self.mmio_base + self.gc_base1;

        // Enable RLC F32 if not already running
        const rlc_cntl = readReg(base + RLC_CNTL);
        if ((rlc_cntl & RLC_CNTL_RLC_ENABLE_F32) == 0) {
            writeReg(base + RLC_CNTL, RLC_CNTL_RLC_ENABLE_F32);
            out.puts("gfx10: RLC started for autoload\n");
        }

        // Poll GPM_GENERAL_3 for autoload completion (timeout ~5s)
        out.puts("gfx10: waiting for autoload: ");
        var i: u32 = 0;
        var last_g3: u32 = 0;
        while (i < 10_000_000) : (i += 1) {
            asm volatile ("pause");
            if (i % 2_000_000 == 0) {
                const g3 = readReg(base + RLC_GPM_GENERAL_3);
                const g4 = readReg(base + RLC_GPM_GENERAL_4);
                if (g3 != last_g3 or i == 0) {
                    out.puts("g3=");
                    main.fmtHexPrint(g3);
                    out.puts(" g4=");
                    main.fmtHexPrint(g4);
                    out.puts(" ");
                    last_g3 = g3;
                }
                // Check if autoload complete (all bits set)
                if (g3 != 0) break;
            }
        }

        // Check L2/aperture accessibility after autoload
        const hub = self.mmio_base + self.gfxhub_base;
        out.puts("\ngfx10: post-autoload L2_CNTL=");
        main.fmtHexPrint(readReg(hub + GCVM_L2_CNTL));
        out.puts(" SYS_APER=");
        main.fmtHexPrint(readReg(hub + GCMC_VM_SYSTEM_APERTURE_LOW_ADDR));
        out.puts("-");
        main.fmtHexPrint(readReg(hub + GCMC_VM_SYSTEM_APERTURE_HIGH_ADDR));
        out.puts("\n");
    }

    /// Stop the RLC to allow GFXHUB register writes.
    /// Reference: gfx_v10_0_rlc_stop
    fn stopRlc(self: *Gfx10State) void {
        const base = self.mmio_base + self.gc_base1;
        writeReg(base + RLC_CNTL, 0); // Clear RLC_ENABLE_F32
        // Wait for RLC to stop
        var delay: u32 = 0;
        while (delay < 100_000) : (delay += 1) {
            asm volatile ("pause");
        }
        out.puts("gfx10: RLC stopped\n");
    }

    /// Enable the RLC (Run List Controller).
    /// Raphael uses RLC autoload — the RLC firmware automatically initializes
    /// hardware blocks (GMC, L2, etc.) after starting. We wait for completion.
    /// Reference: gfx_v10_0_rlc_start(), gfx_v10_0_wait_for_rlc_autoload_complete()
    fn enableRlc(self: *Gfx10State) bool {
        const main = @import("../main.zig");
        const base = self.mmio_base + self.gc_base1; // RLC uses BASE_IDX=1

        const rlc_cntl = readReg(base + RLC_CNTL);
        out.puts("gfx10: RLC_CNTL before=");
        main.fmtHexPrint(rlc_cntl);
        out.puts("\n");

        // Set RLC_ENABLE_F32 to start the RLC F32 microengine
        writeReg(base + RLC_CNTL, RLC_CNTL_RLC_ENABLE_F32);

        // Wait for RLC autoload to initialize hardware (~100ms+ on Raphael)
        // Check GPM_GENERAL_3/4 for autoload status
        out.puts("gfx10: RLC autoload status: ");
        var i: u32 = 0;
        var last_g3: u32 = 0;
        var last_g4: u32 = 0;
        while (i < 5_000_000) : (i += 1) {
            asm volatile ("pause");
            if (i % 1_000_000 == 0) {
                const g3 = readReg(base + RLC_GPM_GENERAL_3);
                const g4 = readReg(base + RLC_GPM_GENERAL_4);
                if (g3 != last_g3 or g4 != last_g4 or i == 0) {
                    out.puts("g3=");
                    main.fmtHexPrint(g3);
                    out.puts(" g4=");
                    main.fmtHexPrint(g4);
                    out.puts(" ");
                    last_g3 = g3;
                    last_g4 = g4;
                }
            }
        }
        out.puts("\n");

        const rlc_cntl_after = readReg(base + RLC_CNTL);
        out.puts("gfx10: RLC_CNTL after=");
        main.fmtHexPrint(rlc_cntl_after);
        out.puts("\n");

        // Check L2 after autoload wait
        const hub = self.mmio_base + self.gfxhub_base;
        out.puts("gfx10: L2_CNTL(post-autoload)=");
        main.fmtHexPrint(readReg(hub + GCVM_L2_CNTL));
        out.puts("\n");

        return true;
    }

    /// Set up GFX CP ring following the Linux gfx_v10_0_cp_gfx_resume sequence.
    fn setupCpRing(self: *Gfx10State) bool {
        const main = @import("../main.zig");
        const base = self.mmio_base + self.gc_base;
        const rptr_phys = self.gfx_ring.rptrPhysAddr();

        // 0. Halt CP before reconfiguring (gfx_v10_0_cp_gfx_enable(false))
        var me_cntl = readReg(base + CP_ME_CNTL);
        writeReg(base + CP_ME_CNTL, me_cntl | CP_ME_CNTL_ALL_HALT);
        busyWait(100_000);

        // 0a. Force all clocks on — RLC restart may have re-enabled clock gating,
        //     which blocks RCIU transactions and RBIU DMA fetches.
        writeReg(self.mmio_base + self.gc_base1 + RLC_CGTT_MGCG_OVERRIDE, 0xFFFFFFFF);

        // 0b. Full CP + GFX soft reset — clears all CP engines and GFX pipeline.
        //     Previous code had bit 4 for GFX which was WRONG (correct = bit 16).
        //     Also reset CPF/CPG/EA for clean DMA path restart.
        out.puts("gfx10: full soft reset (CP+GFX+CPF+CPG+EA)...\n");
        const stall_before = readReg(base + CP_STALLED_STAT1);
        const grbm_before = readReg(base + GRBM_STATUS);
        const reset_bits = GRBM_SOFT_RESET_CP | GRBM_SOFT_RESET_GFX | GRBM_SOFT_RESET_CPF | GRBM_SOFT_RESET_CPG | GRBM_SOFT_RESET_EA;
        writeReg(base + GRBM_SOFT_RESET, reset_bits);
        _ = readReg(base + GRBM_SOFT_RESET); // read-back fence
        busyWait(500_000); // longer delay for full reset
        writeReg(base + GRBM_SOFT_RESET, 0); // de-assert reset
        _ = readReg(base + GRBM_SOFT_RESET);
        busyWait(500_000);
        const grbm_after = readReg(base + GRBM_STATUS);
        const stall_after = readReg(base + CP_STALLED_STAT1);
        out.puts("gfx10: post-reset GRBM: ");
        main.fmtHexPrint(grbm_before);
        out.puts(" -> ");
        main.fmtHexPrint(grbm_after);
        out.puts(" STALL1: ");
        main.fmtHexPrint(stall_before);
        out.puts(" -> ");
        main.fmtHexPrint(stall_after);
        out.puts("\n");

        // 0b2. Post-reset window: try writing GFXHUB registers that were protected.
        //      After full reset, protection logic may be temporarily relaxed.
        {
            const gc_base_dw: u32 = @truncate(self.gc_base >> 2);
            // Try END_ADDR via RLCG first (fastest path)
            _ = self.rlcgWrite(gc_base_dw + 0x15c8, 0x3FFF); // END_LO
            _ = self.rlcgWrite(gc_base_dw + 0x15c9, 0); // END_HI
            // Try CTX0_CNTL: ENABLE=1, DEPTH=1, RETRY=1 (0x403)
            const ctx0_d1: u32 = (1 << 0) | (1 << 1) | (1 << 10);
            _ = self.rlcgWrite(gc_base_dw + 0x1580, ctx0_d1);
            // Also direct write
            writeReg(base + GCVM_CONTEXT0_PAGE_TABLE_END_ADDR_LO32, 0x3FFF);
            writeReg(base + GCVM_CONTEXT0_PAGE_TABLE_END_ADDR_HI32, 0);
            writeReg(base + GCVM_CONTEXT0_CNTL, ctx0_d1);
            // Readback
            const end_rb = readReg(base + GCVM_CONTEXT0_PAGE_TABLE_END_ADDR_LO32);
            const ctx0_rb = readReg(base + GCVM_CONTEXT0_CNTL);
            out.puts("gfx10: post-reset END=");
            main.fmtHexPrint(end_rb);
            out.puts(" CTX0=");
            main.fmtHexPrint(ctx0_rb);
            out.puts(if (end_rb == 0x3FFF) " END_OK" else " END_STALE");
            out.puts(if (ctx0_rb & 3 == 3) " CTX_OK" else " CTX_STALE");
            out.puts("\n");
        }

        // 0c. VM TLB invalidation — flush stale L2/L1 entries from host.
        //     Stale TLB entries cause RBIU DMA stalls (host addresses no longer valid).
        //     Full invalidation: VMID 0, heavy-weight flush, all L2+L1 levels.
        {
            const hub = self.mmio_base; // GFXHUB at flat offsets
            const inv_req: u32 = (1 << 0) // PER_VMID_INVALIDATE_REQ: VMID 0
            | (0 << 16) // FLUSH_TYPE: heavy weight
            | (1 << 18) // INVALIDATE_L2_PTES
            | (1 << 19) // INVALIDATE_L2_PDE0
            | (1 << 20) // INVALIDATE_L2_PDE1
            | (1 << 21) // INVALIDATE_L2_PDE2
            | (1 << 22) // INVALIDATE_L1_PTES
            | (1 << 23); // CLEAR_PROTECTION_FAULT_STATUS_ADDR
            writeReg(hub + GCVM_INVALIDATE_ENG17_REQ, inv_req);
            // Wait for ACK (bit 0 = VMID 0)
            var inv_wait: u32 = 0;
            var inv_ok = false;
            while (inv_wait < 500_000) : (inv_wait += 1) {
                const ack = readReg(hub + GCVM_INVALIDATE_ENG17_ACK);
                if (ack & 1 != 0) {
                    inv_ok = true;
                    break;
                }
                asm volatile ("pause");
            }
            // Also try at gc_base offset
            if (!inv_ok) {
                writeReg(base + GCVM_INVALIDATE_ENG17_REQ, inv_req);
                inv_wait = 0;
                while (inv_wait < 500_000) : (inv_wait += 1) {
                    const ack = readReg(base + GCVM_INVALIDATE_ENG17_ACK);
                    if (ack & 1 != 0) {
                        inv_ok = true;
                        break;
                    }
                    asm volatile ("pause");
                }
            }
            const stall_inv = readReg(base + CP_STALLED_STAT1);
            out.puts("gfx10: VM inv: ");
            out.puts(if (inv_ok) "ACK" else "TIMEOUT");
            out.puts(" STALL1=");
            main.fmtHexPrint(stall_inv);
            out.puts(" GRBM=");
            main.fmtHexPrint(readReg(base + GRBM_STATUS));
            out.puts("\n");
        }

        // Re-halt after soft reset (reset may have cleared halt bits)
        writeReg(base + CP_ME_CNTL, CP_ME_CNTL_ALL_HALT);

        // 1. Set write pointer delay to 0
        writeReg(base + CP_RB_WPTR_DELAY, 0);

        // 2. Use VMID 0 (Data Fabric system aperture covers physical RAM;
        //    VMID 1 requires L2 identity mode which may not work if L2 is still gated)
        writeReg(base + CP_RB_VMID, 0);

        // 3. Set ring buffer size in CP_RB0_CNTL
        //    RB_BUFSZ[5:0] = order_base_2(ring_size / 8)
        //    RB_BLKSZ[13:8] = order_base_2(PAGE_SIZE / 8) = 9 (matches Linux)
        const rb_bufsz: u32 = 5; // order_base_2(256 / 8) = log2(32) = 5
        const rb_blksz: u32 = 9; // order_base_2(4096 / 8) = log2(512) = 9
        const cntl_val: u32 = (rb_bufsz & 0x3F) | ((rb_blksz & 0x3F) << 8);
        writeReg(base + CP_RB0_CNTL, cntl_val);

        // 4. Initialize write pointers to 0
        self.gfx_ring.wptr = 0;
        writeReg(base + CP_RB0_WPTR, 0);
        writeReg(base + CP_RB0_WPTR_HI, 0);

        // 5. Set rptr writeback address (register stores addr >> 2, dword-aligned)
        const rptr_shifted = rptr_phys >> 2;
        writeReg(base + CP_RB0_RPTR_ADDR, @truncate(rptr_shifted));
        writeReg(base + CP_RB0_RPTR_ADDR_HI, @truncate(rptr_shifted >> 32));

        // 6. mdelay(1) then re-write CNTL
        var delay: u32 = 0;
        while (delay < 100_000) : (delay += 1) {
            asm volatile ("pause");
        }
        writeReg(base + CP_RB0_CNTL, cntl_val);

        // 7. Set ring base address — GPU virtual address >> 8
        //    DEPTH=1 mode: ring is mapped at GPU VA 0 via PTE[0]
        writeReg(base + CP_RB0_BASE, 0);
        writeReg(base + CP_RB0_BASE_HI, 0);

        // 8. Disable doorbell, force MMIO wptr mode
        //    (host driver may have left doorbell enabled, causing CP to
        //    ignore MMIO wptr writes)
        const db_ctrl = readReg(base + CP_RB_DOORBELL_CONTROL);
        writeReg(base + CP_RB_DOORBELL_CONTROL, db_ctrl & ~CP_RB_DOORBELL_CONTROL_EN);

        // 9. Activate ring
        writeReg(base + CP_RB_ACTIVE, 1);

        // 10. Store wptr MMIO address for non-doorbell commit
        self.gfx_ring.setWptrMmio(base + CP_RB0_WPTR);

        self.gfx_ring.active = true;

        // 11. Enable ME + PFP only (keep CE halted).
        //     CE (Constant Engine) stalls on GFXHUB memory init when system
        //     aperture registers are hardware-protected (VFIO/APU).
        //     NOP/basic commands only need PFP (fetch) + ME (execute).
        writeReg(base + CP_MAX_CONTEXT, 7); // 8 contexts - 1
        writeReg(base + CP_DEVICE_ID, 1);
        me_cntl = readReg(base + CP_ME_CNTL);
        writeReg(base + CP_ME_CNTL, (me_cntl & ~(CP_ME_CNTL_PFP_HALT | CP_ME_CNTL_ME_HALT)) | CP_ME_CNTL_CE_HALT);

        // 12. Wait for CP firmware to initialize after un-halt
        var delay2: u32 = 0;
        while (delay2 < 500_000) : (delay2 += 1) {
            asm volatile ("pause");
        }

        return true;
    }
};

/// Build a firmware filename like "gc_10_3_7_pfp.bin" from IP version + suffix.
/// Uses a static buffer so the returned slice is valid until the next call.
var fw_name_buf: [48]u8 = undefined;
fn busyWait(iterations: u32) void {
    var i: u32 = 0;
    while (i < iterations) : (i += 1) asm volatile ("pause");
}

fn fmtFwName(prefix: []const u8, major: u8, minor: u8, revision: u8, suffix: []const u8) []const u8 {
    var pos: usize = 0;
    @memcpy(fw_name_buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    fw_name_buf[pos] = '_';
    pos += 1;
    pos += fmtDecU8(fw_name_buf[pos..], major);
    fw_name_buf[pos] = '_';
    pos += 1;
    pos += fmtDecU8(fw_name_buf[pos..], minor);
    fw_name_buf[pos] = '_';
    pos += 1;
    pos += fmtDecU8(fw_name_buf[pos..], revision);
    @memcpy(fw_name_buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    return fw_name_buf[0..pos];
}

fn fmtDecU8(buf: []u8, val: u8) usize {
    if (val == 0) {
        buf[0] = '0';
        return 1;
    }
    var tmp: [3]u8 = undefined;
    var n: usize = 0;
    var v = val;
    while (v != 0) : (n += 1) {
        tmp[n] = '0' + @as(u8, @truncate(v % 10));
        v /= 10;
    }
    for (0..n) |i| buf[i] = tmp[n - 1 - i];
    return n;
}

fn readFirmware(name: []const u8, buf: []u8) usize {
    var path_buf: [64]u8 = undefined;
    const prefix = "/lib/firmware/amdgpu/";
    if (prefix.len + name.len >= path_buf.len) return 0;
    @memcpy(path_buf[0..prefix.len], prefix);
    @memcpy(path_buf[prefix.len..][0..name.len], name);
    const path = path_buf[0 .. prefix.len + name.len];

    const fd = fx.open(path);
    if (fd < 0) return 0;
    defer _ = fx.close(fd);

    var total: usize = 0;
    while (total < buf.len) {
        const n = fx.read(fd, buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return total;
}

/// Read a little-endian u32 from a byte slice at the given offset.
fn rdU32(data: []const u8, off: usize) u32 {
    return @as(u32, data[off]) |
        (@as(u32, data[off + 1]) << 8) |
        (@as(u32, data[off + 2]) << 16) |
        (@as(u32, data[off + 3]) << 24);
}

const mmio = @import("../mmio.zig");

fn writeReg(addr: u64, val: u32) void {
    mmio.write(addr, val);
}

fn readReg(addr: u64) u32 {
    return mmio.read(addr);
}

/// SMN indirect register access via NBIO PCIE_INDEX/PCIE_DATA (MMIO +0x0/+0x4).
/// Used for register blocks not directly mapped in the MMIO BAR (e.g., MMHUB).
/// Reference: amdgpu_device_indirect_rreg / nbio_v7_2_get_pcie_index_offset
fn smnRead(mmio_base: u64, smn_byte_addr: u32) u32 {
    const idx: *volatile u32 = @ptrFromInt(mmio_base); // PCIE_INDEX at +0x0
    const dat: *volatile u32 = @ptrFromInt(mmio_base + 4); // PCIE_DATA at +0x4
    idx.* = smn_byte_addr;
    _ = idx.*; // read-back fence
    return dat.*;
}

fn smnWrite(mmio_base: u64, smn_byte_addr: u32, val: u32) void {
    const idx: *volatile u32 = @ptrFromInt(mmio_base); // PCIE_INDEX at +0x0
    const dat: *volatile u32 = @ptrFromInt(mmio_base + 4); // PCIE_DATA at +0x4
    idx.* = smn_byte_addr;
    _ = idx.*; // read-back fence
    dat.* = val;
    _ = dat.*; // read-back fence
}
