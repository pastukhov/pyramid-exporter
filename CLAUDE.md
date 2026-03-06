# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Prometheus textfile collector exporter for M5Stack AI Pyramid (AX8850). A bash script that collects hardware metrics via `ec_cli` and sysfs, writes a `.prom` file consumed by node_exporter.

## Architecture

```
ec_cli / sysfs → pyramid_exporter.sh → pyramid.prom → node_exporter → Prometheus
                 (systemd timer, 15s)   (atomic write)
```

`pyramid_exporter.sh` has 9 independent collector functions. Each handles its own errors — if one fails, the rest still run and `pyramid_exporter_success` is set to `0`.

Two `ec_cli` calling conventions:
- `ec_device()` — wraps `ec_cli device` subcommands that return unwrapped data
- `ec_exec()` / `exec_data()` — wraps `ec_cli exec -f` which returns JSON envelope `{"created":...,"data":...,"work_id":"..."}`; `.data` is extracted via jq

Output is written atomically: temp file → `mv` to final `.prom`.

## Key Files

- `pyramid_exporter.sh` — main exporter script (all collectors)
- `install.sh` — installs script, systemd units, validates node_exporter config
- `pyramid-exporter.service` / `.timer` — systemd oneshot + 15s timer

## Testing

No automated tests. Manual verification:

```bash
# Run exporter directly (requires ec_cli on the device)
sudo ./pyramid_exporter.sh
cat /var/lib/node_exporter/textfile_collector/pyramid.prom

# Validate output format
promtool check metrics < /var/lib/node_exporter/textfile_collector/pyramid.prom

# Check metrics via node_exporter
curl -s localhost:9100/metrics | grep pyramid_
```

## Conventions

- All metrics prefixed with `pyramid_`
- Voltages in millivolts, currents in milliamps, temperatures in Celsius, power in watts
- Labels use lowercase: `rail="pcie0"`, `slot="0"`, `zone="0"`
- Metric naming follows Prometheus conventions: `<namespace>_<subsystem>_<unit>`
- Dependencies: `jq`, `ec_cli`, standard coreutils + `awk`
- Config via env vars: `TEXTFILE_DIR`, `EC_TIMEOUT`
