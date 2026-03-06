#!/usr/bin/env bash
# pyramid_exporter.sh — Prometheus textfile collector for M5Stack AI Pyramid
# Collects hardware metrics via ec_cli and sysfs, writes .prom file
# for node_exporter textfile collector.

set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM_FILE="${TEXTFILE_DIR}/pyramid.prom"
TMP_FILE="${PROM_FILE}.$$"
EC_TIMEOUT="${EC_TIMEOUT:-5}"

SUCCESS=1
START_TS=$(date +%s%N)

cleanup() { rm -f "$TMP_FILE"; }
trap cleanup EXIT

: > "$TMP_FILE"

# ---------------------------------------------------------------------------
# ec_cli wrappers
# ---------------------------------------------------------------------------

# ec_cli device subcommands return unwrapped data (CLI extracts .data)
ec_device() {
    timeout "$EC_TIMEOUT" ec_cli device "$@" 2>/dev/null
}

# ec_cli exec returns full JSON envelope {"created":...,"data":...,"work_id":...}
ec_exec() {
    timeout "$EC_TIMEOUT" ec_cli exec -f "$@" 2>/dev/null
}

# Extract .data from JSON envelope (for exec commands returning simple values)
exec_data() {
    ec_exec "$1" | jq -r '.data // empty' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

metric_header() {
    printf '# HELP %s %s\n# TYPE %s %s\n' "$1" "$2" "$1" "$3" >> "$TMP_FILE"
}

metric() {
    printf '%s %s\n' "$1" "$2" >> "$TMP_FILE"
}

# ---------------------------------------------------------------------------
# Collectors
# ---------------------------------------------------------------------------

collect_power() {
    local board_json
    board_json=$(ec_device --board) || { SUCCESS=0; return; }
    echo "$board_json" | jq empty 2>/dev/null || { SUCCESS=0; return; }

    metric_header pyramid_power_voltage_millivolts "Power rail voltage in millivolts" gauge
    metric_header pyramid_power_current_milliamps "Power rail current in milliamps" gauge
    metric_header pyramid_power_watts "Power rail power in watts" gauge

    # Lower-case field names: pcie0, pcie1, usb1, usb2
    local rail mv ma
    for rail in pcie0 pcie1 usb1 usb2; do
        mv=$(echo "$board_json" | jq -r ".${rail}_mv // empty")
        ma=$(echo "$board_json" | jq -r ".${rail}_ma // empty")
        [[ -n "$mv" && -n "$ma" ]] || continue
        metric "pyramid_power_voltage_millivolts{rail=\"${rail}\"}" "$mv"
        metric "pyramid_power_current_milliamps{rail=\"${rail}\"}" "$ma"
        metric "pyramid_power_watts{rail=\"${rail}\"}" "$(awk "BEGIN {printf \"%.6f\", $mv * $ma / 1000000}")"
    done

    # Upper-case field names: INVDD, EXTVDD → labels invdd, extvdd
    local key label
    for key in INVDD EXTVDD; do
        label=$(echo "$key" | tr '[:upper:]' '[:lower:]')
        mv=$(echo "$board_json" | jq -r ".${key}_mv // empty")
        ma=$(echo "$board_json" | jq -r ".${key}_ma // empty")
        [[ -n "$mv" && -n "$ma" ]] || continue
        metric "pyramid_power_voltage_millivolts{rail=\"${label}\"}" "$mv"
        metric "pyramid_power_current_milliamps{rail=\"${label}\"}" "$ma"
        metric "pyramid_power_watts{rail=\"${label}\"}" "$(awk "BEGIN {printf \"%.6f\", $mv * $ma / 1000000}")"
    done
}

collect_fan() {
    local rpm
    rpm=$(ec_device --fanspeed) || { SUCCESS=0; return; }
    [[ "$rpm" =~ ^[0-9]+$ ]] || { SUCCESS=0; return; }

    metric_header pyramid_fan_speed_rpm "Fan speed in RPM" gauge
    metric "pyramid_fan_speed_rpm" "$rpm"
}

collect_fan_pwm() {
    local pwm
    pwm=$(exec_data fan_get_pwm) || { SUCCESS=0; return; }
    [[ "$pwm" =~ ^[0-9]+$ ]] || { SUCCESS=0; return; }

    metric_header pyramid_fan_pwm_percent "Fan PWM duty cycle percentage" gauge
    metric "pyramid_fan_pwm_percent" "$pwm"
}

collect_cpu_voltage() {
    local mv
    mv=$(exec_data vddcpu_get) || { SUCCESS=0; return; }
    [[ "$mv" =~ ^[0-9]+$ ]] || { SUCCESS=0; return; }

    metric_header pyramid_cpu_voltage_millivolts "CPU voltage in millivolts" gauge
    metric "pyramid_cpu_voltage_millivolts" "$mv"
}

collect_pd() {
    local pd_raw v_str a_str v_num a_num pd_mv pd_ma
    pd_raw=$(ec_exec pd_power_info) || { SUCCESS=0; return; }

    v_str=$(echo "$pd_raw" | jq -r '.data.voltage // empty' 2>/dev/null)
    a_str=$(echo "$pd_raw" | jq -r '.data.current // empty' 2>/dev/null)
    [[ -n "$v_str" && -n "$a_str" ]] || { SUCCESS=0; return; }

    # Strip units: "12 V" → 12, "3 A" → 3
    v_num=$(echo "$v_str" | grep -oP '[0-9.]+' | head -1)
    a_num=$(echo "$a_str" | grep -oP '[0-9.]+' | head -1)
    [[ -n "$v_num" && -n "$a_num" ]] || { SUCCESS=0; return; }

    pd_mv=$(awk "BEGIN {printf \"%.0f\", $v_num * 1000}")
    pd_ma=$(awk "BEGIN {printf \"%.0f\", $a_num * 1000}")

    metric_header pyramid_pd_voltage_millivolts "USB PD negotiated voltage in millivolts" gauge
    metric "pyramid_pd_voltage_millivolts" "$pd_mv"
    metric_header pyramid_pd_current_milliamps "USB PD negotiated current in milliamps" gauge
    metric "pyramid_pd_current_milliamps" "$pd_ma"
}

collect_rail_health() {
    metric_header pyramid_rail_healthy "Power rail health status (1=healthy, 0=unhealthy)" gauge

    local func label val
    for pair in V3_3_good:3v3 V1_8_good:1v8; do
        func="${pair%%:*}"
        label="${pair##*:}"
        val=$(exec_data "$func") || { SUCCESS=0; continue; }
        [[ "$val" =~ ^[01]$ ]] || { SUCCESS=0; continue; }
        metric "pyramid_rail_healthy{rail=\"${label}\"}" "$val"
    done
}

collect_pcie() {
    metric_header pyramid_pcie_present "PCIe slot device presence (1=present, 0=absent)" gauge

    local slot val
    for slot in 0 1; do
        val=$(exec_data "pcie${slot}_exists") || { SUCCESS=0; continue; }
        [[ "$val" =~ ^[01]$ ]] || { SUCCESS=0; continue; }
        metric "pyramid_pcie_present{slot=\"${slot}\"}" "$val"
    done
}

collect_thermal() {
    local found=0 zone_path temp_raw zone_type zone_num celsius
    for zone_path in /sys/class/thermal/thermal_zone*; do
        [[ -d "$zone_path" ]] || continue
        temp_raw=$(cat "$zone_path/temp" 2>/dev/null) || continue
        zone_type=$(cat "$zone_path/type" 2>/dev/null) || continue
        zone_num=${zone_path##*thermal_zone}

        if [[ $found -eq 0 ]]; then
            metric_header pyramid_thermal_zone_celsius "Thermal zone temperature in degrees Celsius" gauge
            found=1
        fi

        celsius=$(awk "BEGIN {printf \"%.1f\", $temp_raw / 1000}")
        metric "pyramid_thermal_zone_celsius{zone=\"${zone_num}\",type=\"${zone_type}\"}" "$celsius"
    done
}

collect_version() {
    local ver
    ver=$(ec_device --version) || { SUCCESS=0; return; }
    [[ "$ver" =~ ^[0-9]+$ ]] || { SUCCESS=0; return; }

    metric_header pyramid_ec_firmware_version "EC controller firmware version" gauge
    metric "pyramid_ec_firmware_version" "$ver"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

collect_power
collect_fan
collect_fan_pwm
collect_cpu_voltage
collect_pd
collect_rail_health
collect_pcie
collect_thermal
collect_version

# Exporter metadata
END_TS=$(date +%s%N)
DURATION=$(awk "BEGIN {printf \"%.6f\", ($END_TS - $START_TS) / 1000000000}")

metric_header pyramid_exporter_duration_seconds "Time spent collecting metrics" gauge
metric "pyramid_exporter_duration_seconds" "$DURATION"
metric_header pyramid_exporter_success "Whether the last collection was fully successful (1=yes, 0=partial failure)" gauge
metric "pyramid_exporter_success" "$SUCCESS"

# Atomic write
mv "$TMP_FILE" "$PROM_FILE"
trap - EXIT
