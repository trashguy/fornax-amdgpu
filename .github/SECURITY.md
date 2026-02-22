# Security Policy

## Scope

fornax-amdgpu is a userspace AMD GPU driver for the Fornax research/hobby OS.
It is not intended for production use. That said, we take correctness seriously —
especially for code that handles MMIO access and firmware loading.

## Reporting

If you find a security-relevant bug, open a regular GitHub issue. For this project,
public disclosure is fine — there are no production deployments to protect.

If you'd prefer to report privately, use GitHub's
[private vulnerability reporting](https://github.com/trashguy/fornax-amdgpu/security/advisories/new).

## What counts

- MMIO/DMA mapping errors that could allow device-to-host attacks
- Command ring injection from unprivileged processes
- Firmware loading path traversal or tampering
- Shared memory buffer overflows

## What doesn't

- Denial of service (a hobby OS with no uptime SLA)
- Bugs requiring physical access
