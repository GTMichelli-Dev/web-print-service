#!/bin/bash
# =============================================================================
# Foundation Web Print Service - Self-Install Script for Raspberry Pi / Linux
# =============================================================================
# Bundles the BIXOLON POS CUPS driver pack and provisions the USB
# BIXOLON SRP-F310II ticket printer as a CUPS queue named "TicketPrinter"
# (the default; override with --printer-name). No manual driver install
# or CUPS configuration required.
#
# Recommended flow (run from inside a fresh checkout):
#
#   git clone https://github.com/GTMichelli-Dev/web-print-service.git /tmp/wps
#   sudo bash /tmp/wps/deploy/install.sh http://your-server:5110
#   rm -rf /tmp/wps
#
# When run from inside a checkout, the script builds from local source and
# uses the bundled BIXOLON driver — no further network access needed for
# source. When run standalone, the script clones the repo itself.
#
# Examples:
#   bash install.sh http://basicscale.scaledata.net
#   bash install.sh http://192.168.1.100:5110 --printer-name TicketPrinter
#   bash install.sh http://192.168.1.100:5110 --service-id scalehouse --port 5230
#
# To update an existing install, run the same command again — it stops the
# service, rebuilds, preserves the settings database, and restarts.
# =============================================================================

set -e

# ---- Locate this script's repo checkout (local-source build + bundled drivers) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"  # parent of deploy/

# ---- Defaults ----
SERVICE_ID=""           # blank → falls back to $(hostname) after arg parsing
PRINTER_NAME=""         # blank → prompted (default TicketPrinter) or set via --printer-name
SERVICE_PORT="5230"
INSTALL_DIR="/opt/web-print-service"
SERVICE_NAME="web-print-service"
DOTNET_CHANNEL="10.0"
GITHUB_REPO="GTMichelli-Dev/web-print-service"
BRANCH="master"
WEB_URL=""
PPD_OVERRIDE=""         # optional PPD file path override; defaults to the bundled SRP-F310II PPD
# Default page rotation in degrees (0/90/180/270). The SRP-F310II prints
# 80mm receipts portrait, so no rotation by default. Maps to BIXOLON's
# PPD-specific "Rotation" option AND the generic IPP
# orientation-requested-default; the BIXOLON raster filter honors the PPD
# option, generic filters honor the IPP one.
ROTATION_DEFAULT="0"
# BIXOLON PPD PageSize value — opaque indexed names from the PPD. Default is
# "74X72MMY200MM" = 72mm print width x 200mm receipt. (Do NOT use the 2000mm
# continuous-strip sizes for fixed-page ticket PDFs — CUPS scales the page to
# fill the strip and prints a 3-foot banner.) Inspect alternates with:
#   lpoptions -p TicketPrinter -l | grep -i pagesize
MEDIA_SIZE="74X72MMY200MM"
FORCE_HOSTNAME=""       # set with --force-hostname to skip the generic-hostname check

# ---- Parse arguments ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --service-id)      SERVICE_ID="$2"; shift 2 ;;
        --printer-name)    PRINTER_NAME="$2"; shift 2 ;;
        --port)            SERVICE_PORT="$2"; shift 2 ;;
        --branch)          BRANCH="$2"; shift 2 ;;
        --install-dir)     INSTALL_DIR="$2"; shift 2 ;;
        --ppd)             PPD_OVERRIDE="$2"; shift 2 ;;
        --rotate)          ROTATION_DEFAULT="$2"; shift 2 ;;
        --media-size)      MEDIA_SIZE="$2"; shift 2 ;;
        --force-hostname)  FORCE_HOSTNAME="yes"; shift ;;
        --help|-h)
            cat <<HELP
Usage: install.sh <web-server-url> [options]

  <web-server-url>        Required. URL of the Foundation web server.
                          Examples:
                            http://basicscale.scaledata.net
                            http://192.168.1.100:5110

Options:
  --printer-name <name>   CUPS printer queue name. If omitted, the script
                          prompts interactively with a default of TicketPrinter.
  --service-id <id>       SignalR group ID for this service (default: \$(hostname))
  --port <port>           API port (default: 5230)
  --branch <branch>       Git branch to install (default: master)
  --install-dir <path>    Install location (default: /opt/web-print-service)
  --ppd <path>            Override printer PPD path (default: bundled
                          BIXOLON SRP-F310II PPD)
  --rotate <deg>          Default rotation for the queue (0, 90, 180, 270).
                          Sets BIXOLON's PPD Rotation option and the generic
                          IPP orientation-requested-default fallback.
                          (default: 0 — SRP-F310II receipts print portrait)
  --media-size <ppd-val>  BIXOLON PPD PageSize value for the queue. Default is
                          "74X72MMY200MM" (72mm x 200mm receipt).
                          List alternates on the Pi with:
                              lpoptions -p TicketPrinter -l | grep -i pagesize
  --force-hostname        Skip the check that warns about generic hostnames
                          (raspberrypi, kiosk, localhost, pi, debian, ubuntu)
  --help                  Show this help
HELP
            exit 0
            ;;
        -*)
            echo "Unknown option: $1 (use --help for usage)"
            exit 1
            ;;
        *)
            if [ -z "$WEB_URL" ]; then
                WEB_URL="$1"
            else
                echo "Unknown argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# ---- Interactive prompts for missing inputs ----
# curl is needed to test the URL and to apply settings post-start.
if ! command -v curl > /dev/null 2>&1; then
    echo "Installing curl (needed for URL reachability check)..."
    sudo apt-get update -qq && sudo apt-get install -y -qq curl
fi

# Returns 0 if $1 produces any HTTP response within 5s (200/404/500 — anything
# means the server is up). Returns 1 only on actual connect/dns/timeout errors.
url_reachable() {
    local code
    code=$(curl -s -o /dev/null --max-time 5 --connect-timeout 5 \
        -w "%{http_code}" "$1" 2>/dev/null) || true
    [ -n "$code" ] && [ "$code" != "000" ]
}

if [ -z "$WEB_URL" ]; then
    if [ -t 0 ]; then
        printf "Enter the Foundation web server URL (e.g. http://192.168.1.100:5110): "
        read -r WEB_URL
    fi
    if [ -z "$WEB_URL" ]; then
        echo "ERROR: Web server URL is required."
        echo "Usage: install.sh http://your-server:5110 [--printer-name TicketPrinter]"
        exit 1
    fi
fi

# Reachability check. Non-interactive runs abort on an unreachable URL;
# interactive runs let the operator retype or accept-anyway, since the print
# service retries forever in the background and a greenfield site may not
# have its web app up yet.
while true; do
    if url_reachable "$WEB_URL"; then
        echo "  ${WEB_URL} is reachable."
        break
    fi
    echo "  WARNING: Cannot reach ${WEB_URL} (no HTTP response within 5s)."
    echo "  Check the host, port, and network — and that the web app is running."
    if [ ! -t 0 ]; then
        echo "  Non-interactive shell — aborting. Re-run with a valid URL."
        exit 1
    fi
    printf "  Re-enter URL, or press Enter to continue anyway with '%s': " "$WEB_URL"
    read -r new_url
    if [ -z "$new_url" ]; then
        echo "  Continuing with ${WEB_URL}. The print service will retry until the web app is up."
        break
    fi
    WEB_URL="$new_url"
done

# Prompt for the printer queue name if not provided via --printer-name.
# Default to TicketPrinter; operator can hit Enter to accept.
if [ -z "$PRINTER_NAME" ]; then
    if [ -t 0 ]; then
        printf "Printer queue name [TicketPrinter]: "
        read -r answer
        PRINTER_NAME="${answer:-TicketPrinter}"
    else
        PRINTER_NAME="TicketPrinter"
    fi
fi

# Default ServiceId to the Pi's hostname so each print box in the fleet shows
# up under a unique name on the Foundation Printers page. Override with
# --service-id if you need something specific.
SERVICE_ID_FROM_HOSTNAME=""
if [ -z "$SERVICE_ID" ]; then
    SERVICE_ID="$(hostname)"
    SERVICE_ID_FROM_HOSTNAME="yes"
fi

# ---- Hostname sanity check ----
# ServiceId defaults to the Pi's hostname, so two print boxes with the same
# hostname collide on the same SignalR group: only one connection wins and
# print jobs route unpredictably. Stop here if the hostname looks like a
# fresh-image default. Skipped when the operator passed --service-id.
GENERIC_HOSTNAMES="raspberrypi kiosk localhost pi debian ubuntu linux"
CURRENT_HOSTNAME="$(hostname)"

if [ "$FORCE_HOSTNAME" != "yes" ] && [ "$SERVICE_ID_FROM_HOSTNAME" = "yes" ] && \
   echo "$GENERIC_HOSTNAMES" | tr ' ' '\n' | grep -qx "$CURRENT_HOSTNAME"; then
    cat <<HOSTWARN

============================================
  WARNING: generic hostname '${CURRENT_HOSTNAME}'
============================================
This Pi's hostname is "${CURRENT_HOSTNAME}", one of the common default
names. Every print box in the fleet MUST have a unique hostname — the
install uses it as the SignalR ServiceId, and two boxes sharing a name
will collide: only one connection wins and print jobs may route to the
wrong device or vanish.

To rename the Pi now:
  sudo hostnamectl set-hostname scalehouse-<unique-name>
  sudo nano /etc/hosts            # update the 127.0.1.1 line to match
  sudo reboot
  # re-run this install after the reboot.

Or override the ServiceId for this install only (hostname stays the same):
  bash install.sh ... --service-id scalehouse-<unique-name>

Or bypass this check entirely with --force-hostname.
============================================

HOSTWARN

    if [ -t 0 ]; then
        printf "  Continue with hostname '%s' anyway? [y/N] " "$CURRENT_HOSTNAME"
        read -r answer
        case "$answer" in
            [yY]|[yY][eE][sS])
                echo "  Proceeding with hostname '$CURRENT_HOSTNAME' (you can rename later and re-run)."
                ;;
            *)
                echo "  Aborted. Rename the host and re-run, or pass --force-hostname."
                exit 1
                ;;
        esac
    else
        echo "ERROR: non-interactive shell (no TTY) — cannot prompt for confirmation."
        echo "Pass --force-hostname to skip this check, or rename the Pi first."
        exit 1
    fi
fi

echo ""
echo "============================================"
echo "  Foundation Web Print Service - Install"
echo "============================================"
echo "  Web Server:    ${WEB_URL}"
echo "  Service ID:    ${SERVICE_ID}"
echo "  Hostname:      ${CURRENT_HOSTNAME}"
echo "  Printer Name:  ${PRINTER_NAME}"
echo "  Port:          ${SERVICE_PORT}"
echo "  Install Dir:   ${INSTALL_DIR}"
echo "  Branch:        ${BRANCH}"
echo "============================================"
echo ""

# ---- Detect architecture ----
echo "[1/7] Detecting system..."
ARCH=$(uname -m)
case "$ARCH" in
    aarch64) RID="linux-arm64" ;;
    armv7l)  RID="linux-arm" ;;
    x86_64)  RID="linux-x64" ;;
    *)       echo "WARNING: Unknown arch '${ARCH}', trying linux-arm64"; RID="linux-arm64" ;;
esac
echo "  OS: $(uname -s) $(uname -r)"
echo "  Architecture: ${ARCH} (${RID})"

# ---- Install CUPS ----
echo "[2/7] Installing CUPS..."
if command -v lpstat &> /dev/null && command -v cups-config &> /dev/null; then
    echo "  CUPS already installed."
else
    echo "  Installing CUPS + cups-config (libcups2-dev)..."
    sudo apt-get update -qq
    # libcups2-dev provides cups-config, which the bundled BIXOLON setup
    # script calls to detect the CUPS version. Pulling it in upfront keeps
    # the BIXOLON install non-interactive.
    sudo apt-get install -y -qq cups libcups2-dev
    echo "  CUPS installed."
fi

# Add the real (non-root) user who invoked sudo to lpadmin so they can
# administer CUPS at http://<pi>:631 without using root. $USER under sudo
# is "root" — fall back to $SUDO_USER for the real account.
LPADMIN_USER="${SUDO_USER:-$USER}"
if [ -n "${LPADMIN_USER}" ] && [ "${LPADMIN_USER}" != "root" ]; then
    if ! id -nG "${LPADMIN_USER}" 2>/dev/null | tr ' ' '\n' | grep -qx 'lpadmin'; then
        sudo usermod -aG lpadmin "${LPADMIN_USER}"
        echo "  Added ${LPADMIN_USER} to lpadmin group (CUPS admin)."
        echo "  NOTE: ${LPADMIN_USER} must log out and back in (or run 'newgrp lpadmin') for this to take effect."
    else
        echo "  ${LPADMIN_USER} already in lpadmin group (CUPS admin)."
    fi
fi

sudo systemctl enable cups 2>/dev/null || true
sudo systemctl start cups 2>/dev/null || true

# Open the CUPS web admin to the LAN so a tech can reach this box's CUPS UI
# from another machine:
#   WebInterface=Yes  explicitly turns the /admin and / pages on
#   --remote-admin    makes the admin UI reachable from other hosts
#   --remote-any      accepts connections from any network (not just localhost)
#   --share-printers  advertises queues on the network
# Safe for a trusted internal scale-house network; tighten cupsd.conf
# <Location> blocks if the box ever moves to a less-trusted segment.
sudo cupsctl WebInterface=Yes --remote-admin --remote-any --share-printers 2>/dev/null || \
    echo "  WARNING: cupsctl failed; CUPS admin may only be reachable from localhost."

# Stamp the host's name into CUPS so the box identity is visible on the
# CUPS web UI itself.
sudo cupsctl "ServerName=${CURRENT_HOSTNAME}" 2>/dev/null || \
    echo "  WARNING: failed to set CUPS ServerName=${CURRENT_HOSTNAME}."

PI_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo "  CUPS running. Admin UI: http://${PI_IP:-localhost}:631"

# Open firewall ports for the service API/Swagger and the CUPS web admin
# (Pi OS ships with no firewall, but a site-hardened image may have ufw or
# iptables rules that would block them)
if command -v ufw &> /dev/null && sudo ufw status | grep -q "active"; then
    sudo ufw allow 22/tcp > /dev/null
    sudo ufw allow "${SERVICE_PORT}"/tcp > /dev/null
    sudo ufw allow 631/tcp > /dev/null
    echo "  Firewall: ufw — ports 22, ${SERVICE_PORT}, 631 opened."
fi

if command -v iptables &> /dev/null; then
    for fw_port in "${SERVICE_PORT}" 631; do
        sudo iptables -C INPUT -p tcp --dport "$fw_port" -j ACCEPT 2>/dev/null || \
            sudo iptables -I INPUT -p tcp --dport "$fw_port" -j ACCEPT
    done
    echo "  Firewall: iptables — ports ${SERVICE_PORT} and 631 opened."

    # Persist iptables rules across reboots
    if command -v netfilter-persistent &> /dev/null; then
        sudo netfilter-persistent save 2>/dev/null || true
    elif command -v iptables-save &> /dev/null; then
        sudo mkdir -p /etc/iptables
        sudo sh -c 'iptables-save > /etc/iptables/rules.v4' 2>/dev/null || true
    fi
    echo "  Firewall: rules saved for reboot persistence."
fi

# ---- Install bundled BIXOLON POS CUPS driver pack ----
# Looks for deploy/drivers/bixolon-cups/Software_BxlPOSCupsDrv_Linux_*.tgz
# inside the script's checkout. Skips if the SRP-F310II PPD is already there.
BIXOLON_DRIVERS_DIR="${SOURCE_DIR}/deploy/drivers/bixolon-cups"
PPD_DEFAULT="/usr/share/cups/model/Bixolon/SRPF310II_v1.0.4.ppd"

if [ -f "${PPD_DEFAULT}" ]; then
    echo "  BIXOLON SRP-F310II PPD already present (${PPD_DEFAULT})."
elif compgen -G "${BIXOLON_DRIVERS_DIR}"/Software_BxlPOSCupsDrv_Linux_*.tgz > /dev/null; then
    BIXOLON_TGZ=$(ls "${BIXOLON_DRIVERS_DIR}"/Software_BxlPOSCupsDrv_Linux_*.tgz | sort | tail -1)
    echo "  Installing BIXOLON CUPS driver pack from $(basename "${BIXOLON_TGZ}")..."
    BIXOLON_EXTRACT=$(mktemp -d)
    tar xzf "${BIXOLON_TGZ}" -C "${BIXOLON_EXTRACT}"
    BIXOLON_SETUP=$(find "${BIXOLON_EXTRACT}" -maxdepth 3 -name 'setup_*.sh' -type f | head -1)
    if [ -n "${BIXOLON_SETUP}" ]; then
        # The BIXOLON setup script uses relative paths (./filters/, ./Bixolon/),
        # so it MUST run with its containing directory as CWD. Subshell + cd
        # keeps the rest of install.sh's CWD intact. Pipe /dev/null in case the
        # script prompts.
        BIXOLON_SETUP_DIR=$(dirname "${BIXOLON_SETUP}")
        BIXOLON_SETUP_NAME=$(basename "${BIXOLON_SETUP}")
        (
            cd "${BIXOLON_SETUP_DIR}" && \
                sudo bash "./${BIXOLON_SETUP_NAME}" < /dev/null
        ) || echo "  WARNING: BIXOLON setup script returned non-zero; check ${PPD_DEFAULT}."
        if [ -f "${PPD_DEFAULT}" ]; then
            echo "  BIXOLON PPDs installed under /usr/share/cups/model/Bixolon."
        fi
    else
        echo "  WARNING: no setup_*.sh found inside ${BIXOLON_TGZ}."
    fi
    rm -rf "${BIXOLON_EXTRACT}"
else
    echo "  No bundled BIXOLON driver pack found at ${BIXOLON_DRIVERS_DIR}."
    echo "  PDFs will not render unless --ppd points to a valid PPD."
fi

# ---- Install .NET 8 ----
echo "[3/7] Installing .NET runtime..."
DOTNET_ROOT="$HOME/.dotnet"

if [ -x "$DOTNET_ROOT/dotnet" ]; then
    DOTNET_VER=$("$DOTNET_ROOT/dotnet" --version 2>/dev/null || echo "unknown")
    echo "  .NET already installed: ${DOTNET_VER}"
elif command -v dotnet &> /dev/null; then
    DOTNET_VER=$(dotnet --version 2>/dev/null || echo "unknown")
    DOTNET_ROOT=$(dirname "$(which dotnet)")
    echo "  .NET already installed: ${DOTNET_VER}"
else
    echo "  Downloading .NET ${DOTNET_CHANNEL} ASP.NET Core runtime..."
    sudo apt-get install -y -qq curl libicu-dev 2>/dev/null || true
    curl -sSL https://dot.net/v1/dotnet-install.sh | bash /dev/stdin \
        --channel ${DOTNET_CHANNEL} \
        --runtime aspnetcore \
        --install-dir "$DOTNET_ROOT"
    echo "  .NET installed: $($DOTNET_ROOT/dotnet --version)"
fi

export PATH="$DOTNET_ROOT:$PATH"
export DOTNET_ROOT

if ! grep -q 'DOTNET_ROOT' "$HOME/.bashrc" 2>/dev/null; then
    echo "" >> "$HOME/.bashrc"
    echo "# .NET" >> "$HOME/.bashrc"
    echo "export DOTNET_ROOT=$DOTNET_ROOT" >> "$HOME/.bashrc"
    echo 'export PATH=$DOTNET_ROOT:$PATH' >> "$HOME/.bashrc"
    echo "  Added .NET to PATH in .bashrc"
fi

# ---- Install SDK for building (if not present) ----
echo "[4/7] Downloading and building Web Print Service..."

# Does a matching SDK already exist? Match the MAJOR version of DOTNET_CHANNEL
# (e.g. "8" from "8.0") — `dotnet --list-sdks` prints lines like
# "8.0.301 [/path]".
DOTNET_MAJOR="${DOTNET_CHANNEL%%.*}"
HAS_SDK=false
if dotnet --list-sdks 2>/dev/null | grep -q "^${DOTNET_MAJOR}\."; then
    HAS_SDK=true
fi

sudo systemctl stop ${SERVICE_NAME} 2>/dev/null || true

sudo mkdir -p "${INSTALL_DIR}"
# Recursive: a prior sudo'd install leaves published DLLs inside INSTALL_DIR
# owned by root, so a non-root `dotnet publish -o` can't overwrite them.
sudo chown -R "$USER:$USER" "${INSTALL_DIR}"

# Backup existing settings database
DB_BACKUP=""
if [ -f "${INSTALL_DIR}/webprintservice.db" ]; then
    DB_BACKUP="/tmp/webprintservice-db-backup.db"
    cp "${INSTALL_DIR}/webprintservice.db" "$DB_BACKUP"
    echo "  Backed up existing settings database."
fi

# Build from local checkout when available; otherwise clone. The local-source
# path is preferred — re-runs and offline rebuilds work without re-cloning.
CLONE_DIR=""
if [ -f "${SOURCE_DIR}/PiPrintService.csproj" ]; then
    BUILD_DIR="${SOURCE_DIR}"
    echo "  Building from local source: ${BUILD_DIR}"
    # A prior sudo'd run can leave obj/ or bin/ owned by root, breaking a
    # non-root `dotnet publish`. Reclaim ownership before restoring.
    sudo chown -R "$(id -un):$(id -gn)" "${BUILD_DIR}" 2>/dev/null || true
else
    sudo apt-get install -y -qq git 2>/dev/null || true
    CLONE_DIR=$(mktemp -d)
    BUILD_DIR="${CLONE_DIR}"
    echo "  Cloning ${GITHUB_REPO} (${BRANCH})..."
    git clone --depth 1 --branch "${BRANCH}" "https://github.com/${GITHUB_REPO}.git" "${CLONE_DIR}"
fi

if [ "$HAS_SDK" = true ]; then
    echo "  .NET SDK already installed."
else
    # The SDK install writes into DOTNET_ROOT. If the runtime we detected lives
    # in a root-owned system dir, this script — run as the unprivileged Pi
    # user — can't write there. Fall back to a writable per-user SDK at
    # $HOME/.dotnet and re-point DOTNET_ROOT at it.
    if [ ! -w "$DOTNET_ROOT" ]; then
        echo "  DOTNET_ROOT '$DOTNET_ROOT' is not writable by $(id -un) — installing the SDK to \$HOME/.dotnet instead."
        DOTNET_ROOT="$HOME/.dotnet"
        mkdir -p "$DOTNET_ROOT"
        export DOTNET_ROOT
        export PATH="$DOTNET_ROOT:$PATH"
    fi
    echo "  Installing .NET SDK permanently (reused on future updates)..."
    curl -sSL https://dot.net/v1/dotnet-install.sh | bash /dev/stdin \
        --channel ${DOTNET_CHANNEL} \
        --install-dir "$DOTNET_ROOT"
    echo "  .NET SDK installed to $DOTNET_ROOT"
fi

echo "  Building..."
dotnet publish "${BUILD_DIR}/PiPrintService.csproj" \
    -c Release \
    -r "${RID}" \
    --self-contained true \
    -o "${INSTALL_DIR}" \
    -p:PublishSingleFile=false \
    -p:PublishTrimmed=false

[ -n "${CLONE_DIR}" ] && rm -rf "${CLONE_DIR}"

# Restore settings database if it existed
if [ -n "$DB_BACKUP" ] && [ -f "$DB_BACKUP" ]; then
    cp "$DB_BACKUP" "${INSTALL_DIR}/webprintservice.db"
    rm "$DB_BACKUP"
    echo "  Restored existing settings database."
fi

chmod +x "${INSTALL_DIR}/PiPrintService" 2>/dev/null || true

# ---- Configure ----
echo "[5/7] Configuring..."

# Update appsettings.json. ASP.NET's JSON config tolerates // comments, so we
# can't assume json.load will parse it. Use sed for an in-place edit that
# preserves comments and only touches the fields we own.
if [ -f "${INSTALL_DIR}/appsettings.json" ]; then
    ESCAPED_URL=$(printf '%s' "${WEB_URL}" | sed 's/[&|\\]/\\&/g')
    sed -i "s|\"ServerUrl\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"ServerUrl\": \"${ESCAPED_URL}\"|" \
        "${INSTALL_DIR}/appsettings.json"
    sed -i "s|\"Port\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"Port\": \"${SERVICE_PORT}\"|" \
        "${INSTALL_DIR}/appsettings.json"
    echo "  Updated appsettings.json"
fi

# ---- BIXOLON SRP-F310II USB printer setup ----
echo "[6/7] Setting up BIXOLON SRP-F310II USB printer '${PRINTER_NAME}'..."

# Find a USB device URI — prefer a Bixolon match, otherwise first USB device.
PRINTER_USB=""
if command -v lpinfo &> /dev/null; then
    PRINTER_USB=$(sudo lpinfo -v 2>/dev/null | awk '/usb:\/\// && /BIXOLON/ {print $2; exit}')
    if [ -z "$PRINTER_USB" ]; then
        PRINTER_USB=$(sudo lpinfo -v 2>/dev/null | awk '/usb:\/\// {print $2; exit}')
    fi
fi
if [ -z "$PRINTER_USB" ]; then
    PRINTER_USB="usb://BIXOLON/SRP-F310II"
    echo "  WARNING: no USB printer detected — using placeholder URI ${PRINTER_USB}."
    echo "  Plug the printer in and re-run this script (or fix the URI in CUPS admin)."
fi

# Pick a driver: explicit --ppd > bundled SRP-F310II PPD > lpinfo model match > raw.
DRIVER_FLAG="-m raw"
PPD_FILE="$PPD_OVERRIDE"
if [ -z "$PPD_FILE" ] && [ -f "$PPD_DEFAULT" ]; then
    PPD_FILE="$PPD_DEFAULT"
fi
if [ -n "$PPD_FILE" ] && [ -f "$PPD_FILE" ]; then
    DRIVER_FLAG="-P $PPD_FILE"
    echo "  Using PPD: $PPD_FILE"
elif command -v lpinfo &> /dev/null; then
    PRINTER_MODEL=$(sudo lpinfo -m 2>/dev/null | awk '/BIXOLON.*F310II/ {print $1; exit}')
    if [ -n "$PRINTER_MODEL" ]; then
        DRIVER_FLAG="-m $PRINTER_MODEL"
        echo "  Using CUPS model: $PRINTER_MODEL"
    else
        echo "  No BIXOLON SRP-F310II PPD found in CUPS — using raw queue."
        echo "  (Pass --ppd /path/to/SRPF310II.ppd to use the BIXOLON driver.)"
    fi
fi

if lpstat -p "$PRINTER_NAME" &> /dev/null; then
    echo "  Printer '$PRINTER_NAME' already exists — updating device URI..."
else
    echo "  Adding printer '$PRINTER_NAME' on $PRINTER_USB..."
fi
sudo lpadmin -p "$PRINTER_NAME" -v "$PRINTER_USB" $DRIVER_FLAG -E

# Set the default page rotation for this queue. The BIXOLON raster filter
# only honors its own PPD "Rotation" option (0NoRotation, 1Rotate90,
# 2Rotate180, 3Rotate270) — the generic IPP orientation-requested-default is
# ignored. We set both so non-BIXOLON fallback PPDs still rotate.
case "$ROTATION_DEFAULT" in
    0)   PPD_ROTATION="0NoRotation"; IPP_ORIENTATION="3"; ROTATION_LABEL="0 deg (portrait)" ;;
    90)  PPD_ROTATION="1Rotate90";   IPP_ORIENTATION="4"; ROTATION_LABEL="90 deg (landscape)" ;;
    180) PPD_ROTATION="2Rotate180";  IPP_ORIENTATION="6"; ROTATION_LABEL="180 deg (reverse portrait)" ;;
    270) PPD_ROTATION="3Rotate270";  IPP_ORIENTATION="5"; ROTATION_LABEL="270 deg (reverse landscape)" ;;
    *)
        echo "  WARNING: --rotate '${ROTATION_DEFAULT}' must be 0, 90, 180, or 270. Using 0."
        PPD_ROTATION="0NoRotation"; IPP_ORIENTATION="3"; ROTATION_LABEL="0 deg (portrait, fallback)"
        ;;
esac
sudo lpadmin -p "$PRINTER_NAME" \
    -o "Rotation=${PPD_ROTATION}" \
    -o "orientation-requested-default=${IPP_ORIENTATION}" \
    -o "PageSize=${MEDIA_SIZE}" \
    -o "fit-to-page=true" \
    -L "Scale house: ${CURRENT_HOSTNAME}" \
    -D "${PRINTER_NAME} on ${CURRENT_HOSTNAME}"
echo "  Default rotation: ${ROTATION_LABEL}."
echo "  Default media size: ${MEDIA_SIZE}."

sudo cupsenable "$PRINTER_NAME" 2>/dev/null || true
sudo cupsaccept "$PRINTER_NAME" 2>/dev/null || true
sudo lpadmin -d "$PRINTER_NAME" 2>/dev/null || true
echo "  Printer '$PRINTER_NAME' configured (default queue)."

# ---- Create systemd service ----
echo "[7/7] Setting up systemd service..."

if [ -f "${INSTALL_DIR}/PiPrintService" ]; then
    EXEC="${INSTALL_DIR}/PiPrintService"
else
    EXEC="${DOTNET_ROOT}/dotnet ${INSTALL_DIR}/PiPrintService.dll"
fi

sudo tee /etc/systemd/system/${SERVICE_NAME}.service > /dev/null << UNIT
[Unit]
Description=Foundation Web Print Service
After=network.target cups.service
Wants=cups.service

[Service]
Type=simple
ExecStart=${EXEC}
WorkingDirectory=${INSTALL_DIR}
Restart=always
RestartSec=5
User=${USER}
Environment=DOTNET_ROOT=${DOTNET_ROOT}
Environment=ASPNETCORE_URLS=http://0.0.0.0:${SERVICE_PORT}
Environment=DOTNET_ENVIRONMENT=Production

NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable ${SERVICE_NAME}
sudo systemctl start ${SERVICE_NAME}

sleep 3

# ---- Apply ServiceId + ServerUrl through the service's own settings API ----
# The settings live in the service's SQLite db, which survives updates — so a
# re-run with a new URL or service-id must push the values through the API
# (which also triggers a SignalR reconnect). Retry briefly while the service
# finishes starting.
SETTINGS_APPLIED="no"
for _ in 1 2 3 4 5; do
    if curl -s -X PUT "http://localhost:${SERVICE_PORT}/api/settings" \
        -H 'Content-Type: application/json' \
        -d "{\"serviceId\": \"${SERVICE_ID}\", \"serverUrl\": \"${WEB_URL}\"}" \
        -o /dev/null --max-time 5 -w '%{http_code}' 2>/dev/null | grep -q '^200$'; then
        SETTINGS_APPLIED="yes"
        break
    fi
    sleep 2
done
if [ "$SETTINGS_APPLIED" = "yes" ]; then
    echo "  Applied settings (ServiceId=${SERVICE_ID}, ServerUrl=${WEB_URL})."
else
    echo "  WARNING: could not apply settings via the API. Apply manually with:"
    echo "    curl -X PUT http://localhost:${SERVICE_PORT}/api/settings \\"
    echo "      -H 'Content-Type: application/json' \\"
    echo "      -d '{\"serviceId\": \"${SERVICE_ID}\", \"serverUrl\": \"${WEB_URL}\"}'"
fi

echo ""
if sudo systemctl is-active --quiet ${SERVICE_NAME}; then
    echo "============================================"
    echo "  Install Complete!"
    echo "============================================"
    echo "  Service URL:  http://$(hostname -I | awk '{print $1}'):${SERVICE_PORT}"
    echo "  Swagger:      http://$(hostname -I | awk '{print $1}'):${SERVICE_PORT}/swagger"
    echo "  Web Server:   ${WEB_URL}"
    echo "  Service ID:   ${SERVICE_ID}"
    echo "  Printer:      ${PRINTER_NAME} (BIXOLON SRP-F310II, USB)"
    echo ""
    echo "  CUPS Admin:   http://${PI_IP:-localhost}:631"
    echo ""
    echo "  Commands:"
    echo "    sudo systemctl status ${SERVICE_NAME}"
    echo "    sudo systemctl restart ${SERVICE_NAME}"
    echo "    sudo journalctl -u ${SERVICE_NAME} -f"
    echo "    lpstat -p ${PRINTER_NAME}"
    echo "    echo 'Printer test' | lp -d ${PRINTER_NAME}"
    echo ""
    echo "  Next: open Foundation's Setup -> Printers page and assign"
    echo "  '${SERVICE_ID}:${PRINTER_NAME}' as the inbound/outbound printer."
    echo "  (If this box previously registered under a different service id,"
    echo "  re-save the printer assignments.)"
    echo ""
    echo "  To update later, run this command again."
    echo "============================================"
else
    echo "============================================"
    echo "  WARNING: Service may not have started."
    echo "============================================"
    echo "  Check logs:"
    echo "    sudo journalctl -u ${SERVICE_NAME} -n 30 --no-pager"
    echo "============================================"
fi
