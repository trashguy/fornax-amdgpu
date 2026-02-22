# Phase G7d: Full radeonsi + ACO

## Status: Planning

## Summary

Build and deploy the full Mesa radeonsi Gallium3D driver with ACO shader compiler, producing GPU-accelerated OpenGL rendering on both RDNA 2 (iGPU) and RDNA 4 (RX 9070 XT).

## Motivation

This is the final integration phase. All prior phases come together: kernel infrastructure (PCI, MSI-X, mmap, shared memory, IRQ forwarding), GPU server (AMD driver with PSP, command rings, display), Mesa cross-compilation, Fornax winsys, and ACO shaders. The result is hardware-accelerated OpenGL rendering.

## Implementation

### Mesa Build Configuration

Full build with radeonsi:
```sh
meson setup builddir \
  --cross-file fornax.cross \
  -Dgallium-drivers=radeonsi \
  -Dvulkan-drivers= \
  -Dglx=disabled \
  -Degl=enabled \
  -Dgbm=disabled \
  -Dplatforms= \
  -Dllvm=disabled \
  -Damd-use-llvm=false \
  -Dshader-cache=disabled \
  -Dshared-glapi=enabled \
  -Dbuildtype=release
```

### Deployment

Libraries installed to Fornax rootfs:
```
/lib/libGL.so.1           — OpenGL library
/lib/libEGL.so.1          — EGL (context management)
/lib/libgbm.so.1          — (if needed for buffer management)
/lib/libglapi.so.0        — GL dispatch
/lib/dri/radeonsi_dri.so  — radeonsi + ACO driver
```

Total size estimate: ~5-10 MB (ReleaseSmall).

### EGL Platform

Fornax-specific EGL platform for creating rendering contexts:
- No X11, no Wayland (yet)
- EGL "surfaceless" platform or custom "fornax" platform
- Surface backed by shared memory framebuffer
- SwapBuffers copies to GPU server's display scanout (or page-flips)

### OpenGL Version Target

radeonsi on GFX 10.3+ supports OpenGL 4.6. However, initial target is:
- **OpenGL 3.3** (Core Profile) — simpler, sufficient for most applications
- Higher versions enabled naturally as Mesa features work correctly

### Test Programs

1. **glxgears** (classic benchmark): rotating gears, validates basic 3D rendering
2. **glmark2**: comprehensive OpenGL benchmark suite
3. **Simple triangle**: minimal EGL + GL test
4. **Texture test**: load texture from file, render textured quad

### Performance Expectations

- iGPU (RDNA 2): Basic 3D rendering at reasonable framerates
- 9070 XT (RDNA 4): Full gaming-class performance potential (limited by Fornax maturity, not GPU)
- Initial bottleneck will likely be CPU-side overhead (IPC latency, shader compilation)

## Integration with Fornax Ecosystem

### Window Manager (Future — Phase 2003)

Once radeonsi works:
- Each window gets its own EGL surface backed by shared memory
- Window manager composites surfaces (can use GPU via radeonsi)
- Plan 9 window model: "a window is just a namespace"

### Wayland Bridge (Future — Phase 2006)

Sommelier in POSIX realm translates Wayland → Fornax native windows:
- Linux Wayland clients render via radeonsi (same GPU)
- Sommelier copies/shares framebuffers with Fornax window manager

### Chrome (Future — Phase 2007)

Chrome uses GPU acceleration via Wayland + EGL:
- Chrome → Wayland → sommelier → Fornax window manager
- GPU acceleration via radeonsi + Fornax winsys

## Challenges

- **Mesa version pinning**: radeonsi evolves rapidly. Pin to a stable Mesa release.
- **Missing GL extensions**: Some applications may need extensions not yet working. Debug with `MESA_GL_VERSION_OVERRIDE`.
- **Shader compilation latency**: First run compiles all shaders. Enable Mesa shader cache in Phase G7d+.
- **SwapBuffers path**: Need efficient page-flip or blit to display scanout. Avoid double-copy.

## Testing

| Test | Validates |
|------|-----------|
| Triangle renders correctly | Basic pipeline: vertex → fragment → framebuffer |
| Textured quad | Texture upload via VRAM, sampler state |
| glxgears spins smoothly | Continuous rendering, SwapBuffers, depth buffer |
| glmark2 completes | Broad GL feature coverage |
| No GPU hangs after 10 min stress | Stability, fence handling, memory management |
| Both iGPU and 9070 XT | Multi-generation support |

## Dependencies

- Phase G7c (ACO shader compiler — compiles shaders to GPU ISA)
- Phase G7b (Fornax winsys — buffer alloc, command submit, fences)
- Phase G6a-d (AMD GPU driver — hardware access)
- All Fornax kernel prerequisites (2000a-2000f)

## Estimated Size

Mesa radeonsi is ~100K lines (external, not modified). Fornax-specific:
- Build configuration: ~100 lines (meson cross-file, build scripts)
- EGL platform glue: ~200-300 lines
- Deployment scripts: ~50 lines

## Success Criteria

A POSIX program on Fornax calls OpenGL functions, radeonsi encodes GPU commands, the Fornax winsys submits them to the GPU server, the AMD GPU renders the scene, and the result appears on screen — all with zero Linux kernel code in the path.
