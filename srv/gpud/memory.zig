/// GPU memory management — DMA buffer allocation for firmware loading
/// and command submission.
///
/// On UMA (iGPU), all memory is system RAM. We allocate shared memory
/// segments via the kernel and query their physical addresses for DMA.
/// For PSP firmware loading, buffers must be physically contiguous and
/// 1MB-aligned (since the bootloader address register uses phys >> 20).
const fx = @import("fornax");

pub const DmaBuffer = struct {
    shmem_id: u32,
    virt: [*]u8,
    phys: u64, // physical address of first page (contiguous)
    size: u32,
};

const DMA_ALIGNMENT: u32 = 1 << 20; // 1MB alignment for PSP bootloader

/// Allocate a DMA-capable buffer with physically contiguous, 1MB-aligned
/// pages. Returns the buffer with virtual and physical addresses populated.
pub fn dmaAlloc(size: u32) ?DmaBuffer {
    if (size == 0) return null;

    // Use the DMA shmem syscall for contiguous + aligned allocation
    const id = fx.shmemCreateDma(size, DMA_ALIGNMENT) orelse return null;
    const ptr = fx.shmemMap(id) orelse {
        _ = fx.shmemDestroy(id);
        return null;
    };

    // Get the physical address (contiguous, so page 0 is the base)
    const phys = fx.shmemPhys(id, 0) orelse {
        _ = fx.shmemDestroy(id);
        return null;
    };

    // Zero the buffer
    @memset(ptr[0..size], 0);

    return DmaBuffer{
        .shmem_id = id,
        .virt = ptr,
        .phys = phys,
        .size = size,
    };
}

/// Free a DMA buffer.
pub fn dmaFree(buf: *DmaBuffer) void {
    _ = fx.shmemDestroy(buf.shmem_id);
    buf.size = 0;
}

/// Get the physical address of the buffer.
pub fn physAddr(buf: *const DmaBuffer) u64 {
    return buf.phys;
}

/// Get the virtual address as a slice.
pub fn asSlice(buf: *const DmaBuffer) []u8 {
    return buf.virt[0..buf.size];
}
