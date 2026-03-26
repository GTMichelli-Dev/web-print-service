# Pi Print Service

A .NET 8.0 service that runs on a Raspberry Pi (or any Linux/macOS/Windows machine) and provides remote printing via CUPS. Connects to a web application through SignalR for print commands and printer management.

## Architecture

```
Web App (BasicWeigh, etc.)
    │
    ├── SignalR Hub (/scaleHub)
    │       │
    │       └── Pi Print Service (this)
    │               │
    │               └── CUPS → Physical Printer
```

## Features

- **SignalR Connection** — connects to any web app's SignalR hub behind a firewall (outbound only)
- **CUPS Integration** — uses `lpstat`, `lp`, `lpoptions` to manage and print to local printers
- **Printer Discovery** — announces available CUPS printers to the web app on connect
- **PDF Printing** — downloads ticket PDFs from the web app and prints via CUPS
- **Test Print** — send a test page to any connected printer
- **Swagger API** — local REST API for configuration and testing
- **SQLite Settings** — persistent configuration stored locally
- **Forever Retry** — never gives up reconnecting to the web app

## Endpoints (Swagger at http://localhost:5230/swagger)

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | /api/status/health | Health check with CUPS status and printer count |
| GET | /api/printers | List all CUPS printers with status |
| GET | /api/printers/{id}/status | Get status of a specific printer |
| POST | /api/printers/{id}/test | Send a test print to a specific printer |
| GET | /api/settings | Get service settings |
| PUT | /api/settings | Update settings (triggers reconnect) |

## SignalR Methods

| Direction | Method | Description |
|-----------|--------|-------------|
| Service → Hub | JoinPrintGroup(serviceId) | Join the PrintClients group |
| Service → Hub | PrintServiceReady(announcement) | Announce printers on connect |
| Service → Hub | PrinterListResponse(data) | Respond to printer list request |
| Service → Hub | PrintResult(result) | Report print job result |
| Service → Hub | TestPrintResult(result) | Report test print result |
| Hub → Service | PrintTicket(data) | Print a ticket PDF |
| Hub → Service | GetPrinterList | Request printer list |
| Hub → Service | TestPrint(printerId) | Send test page to printer |
| Hub → Service | ReloadConfig | Restart the service |

## Setup on Raspberry Pi

```bash
# Install .NET 8 runtime
curl -sSL https://dot.net/v1/dotnet-install.sh | bash /dev/stdin --channel 8.0

# Install CUPS (usually pre-installed on Raspberry Pi OS)
sudo apt-get install cups

# Add your user to the lpadmin group
sudo usermod -aG lpadmin $USER

# Configure CUPS (add printers via web interface)
# Access CUPS at https://localhost:631

# Run the service
dotnet run

# Or install as a systemd service
sudo cp piprintservice.service /etc/systemd/system/
sudo systemctl enable piprintservice
sudo systemctl start piprintservice
```

## Configuration

Edit `appsettings.json` or use the API:

```json
{
  "Print": {
    "ServerUrl": "http://your-server:5110",
    "Port": "5230"
  }
}
```

Or via API:
```bash
curl -X PUT http://localhost:5230/api/settings \
  -H "Content-Type: application/json" \
  -d '{"serverUrl": "http://your-server:5110", "serviceId": "pi-office"}'
```
