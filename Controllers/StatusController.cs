using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using PiPrintService.Data;
using PiPrintService.Services;

namespace PiPrintService.Controllers;

[ApiController]
public class StatusController : ControllerBase
{
    private readonly PrintDbContext _db;
    private readonly CupsClient _cups;
    private readonly RestartSignal _restart;

    public StatusController(PrintDbContext db, CupsClient cups, RestartSignal restart)
    {
        _db = db;
        _cups = cups;
        _restart = restart;
    }

    // ===== HEALTH =====

    [HttpGet("api/status/health")]
    public async Task<IActionResult> Health()
    {
        var cupsOk = await _cups.IsCupsAvailableAsync();
        var printers = cupsOk ? await _cups.GetPrintersAsync() : new();
        return Ok(new
        {
            status = cupsOk ? "ok" : "cups_unavailable",
            cupsAvailable = cupsOk,
            printerCount = printers.Count,
            printers = printers.Select(p => new { p.PrinterId, p.DisplayName, p.Status, p.Enabled, p.IsDefault })
        });
    }

    // ===== PRINTERS =====

    /// <summary>
    /// List all CUPS printers with status.
    /// </summary>
    [HttpGet("api/printers")]
    public async Task<IActionResult> GetPrinters()
    {
        var printers = await _cups.GetPrintersAsync();
        return Ok(printers);
    }

    /// <summary>
    /// Get status of a specific printer.
    /// </summary>
    [HttpGet("api/printers/{printerId}/status")]
    public async Task<IActionResult> GetPrinterStatus(string printerId)
    {
        var status = await _cups.GetPrinterStatusAsync(printerId);
        return Ok(new { printerId, status });
    }

    /// <summary>
    /// Send a test print to a specific printer.
    /// </summary>
    [HttpPost("api/printers/{printerId}/test")]
    public async Task<IActionResult> TestPrint(string printerId)
    {
        var testFile = Path.Combine(Path.GetTempPath(), $"testprint_{Guid.NewGuid():N}.txt");
        await System.IO.File.WriteAllTextAsync(testFile,
            $"Pi Print Service Test Page\n\nPrinter: {printerId}\nDate: {DateTime.Now:yyyy-MM-dd HH:mm:ss}\n\nIf you can read this, printing is working!");

        var (success, message) = await _cups.PrintFileAsync(printerId, testFile, "Test Page");

        try { System.IO.File.Delete(testFile); } catch { }

        return Ok(new { success, message });
    }

    // ===== SETTINGS =====

    [HttpGet("api/settings")]
    public IActionResult GetSettings()
    {
        var settings = _db.Settings.OrderBy(s => s.Id).FirstOrDefault();
        return Ok(settings);
    }

    [HttpPut("api/settings")]
    public IActionResult UpdateSettings([FromBody] ServiceSettings update)
    {
        var settings = _db.Settings.OrderBy(s => s.Id).FirstOrDefault();
        if (settings == null)
        {
            settings = new ServiceSettings();
            _db.Settings.Add(settings);
        }

        if (update.ServiceId != null) settings.ServiceId = update.ServiceId;
        if (update.ServerUrl != null) settings.ServerUrl = update.ServerUrl;
        if (update.SignalRHub != null) settings.SignalRHub = update.SignalRHub;

        _db.SaveChanges();
        _restart.TriggerRestart();
        return Ok(new { success = true, message = "Settings saved. Service restarting..." });
    }
}
