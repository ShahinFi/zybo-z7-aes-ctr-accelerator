# AES-CTR Benchmark Results

## Purpose

This document records the final AES-128 CTR performance measurements from the physical Digilent Zybo Z7-20.

The benchmark compares two ways of processing the same data on the same board:

- the FPGA AES-CTR accelerator;
- the software AES-CTR implementation running on the Zynq ARM processor.

This is a comparison within the Zybo Z7-20 system. It is not a comparison with desktop or server CPUs.

## Benchmark program

The benchmark program is:

```text
zybo-aes-ctr-bench
```

It can measure the FPGA path, the CPU path, or both.

The final results were collected in compare mode so that both implementations were measured with the same transfer sizes and AES settings.

## What was timed

### FPGA measurement

The FPGA time covers one complete request from the application until the processed buffer is returned.

It includes:

```text
application request
      |
      v
Linux driver
      |
      v
input transfer to FPGA
      |
      v
AES-CTR processing
      |
      v
output transfer back to memory
      |
      v
return to application
```

The FPGA number therefore represents the performance seen by an application using the accelerator. It is not the isolated execution time of the AES RTL core.
The measured FPGA time includes the blocking ioctl call, the user-to-driver and driver-to-user buffer copies, DMA setup, and the DMA/accelerator execution.

### CPU measurement

The CPU baseline uses the benchmark program's built-in C AES-128 CTR implementation running on the Zybo's ARM processor. It is not an OpenSSL or other externally optimized crypto-library result.

## Correctness checks

Correctness checks were performed before and after the repeated timing loop for each transfer size.

These checks were not included in the reported timing values.

Average latency is calculated from the individual timed operations. Throughput is calculated from the total processed payload divided by the elapsed time of the complete timed loop.

The FPGA result was also rejected if the driver reported a failed request, timeout, or error.

The complete final sweep finished with:

```text
failed FPGA requests: 0
timeouts:             0
driver errors:        0
overall result:       PASS
```

## Final benchmark settings

```text
Key:
00112233445566778899aabbccddeeff

Nonce:
0102030405060708090a0b0c

Initial counter:
00000001

Input pattern:
affine
```

The final sweep can be reproduced with:

```bash
sudo zybo-aes-ctr-bench \
  --mode compare \
  --sweep \
  --key 00112233445566778899aabbccddeeff \
  --nonce 0102030405060708090a0b0c \
  --counter 00000001 \
  --pattern affine
```

If `--csv` is not specified, the benchmark writes its local results to `zybo_aes_ctr_bench_results.csv`.

## Sweep sizes

| Transfer size | Timed runs for FPGA | Timed runs for CPU |
|---:|---:|---:|
| 64 B | 10,000 | 10,000 |
| 256 B | 10,000 | 10,000 |
| 1 KiB | 5,000 | 5,000 |
| 4 KiB | 5,000 | 5,000 |
| 16 KiB | 2,000 | 2,000 |
| 64 KiB | 1,000 | 1,000 |
| 256 KiB | 300 | 300 |
| 1 MiB | 100 | 100 |

The full sweep therefore contained:

```text
33,800 timed FPGA requests
33,800 timed CPU runs
67,600 timed operations in total
```

## Results

| Size | FPGA average latency | FPGA throughput | CPU average latency | CPU throughput |
|---:|---:|---:|---:|---:|
| 64 B | 61.941 us | 0.959 MiB/s | 20.121 us | 2.867 MiB/s |
| 256 B | 67.399 us | 3.531 MiB/s | 77.024 us | 3.122 MiB/s |
| 1 KiB | 86.602 us | 11.054 MiB/s | 304.369 us | 3.196 MiB/s |
| 4 KiB | 174.980 us | 22.103 MiB/s | 1211.664 us | 3.221 MiB/s |
| 16 KiB | 524.438 us | 29.693 MiB/s | 4859.982 us | 3.214 MiB/s |
| 64 KiB | 1918.884 us | 32.540 MiB/s | 19147.545 us | 3.264 MiB/s |
| 256 KiB | 7729.376 us | 32.334 MiB/s | 76626.077 us | 3.262 MiB/s |
| 1 MiB | 31161.454 us | 32.087 MiB/s | 307055.557 us | 3.257 MiB/s |

Every FPGA row and every CPU row passed the required checks.

## Reading the results

At 64 bytes, the CPU path is faster:

```text
FPGA: 0.959 MiB/s
CPU:  2.867 MiB/s
```

For a very small transfer, the fixed cost of sending a request through Linux and moving the data to and from the FPGA is large compared with the amount of data being processed.

At 256 bytes, the FPGA path becomes slightly faster:

```text
FPGA: 3.531 MiB/s
CPU:  3.122 MiB/s
```

From 1 KiB upward, the FPGA advantage increases.

For the largest transfer sizes, FPGA throughput stays close to 32 MiB/s:

```text
64 KiB:  32.540 MiB/s
256 KiB: 32.334 MiB/s
1 MiB:   32.087 MiB/s
```

Over the same range, the software implementation remains close to 3.2 MiB/s.

## 1 MiB result

At the current maximum transfer size:

```text
Transfer size:   1,048,576 bytes

FPGA latency:    31,161.454 us
FPGA throughput: 32.087 MiB/s

CPU latency:     307,055.557 us
CPU throughput:  3.257 MiB/s
```

The throughput ratio is:

```text
32.087 / 3.257 = approximately 9.85
```

For this 1 MiB test, the FPGA path therefore delivered about 9.85 times the throughput of the software AES-CTR implementation running on the embedded ARM processor.

## Conclusion

The benchmark shows a clear size-dependent result:

- the CPU is faster for the smallest 64-byte transfer;
- the FPGA becomes slightly faster at 256 bytes;
- the FPGA advantage is clear from 1 KiB upward;
- large FPGA transfers reach about 32 MiB/s;
- the 1 MiB FPGA result is about 9.85 times the measured CPU throughput.

These numbers describe the complete accelerator path as used by an application on the Zybo Z7-20.
