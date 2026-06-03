// MMIO register access with indirect fallback for registers beyond the BAR.
//
// AMD GPUs have a small MMIO BAR (512 KB on Raphael APU) but register blocks
// extending far beyond it. For out-of-range registers, we use the NBIO
// RSMU_INDEX/DATA indirect mechanism (nbio_v7_2, regBIF_BX_PF0_RSMU_INDEX).
//
// Reference: amdgpu_device_indirect_rreg / nbio_v7_2_get_pcie_index_offset

var base: u64 = 0; // virtual address of MMIO BAR start
var size: u64 = 0; // MMIO BAR size in bytes
var rsmu_idx: u64 = 0; // virtual address of RSMU_INDEX register
var rsmu_dat: u64 = 0; // virtual address of RSMU_DATA register

pub fn init(mmio_base: u64, mmio_size: u64, nbio_base1: u64) void {
    base = mmio_base;
    size = mmio_size;
    // RSMU_INDEX = NBIO base[1] + regBIF_BX_PF0_RSMU_INDEX (0x0000)
    // RSMU_DATA  = NBIO base[1] + regBIF_BX_PF0_RSMU_DATA  (0x0004)
    rsmu_idx = mmio_base + nbio_base1;
    rsmu_dat = mmio_base + nbio_base1 + 4;
}

pub fn read(addr: u64) u32 {
    const offset = addr -% base;
    if (offset < size) {
        const ptr: *const volatile u32 = @ptrFromInt(addr);
        return ptr.*;
    }
    // Indirect: write dword offset to RSMU_INDEX, read RSMU_DATA
    const dw: u32 = @truncate(offset >> 2);
    const idx: *volatile u32 = @ptrFromInt(rsmu_idx);
    const dat: *const volatile u32 = @ptrFromInt(rsmu_dat);
    idx.* = dw;
    _ = idx.*; // read-back fence
    return dat.*;
}

pub fn write(addr: u64, val: u32) void {
    const offset = addr -% base;
    if (offset < size) {
        const ptr: *volatile u32 = @ptrFromInt(addr);
        ptr.* = val;
        return;
    }
    const dw: u32 = @truncate(offset >> 2);
    const idx: *volatile u32 = @ptrFromInt(rsmu_idx);
    const dat: *volatile u32 = @ptrFromInt(rsmu_dat);
    idx.* = dw;
    _ = idx.*; // read-back fence
    dat.* = val;
}

/// Read a u32 from shared DMA memory (non-MMIO, always direct).
pub fn readMem(addr: u64) u32 {
    const ptr: *const volatile u32 = @ptrFromInt(addr);
    return ptr.*;
}

/// Write a u32 to shared DMA memory (non-MMIO, always direct).
pub fn writeMem(addr: u64, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    ptr.* = val;
}
