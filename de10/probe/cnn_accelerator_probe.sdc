# 50 MHz target clock, matching the DE10-Standard's onboard oscillator
# that the pin-locked board build (../board) actually drives clk from.
create_clock -name clk -period 20.000 [get_ports clk]
derive_clock_uncertainty
