# Phase G7c: ACO Shader Compiler

## Status: Planning

## Summary

Cross-compile Mesa's ACO (AMD Compiler) backend for Fornax. ACO compiles GLSL/SPIR-V shaders to AMD GPU ISA (GFX 10.3 / GFX 12 machine code). ~50K lines of C++ with no LLVM dependency.

## Background

Mesa has two AMD shader compiler backends:
- **LLVM (amd-llvm)**: Uses LLVM's AMDGPU backend. 30M+ lines of code, massive dependency.
- **ACO**: Mesa-native compiler, ~50K lines C++. Produces equal or better code quality for games. Used by default in Mesa since 2020.

ACO is the only viable option for Fornax — LLVM is far too large to cross-compile or run.

## Implementation

### Cross-Compilation

ACO is C++ code in `src/amd/compiler/`. Cross-compile with clang++:

```sh
# In Mesa meson build, ACO is built as part of radeonsi
meson setup builddir \
  --cross-file fornax.cross \
  -Dgallium-drivers=radeonsi \
  -Damd-use-llvm=false \
  -Dshader-cache=disabled
```

The `fornax.cross` file must specify C++ compiler:
```ini
[binaries]
cpp = 'clang++'
# Or: zig c++ (if Zig's C++ support handles ACO's templates)
```

### C++ Runtime

ACO uses:
- `<vector>`, `<algorithm>`, `<unordered_map>`, `<memory>` — STL containers
- `std::unique_ptr`, `std::move` — move semantics
- No exceptions (Mesa disables them)
- No RTTI (Mesa disables it)

Options:
1. **libc++ (LLVM's C++ runtime)**: Cross-compile libc++ for Fornax musl. ~100K lines, well-tested with clang.
2. **libstdc++ (GCC)**: Heavier, less clean cross-compile.
3. **Zig's C++ support**: May work for simple templates; risky for heavy STL usage.

Recommended: libc++ — it's designed for cross-compilation and works with clang.

### Build Flags

```
-fno-exceptions -fno-rtti
-std=c++17
-target x86_64-linux-musl
--sysroot=/path/to/fornax/sysroot
```

### ACO Targets

ACO shader targets for our hardware:
- `gfx1030` (GFX 10.3) — RDNA 2 iGPU
- `gfx1200` (GFX 12) — RDNA 4 (9070 XT)

ACO selects instruction set based on GPU chip reported by winsys `query_info`.

### Deployment

ACO compiles shaders at runtime (when an OpenGL program first uses a shader). The compiled binary is part of `libgallium_dri.so` (or `radeonsi_dri.so`).

```
/lib/radeonsi_dri.so  (includes ACO)
```

## Challenges

- **C++ cross-compilation**: libc++ + musl is non-trivial. May need to build libc++ separately.
- **Template-heavy code**: ACO uses heavy templates. Compiler must handle them correctly.
- **Binary size**: ACO + STL might be large. `ReleaseSmall` / `-Os` helps.
- **Runtime shader compilation**: First shader compile will be slow on Fornax (no JIT cache initially). Mesa's shader cache can be enabled later.

## Testing

- ACO compiles a simple vertex + fragment shader on Fornax
- Compiled shader binary is valid GFX 10.3 / GFX 12 ISA
- Shader runs on GPU, produces correct rendering output
- Compare rendering output with reference image (softpipe vs radeonsi+ACO)

## Dependencies

- Phase G7b (Fornax winsys — ACO queries GPU info via winsys)
- Phase G7a (Mesa cross-compilation pipeline)
- Fornax POSIX realm (musl libc, `mmap`, `pthread`)

## Estimated Size

Configuration + build system integration. ACO source is in Mesa repo (~50K lines, not modified).
Cross-compile libc++: ~2-3 hours of build system work.
