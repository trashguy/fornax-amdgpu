# Phase G7a: Mesa Softpipe (Software Rasterizer)

## Status: Planning

## Summary

Cross-compile Mesa's softpipe (pure CPU software rasterizer) targeting Fornax's musl POSIX sysroot. This proves the cross-compilation pipeline and winsys interface without requiring any GPU hardware or driver.

## Motivation

Softpipe is the simplest Mesa Gallium3D driver — it does all rendering in software. Getting it running on Fornax validates:
1. Mesa cross-compilation with Fornax musl sysroot
2. The Fornax winsys interface (how Mesa talks to the GPU server)
3. Framebuffer output via shared memory to `/dev/gpu/fb0`
4. EGL/GL headers and library deployment

## Implementation

### Cross-Compilation Setup

Meson cross-file (`fornax.cross`):
```ini
[binaries]
c = 'zig cc'
cpp = 'zig c++'
ar = 'zig ar'

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[properties]
sys_root = '/path/to/fornax/sysroot'
```

Meson configure:
```sh
meson setup builddir \
  --cross-file fornax.cross \
  -Dgallium-drivers=swrast \
  -Dvulkan-drivers= \
  -Dglx=disabled \
  -Degl=enabled \
  -Dplatforms= \
  -Dllvm=disabled \
  -Dshared-glapi=enabled
```

### Fornax Winsys (Minimal for Softpipe)

Softpipe doesn't need GPU command submission. The winsys only needs:
- Framebuffer allocation (shared memory segment mapped to `/dev/gpu/fb0`)
- SwapBuffers (notify GPU server to display new frame)

Minimal winsys stub (`winsys/sw_fornax.c`, ~200 lines):
```c
struct fornax_sw_winsys {
    struct sw_winsys base;
    int gpu_fd;          // IPC fd to /dev/gpu/
    void *framebuf;      // shared memory mapped framebuffer
    uint32_t width, height;
};
```

### Build Artifacts

Output libraries for Fornax rootfs:
```
/lib/libGL.so.1
/lib/libEGL.so.1
/lib/libgallium_dri.so   (softpipe driver)
```

### Test Program

Simple EGL + GL triangle:
```c
// Uses EGL to create context, GL to draw, winsys to present
eglInitialize(dpy, ...);
eglCreateContext(dpy, ...);
glClear(GL_COLOR_BUFFER_BIT);
glBegin(GL_TRIANGLES);
  glColor3f(1, 0, 0); glVertex2f(0, 1);
  glColor3f(0, 1, 0); glVertex2f(-1, -1);
  glColor3f(0, 0, 1); glVertex2f(1, -1);
glEnd();
eglSwapBuffers(dpy, surface);
```

## Challenges

- **Mesa build system complexity**: Many generated files (`gl_api.h`, XML-based codegen). May need host tools.
- **Missing POSIX functions**: Mesa may use functions not yet in Fornax shim (e.g., `mmap`, `pthread_*`, `dlopen`). Stub or implement as needed.
- **No X11/Wayland**: EGL platform must be "surfaceless" or a custom Fornax platform. Start with surfaceless + manual framebuffer management.

## Testing

- Cross-compilation completes without errors
- `libGL.so` loads on Fornax (no unresolved symbols)
- Test program renders colored triangle to `/dev/gpu/fb0`
- Triangle visible in QEMU display window (via GPU server's GOP/Bochs/virtio backend)

## Dependencies

- Fornax Phase 2000f (core GPU server — provides `/dev/gpu/fb0`)
- Fornax Phase 2000d (shared memory — framebuffer backing)
- Fornax POSIX sysroot (musl libc, working POSIX realm)

## Estimated Size

~200 lines winsys stub + cross-compilation configuration. Mesa itself is external.
