/// GPU command ring buffer management.
///
/// Commands are encoded as PM4 packets and written to a ring buffer
/// in system RAM. The CP (Command Processor) reads from the ring via
/// DMA. The driver advances the write pointer and notifies the CP
/// via a doorbell register write.
///
/// Reference: drivers/gpu/drm/amd/amdgpu/amdgpu_ring.c, gfx_v10_0.c
const fx = @import("fornax");
const memory = @import("memory.zig");

const out = fx.io.Writer.stdout;

// PM4 packet types
const PM4_TYPE3: u32 = 3 << 30;

// PM4 opcodes
pub const PM4_NOP: u32 = 0x10;
pub const PM4_EVENT_WRITE_EOP: u32 = 0x47;
pub const PM4_RELEASE_MEM: u32 = 0x49;
pub const PM4_SET_UCONFIG_REG: u32 = 0x79;

// Default ring size: 256 entries = 1KB (small for bring-up)
const DEFAULT_RING_SIZE_DWORDS: u32 = 256;

pub const RingType = enum {
    gfx,
    sdma,
    compute,
};

pub const Ring = struct {
    ring_buf: memory.DmaBuffer,
    rptr_buf: memory.DmaBuffer, // GPU writes read pointer here
    ring_size: u32, // size in dwords
    wptr: u32, // write pointer (dword offset)
    doorbell_addr: u64, // virtual address of doorbell register
    wptr_mmio_addr: u64, // MMIO wptr register (fallback when no doorbell)
    ring_type: RingType,
    active: bool,

    /// Initialize a new ring buffer. Allocates DMA memory for the ring
    /// and the read-pointer writeback location.
    pub fn init(ring_type: RingType) ?Ring {
        const ring_bytes = DEFAULT_RING_SIZE_DWORDS * 4;
        var ring_buf = memory.dmaAlloc(ring_bytes) orelse return null;
        const rptr_buf = memory.dmaAlloc(4096) orelse {
            memory.dmaFree(&ring_buf);
            return null;
        };

        return Ring{
            .ring_buf = ring_buf,
            .rptr_buf = rptr_buf,
            .ring_size = DEFAULT_RING_SIZE_DWORDS,
            .wptr = 0,
            .doorbell_addr = 0,
            .wptr_mmio_addr = 0,
            .ring_type = ring_type,
            .active = false,
        };
    }

    /// Free ring buffer resources.
    pub fn deinit(self: *Ring) void {
        memory.dmaFree(&self.ring_buf);
        memory.dmaFree(&self.rptr_buf);
        self.active = false;
    }

    /// Set the doorbell register address (mapped MMIO).
    pub fn setDoorbell(self: *Ring, addr: u64) void {
        self.doorbell_addr = addr;
    }

    /// Get the physical address of the ring buffer (for CP programming).
    pub fn ringPhysAddr(self: *const Ring) u64 {
        return memory.physAddr(&self.ring_buf);
    }

    /// Get the physical address of the rptr writeback location.
    pub fn rptrPhysAddr(self: *const Ring) u64 {
        return memory.physAddr(&self.rptr_buf);
    }

    /// Get the current hardware read pointer value.
    pub fn readRptr(self: *const Ring) u32 {
        const rptr_ptr: *const volatile u32 = @ptrFromInt(@intFromPtr(self.rptr_buf.virt));
        return rptr_ptr.*;
    }

    /// Write a PM4 Type 3 packet to the ring.
    /// Returns false if the ring is full.
    pub fn writePacket(self: *Ring, opcode: u32, body: []const u32) bool {
        const total_dwords: u32 = 1 + @as(u32, @intCast(body.len)); // header + body
        if (!self.hasSpace(total_dwords)) return false;

        // PM4 type 3 header: [31:30]=3, [15:8]=opcode, [29:16]=count-1
        const count_minus_1: u32 = if (body.len > 0) @as(u32, @intCast(body.len)) - 1 else 0;
        const header = PM4_TYPE3 | (opcode << 8) | (count_minus_1 << 16);

        self.writeWord(header);
        for (body) |word| {
            self.writeWord(word);
        }

        return true;
    }

    /// Write a NOP packet (for testing ring submission).
    pub fn writeNop(self: *Ring) bool {
        return self.writePacket(PM4_NOP, &.{});
    }

    /// Set the MMIO wptr register address (fallback when no doorbell).
    pub fn setWptrMmio(self: *Ring, addr: u64) void {
        self.wptr_mmio_addr = addr;
    }

    /// Commit pending writes by updating the doorbell or MMIO wptr.
    pub fn commit(self: *Ring) void {
        if (self.doorbell_addr != 0) {
            const db: *volatile u32 = @ptrFromInt(self.doorbell_addr);
            db.* = self.wptr;
        } else if (self.wptr_mmio_addr != 0) {
            const lo: *volatile u32 = @ptrFromInt(self.wptr_mmio_addr);
            lo.* = self.wptr;
            // CP_RB0_WPTR_HI is the next register (+4 bytes)
            const hi: *volatile u32 = @ptrFromInt(self.wptr_mmio_addr + 4);
            hi.* = 0;
        }
    }

    /// Check if rptr has caught up to a given wptr value.
    pub fn isComplete(self: *const Ring, target_wptr: u32) bool {
        const rptr = self.readRptr();
        // Simple comparison (handles wraparound for power-of-2 sizes)
        return rptr == target_wptr;
    }

    /// Wait for the ring to drain up to the given write pointer.
    /// Returns false on timeout.
    pub fn waitComplete(self: *const Ring, target_wptr: u32) bool {
        var i: u32 = 0;
        while (i < 1_000_000) : (i += 1) {
            if (self.isComplete(target_wptr)) return true;
        }
        return false;
    }

    // --- Internal ---

    fn hasSpace(self: *const Ring, dwords: u32) bool {
        const rptr = self.readRptr();
        const used = if (self.wptr >= rptr)
            self.wptr - rptr
        else
            self.ring_size - rptr + self.wptr;
        return (self.ring_size - used - 1) >= dwords;
    }

    fn writeWord(self: *Ring, val: u32) void {
        const ring_base: [*]volatile u32 = @ptrCast(@alignCast(self.ring_buf.virt));
        ring_base[self.wptr] = val;
        self.wptr = (self.wptr + 1) & (self.ring_size - 1);
    }
};
