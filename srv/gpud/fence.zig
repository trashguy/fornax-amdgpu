/// GPU fence tracking.
///
/// A fence is a sequence number written by the GPU to a known memory
/// location after completing a batch of commands. The driver polls
/// this memory location to determine completion.
const memory = @import("memory.zig");

pub const FencePool = struct {
    fence_buf: memory.DmaBuffer,
    last_emitted: u64,
    last_completed: u64,

    /// Initialize fence pool. Allocates a DMA buffer for GPU-written fence values.
    pub fn init() ?FencePool {
        const buf = memory.dmaAlloc(4096) orelse return null;
        // Initialize fence memory to 0
        const fence_ptr: *volatile u64 = @ptrCast(@alignCast(buf.virt));
        fence_ptr.* = 0;

        return FencePool{
            .fence_buf = buf,
            .last_emitted = 0,
            .last_completed = 0,
        };
    }

    pub fn deinit(self: *FencePool) void {
        memory.dmaFree(&self.fence_buf);
    }

    /// Get the physical address where the GPU should write fence values.
    pub fn fencePhysAddr(self: *const FencePool) u64 {
        return memory.physAddr(&self.fence_buf);
    }

    /// Emit a new fence (increment sequence number). Returns the fence seq.
    pub fn emit(self: *FencePool) u64 {
        self.last_emitted += 1;
        return self.last_emitted;
    }

    /// Read the current fence value from GPU-written memory.
    pub fn readCompleted(self: *FencePool) u64 {
        const fence_ptr: *const volatile u64 = @ptrCast(@alignCast(self.fence_buf.virt));
        return fence_ptr.*;
    }

    /// Check if a fence has completed.
    pub fn isSignaled(self: *FencePool, seq: u64) bool {
        self.last_completed = self.readCompleted();
        return self.last_completed >= seq;
    }

    /// Wait for a fence to complete. Returns false on timeout.
    pub fn wait(self: *FencePool, seq: u64) bool {
        var i: u32 = 0;
        while (i < 10_000_000) : (i += 1) {
            if (self.isSignaled(seq)) return true;
        }
        return false;
    }
};
