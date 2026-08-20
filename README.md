# AES-128 CTR FPGA Accelerator on Zybo Z7

This project implements a Linux-controlled AES-128 CTR accelerator on the
Digilent Zybo Z7-20.

Linux runs on the Zynq processing system and submits buffers through a custom
kernel driver. AXI DMA moves data between system memory and the programmable
logic, where the AES-CTR accelerator transforms the stream and returns the
result to software for validation and benchmarking.

This repository builds on the verified Linux-FPGA acceleration platform
contained in the pinned `platform/` Git submodule.

## Current verified result

The AES-CTR system has been integrated and functionally tested on the physical
Zybo Z7-20.

Verified behavior includes:

- Linux exposes the accelerator through `/dev/zybo_aes_ctr0`.
- The kernel driver acquires the DMA channels named `tx` and `rx`.
- User-space software can configure the AES key, nonce, and initial counter.
- AXI DMA transfers buffers through the AES-CTR FPGA datapath.
- Returned data is checked against a software AES-CTR reference.
- The driver supports transfers up to the current 1 MiB policy limit.
- Functional validation and benchmarking complete successfully on the final
  hardware/software system.

The RTL implementation was also verified independently in ModelSim using a
regression suite containing:

- 11 tests
- 16,955 checks
- zero failures

The final 1 MiB benchmark result was:

```text
FPGA AES-CTR throughput : 32.087 MiB/s
CPU AES-CTR throughput  : 3.257 MiB/s
Speedup                 : approximately 9.85x
```

## Documentation

- [System Architecture](docs/architecture.md) — complete Linux-FPGA system structure, control path, data path, driver responsibilities, and PetaLinux integration.
- [RTL Design](docs/rtl-design.md) — detailed AES-CTR RTL datapath, stream handling, AES core, counter behavior, control sequencing, and parallelism.
- [RTL Verification](tests/rtl/modelsim/README.md) — ModelSim regression structure, test coverage, instructions, and final verification result.
- [Board Validation](results/board-validation.md) — functional validation of the complete system on the physical Zybo Z7-20.
- [Benchmark Results](results/benchmark-results.md) — FPGA-versus-CPU benchmark method and complete measured results.
- [Build and Reproduction Guide](BUILD.md) — complete hardware and Linux rebuild, deployment, validation, and benchmark procedure.

## Relationship to the base platform

The `platform/` submodule is the reusable Linux-FPGA foundation for this
accelerator.

It provides the verified base infrastructure, including:

- Zynq processing-system integration
- AXI DMA infrastructure
- AXI-Lite control path
- Linux/PetaLinux base configuration
- the original end-to-end Linux-to-FPGA acceleration framework

This repository extends that foundation with:

- the AES-128 CTR RTL datapath
- AES-specific control and status registers
- 128-bit key handling
- 96-bit nonce handling
- 32-bit initial-counter handling
- the AES-specific Linux kernel driver
- AES validation and benchmark applications
- ModelSim regression tests
- AES-specific Vivado integration
- AES-specific PetaLinux integration

The platform is kept as a pinned submodule instead of duplicating its base
infrastructure inside this repository.

## How the system is divided

### Linux software

The Linux side provides:

- the AES accelerator kernel driver
- a functional validation application
- a benchmark application

The final device interface is:

```text
/dev/zybo_aes_ctr0
```

The user-space applications are:

```text
zybo-aes-ctr-test
zybo-aes-ctr-bench
```

The validation application submits AES-CTR operations to the FPGA and compares
the returned output against a software reference implementation.

The benchmark application measures FPGA and CPU AES-CTR performance across a
range of transfer sizes while also checking output correctness.

### Kernel driver

The driver provides the controlled interface between Linux user space and the
FPGA accelerator.

It is responsible for:

- accessing the AES control registers
- configuring key, nonce, and initial counter values
- issuing accelerator start operations
- acquiring the AXI DMA channels
- submitting blocking DMA transfers
- managing transfer completion
- enforcing the current maximum transfer policy
- reporting timeout and error conditions

The DMA channels are requested using:

```text
tx
rx
```

The driver matches the FPGA control node using:

```text
xlnx,zybo-accel-ctrl-1.0
```

### FPGA hardware

The programmable-logic design contains:

- the AES-128 CTR accelerator
- AXI DMA
- the AES-extended AXI-Lite control IP
- the Zynq processing-system integration

The primary address assignments are:

```text
AXI DMA       0x40400000
Control IP    0x43C00000
```

The AES control interface provides:

- 128-bit AES key
- 96-bit nonce
- 32-bit initial counter
- start control
- idle/busy status

The streaming datapath is:

```text
Linux memory
    |
    v
AXI DMA MM2S
    |
    v
AES-128 CTR accelerator
    |
    v
AXI DMA S2MM
    |
    v
Linux memory
```

## AES-CTR RTL

The AES implementation is maintained as a VHDL project under HDL Designer.

The actual VHDL sources used by Vivado are stored in:

```text
hardware/hdl_designer/zybo_aes_hdl_lib/hdl/
```

Vivado consumes these files directly. There is intentionally no duplicated
`hardware/rtl/` source tree.

The committed RTL contains the AES encryption datapath, key expansion,
SubBytes, ShiftRows, MixColumns, counter handling, stream collection, stream
serialization, and AES-CTR control logic.

## RTL verification

The ModelSim regression suite is located at:

```text
tests/rtl/modelsim/
```

The entry point is:

```text
tests/rtl/modelsim/run_all.do
```

The 11-test regression covers:

- reset behavior
- NIST AES-CTR vectors
- input AXI-Stream handshaking
- output backpressure
- partial blocks
- start requests while busy
- counter progression
- reset during operation
- multiple transactions
- continuous streaming
- randomized stress

The final regression result is:

```text
16,955 checks
0 failures
```

See [RTL Verification](tests/rtl/modelsim/README.md) for the regression structure, per-test coverage, final results, and run instructions.

## Target platform

- Board: Digilent Zybo Z7-20
- SoC: Xilinx Zynq-7020
- Hardware design tool: Vivado 2025.2
- Linux build tool: PetaLinux 2025.2
- Linux build host: Ubuntu 22.04.5 LTS

## Repository layout

```text
platform/
  pinned base Linux-FPGA acceleration platform

hardware/
  hdl_designer/
    HDL Designer project, VHDL sources, and design metadata

  ip/
    AES-extended AXI-Lite control IP

  vivado/
    project and block-design recreation Tcl

linux/
  driver/
    AES-CTR kernel driver and UAPI

  apps/
    validation and benchmark applications

  petalinux/
    AES-specific PetaLinux overlay

docs/
  architecture.md
    complete Linux-FPGA system architecture

  rtl-design.md
    detailed AES-CTR RTL design

tests/
  rtl/
    modelsim/
      ModelSim AES-CTR regression suite

results/
  README.md
    result documentation index

  board-validation.md
    physical-board functional validation

  benchmark-results.md
    FPGA-versus-CPU benchmark results

BUILD.md
  complete AES hardware/software rebuild and deployment procedure
```

## PetaLinux integration model

The Linux build intentionally reuses the pinned platform PetaLinux snapshot
instead of copying the complete platform configuration into this repository.

A fresh AES PetaLinux build is reproduced by applying:

```text
fresh PetaLinux project
        |
        v
import AES XSA
        |
        v
platform project-spec
        |
        v
AES project-spec overlay
        |
        v
synchronize maintained Linux sources
        |
        v
PetaLinux configuration and build
```

The AES overlay adds the final AES packages:

```text
zybo-aes-ctr-accel
zybo-aes-ctr-test
zybo-aes-ctr-bench
```

The final compiled device tree contains the two DMA channel names required by
the driver:

```text
tx
rx
```

## Build and reproduce

See [BUILD.md](BUILD.md) for the complete workflow to:

- clone the repository and pinned platform submodule
- optionally run the ModelSim regression
- recreate the Vivado project from committed sources
- generate the bitstream
- export the AES XSA
- create a fresh PetaLinux project
- apply the platform and AES PetaLinux layers
- synchronize the maintained Linux sources into the PetaLinux recipes
- build the Linux image
- verify the AES packages and device-tree DMA binding
- package `BOOT.BIN`
- deploy the SD card
- boot the Zybo Z7-20
- run functional validation
- run the benchmark

## Validation and benchmark

The final board-side validation application is:

```bash
sudo zybo-aes-ctr-test
```

The final benchmark application is:

```bash
sudo zybo-aes-ctr-bench
```

The benchmark covers transfer sizes from small messages through the current
1 MiB maximum transfer policy.

The final 1 MiB result measured:

```text
FPGA : 32.087 MiB/s
CPU  : 3.257 MiB/s
      ~9.85x speedup
```

See [Board Validation](results/board-validation.md) for the final physical-board functional checks and [Benchmark Results](results/benchmark-results.md) for the complete performance sweep and measurement method.

## Project status

The repository represents the completed AES-128 CTR accelerator extension of
the reusable Zybo Z7 Linux-FPGA platform.

The final system includes:

- verified AES-CTR RTL
- Vivado integration
- AXI DMA streaming
- AES-specific Linux control
- user-space validation
- benchmarking
- reproducible Vivado project generation
- reproducible PetaLinux integration

The clean PetaLinux reproduction flow has been verified from the committed
public-repository inputs, including successful image generation, AES package
inclusion, and final compiled device-tree DMA binding verification.
