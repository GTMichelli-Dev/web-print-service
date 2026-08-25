# Web Print Service

A cross-platform .NET 10 print service that connects to a web application via SignalR and provides remote printing. Automatically detects the operating system and uses **Windows Print** (PowerShell/WMI) on Windows or **CUPS** (`lpstat`, `lp`) on Linux/macOS.

## Architecture

### Windows
```
Web App (BasicWeigh, etc.)
    |
    +-- SignalR Hub (/scaleHub)
            |
            +-- Web Print Service (this)
                    |
                    +-- SumatraPDF (silent PDF printing)
                            |
                            +-- Physical Printer (USB, Network, Shared)
```

#### Windows PDF Printing Requirements

The service needs a silent PDF printing tool to send tickets to printers. It auto-detects in this order:

1. **SumatraPDF** (recommended) — auto-installed via `winget` if not found
2. **PDFtoPrinter.exe** — if placed in the service directory
3. **Fallback** — uses `Start-Process -Verb PrintTo` (may open a dialog, not recommended for unattended use)

To manually install SumatraPDF:
```
winget install SumatraPDF.SumatraPDF
```

Or download from https://www.sumatrapdfreader.org/free-pdf-reader

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

### Raspberry Pi install (recommended)

The installer provisions everything: CUPS, the bundled BIXOLON POS CUPS
driver, a queue named **TicketPrinter** for the USB **BIXOLON SRP-F310II**
ticket printer (override with `--printer-name` / `--ppd`), the .NET runtime,
and a systemd service. The SignalR ServiceId defaults to the Pi's hostname —
give each print box a unique hostname before installing.

```bash
git clone https://github.com/GTMichelli-Dev/web-print-service.git /tmp/wps
bash /tmp/wps/deploy/install.sh http://your-server:5110
rm -rf /tmp/wps
```

Re-run the same command to update; settings survive. See
`deploy/install.sh --help` for all options (`--printer-name`, `--service-id`,
`--rotate`, `--media-size`, ...). After install, assign
`<hostname>:TicketPrinter` on Foundation's Setup → Printers page.

### Windows install

Download `web-print-service-win-x64.zip` from
[Releases](https://github.com/GTMichelli-Dev/web-print-service/releases), unzip
it on the PC the printer is attached to, and from an **admin** prompt in that
folder:

```powershell
INSTALL.bat https://your-server
```

Self-contained — no .NET, no SDK and no git needed on that PC. Full option set
and the printing gotchas that bite on Windows are in
[Install on Windows](#install-on-windows).

### Development

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

### Install on Raspberry Pi / Linux

SSH into the Pi and run:

```bash
git clone https://github.com/GTMichelli-Dev/web-print-service.git /tmp/wps
bash /tmp/wps/deploy/install.sh https://basicscale.scaledata.net
rm -rf /tmp/wps
```

With options:

```bash
git clone https://github.com/GTMichelli-Dev/web-print-service.git /tmp/wps
bash /tmp/wps/deploy/install.sh https://basicscale.scaledata.net \
    --service-id office --port 5230
rm -rf /tmp/wps
```

For private repos, git will prompt for credentials. You can also use a deploy key or GitHub token.

Options:
| Option | Default | Description |
|--------|---------|-------------|
| `--service-id <id>` | `default` | Unique ID for this service instance |
| `--port <port>` | `5230` | API/Swagger port |
| `--branch <branch>` | `master` | Git branch to install |
| `--install-dir <path>` | `/opt/web-print-service` | Install location |

**What the script does automatically:**
1. Detects Pi architecture (arm64, armv7l, x64)
2. Installs CUPS (printer system)
3. Installs the .NET 10 SDK and runtime permanently (skips download on future updates)
4. Downloads latest source from GitHub
5. Builds for the Pi's architecture
6. Installs to `/opt/web-print-service`
7. Preserves existing database on updates
8. Registers and starts as a systemd service

**Prerequisites:** Just internet access and `git` (pre-installed on Raspberry Pi OS). No .NET, no CUPS — the script installs everything. The .NET SDK is installed permanently so future updates skip the download.

**To update:** Run the same command again. The script stops the service, updates files, preserves your database, and restarts.

**After install:**
- Swagger: `http://<pi-ip>:5230/swagger`
- CUPS Admin: `http://<pi-ip>:631`
- Logs: `sudo journalctl -u web-print-service -f`
- Restart: `sudo systemctl restart web-print-service`

### Install on Windows

`deploy/install.ps1` is the Windows counterpart to `install.sh`, with
`deploy/INSTALL.bat` as a double-clickable wrapper so nobody has to touch the
machine's execution policy.

**Get the package.** Every tagged release ships a prebuilt, self-contained
`web-print-service-win-x64.zip` — the .NET runtime is bundled, so the target PC
needs no .NET, no SDK and no git. Download it from
[Releases](https://github.com/GTMichelli-Dev/web-print-service/releases) and
unzip it on the PC the printer is attached to.

To build the same package by hand — publish into an `app` folder next to the
scripts:

```powershell
dotnet publish PiPrintService.csproj -c Release -r win-x64 --self-contained true -o C:\Temp\web-print\app
copy deploy\install.ps1          C:\Temp\web-print\
copy deploy\INSTALL.bat          C:\Temp\web-print\
copy deploy\package-README.txt   C:\Temp\web-print\README.txt
```

**Install.** From an **admin** prompt in that folder:

```powershell
INSTALL.bat https://basicscale.scaledata.net
```

Or drive the script directly for the full option set:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -WebUrl https://basicscale.scaledata.net -ServiceId scalehouse
```

| Option | Default | Description |
|--------|---------|-------------|
| `-WebUrl` | *(required)* | Base URL of the web app. Must match its real scheme and port. |
| `-ServiceId` | computer name | Names this PC on the web app's Printers page. |
| `-Port` | `5230` | Local Swagger / diagnostic API port. |
| `-InstallDir` | `C:\Services\WebPrintService` | Install location. |
| `-ServiceName` | `WebPrintService` | Windows service name. |
| `-TestPrinter` | *(none)* | Print a test page to this printer at the end. |
| `-ResetDb` | off | Start from a clean database. **Destroys** the ServiceId, ServerUrl and printer settings — a timestamped backup is taken first regardless. |
| `-SkipUrlCheck` | off | Install even if the SignalR hub probe fails. |
| `-SkipPdfTool` | off | Don't try to install SumatraPDF when none is found. |

The script is idempotent — re-run it to update. It will:

1. Validate the arguments, find the binaries, and probe the web app's
   **SignalR hub** — a redirect or a 404 is reported before anything is
   installed, since either leaves the service reconnecting forever. (Negotiate
   is a POST; an `http`→`https` redirect downgrades it to GET and the hub
   answers 405 for good.)
2. Stop the service and **wait for it to actually stop** (it holds its own
   `.exe`; copying too early fails with a file lock), plus stop any copy left
   running from a console.
3. Back up the database to the Desktop, timestamped.
4. Copy the binaries, excluding the database and its `-wal`/`-shm` companions.
5. Write `ServerUrl` and the listen port into `appsettings.json`.
6. Check that a silent PDF printer is installed **for all users**, installing
   SumatraPDF via `winget --scope machine` if not — see
   [Silent PDF printing](#silent-pdf-printing).
7. Create the service if missing — **automatic startup**, and configured to
   restart itself on failure (5s, 15s, then every 60s), since a scale-house PC
   is rarely watched. An existing service has its path corrected and startup
   set to automatic.
8. Start it, poll `/api/status/health` until it answers, and list the printers
   the service can see — failing loudly rather than reporting success over a
   dead service.
9. Apply `ServiceId` and `ServerUrl` **through the API**, then read them back.

Step 9 matters: `appsettings.json` only seeds the database on the first run, so
on a machine that has been running for months, editing the config file alone
would change nothing.

**Manage it afterwards:**

```powershell
Get-Service WebPrintService
Restart-Service WebPrintService
Invoke-RestMethod http://localhost:5230/api/printers
```

#### Silent PDF printing

Tickets are PDFs, and printing one without a dialog needs a helper. The service
looks for `PDFtoPrinter.exe` in its install folder, then
`C:\Program Files\PDFtoPrinter\PDFtoPrinter.exe`, then
`C:\Program Files\SumatraPDF\SumatraPDF.exe`. Without one it falls back to
`Start-Process -Verb PrintTo`, which wants a desktop — under a service account
there isn't one, so tickets quietly never come out.

**All-users installs only.** The service runs as LocalSystem, whose
`LocalAppData` is `C:\Windows\System32\config\systemprofile\AppData\Local`, so
an ordinary `winget install SumatraPDF.SumatraPDF` — which installs per-user —
is invisible to it. It then works perfectly when you double-click a PDF and not
at all from the service. The installer asks for `--scope machine` for exactly
this reason, and says so when that fails.

Fixing it later needs no reinstall: drop `PDFtoPrinter.exe` into the install
folder, or install SumatraPDF for all users, and the next print finds it.

**Printers follow the same rule.** A printer added while logged in as yourself
— including a shared `\\server\printer` — belongs to your profile and is
invisible to LocalSystem. Either add it for all users, or point the service at
that account in `services.msc` → **WebPrintService** → **Log On**. The
installer prints the list of printers it can actually see; an empty list, or
one missing the ticket printer, is this.

**Run it in the foreground** — for development, or to see an error the service swallows:

```powershell
cd PiPrintService
dotnet run
```

Or, on a machine where it is already installed:

```powershell
net stop WebPrintService
"C:\Services\WebPrintService\PiPrintService.exe"
```


## Configuration

Initial config via `appsettings.json`:
```json
{
  "Print": {
    "ServerUrl": "https://your-server",
    "Port": "5230"
  }
}
```

After first run, use the API to update settings (persists to SQLite):
```bash
curl -X PUT http://localhost:5230/api/settings \
  -H "Content-Type: application/json" \
  -d '{"serverUrl": "https://your-server", "serviceId": "office-printer"}'
```
