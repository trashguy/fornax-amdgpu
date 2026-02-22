# fornax-amdgpu

AMD GPU driver package for [Fornax OS](https://github.com/trashguy/Fornax). Provides RDNA 2 and RDNA 4 GPU support via the Fornax GPU server framework.

## Target Hardware

- **Ryzen 9 7950X iGPU** — RDNA 2 (GFX 10.3, Raphael) — stepping stone
- **RX 9070 XT** — RDNA 4 (GFX 12, Navi 48) — primary target

## Architecture

This package replaces the core Fornax `gpud` with an AMD-capable version that imports `lib/gpu` from the Fornax core repo.

```
srv/gpud/
  main.zig            — AMD gpud entry point
  psp.zig             — PSP firmware loading (shared RDNA 2/4)
  discovery.zig       — IP Discovery table parser (shared)
  memory.zig          — VRAM/UMA allocator
  ring.zig            — command ring management
  fence.zig           — GPU fence tracking
  display.zig         — display engine abstraction
  backends/
    gfx10.zig         — RDNA 2 (GFX 10.3, legacy CP)
    gfx12.zig         — RDNA 4 (GFX 12, MES)
  display/
    dcn3.zig          — DCN 3.x (RDNA 2)
    dcn4.zig          — DCN 4.x (RDNA 4)

winsys/
  amdgpu_fornax.c     — Mesa Fornax winsys (~2000 lines)

firmware/
  (not committed — download from linux-firmware/amdgpu/)
```

## Installation

```
fay install fornax-amdgpu
```

## Firmware

AMD GPU firmware blobs are required but not included in this repo. Download from [linux-firmware](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/amdgpu) and place in `firmware/`:

**RDNA 2 (iGPU):** `psp_13_0_*`, `gc_10_3_*`, `sdma_5_2_*`, `smu_13_*`, `dmcub_dcn3*`
**RDNA 4 (9070 XT):** `psp_14_0_*`, `gc_12_*`, `sdma_v*`, `mes_v12_*`, `smu_14_*`, `dmcub_dcn4*`

## Phases

| Phase | Description | Status |
|-------|-------------|--------|
| G6a | IP Discovery + PSP Bootstrap (RDNA 2) | Planning |
| G6b | GFX + SDMA (Legacy CP, RDNA 2) | Planning |
| G6c | SMU + Display (DCN 3.x, RDNA 2) | Planning |
| G6d | Extend to RDNA 4 (MES, DCN 4.x, discrete VRAM) | Planning |
| G7a | Mesa softpipe (software rasterizer) | Planning |
| G7b | Fornax winsys (IPC to /dev/gpu/*) | Planning |
| G7c | ACO shader compiler | Planning |
| G7d | Full radeonsi + ACO | Planning |

## Dependencies

Requires Fornax kernel phases G0-G4 (PCI enhancement, IOAPIC/MSI-X, device mmap, shared memory, IRQ forwarding) and Phase G5 (core GPU server framework).

## License

MIT
