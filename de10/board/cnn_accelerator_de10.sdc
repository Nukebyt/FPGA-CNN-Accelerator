# DE10-Standard onboard oscillator: 50 MHz.
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_clock_uncertainty

# KEY/SW are debounced only by the design's own sampling registers, not by
# a hardware debouncer -- treat them as slow/asynchronous w.r.t. CLOCK_50.
set_false_path -from [get_ports {KEY[*] SW[*]}] -to [get_registers *]
