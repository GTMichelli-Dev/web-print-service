# Web Print Service

A cross-platform .NET 8.0 print service that connects to a web application via SignalR and provides remote printing. Automatically detects the operating system and uses **Windows Print** (PowerShell/WMI) on Windows or **CUPS** (`lpstat`, `lp`) on Linux/macOS.

## Architecture

### Windows
```
Web App (BasicWeigh, etc.)
    |
    +-- SignalR Hub (/scaleHub)
            |
            +-- Web Print Service (this)
                    |
                    +-- Windows Print (PowerShell Get-Printer / Start-Process)
                            |
                            +-- Physical Printer (USB, Network, Shared)
```

### Linux / macOS / Raspberry Pi
```
Web App (BasicWeigh, etc.)
    |
    +-- SignalR Hub (/scaleHub)
            |
            +-- Web Print Service (this)
                    |
                    +-- CUPS (lpstat, lp, lpoptions)
                            |
                            +-- Physical Printer (USB, Network, IPP)
```

## Features

- **Cross-Platform** — automatically uses Windows Print or CUPS based on the OS
- **Windows Integration** — uses PowerShell `Get-Printer`, `Start-Process`, `Out-Printer` to manage and print to local and network printers
- **CUPS Integration** — uses `lpstat`, `lp`, `lpoptions` to manage and print to local printers on Linux/macOS
- **SignalR Connection** — connects to any web app's SignalR hub (outbound only, works behind firewalls)
- **Printer Discovery** — announces available CUPS or Windows printers to the web app on connect/reconnect
- **PDF Printing** — downloads ticket PDFs from the web app and prints locally
- **Test Print** — send a test page to any connected printer from the web UI
- **Swagger API** — local REST API for configuration, testing, and diagnostics
- **SQLite Settings** — persistent configuration stored locally (no appsettings.json edits needed)
- **Forever Retry** — exponential backoff, never gives up reconnecting

## Quick Start

```bash
# Windows
cd WebPrintService
dotnet run

# Linux / Raspberry Pi
sudo apt-get install cups
dotnet run
```

## Endpoints (Swagger at http://<your-ip>:<your-port>/swagger)

### Health & Status

#### `GET /api/status/health`
Returns service health, print system type, and printer count.

**Response:**
```json
{
  "status": "ok",
  "printSystem": "Windows",
  "printSystemAvailable": true,
  "printerCount": 3,
  "printers": [
    { "printerId": "HP LaserJet", "displayName": "HP LaserJet", "status": "idle", "enabled": true, "isDefault": true }
  ]
}
```

#### `GET /api/readme`
Returns API documentation as JSON including all endpoints, parameters, response formats, and SignalR methods.

---

### Printers

#### `GET /api/printers`
List all printers with their status.

**Response:**
```json
[
  {
    "printerId": "HP_LaserJet_Pro",
    "displayName": "HP LaserJet Pro",
    "status": "idle",
    "isDefault": true,
    "enabled": true
  }
]
```

#### `GET /api/printers/{printerId}/status`
Get detailed status of a specific printer.

**Example:** `GET /api/printers/HP_LaserJet_Pro/status`

**Response:**
```json
{
  "printerId": "HP_LaserJet_Pro",
  "status": "printer HP_LaserJet_Pro is idle. enabled since Mon 24 Mar 2026 08:00:00 AM CDT"
}
```

#### `POST /api/printers/{printerId}/test`
Send a test page to a printer. No request body needed.

**Example:** `POST /api/printers/HP_LaserJet_Pro/test`

**Response:**
```json
{
  "success": true,
  "message": "Sent to HP_LaserJet_Pro"
}
```

---

### Settings

#### `GET /api/settings`
Get current service settings.

**Response:**
```json
{
  "id": 1,
  "serviceId": "default",
  "serverUrl": "http://localhost:5110",
  "signalRHub": "/scaleHub"
}
```

#### `PUT /api/settings`
Update service settings. Triggers a reconnect to the web app.

**Request:**
```json
{
  "serviceId": "office-printer",
  "serverUrl": "http://192.168.1.100:5110"
}
```

**Response:**
```json
{
  "success": true,
  "message": "Settings saved. Service restarting..."
}
```

---

## SignalR Methods

| Direction | Method | Description |
|-----------|--------|-------------|
| Service -> Hub | `JoinPrintGroup(serviceId)` | Join the PrintClients group |
| Service -> Hub | `PrintServiceReady(announcement)` | Announce printers on connect |
| Service -> Hub | `PrinterListResponse(data)` | Respond to printer list request |
| Service -> Hub | `PrintResult(result)` | Report print job result |
| Service -> Hub | `TestPrintResult(result)` | Report test print result |
| Hub -> Service | `PrintTicket(data)` | Print a ticket PDF |
| Hub -> Service | `GetPrinterList` | Request printer list |
| Hub -> Service | `TestPrint(printerId)` | Send test page to printer |
| Hub -> Service | `ReloadConfig` | Restart the service |

## Platform Details

### Windows
Uses PowerShell commands:
- `Get-Printer` — enumerate all local and network printers
- `Start-Process -Verb PrintTo` — print PDFs (or SumatraPDF if installed)
- `Out-Printer` — print text files
- `rundll32 shimgvw.dll` — print images
- Optional: [SumatraPDF](https://www.sumatrapdfreader.org/) for better PDF printing

### Linux / macOS (CUPS)
Uses CUPS command-line tools:
- `lpstat -p -d` — enumerate printers and default
- `lp -d <printer>` — print files
- `lpoptions -p <printer>` — get printer options/description
- CUPS web interface at https://localhost:631

## Deployment

### Automated Deploy to Raspberry Pi / Linux

The `deploy/deploy-to-pi.sh` script handles everything: installs .NET, CUPS, builds, deploys, and registers as a systemd service.

```bash
# Basic usage
./deploy/deploy-to-pi.sh 192.168.1.50 http://basicscale.scaledata.net

# With options
./deploy/deploy-to-pi.sh 192.168.1.50 http://basicscale.scaledata.net \
    --user pi --service-id office --port 5230

# Options:
#   --user <username>       SSH user (default: pi)
#   --service-id <id>       Unique ID for this service instance (default: default)
#   --port <port>           API port on the Pi (default: 5230)
#   --arch <arch>           Override architecture (linux-arm64, linux-arm, linux-x64)
#   --branch <branch>       Git branch to deploy (default: main)
```

**Prerequisites:**
- SSH key access to the Pi (`ssh-copy-id pi@192.168.1.50`)
- Pi must have internet access
- The script must be run from a machine with .NET SDK installed

**What the script does:**
1. Tests SSH connection
2. Detects Pi architecture (arm64, armv7l, x64)
3. Installs CUPS on the Pi
4. Installs .NET 8 ASP.NET Core runtime
5. Cross-compiles the service for the Pi's architecture
6. Deploys to `/opt/web-print-service`
7. Configures and starts as a systemd service

**After deployment:**
- Service URL: `http://<pi-ip>:5230`
- Swagger: `http://<pi-ip>:5230/swagger`
- CUPS admin: `http://<pi-ip>:631`
- Logs: `sudo journalctl -u web-print-service -f`

### Automated Deploy to Windows

The `deploy/deploy-to-windows.ps1` script installs as a Windows Service with auto-restart on failure.

```powershell
# Run as Administrator
.\deploy\deploy-to-windows.ps1 -WebServerUrl "http://basicscale.scaledata.net"

# With options
.\deploy\deploy-to-windows.ps1 -WebServerUrl "http://192.168.1.100:5110" `
    -ServiceId "office" -Port 5230 -InstallDir "C:\Services\WebPrintService"

# Parameters:
#   -WebServerUrl <url>         (Required) BasicWeigh web server URL
#   -ServiceId <id>             Unique ID for this instance (default: default)
#   -Port <port>                API port (default: 5230)
#   -InstallDir <path>          Install location (default: C:\Services\WebPrintService)
#   -ServiceName <name>         Windows service name (default: WebPrintService)
#   -ServiceDisplayName <name>  Display name in services.msc
```

**What the script does:**
1. Checks for admin privileges
2. Installs .NET 8 runtime if needed
3. Stops existing service (if upgrading)
4. Builds and publishes for win-x64
5. Installs to `C:\Services\WebPrintService`
6. Backs up and restores existing SQLite database
7. Registers as a Windows Service with auto-restart
8. Starts the service

**After deployment:**
- Service URL: `http://localhost:5230`
- Swagger: `http://localhost:5230/swagger`
- Manage: `services.msc` > "Web Print Service"
- Logs: `Get-EventLog -LogName Application -Source WebPrintService -Newest 20`

### Manual Setup on Windows (Development)

```powershell
# No additional setup needed — Windows printers are auto-detected
cd WebPrintService
dotnet run
```

The service will automatically find all printers configured in Windows (Settings > Printers & Scanners).

### Manual Setup on Raspberry Pi / Linux

```bash
# Install .NET 8 runtime
curl -sSL https://dot.net/v1/dotnet-install.sh | bash /dev/stdin --channel 8.0 --runtime aspnetcore

# Install CUPS
sudo apt-get install cups
sudo usermod -aG lpadmin $USER

# Configure printers via CUPS web interface
# https://localhost:631

# Run the service
dotnet run
```

## Configuration

Initial config via `appsettings.json`:
```json
{
  "Print": {
    "ServerUrl": "http://your-server:5110",
    "Port": "5230"
  }
}
```

After first run, use the API to update settings (persists to SQLite):
```bash
curl -X PUT http://localhost:5230/api/settings \
  -H "Content-Type: application/json" \
  -d '{"serverUrl": "http://your-server:5110", "serviceId": "office-printer"}'
```
