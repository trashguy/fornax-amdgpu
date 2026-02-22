# Phase G7b: Fornax Winsys

## Status: Planning

## Summary

Implement the full Mesa Fornax winsys (~2000 lines C) that replaces the Linux DRM/libdrm winsys. Handles buffer allocation via `/dev/gpu/vram`, command submission via `/dev/gpu/draw`, and fence tracking via shared memory.

## Motivation

Mesa's radeonsi Gallium3D driver communicates with the kernel via libdrm/DRM ioctls on Linux. On Fornax, we replace this with IPC to the GPU server's Plan 9 interface. The winsys is the only Mesa component that needs Fornax-specific code — everything above it (radeonsi, ACO, Gallium state tracker) works unchanged.

## Architecture

```
Application (GL/EGL calls)
        |
Mesa Gallium State Tracker
        |
radeonsi driver (GPU-specific command encoding)
        |
Fornax winsys (THIS PHASE) ←→ GPU server via /dev/gpu/*
        |
Hardware
```

## Implementation

### `winsys/amdgpu_fornax.c` (~2000 lines)

Key structures:
```c
struct fornax_winsys {
    struct radeon_winsys base;       // Mesa winsys vtable
    int ctl_fd;                       // fd for /dev/gpu/ctl
    int draw_fd;                      // fd for /dev/gpu/draw
    int vram_fd;                      // fd for /dev/gpu/vram
    int fence_fd;                     // fd for /dev/gpu/fence
    volatile uint64_t *fence_mem;     // shared memory for fence polling
};

struct fornax_bo {                    // buffer object
    struct pb_buffer base;            // Mesa buffer interface
    uint32_t handle;                  // GPU server buffer handle
    uint64_t gpu_addr;                // GPU virtual address
    void *cpu_map;                    // CPU mapping (shared memory)
    uint64_t size;
};
```

### Buffer Allocation

```c
// Allocate VRAM buffer
write(vram_fd, "alloc 65536 vram", ...);
// Response: "handle=42 gpu_addr=0x... seg_handle=7"
seg_attach(7);  // Map into our address space for CPU access
```

Buffer types:
- **VRAM**: Fast GPU-local (vertex buffers, textures, command buffers)
- **GTT**: System RAM, GPU-accessible (staging buffers, readback)
- **Shared**: CPU+GPU accessible (fence memory, upload buffers)

### Command Submission

```c
struct submit_msg {
    uint32_t ring;           // GFX, SDMA, COMPUTE
    uint64_t ib_gpu_addr;    // indirect buffer GPU address
    uint32_t ib_size;        // size in dwords
    uint64_t fence_seq;      // fence sequence number to write on completion
};

// Write 32 bytes to /dev/gpu/draw
write(draw_fd, &submit_msg, sizeof(submit_msg));
```

The actual command buffer data is in shared memory (zero-copy). Only the 32-byte metadata goes through IPC.

### Fence Tracking

```c
// Shared memory page mapped at init:
// GPU server writes completed fence values here
volatile uint64_t *fence_mem = seg_attach(fence_seg_handle);

// Check completion (no IPC needed):
bool completed = (*fence_mem >= expected_seq);

// Blocking wait (rare):
while (*fence_mem < expected_seq) {
    read(fence_fd, &buf, 4);  // blocks until fence advances
}
```

### Mesa Winsys Vtable

Implement these callbacks:
```c
.buffer_create          → IPC to /dev/gpu/vram "alloc"
.buffer_destroy         → IPC to /dev/gpu/vram "free"
.buffer_map             → seg_attach (shared memory)
.buffer_unmap           → seg_detach
.cs_create              → allocate command buffer from VRAM pool
.cs_flush               → IPC to /dev/gpu/draw with submit_msg
.fence_wait             → poll shared memory or blocking read
.query_info             → IPC to /dev/gpu/ctl "info"
```

## Testing

- radeonsi creates buffer objects via winsys → GPU server allocates successfully
- Command submission: radeonsi encodes draw commands, winsys submits, fence completes
- Fence polling: shared memory value advances after GPU completion
- Buffer map/unmap: CPU writes to mapped buffer, GPU reads correctly
- Stress test: rapid alloc/free cycle, no memory leaks

## Dependencies

- Phase G6a-c (working AMD GPU driver — command submission + display)
- Fornax Phase G3 (shared memory — buffer backing + fence memory)
- Phase G7a (Mesa cross-compilation pipeline proven)

## Estimated Size

~2000 lines C in `winsys/amdgpu_fornax.c`.
