namespace WebPrintService.Services;

/// <summary>
/// Platform-agnostic print client interface.
/// Implemented by CupsClient (Linux/macOS) and WindowsPrintClient (Windows).
/// </summary>
public interface IPrintClient
{
    Task<List<PrinterInfo>> GetPrintersAsync();
    /// <param name="onJobQueued">
    /// Invoked with the spooler job id as soon as the job is accepted by the print system,
    /// before the physical print finishes. Used to tell the kiosk the ticket is now printing.
    /// </param>
    Task<(bool success, string message)> PrintFileAsync(string printerId, string filePath, string? jobTitle = null, Func<string, Task>? onJobQueued = null);
    Task<(bool success, string message)> PrintFromUrlAsync(string printerId, string url, string? jobTitle = null, HttpClient? http = null, Func<string, Task>? onJobQueued = null);
    Task<string> GetPrinterStatusAsync(string printerId);
    Task<bool> IsAvailableAsync();
}

public class PrinterInfo
{
    public string PrinterId { get; set; } = "";
    public string DisplayName { get; set; } = "";
    public string Status { get; set; } = "unknown";
    public bool IsDefault { get; set; }
    public bool Enabled { get; set; } = true;
}
