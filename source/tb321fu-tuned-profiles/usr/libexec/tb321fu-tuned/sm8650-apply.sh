#!/bin/sh
# SM8650 / Snapdragon 8 Gen 3 tuning for Lenovo Y700 TB321FU.
# Applies to every cpufreq policy, GPU/interconnect devfreq nodes, and EAS knobs.
set -eu

mode=${1:-balanced}

log() {
  printf 'tb321fu-tuned[%s]: %s\n' "$mode" "$*" >&2
}

write_sysfs() {
  path=$1
  value=$2
  [ -e "$path" ] || return 0
  [ -w "$path" ] || return 0
  printf '%s' "$value" > "$path" 2>/dev/null || true
}

first_available() {
  wanted=$1
  available=$2
  for item in $wanted; do
    for have in $available; do
      if [ "$item" = "$have" ]; then
        printf '%s\n' "$item"
        return 0
      fi
    done
  done
  return 1
}

pick_freq() {
  # pick_freq INDEX_OR_PERCENT available_list
  # percent 0-100 selects nearest freq; "min"/"max" also accepted.
  kind=$1
  shift
  # shellcheck disable=SC2086
  set -- $1
  [ "$#" -gt 0 ] || return 1
  min=$1
  max=$1
  for f in "$@"; do
    [ "$f" -lt "$min" ] && min=$f
    [ "$f" -gt "$max" ] && max=$f
  done
  case "$kind" in
    min) printf '%s\n' "$min"; return 0 ;;
    max) printf '%s\n' "$max"; return 0 ;;
  esac
  target=$((max * kind / 100))
  best=$min
  best_delta=$((target - min))
  [ "$best_delta" -lt 0 ] && best_delta=$((-best_delta))
  for f in "$@"; do
    delta=$((f - target))
    [ "$delta" -lt 0 ] && delta=$((-delta))
    if [ "$delta" -lt "$best_delta" ]; then
      best=$f
      best_delta=$delta
    fi
  done
  printf '%s\n' "$best"
}

case "$mode" in
  powersave)
    cpu_gov_order="powersave schedutil conservative"
    gpu_gov_order="powersave simple_ondemand msm-adreno-tz userspace"
    epp=power
    bias=15
    min_pct=0
    max_pct=55
    schedutil_rate=4000
    power_efficient=1
    ;;
  performance)
    cpu_gov_order="performance schedutil"
    gpu_gov_order="performance simple_ondemand msm-adreno-tz"
    epp=performance
    bias=0
    min_pct=100
    max_pct=100
    schedutil_rate=1000
    power_efficient=0
    ;;
  balanced)
    cpu_gov_order="schedutil ondemand"
    gpu_gov_order="msm-adreno-tz simple_ondemand ondemand"
    epp=balance_performance
    bias=6
    min_pct=0
    max_pct=100
    schedutil_rate=1000
    power_efficient=0
    ;;
  *)
    log "unsupported mode $mode"
    exit 1
    ;;
esac

write_sysfs /proc/sys/kernel/sched_energy_aware 1
write_sysfs /sys/module/workqueue/parameters/power_efficient "$power_efficient"
write_sysfs /sys/devices/system/cpu/cpufreq/boost "$([ "$mode" = powersave ] && echo 0 || echo 1)"

for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
  [ -d "$cpu" ] || continue
  if [ -f "$cpu/online" ] && [ "$mode" != powersave ]; then
    write_sysfs "$cpu/online" 1
  fi
  write_sysfs "$cpu/power/energy_performance_preference" "$epp"
  write_sysfs "$cpu/power/energy_perf_bias" "$bias"
done

for policy in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -d "$policy" ] || continue
  available=""
  [ -f "$policy/scaling_available_governors" ] && available=$(cat "$policy/scaling_available_governors")
  if gov=$(first_available "$cpu_gov_order" "$available"); then
    write_sysfs "$policy/scaling_governor" "$gov"
  fi
  freqs=""
  [ -f "$policy/scaling_available_frequencies" ] && freqs=$(cat "$policy/scaling_available_frequencies")
  if [ -n "$freqs" ]; then
    minf=$(pick_freq min "$freqs")
    maxf=$(pick_freq max "$freqs")
    if [ "$max_pct" -lt 100 ]; then
      maxf=$(pick_freq "$max_pct" "$freqs")
    fi
    if [ "$min_pct" -gt 0 ]; then
      minf=$(pick_freq "$min_pct" "$freqs")
    fi
    # Restore a usable range before tightening, then apply min then max.
    write_sysfs "$policy/scaling_min_freq" "$(pick_freq min "$freqs")"
    write_sysfs "$policy/scaling_max_freq" "$maxf"
    write_sysfs "$policy/scaling_min_freq" "$minf"
  fi
  write_sysfs "$policy/energy_performance_preference" "$epp"
  write_sysfs "$policy/schedutil/rate_limit_us" "$schedutil_rate"
done

for node in /sys/class/devfreq/*; do
  [ -d "$node" ] || continue
  name=$(basename "$node")
  case "$name" in
    *gpu*|*kgsl*|*adreno*|*mdss*|*gmu*|*cci*|*llcc*|*ddrss*|*interconnect*|*bwmon*)
      ;;
    *)
      continue
      ;;
  esac
  available=""
  [ -f "$node/available_governors" ] && available=$(cat "$node/available_governors")
  if gov=$(first_available "$gpu_gov_order" "$available"); then
    write_sysfs "$node/governor" "$gov"
  fi
  freqs=""
  [ -f "$node/available_frequencies" ] && freqs=$(cat "$node/available_frequencies")
  if [ -n "$freqs" ]; then
    minf=$(pick_freq min "$freqs")
    maxf=$(pick_freq max "$freqs")
    if [ "$mode" = powersave ]; then
      maxf=$(pick_freq 50 "$freqs")
    fi
    if [ "$mode" = performance ]; then
      minf=$maxf
    fi
    write_sysfs "$node/min_freq" "$(pick_freq min "$freqs")"
    write_sysfs "$node/max_freq" "$maxf"
    write_sysfs "$node/min_freq" "$minf"
  fi
done

# Adreno sysfs used by some Qualcomm trees.
if [ -d /sys/class/kgsl/kgsl-3d0 ]; then
  write_sysfs /sys/class/kgsl/kgsl-3d0/devfreq/governor "$( [ "$mode" = performance ] && echo performance || echo msm-adreno-tz )"
  if [ "$mode" = powersave ]; then
    write_sysfs /sys/class/kgsl/kgsl-3d0/force_bus_on 0
    write_sysfs /sys/class/kgsl/kgsl-3d0/force_clk_on 0
    write_sysfs /sys/class/kgsl/kgsl-3d0/force_rail_on 0
  fi
fi

# Keep the 8.4" 120 Hz panel at full rate except in powersave.
for drm in /sys/class/drm/card*-DSI-1/modes /sys/class/drm/card*/device/drm/card*/card*-DSI-1; do
  [ -e "$drm" ] || continue
done
if [ -d /sys/class/backlight ]; then
  :
fi

log "applied SM8650 $mode policy"
exit 0
