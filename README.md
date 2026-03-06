# Pyramid Exporter

Prometheus metrics exporter for [M5Stack AI Pyramid](https://docs.m5stack.com/en/module/AI%20Pyramid) (AX8850) hardware monitoring.

Works as a [node_exporter textfile collector](https://github.com/prometheus/node_exporter#textfile-collector) — a bash script that collects hardware metrics via `ec_cli` and sysfs, writes a `.prom` file, and lets node_exporter serve them over HTTP.

## Collected Metrics

### Power Rails

Per-rail metrics for 6 power rails: `pcie0`, `pcie1`, `usb1`, `usb2`, `invdd`, `extvdd`.

| Metric | Type | Description |
|--------|------|-------------|
| `pyramid_power_voltage_millivolts{rail="..."}` | gauge | Rail voltage (mV) |
| `pyramid_power_current_milliamps{rail="..."}` | gauge | Rail current (mA) |
| `pyramid_power_watts{rail="..."}` | gauge | Rail power (W), computed |

### Fan

| Metric | Type | Description |
|--------|------|-------------|
| `pyramid_fan_speed_rpm` | gauge | Fan speed (RPM) |
| `pyramid_fan_pwm_percent` | gauge | Fan PWM duty cycle (0-100%) |

### CPU

| Metric | Type | Description |
|--------|------|-------------|
| `pyramid_cpu_voltage_millivolts` | gauge | CPU core voltage (mV) |

### USB Power Delivery

| Metric | Type | Description |
|--------|------|-------------|
| `pyramid_pd_voltage_millivolts` | gauge | Negotiated PD voltage (mV) |
| `pyramid_pd_current_milliamps` | gauge | Negotiated PD current (mA) |

### Rail Health

| Metric | Type | Description |
|--------|------|-------------|
| `pyramid_rail_healthy{rail="3v3"}` | gauge | 3.3V rail status (1/0) |
| `pyramid_rail_healthy{rail="1v8"}` | gauge | 1.8V rail status (1/0) |

### PCIe

| Metric | Type | Description |
|--------|------|-------------|
| `pyramid_pcie_present{slot="0"}` | gauge | Slot 0 device presence (1/0) |
| `pyramid_pcie_present{slot="1"}` | gauge | Slot 1 device presence (1/0) |

### Thermal

| Metric | Type | Description |
|--------|------|-------------|
| `pyramid_thermal_zone_celsius{zone="...",type="..."}` | gauge | Temperature per thermal zone (C) |

### Exporter Internal

| Metric | Type | Description |
|--------|------|-------------|
| `pyramid_ec_firmware_version` | gauge | EC firmware version |
| `pyramid_exporter_duration_seconds` | gauge | Collection duration (s) |
| `pyramid_exporter_success` | gauge | Full success flag (1/0) |

## Requirements

- **M5Stack AI Pyramid** (AX8850) with `ec_cli` installed
- `jq`
- `node_exporter` with `--collector.textfile.directory` enabled

## Quick Start

```bash
git clone https://github.com/pastukhov/pyramid-exporter.git
cd pyramid-exporter
sudo ./install.sh
```

The installer will:
1. Check that `jq` and `ec_cli` are available
2. Copy the exporter script to `/usr/local/bin/`
3. Install and start a systemd timer (runs every 15 seconds)
4. Verify node_exporter textfile collector configuration

## Manual Run

```bash
sudo ./pyramid_exporter.sh
cat /var/lib/node_exporter/textfile_collector/pyramid.prom
```

## Verify in Prometheus

```bash
curl -s localhost:9100/metrics | grep pyramid_
```

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `TEXTFILE_DIR` | `/var/lib/node_exporter/textfile_collector` | Output directory for `.prom` file |
| `EC_TIMEOUT` | `5` | Timeout for `ec_cli` calls (seconds) |

## How It Works

```
ec_cli / sysfs  →  pyramid_exporter.sh  →  pyramid.prom  →  node_exporter  →  Prometheus
                   (systemd timer, 15s)     (atomic write)    (textfile collector)
```

The script collects metrics from two sources:
- **ec_cli** — talks to the embedded controller (EC) for power, fan, PD, PCIe, and firmware data
- **sysfs** — reads `/sys/class/thermal/thermal_zone*/temp` for thermal data

Output is written atomically (temp file + `mv`) to avoid partial reads by node_exporter.

Each collector handles errors independently — if one fails, the rest still run and `pyramid_exporter_success` is set to `0`.

## Uninstall

```bash
sudo systemctl disable --now pyramid-exporter.timer
sudo rm /usr/local/bin/pyramid_exporter.sh
sudo rm /etc/systemd/system/pyramid-exporter.{service,timer}
sudo rm /var/lib/node_exporter/textfile_collector/pyramid.prom
sudo systemctl daemon-reload
```

## License

GPL-3.0
