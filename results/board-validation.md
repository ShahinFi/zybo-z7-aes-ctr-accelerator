# Board Validation

## Purpose

This document records the final functional validation of the AES-128 CTR accelerator on the physical Digilent Zybo Z7-20.

The goal was to verify the complete path from the Linux application to the FPGA and back:

```text
user application
      |
      v
Linux AES-CTR driver
      |
      v
input transfer to FPGA
      |
      v
AES-128 CTR accelerator
      |
      v
output transfer back to memory
      |
      v
software comparison
```

This is a board-level test of the complete integrated system. RTL-only verification is documented separately in [`tests/rtl/modelsim/README.md`](../tests/rtl/modelsim/README.md).

## Tested system

| Item | Final configuration |
|---|---|
| Board | Digilent Zybo Z7-20 |
| SoC | Xilinx Zynq-7020 |
| Hardware tools | Vivado 2025.2 |
| Linux build tools | PetaLinux 2025.2 |
| Accelerator | AES-128 CTR |
| Linux device | `/dev/zybo_aes_ctr0` |
| Validation program | `zybo-aes-ctr-test` |

After boot, the expected AES-CTR device was present, the AES driver was loaded, and the validation program was installed.

## Validation method

For each test, `zybo-aes-ctr-test`:

1. prepares an input buffer;
2. sets the AES key, nonce, and initial counter;
3. submits the request through `/dev/zybo_aes_ctr0`;
4. waits for the FPGA result;
5. calculates the expected AES-CTR result in software;
6. compares the complete FPGA output with the software result.

A test passes only when the complete output matches.

Because the test uses the normal Linux driver and data-transfer path, a passing result checks more than the AES core alone. It also confirms that the input reaches the FPGA correctly and that the processed output returns correctly to Linux memory.

## Final validation results

The final board tests passed:

| Test | Result |
|---|---|
| 4096-byte AES-CTR transfer | PASS |
| Multiple input patterns | PASS |
| 1,048,576-byte transfer | PASS |

The 1,048,576-byte test is the current maximum transfer size allowed by the driver.

These results confirm correct AES-CTR operation through the complete Linux-to-FPGA path at both a normal transfer size and the current maximum transfer size.

## Byte order used by the software comparison

During board testing, the software reference had to match the byte order produced by the 32-bit data stream.

Within each 32-bit word, the software reference selects the AES keystream byte as:

```c
aes_byte = (i & ~3U) + (3U - (i & 3U));
```

For one four-byte word, this gives:

```text
memory position: 0 1 2 3
AES byte used:   3 2 1 0
```

The same mapping is applied independently to every 32-bit word.

This rule is only for comparing the software byte array with the observed board data order. It does not change the AES-CTR counter construction or the RTL word order.

## What this validation proves

The passing tests confirm that:

- Linux can configure the AES-CTR accelerator;
- input data can be transferred from memory to the FPGA;
- the FPGA processes the data correctly;
- the result can be transferred back to memory;
- the returned data matches the software AES-CTR reference;
- transfers up to the current 1 MiB limit complete correctly.

The tests do not replace RTL simulation and do not prove every possible input case. Detailed RTL verification is kept with the ModelSim test suite, while measured performance is reported in [`benchmark-results.md`](benchmark-results.md).
