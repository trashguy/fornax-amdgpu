# Phase G6d: Extend to RDNA 4 (RX 9070 XT)

## Status: Planning

## Summary

Adapt the RDNA 2 driver to support RDNA 4 (GFX 12, Navi 48): swap firmware blobs (PSP 14.x, GFX 12, new SDMA/SMU/DCN), add MES firmware loading (required for GFX 12 command submission), switch from legacy CP to MES-based queues, add discrete VRAM management, and update display to DCN 4.x.

## Target Hardware

RX 9070 XT (RDNA 4, Navi 48, GFX 12, 16 GB GDDR6). Test via VFIO passthrough with host display on iGPU.

## Key Differences from RDNA 2

| Component | RDNA 2 (Phase G6a-c) | RDNA 4 (This Phase) |
|-----------|----------------------|----------------------|
| PSP | 13.x | 14.x (same mailbox protocol) |
| GFX | Legacy CP rings | MES (Micro Engine Scheduler) required |
| SDMA | 5.2 | Newer version |
| SMU | 13 | 14 |
| Display | DCN 3.x | DCN 4.x |
| Memory | UMA (system RAM) | Dedicated VRAM (16 GB, BAR above 4 GB) |

~70-80% code reuse from RDNA 2. Major new work: MES and VRAM management.

## Implementation

### PSP 14.x (`psp.zig` — minor changes)

Same mailbox protocol as PSP 13.x. Changes:
- Different firmware filenames (`psp_14_0_*`)
- Possibly different register offsets (read from IP Discovery — already handled)
- New firmware type IDs for MES

### MES Firmware Loading (NEW — `backends/gfx12.zig`)

MES replaces the legacy CP for command submission on GFX 12:

```
mes_v12_*.bin — MES microcode
```

MES initialization:
1. Load MES firmware via PSP (new firmware type ID)
2. Allocate MES data structures in VRAM:
   - MES ring buffer
   - MES queue management tables
   - Per-queue context save areas
3. Configure MES via MMIO registers
4. MES manages hardware queues — driver submits to MES, MES dispatches to GFX engine

MES command submission replaces direct CP ring writes:
```
Legacy CP: driver → ring buffer → CP → GFX engine
MES:       driver → MES queue → MES scheduler → CP → GFX engine
```

MES provides:
- Priority-based scheduling
- Context switching between queues
- Preemption support

### Discrete VRAM Management (`memory.zig` — major changes)

RDNA 2 iGPU uses UMA (system RAM). RX 9070 XT has dedicated 16 GB GDDR6:

- VRAM accessed via PCI BAR (typically BAR 0, 256 MB visible window + resize BAR for full 16 GB)
- Above-4GB BAR: `mapMmioRegion()` handles this, need bulk 2MB page mapping (Phase 2000c)
- VRAM allocator: simple bump or bitmap allocator for VRAM regions
- Separate pools: VRAM (fast, GPU-local) and system RAM (slower, CPU-accessible via GTT)
- Page table setup: GPU has its own page tables (GPUVM) — separate from CPU page tables

### DCN 4.x Display (`display/dcn4.zig`)

Same architecture as DCN 3.x with register offset changes:
- Read register bases from IP Discovery table (already handled)
- New register fields/widths in some blocks
- Possibly new DMCUB firmware interface
- HDMI 2.1 / DP 2.1 support (not needed initially)

### Backend Selection

`main.zig` auto-detects GPU generation via IP Discovery table:
```
GFX hw_id version:
  10.3.x → gfx10 backend (legacy CP)
  12.x.x → gfx12 backend (MES)
```

## Firmware Files

```
psp_14_0_*_sos.bin, psp_14_0_*_ta.bin
gc_12_*_pfp.bin, gc_12_*_me.bin, gc_12_*_mec.bin
sdma_v*_*.bin
mes_v12_*.bin              ← MES (NEW for GFX 12)
smu_14_*.bin
dmcub_dcn4*.bin
```

## Risk: Firmware Blob Availability

Navi 48 (9070 XT) is very new. Firmware blobs may lag in linux-firmware. Mitigation:
- Check linux-firmware git frequently
- Navi 48 Pro variants may ship firmware earlier
- Mesa ACO already supports GFX 12 (validates register documentation exists)

## Reference Code

Linux kernel:
- `drivers/gpu/drm/amd/amdgpu/gfx_v12_0.c` — GFX 12
- `drivers/gpu/drm/amd/amdgpu/mes_v12_0.c` — MES v12
- `drivers/gpu/drm/amd/amdgpu/psp_v14_0.c` — PSP 14.x
- `drivers/gpu/drm/amd/display/dc/dcn401/` — DCN 4.x

## Testing

- PSP 14.x SecureOS + Trusted Apps loaded on 9070 XT
- MES firmware loaded, MES status register shows ready
- Submit NOP via MES queue, fence returned
- Display output via DCN 4.x (start with fixed resolution)
- VRAM allocation: allocate buffer in VRAM, write from CPU, read from GPU

## Dependencies

- Phases G6a-c (RDNA 2 bring-up — reuse PSP, ring, display framework)
- Fornax Phase 2000c (device mmap — VRAM BAR mapping with huge pages)

## Estimated Size

~800-1000 lines new code (gfx12.zig ~400, dcn4.zig ~300, VRAM allocator changes ~200).

## Notes

MES is the biggest engineering challenge in this phase. The legacy CP is a simple ring buffer; MES is a full scheduler with its own firmware. Start by loading MES firmware and submitting a single NOP — don't try to implement the full queue management model initially.
