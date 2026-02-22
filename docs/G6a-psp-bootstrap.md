# Phase G6a: IP Discovery + PSP Bootstrap

## Status: Planning

## Summary

Parse the AMD IP Discovery table from VRAM/system RAM to locate hardware IP block register bases, then implement the PSP (Platform Security Processor) mailbox protocol to load PSP SecureOS and Trusted Applications on RDNA 2 iGPU.

## Background

Modern AMD GPUs (RDNA 2+) use a firmware-driven initialization model. The GPU's register layout is not hardcoded — instead, an IP Discovery table in VRAM describes the base addresses of all IP blocks (GFX, SDMA, DCN, etc.). The PSP is an ARM Cortex-A5 embedded in the GPU that manages firmware loading, security, and hardware initialization.

## Target Hardware

Ryzen 9 7950X iGPU (RDNA 2, Raphael, GFX 10.3). Test via VFIO passthrough with host display on 9070 XT.

## Implementation

### IP Discovery Table Parser (`discovery.zig`)

Located at a known offset in VRAM BAR (0x0000 or discoverable via MMIO scratch registers).

Structure (from `amdgpu_discovery.h`):
```
Header:
  signature: "IPDI" (4 bytes)
  version: u16
  size: u16
  checksum: u32
  num_ips: u16

Per-IP entry:
  hw_id: u16          — identifies IP block type (GFX=1, SDMA=2, DCN=8, PSP=13, etc.)
  instance: u8
  revision: u8
  base_address[6]: u32  — up to 6 register base addresses per IP
```

Parser outputs a map of `hw_id -> base_address[]` used by all subsequent phases.

### PSP Mailbox Protocol (`psp.zig`)

PSP communication via MMIO registers at the PSP IP base address:

```
1. Write firmware physical address to PSP_CMD_ADDR_LO / PSP_CMD_ADDR_HI
2. Write command ID to PSP_CMD register
3. Poll PSP_STATUS until ready bit set
4. Check PSP_STATUS for error codes
```

Boot sequence:
1. Allocate contiguous DMA-able memory for firmware (via shared memory or direct alloc)
2. Load `psp_13_0_*_sos.bin` from `/lib/firmware/amdgpu/` into allocated memory
3. Write physical address + size to PSP mailbox
4. PSP validates signature, boots SecureOS
5. Load `psp_13_0_*_ta.bin` (Trusted Applications) via same mailbox

### Firmware File Loading

Read firmware blobs from fxfs filesystem:
```
fd = open("/lib/firmware/amdgpu/psp_13_0_X_sos.bin")
pread(fd, buffer, size, 0)
```

Buffer must be physically contiguous (single segment or known physical address) since PSP uses DMA.

### Error Handling

- PSP timeout: wait up to 10 seconds, report error via `/dev/gpu/ctl`
- Firmware not found: fall back to core gpud (GOP/Bochs)
- PSP error code: log and report, do not proceed with GPU init

## Reference Code

Linux kernel:
- `drivers/gpu/drm/amd/amdgpu/amdgpu_discovery.c` — IP Discovery parser
- `drivers/gpu/drm/amd/amdgpu/amdgpu_psp.c` — PSP framework
- `drivers/gpu/drm/amd/amdgpu/psp_v13_0.c` — PSP 13.x (RDNA 2) specifics
- `drivers/gpu/drm/amd/amdgpu/amdgpu_psp.h` — mailbox register definitions

## Firmware Files

```
psp_13_0_*_sos.bin    — PSP SecureOS
psp_13_0_*_ta.bin     — Trusted Applications (ASD, HDCP, DTM, RAP)
```

## Testing

- IP Discovery table parsed: all IP blocks printed with hw_id + base addresses
- PSP SecureOS loaded: PSP_STATUS returns success
- Trusted Apps loaded: no errors in PSP response
- `cat /dev/gpu/ctl` shows "amd-rdna2" backend with IP block info

## Dependencies

- Fornax Phase G0 (PCI — find AMD GPU device)
- Fornax Phase G2 (device mmap — map VRAM BAR for IP Discovery + MMIO for PSP)
- Fornax Phase G3 (shared memory — DMA buffers for firmware loading)

## Estimated Size

~500-600 lines (discovery.zig ~200, psp.zig ~300-400).
