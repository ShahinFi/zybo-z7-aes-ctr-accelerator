# Results

This directory contains the final on-board validation and performance results for the AES-128 CTR accelerator on the Zybo Z7-20.

## Files

- [Board Validation](board-validation.md) — confirms that the complete AES-CTR system works correctly on the physical board.
- [Benchmark Results](benchmark-results.md) — explains how performance was measured and presents the FPGA-versus-CPU results.

## RTL verification

RTL simulation results are kept with the ModelSim test suite:

[`tests/rtl/modelsim/README.md`](../tests/rtl/modelsim/README.md)

The final RTL regression passed:

```text
11 / 11 tests
16,955 checks
0 failures
```

## Related documentation

- [System Architecture](../docs/architecture.md)
- [RTL Design](../docs/rtl-design.md)
- [Build and Reproduction Guide](../BUILD.md)

The files in this directory focus only on results from the integrated system. Design details, RTL verification details, and build instructions are kept in the documents linked above.
