# DE10-Standard CNN Accelerator

A small, from-scratch FPGA accelerator for one CNN layer (convolution →
quantize → ReLU → pool), targeting the **Terasic DE10-Standard**
(Cyclone V, `5CSXFC6D6F31C6`), built and synthesized with **Quartus Prime
Lite 21.1**.


## Architecture

Unlike a streaming/line-buffer convolver, this design loads the entire
`IMG x IMG` activation map into registers first, then evaluates **every**
convolution window in parallel — one `mac_window` + `quant_relu` pair per
output position — before pooling and streaming the result out. That is
affordable at the default problem size and keeps the whole datapath
combinational apart from three single-cycle register stages.

| Parameter | Default | Meaning |
|---|---|---|
| `N`      | 16 | Operand width (signed fixed point) |
| `Q`      | 12 | Fractional bits |
| `QSHIFT` | 4  | LSBs truncated by the quantizer |
| `IMG`    | 6  | Input activation map is `IMG x IMG` |
| `K`      | 3  | Convolution kernel is `K x K` |
| `POOL`   | 2  | Pooling window is `POOL x POOL` |

```
rtl/
  cnn_accelerator.v   top-level pipeline + control FSM (IDLE/LOAD/CONV/POOL/STREAM/DONE)
  mac_window.v         one KxK signed multiply-accumulate, full-precision sum then saturate
  quant_relu.v          fused post-conv quantizer (LSB truncate) + ReLU
  pool_unit.v            2x2 max / average / min pooling, runtime-selectable
tb/
  cnn_accelerator_tb.v          self-checking core testbench (identity kernel, hand-verified expected values)
  cnn_accelerator_de10_top_tb.v smoke test for the board wrapper's sequencer/reset/display glue
de10/
  probe/    resource + Fmax probe Quartus project (bare core, no pins)
  board/    pin-locked, physically-programmable DE10-Standard board project
```

**Interface** (`cnn_accelerator`): `clk`, `rst`, `en`, `activation_in[N-1:0]`
(streamed in one pixel per cycle), `weight[(K*K*N)-1:0]` (all kernel taps
presented together), `pool_type[1:0]` (`00`=max, `01`=avg, `10`=min),
`data_out[N-1:0]` / `valid_out` (streamed pooled results), `done`.

## Simulation

Both testbenches are self-checking and run under [Icarus Verilog](http://iverilog.icarus.com/):

```
iverilog -g2012 -o sim/cnn_tb.vvp rtl/mac_window.v rtl/quant_relu.v rtl/pool_unit.v rtl/cnn_accelerator.v tb/cnn_accelerator_tb.v
vvp sim/cnn_tb.vvp
# -> ALL TESTS PASSED (12/12, covering max/avg/min pooling)

iverilog -g2012 -o sim/de10_wrapper_tb.vvp rtl/mac_window.v rtl/quant_relu.v rtl/pool_unit.v rtl/cnn_accelerator.v \
  de10/board/seg7_decoder.v de10/board/cnn_accelerator_de10_top.v tb/cnn_accelerator_de10_top_tb.v
vvp sim/de10_wrapper_tb.vvp
# -> ALL WRAPPER TESTS PASSED
```

## DE10-Standard board bring-up

`de10/board/cnn_accelerator_de10_top.v` is a self-contained demo: a fixed
6x6 checkerboard activation map and a fixed 3x3 sharpen kernel both live
on-chip (no HPS/Linux/host PC involvement needed after programming), a
sequencer feeds them through the real core at full 50 MHz once per loop,
and the results are shown on the board's own LEDs and 7-segment displays.

| Board wrapper port | DE10-Standard pin | Function |
|---|---|---|
| `CLOCK_50` | PIN_AF14 | 50 MHz onboard oscillator |
| `KEY[0]` | PIN_AJ4 | Active-low board reset (idle=1, pressed=0) |
| `SW[1:0]` | PIN_AB30, PIN_Y27 | `pool_type` (00 max / 01 avg / 10 min) |
| `LEDR[0]` | PIN_AA24 | Nonzero result this frame |
| `LEDR[1]` | PIN_AB23 | Frame-done pulse (one per loop) |
| `LEDR[2]` | PIN_AC23 | Streaming (lit while loading the demo image) |
| `LEDR[3]` | PIN_AD24 | Heartbeat (design alive / clocking) |
| `HEX3:HEX0` | see `de10/board/cnn_accelerator_de10.qsf` | First pooled result, 4 hex digits |
| `HEX5:HEX4` | see `de10/board/cnn_accelerator_de10.qsf` | Loop counter, 2 hex digits |

All pin locations are copied verbatim from Terasic's own DE10-Standard
Golden Hardware Reference Design (`DE10_Standard_GHRD.qsf`) — real,
board-silkscreened pins, not guessed.

### Running the Quartus flow

Resource/Fmax probe (bare core, no pins — for utilization and STA numbers only):

```
cd de10/probe
quartus_map cnn_accelerator_probe
quartus_fit cnn_accelerator_probe
quartus_sta cnn_accelerator_probe
```

Pin-locked, programmable board bitstream (project/revision name is
`cnn_accelerator_de10`, matching `cnn_accelerator_de10.qpf` — Quartus
names output files after the *project*, not the top-level entity, which is
`cnn_accelerator_de10_top`):

```
cd de10/board
quartus_map cnn_accelerator_de10
quartus_fit cnn_accelerator_de10
quartus_sta cnn_accelerator_de10
quartus_asm cnn_accelerator_de10      # -> output_files/cnn_accelerator_de10.sof
quartus_cpf -c output_files/cnn_accelerator_de10.sof output_files/cnn_accelerator_de10.rbf
```

Do not skip `quartus_sta` or treat a clean `quartus_fit` as sufficient —
`quartus_fit` only confirms the design fits and routes, not that it meets
the 50 MHz clock.

### Programming

**Via JTAG (bring-up/debug):**
```
quartus_pgm -c <cable> -m jtag -o "p;output_files/cnn_accelerator_de10.sof"
```

**Via SD card (no host PC needed after programming):** copy the `.rbf`
onto a FAT32-formatted SD card, set the DE10-Standard's MSEL switches for
FPP configuration from SD card, insert the card, and power on. Confirm the
exact expected filename against Terasic's DE10-Standard User Manual before
relying on it.

### Synthesis results

Real `quartus_map`/`fit`/`sta` runs on Quartus Prime Lite 21.1, targeting
the DE10-Standard's Cyclone V `5CSXFC6D6F31C6`. No numbers below are
estimated. Full detail (including the known DSP-scaling trade-off and a
per-stage pass/fail table) is in [`de10/RESULTS.md`](de10/RESULTS.md).

**Resource utilization:**

| Resource | Probe (bare core) | Board (pin-locked) | Available |
|---|---|---|---|
| ALMs | 2,041 (5%) | 2,185 (5%) | 41,910 |
| Total registers | 260 | 463 | -- |
| Total pins | -- | 51 (10%) | 499 |
| Block memory bits | 0 (0%) | 0 (0%) | 5,662,720 |
| DSP blocks | 112 (**100%**) | 112 (**100%**) | 112 |

**Timing, 50 MHz target (20.000 ns period), all 4 PVT corners:**

| Corner | Probe setup slack | Probe hold slack | Board setup slack | Board hold slack |
|---|---|---|---|---|
| Slow 1100mV 85C | +5.290 ns | +0.375 ns | +6.293 ns | +0.370 ns |
| Slow 1100mV 0C | +4.966 ns | +0.391 ns | +5.917 ns | +0.370 ns |
| Fast 1100mV 85C | +11.382 ns | +0.182 ns | +11.727 ns | +0.181 ns |
| Fast 1100mV 0C | +11.949 ns | +0.172 ns | +12.571 ns | +0.172 ns |

Both projects meet 50 MHz with positive slack on every corner (worst case
+4.966 ns setup, Slow 1100mV 0C). `quartus_asm`/`quartus_cpf` both
completed with 0 errors, producing a real `.sof`/`.rbf`.

## Disclaimer

Developed and synthesized with Quartus Prime Lite 21.1. No physical
DE10-Standard board was connected to the machine this was built on, so the
programming step itself (JTAG or SD card) has not been physically
exercised — everything up through bitstream generation (`.sof`/`.rbf`) has.
