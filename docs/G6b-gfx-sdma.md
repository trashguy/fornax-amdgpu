# Phase G6b: GFX + SDMA (Legacy CP on RDNA 2)

## Status: Planning

## Summary

Load GFX and SDMA microcode via PSP, set up command ring buffers using legacy CP (Command Processor), and submit a test command (NOP) to verify the GFX ring is operational on RDNA 2 iGPU.

## Background

The GFX engine handles 3D rendering and compute. SDMA (System DMA) handles memory copies between VRAM and system RAM. On RDNA 2, both use the legacy CP for command submission — a hardware ring buffer where the driver writes PM4 packets and the CP reads/executes them. This is simpler than RDNA 4's MES (Micro Engine Scheduler).

## Implementation

### GFX Firmware Loading

Load via PSP (from Phase G6a):
```
gc_10_3_*_pfp.bin   — Pre-Fetch Parser: fetches commands from ring buffer
gc_10_3_*_me.bin    — Micro Engine: executes PM4 packets
gc_10_3_*_mec.bin   — Micro Engine Compute: handles compute queues
```

PSP command: `GFX_CMD_ID_LOAD_IP_FW` with firmware type + physical address.

### SDMA Firmware Loading

```
sdma_5_2_*.bin      — SDMA engine firmware
```

Also loaded via PSP with appropriate firmware type ID.

### Command Ring Setup (`ring.zig`)

GFX ring buffer in system RAM (iGPU uses UMA):

```zig
const Ring = struct {
    base: [*]u32,          // ring buffer base (page-aligned)
    size: u32,             // size in dwords (e.g., 1024 = 4KB ring)
    wptr: u32,             // write pointer (driver-managed)
    rptr_addr: *volatile u32, // read pointer (GPU-written, in write-back memory)
    doorbell: *volatile u32,  // doorbell register (MMIO)
};
```

Initialization:
1. Allocate ring buffer memory (shared memory segment, physically contiguous)
2. Write ring base address + size to GFX CP registers (via IP Discovery base)
3. Enable CP by writing to CP_RB_CNTL register
4. Map doorbell BAR for write pointer updates

### PM4 Packet Format

Commands are encoded as PM4 packets:
```
Type 3 packet header:
  [31:30] = 3 (type 3)
  [15:8]  = opcode
  [29:16] = count (dwords - 1)

NOP packet: opcode 0x10, count 0
FENCE packet: opcode 0x45 (EVENT_WRITE_EOP)
```

### Command Submission

```
1. Write PM4 packet(s) to ring at wptr offset
2. Advance wptr (with wraparound)
3. Write new wptr to doorbell register → CP reads new commands
4. Wait for fence (EVENT_WRITE_EOP writes to a memory location)
```

### Fence Tracking (`fence.zig`)

```zig
const FencePool = struct {
    addr: *volatile u64,    // fence memory (GPU writes here)
    last_emitted: u64,      // last fence sequence number sent
    last_completed: u64,    // last fence value read from memory
};
```

Submit a FENCE packet after each command batch. Poll `addr.*` to check completion.

## Reference Code

Linux kernel:
- `drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c` — GFX 10.x ring setup
- `drivers/gpu/drm/amd/amdgpu/amdgpu_ring.c` — ring buffer management
- `drivers/gpu/drm/amd/amdgpu/sdma_v5_2.c` — SDMA 5.2

## Firmware Files

```
gc_10_3_*_pfp.bin, gc_10_3_*_me.bin, gc_10_3_*_mec.bin
sdma_5_2_*.bin
```

## Testing

- GFX + SDMA firmware loaded via PSP without errors
- Ring buffer created, CP enabled
- Submit NOP packet, verify wptr advances and rptr catches up
- Submit FENCE packet, verify fence value appears in memory
- `cat /dev/gpu/ctl` shows "gfx: ready, sdma: ready"

## Dependencies

- Phase G6a (PSP — firmware loading infrastructure)
- Fornax Phase 2000c (device mmap — doorbell BAR access)
- Fornax Phase 2000d (shared memory — ring buffer + fence memory)

## Estimated Size

~400-500 lines (ring.zig ~250, fence.zig ~100, integration ~100).
