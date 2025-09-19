#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# BASH SCRIPT - Main Logic
# ==============================================================================

# --- Auto-detect and use a local Python virtual environment ---
PYTHON_CMD="python3"
if [[ -d ".venv" ]]; then
    echo "Local Python virtual environment '.venv' found. Using it."
    PYTHON_CMD=".venv/bin/python3"
    if [[ ! -x "$PYTHON_CMD" ]]; then
        echo "Error: .venv/bin/python3 not found or not executable." >&2
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# Embedded Python Script Function
# ------------------------------------------------------------------------------
# This Bash function executes the Python script defined below in a heredoc.
# It pipes the Python code directly to the Python interpreter.
# The special "$@" syntax forwards all arguments from this Bash function
# to the Python script, where they become accessible via sys.argv.
# ------------------------------------------------------------------------------
generate_certificate_pdf() {
    "$PYTHON_CMD" - "$@" <<'EOF_PYTHON'
#!/usr/bin/env python3
"""
Generates a PDF wipe certificate using the WeasyPrint library.
This script is embedded within a parent Bash script.
"""
import sys
import os
import datetime
import subprocess
import json
import socket

try:
    from weasyprint import HTML
except ImportError:
    print("Error: WeasyPrint library not found.", file=sys.stderr)
    print("Please install it (ideally in a venv): pip install WeasyPrint", file=sys.stderr)
    sys.exit(1)

def get_device_details(device_path):
    """Uses lsblk to get detailed information about a block device as a pre-formatted string."""
    try:
        cmd = [
            "lsblk", "-d", "-o", "NAME,SIZE,MODEL,SERIAL,TYPE",
            "--bytes", "--json", device_path
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        details_json = json.loads(result.stdout)
        pretty_details = json.dumps(details_json['blockdevices'][0], indent=4)
        return pretty_details
    except (subprocess.CalledProcessError, FileNotFoundError, json.JSONDecodeError, IndexError) as e:
        return f"Could not retrieve device details for '{device_path}'.\nReason: {e}"
    except Exception as e:
        return f"An unexpected error occurred: {e}"

def generate_pdf_certificate(device_path, output_base, wipe_method, verification_hash, mode):
    """Generates the wipe certificate as a PDF file."""
    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    hostname = socket.gethostname()
    try:
        user = os.getlogin()
    except OSError:
        user = f"uid:{os.geteuid()}"

    device_details = get_device_details(device_path)
    output_filename = f"{output_base}_certificate.pdf"

    dry_run_html_banner = ""
    cert_execution_mode = "LIVE"
    if mode.lower() == "dry":
        dry_run_html_banner = """
        <div class="dry-run-banner">
            <h2>DRY RUN MODE</h2>
            <p>This certificate was generated from a dry run. No destructive operations were performed on the device.</p>
        </div>
        """
        cert_execution_mode = "DRY"

    html_content = f"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <title>Secure Data Wipe Certificate for {device_path}</title>
        <style>
            body {{ font-family: sans-serif; font-size: 12pt; line-height: 1.5; color: #333; }}
            .container {{ border: 2px solid #000; padding: 20px 40px; margin: 20px; }}
            h1 {{ text-align: center; border-bottom: 2px solid #ccc; padding-bottom: 10px; margin-bottom: 20px; font-size: 24pt; }}
            h2 {{ font-size: 16pt; color: #555; border-bottom: 1px solid #eee; padding-bottom: 5px; }}
            .dry-run-banner {{ border: 3px dashed #d9534f; background-color: #f2dede; color: #a94442; padding: 10px 20px; text-align: center; margin-bottom: 20px; }}
            .details-grid {{ display: grid; grid-template-columns: 200px 1fr; gap: 5px 20px; margin-bottom: 20px; }}
            .details-grid b {{ font-weight: bold; }}
            .mono {{ font-family: monospace; background-color: #f5f5f5; padding: 15px; border: 1px solid #ccc; border-radius: 4px; white-space: pre-wrap; word-wrap: break-word; }}
        </style>
    </head>
    <body>
        <div class="container">
            {dry_run_html_banner}
            <h1>Secure Data Wipe Certificate</h1>
            <h2>Operation Details</h2>
            <div class="details-grid">
                <b>Wipe Timestamp (UTC):</b> <span>{timestamp}</span>
                <b>Wipe Method Employed:</b> <span>{wipe_method}</span>
                <b>Executing Hostname:</b> <span>{hostname}</span>
                <b>Executing User:</b> <span>{user}</span>
                <b>Execution Mode:</b> <span>{cert_execution_mode}</span>
            </div>
            <h2>Device Information</h2>
            <div class="details-grid">
                <b>Device Path:</b> <span>{device_path}</span>
            </div>
            <pre class="mono">{device_details}</pre>
            <h2>Verification</h2>
            <p>Post-wipe sample hash (SHA256) of the first 4096 bytes:</p>
            <pre class="mono">{verification_hash}</pre>
        </div>
    </body>
    </html>
    """
    try:
        HTML(string=html_content).write_pdf(output_filename)
        print(f"Successfully generated PDF certificate: {output_filename}")
    except Exception as e:
        print(f"Error: Could not write PDF certificate '{output_filename}'. Reason: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) != 6:
        print(f"Usage: SCRIPT_FROM_BASH <device_path> <output_base> \"<wipe_method>\" <verification_hash> <mode>", file=sys.stderr)
        sys.exit(1)
    dev_path, out_base, method, v_hash, mode = sys.argv[1:6]
    generate_pdf_certificate(dev_path, out_base, method, v_hash, mode)
EOF_PYTHON
}

# ------------------------------------------------------------------------------
# Main Script Logic (continued)
# ------------------------------------------------------------------------------
MODE="live"
CERT_MODE="live"
DEVICE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry)
            MODE="dry"; CERT_MODE="dry"; shift ;;
        --simulate)
            MODE="dry"; CERT_MODE="live"; shift ;;
        --live)
            MODE="live"; CERT_MODE="live"; shift ;;
        -*)
            echo "Unknown flag: $1"; echo "Usage: $0 [--dry|--simulate|--live] /dev/DEVICE"; exit 1 ;;
        *)
            if [[ -n "$DEVICE" ]]; then echo "Error: Multiple devices specified."; exit 1; fi
            DEVICE="$1"; shift ;;
    esac
done

if [[ -z "$DEVICE" ]]; then
    echo "Error: Device not specified."; echo "Usage: $0 [--dry|--simulate|--live] /dev/DEVICE"; exit 1
fi
if [[ "$MODE" == "live" && ! -b "$DEVICE" ]]; then
    echo "Error: In live mode, '$DEVICE' must be a valid block device."; exit 1
fi

echo "Execution Mode: $MODE (Certificate Mode: $CERT_MODE)"
echo "Detected device: $DEVICE"
lsblk -o NAME,SIZE,MODEL,TYPE,SERIAL,MOUNTPOINT "$DEVICE" || true

read -p "Type YES to confirm you want to proceed with device '$DEVICE': " CONF
CONF=$(echo "$CONF" | tr '[:lower:]' '[:upper:]')
if [[ "$CONF" != "YES" ]]; then echo "Aborting"; exit 1; fi

run_cmd() {
    if [[ "$MODE" == "dry" ]]; then printf "[DRY] %s\n" "$*"; else "$@"; fi
}

WIPE_METHOD=""
if [[ "$(basename "$DEVICE")" =~ ^nvme ]]; then
    WIPE_METHOD="NVMe Format (Cryptographic Erase, SES=1)"; run_cmd nvme format "$DEVICE" -s 1
else
    if command -v hdparm >/dev/null; then
        WIPE_METHOD="hdparm ATA Secure Erase"; run_cmd hdparm --user-master u --security-set-pass PASS "$DEVICE"; run_cmd hdparm --user-master u --security-erase PASS "$DEVICE"
    else
        WIPE_METHOD="shred (3 passes, pseudorandom)"; run_cmd shred -v -n 3 "$DEVICE"
    fi
fi

echo "After-wipe verification sample:"
VERIFICATION_HASH=""
if [[ "$CERT_MODE" == "dry" ]]; then
    VERIFICATION_HASH="<not-run-in-dry-mode>"; echo "[DRY] Hash: $VERIFICATION_HASH"
else
    echo "Reading first 4K of device to generate hash..."; VERIFICATION_HASH=$(dd if="$DEVICE" bs=4096 count=1 2>/dev/null | sha256sum | awk '{print $1}'); echo "Hash: $VERIFICATION_HASH"
fi

CERT_FILENAME_BASE="wipe_$(basename "$DEVICE")_$(date +%Y%m%d_%H%M%S)"
echo "Generating wipe certificate..."

if ! "$PYTHON_CMD" -c "import weasyprint" &>/dev/null; then
    echo "ERROR: Python dependency 'WeasyPrint' is not installed." >&2; exit 1
fi

# Call the Bash function which in turn executes the embedded Python script
generate_certificate_pdf "$DEVICE" "$CERT_FILENAME_BASE" "$WIPE_METHOD" "$VERIFICATION_HASH" "$CERT_MODE"
