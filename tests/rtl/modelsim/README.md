# AES-CTR RTL Verification

This directory contains the self-checking ModelSim regression suite for the top-level AES-CTR RTL accelerator.

The suite verifies the behavior of `aes_ctr_block_128` before Vivado and Linux integration. For the RTL implementation itself, see [RTL Design](../../../docs/rtl-design.md).

## Regression structure

```text
tests/rtl/modelsim/
├── README.md
├── run_all.do
├── load_design.do
├── common/
│   └── aes_ctr_test_lib.do
└── tests/
    ├── test_01_reset.do
    ├── test_02_nist_vectors.do
    ├── test_03_input_handshake.do
    ├── test_04_output_backpressure.do
    ├── test_05_partial_blocks.do
    ├── test_06_busy_start.do
    ├── test_07_counter.do
    ├── test_08_reset_during_operation.do
    ├── test_09_multiple_transactions.do
    ├── test_10_continuous_streaming.do
    └── test_11_randomized_stress.do
```

`common/aes_ctr_test_lib.do` provides the shared test procedures and checking functions. `load_design.do` provides standalone VHDL compilation and DUT loading when needed. `run_all.do` is the single regression entry point and reports the final result.

## Running the regression

Open ModelSim or Questa and run the regression runner by path:

```tcl
do /path/to/zybo-z7-aes-ctr-accelerator/tests/rtl/modelsim/run_all.do
```

The runner locates the test files relative to itself. If the AES-CTR DUT is not already loaded, it compiles the repository VHDL sources and loads `aes_ctr_block_128` automatically before running the tests.

The runner continues through all tests and returns an error at the end if any test fails.

## Test coverage

| Test | Purpose | Checks | Failures |
|---|---|---:|---:|
| 01 | Reset and idle | 132 | 0 |
| 02 | NIST AES-CTR vectors | 128 | 0 |
| 03 | Input handshake | 232 | 0 |
| 04 | Output backpressure | 626 | 0 |
| 05 | Partial blocks | 1,232 | 0 |
| 06 | Start while busy | 379 | 0 |
| 07 | Counter management | 510 | 0 |
| 08 | Reset during operation | 681 | 0 |
| 09 | Multiple transactions | 975 | 0 |
| 10 | Continuous streaming | 3,839 | 0 |
| 11 | Deterministic randomized stress | 8,221 | 0 |
| **Total** |  | **16,955** | **0** |

Final result:

```text
11 / 11 tests passed
16,955 checks passed
0 failures
```

The suite covers:

- reset and idle behavior;
- AES-CTR known-answer vectors;
- input valid/ready handshaking;
- output backpressure;
- full and partial final blocks;
- `TKEEP` and `TLAST` handling;
- start requests while busy;
- initial-counter loading and per-block increment;
- 32-bit counter rollover;
- reset during an active transaction;
- repeated transactions;
- continuous multi-block operation;
- deterministic randomized stress.

## Verification boundary

This is functional simulation, not formal verification. It verifies the directed and deterministic randomized cases implemented by the regression suite, but it does not prove every possible input sequence.

Malformed `TKEEP` patterns are outside the defined test scope because the current RTL does not define a separate error or abort response for them.

The complete regression should be rerun after any functional change to the AES-CTR RTL.
