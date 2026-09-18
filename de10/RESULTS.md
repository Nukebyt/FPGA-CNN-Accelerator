# Synthesis Results

Real `quartus_map` / `quartus_fit` / `quartus_sta` runs on Quartus Prime
Lite 21.1, targeting the DE10-Standard's Cyclone V `5CSXFC6D6F31C6`. No
numbers here are estimated.

## Resource probe (`de10/probe/`, bare `cnn_accelerator` core, no pins)

Default parameters: `N=16, Q=12, QSHIFT=4, IMG=6, K=3, POOL=2` (16 fully
parallel `mac_window` instances, one per convolution output position).

| Resource | Used | Available | % |
|---|---|---|---|
| ALMs | 2,041 | 41,910 | 5% |
| Total registers | 260 | -- | -- |
| Block memory bits | 0 | 5,662,720 | 0% |
| DSP blocks | 112 | 112 | **100%** |

**Timing (50 MHz target, 20.000 ns period):**

| Corner | Setup slack | Hold slack |
|---|---|---|
| Slow 1100mV 85C | +5.290 ns | +0.375 ns |
| Slow 1100mV 0C | +4.966 ns | +0.391 ns |
| Fast 1100mV 85C | +11.382 ns | +0.182 ns |
| Fast 1100mV 0C | +11.949 ns | +0.172 ns |

All four PVT corners meet 50 MHz with positive slack (worst case +4.966 ns
at Slow 1100mV 0C). 0 errors on `quartus_map`/`fit`/`sta`.

**Known trade-off:** the fully-parallel, fully-unrolled architecture (16
convolution windows evaluated simultaneously, 9 multiplies each = 144
multiplies total) uses **all 112 DSP blocks** on this device even at the
tiny default problem size (`IMG=6, K=3`). ALM/register headroom is huge
(5% used), but DSP usage does not scale — a larger `IMG`/`K` (more
convolution windows) would need a partially time-multiplexed datapath
instead of full unrolling to fit this device. This is an inherent property
of the chosen architecture, not a synthesis artifact.

## Board bring-up bitstream (`de10/board/`, pin-locked `cnn_accelerator_de10_top`)

Same core, wrapped with the on-chip demo sequencer, LEDR/HEX display logic,
and real DE10-Standard pin locations (`CLOCK_50`, `KEY[1:0]`, `SW[1:0]`,
`LEDR[3:0]`, `HEX5:HEX0`).

| Resource | Used | Available | % |
|---|---|---|---|
| ALMs | 2,185 | 41,910 | 5% |
| Total registers | 463 | -- | -- |
| Total pins | 51 | 499 | 10% |
| Block memory bits | 0 | 5,662,720 | 0% |
| DSP blocks | 112 | 112 | **100%** |

**Timing (50 MHz target, 20.000 ns period):**

| Corner | Setup slack | Hold slack |
|---|---|---|
| Slow 1100mV 85C | +6.293 ns | +0.370 ns |
| Slow 1100mV 0C | +5.917 ns | +0.370 ns |
| Fast 1100mV 85C | +11.727 ns | +0.181 ns |
| Fast 1100mV 0C | +12.571 ns | +0.172 ns |

All four PVT corners meet 50 MHz with positive slack (worst case
+5.917 ns at Slow 1100mV 0C). `KEY[1]`/`SW`/`KEY[0]` are correctly treated
as asynchronous (false-pathed in the SDC) since they're unsynchronized
board switches, not clocked I/O.

**Full flow status — every stage ran for real on this machine, 0 errors:**

| Stage | Result |
|---|---|
| `quartus_map` | 0 errors, 5 warnings (all benign — I/O standard defaults, one always-0 HEX segment) |
| `quartus_fit` | 0 errors, 4 warnings (LogicLock license notice, non-dedicated clock routing for `KEY[0]`'s dual use as reset + clock-enable) |
| `quartus_sta` | 0 errors, 0 warnings — timing met on all 4 corners |
| `quartus_asm` | 0 errors, 0 warnings — `output_files/cnn_accelerator_de10.sof` generated |
| `quartus_cpf` | 0 errors, 0 warnings — `output_files/cnn_accelerator_de10.rbf` generated |

No physical DE10-Standard board was connected to the machine this was
built on (`quartus_pgm -l` reports "No JTAG hardware available"), so the
actual programming step — JTAG or SD card — has not been physically
exercised. Everything through bitstream generation has been, for real, on
this machine.
