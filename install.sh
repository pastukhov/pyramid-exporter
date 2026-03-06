#!/usr/bin/env bash
# install.sh — Install pyramid_exporter for node_exporter textfile collector
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_BIN="/usr/local/bin/pyramid_exporter.sh"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
SYSTEMD_DIR="/etc/systemd/system"

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run as root (sudo $0)" >&2
    exit 1
fi

for cmd in jq ec_cli; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not found in PATH" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

echo "Installing pyramid_exporter.sh → ${INSTALL_BIN}"
install -m 0755 "${SCRIPT_DIR}/pyramid_exporter.sh" "$INSTALL_BIN"

echo "Creating textfile collector directory: ${TEXTFILE_DIR}"
mkdir -p "$TEXTFILE_DIR"

echo "Installing systemd units → ${SYSTEMD_DIR}"
cp "${SCRIPT_DIR}/pyramid-exporter.service" "${SYSTEMD_DIR}/pyramid-exporter.service"
cp "${SCRIPT_DIR}/pyramid-exporter.timer" "${SYSTEMD_DIR}/pyramid-exporter.timer"

systemctl daemon-reload
systemctl enable --now pyramid-exporter.timer

echo ""
echo "Installed. Timer status:"
systemctl status pyramid-exporter.timer --no-pager || true

# ---------------------------------------------------------------------------
# Verify node_exporter textfile collector
# ---------------------------------------------------------------------------

echo ""
if systemctl is-active --quiet node_exporter 2>/dev/null; then
    if grep -q -- '--collector.textfile.directory' /etc/default/node_exporter 2>/dev/null ||
       grep -q -- '--collector.textfile.directory' /etc/sysconfig/node_exporter 2>/dev/null ||
       systemctl cat node_exporter 2>/dev/null | grep -q -- '--collector.textfile.directory'; then
        echo "node_exporter textfile collector: OK"
    else
        echo "WARNING: node_exporter is running but --collector.textfile.directory"
        echo "         may not be configured. Add this flag pointing to:"
        echo "         ${TEXTFILE_DIR}"
    fi
else
    echo "NOTE: node_exporter is not running. Make sure it is configured with:"
    echo "      --collector.textfile.directory=${TEXTFILE_DIR}"
fi

echo ""
echo "Done. Test manually:  sudo ${INSTALL_BIN} && cat ${TEXTFILE_DIR}/pyramid.prom"
