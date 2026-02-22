# Phase G6c: SMU + Display (DCN 3.x on RDNA 2)

## Status: Planning

## Summary

Load SMU firmware for thermal safety and power management, load DMCUB firmware, program DCN 3.x display registers, and transition from UEFI GOP to GPU-driven scanout on the RDNA 2 iGPU.

## Background

### SMU (System Management Unit)

The SMU manages power states, thermal throttling, and clock frequencies. Without it, the GPU runs in a minimal power state. SMU firmware is loaded via PSP and communicates via a separate mailbox.

### DCN (Display Core Next)

DCN 3.x is the display engine on RDNA 2. It handles:
- Surface programming (framebuffer address, format, pitch)
- CRTC timing (pixel clock, hsync/vsync, blanking)
- Output encoding (DisplayPort, HDMI via DIG/PHY)
- DMCUB (Display Microcontroller Unit B) — handles display-related offload tasks

For the iGPU, display outputs go through the chipset's integrated encoder.

## Implementation

### SMU Firmware Loading

```
smu_13_*.bin — loaded via PSP
```

After loading, communicate via SMU mailbox registers:
1. Write message ID to SMU_MSG register
2. Write parameter to SMU_ARG register
3. Wait for SMU_RESP (success/error)

Essential commands:
- Set minimum power state (thermal safety)
- Enable basic clock gating
- Query temperature / power limits

### DMCUB Firmware Loading

```
dmcub_dcn3*.bin — loaded to DMCUB SRAM via MMIO
```

DMCUB load sequence:
1. Reset DMCUB (write to DMCUB_CNTL)
2. Write firmware to DMCUB instruction RAM (MMIO region)
3. Write boot parameters to DMCUB data RAM
4. Release reset
5. Poll DMCUB status register for "ready"

### Display Engine Setup (`display.zig`, `display/dcn3.zig`)

Minimal display init (single output):

1. **Surface setup**: Program HUBP (Hub Pipe) with framebuffer address, format (ARGB8888), pitch, dimensions
2. **OPP (Output Pixel Processing)**: Format conversion, no color management initially
3. **OPTC (Output Pipe Timing Combiner)**: Program timing generator with target resolution + refresh rate
4. **DIG (Display Interface Gateway)**: Configure for DisplayPort or HDMI output
5. **Link training**: DP link training via DPCD (display-side) + DIG registers (GPU-side)

### GOP to GPU Transition

```
1. Current state: UEFI GOP framebuffer active
2. Program DCN: point HUBP at new framebuffer (or same address initially)
3. Program OPTC with matching timing
4. Enable scanout → display seamlessly transitions
5. Disable GOP framebuffer (optional)
```

### UMA Memory Management (`memory.zig`)

iGPU has no dedicated VRAM — uses system RAM (UMA):
- Framebuffer allocated from system RAM (shared memory segment)
- GPU accesses via physical address (same as CPU)
- No VRAM BAR to map
- Simpler than discrete GPU but must coordinate with kernel PMM

## Reference Code

Linux kernel:
- `drivers/gpu/drm/amd/pm/swsmu/smu13/` — SMU 13 driver
- `drivers/gpu/drm/amd/display/dmub/` — DMCUB loader
- `drivers/gpu/drm/amd/display/dc/dcn31/` — DCN 3.1 display engine
- `drivers/gpu/drm/amd/display/dc/core/dc_link_dp.c` — DP link training

## Firmware Files

```
smu_13_*.bin
dmcub_dcn3*.bin
```

## Testing

- SMU loaded: temperature and clock queries return valid values
- DMCUB loaded: status register shows "ready"
- Display init: screen shows GPU-rendered framebuffer (start with solid color fill)
- Mode setting: resolution change from `/dev/gpu/display` works
- Thermal safety: GPU throttles under stress (SMU active)

## Dependencies

- Phase G6a (PSP — firmware loading for SMU)
- Phase G6b (GFX ring — needed for framebuffer blit operations)
- Fornax Phase 2000c (device mmap — DCN register access)

## Estimated Size

~600-800 lines (display.zig ~200, dcn3.zig ~300-400, SMU ~100-200).

## Notes

Display bring-up is the hardest part of GPU initialization. DCN is complex (hundreds of registers). Start with the simplest possible configuration: single output, fixed resolution matching UEFI GOP, ARGB8888 format. Add mode enumeration and switching later.
