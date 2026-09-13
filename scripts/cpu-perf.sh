#!/bin/bash
# cpu-perf.sh — boot-time performance settings for the Dell Precision 3650 (run by cpu-perf.service). MIT license.
modprobe msr
# HWP: full performance (Ubuntu Server's default balance_performance capped the i7-10700 at 3.6-3.9 GHz)
for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do echo performance > "$f"; done
# PL1 90 W (the EC's real sustained ceiling on this machine) / PL2 115 W (bursts without reaching the ~87 C penalty).
# setPL (https://github.com/horshack-dpreview/setPL) also neutralises + locks the MMIO copy of the limit; fall back to RAPL only.
if command -v setPL.sh >/dev/null 2>&1; then
  setPL.sh 90 115 >/dev/null 2>&1
else
  R=/sys/class/powercap/intel-rapl:0
  echo 115000000 > $R/constraint_1_power_limit_uw; echo 90000000 > $R/constraint_0_power_limit_uw
fi
# GPU: keep the driver resident and cap the power limit (RTX 3060: 130 W keeps ~95 % of the performance)
nvidia-smi -pm 1 >/dev/null 2>&1; nvidia-smi -pl 130 >/dev/null 2>&1
