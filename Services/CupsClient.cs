using System.Diagnostics;
using System.Text.RegularExpressions;

namespace WebPrintService.Services;

/// <summary>
/// Wrapper around CUPS command-line tools (lpstat, lp, lpoptions).
/// Works on Linux (Raspberry Pi) and macOS.
/// </summary>
public class CupsClient : IPrintClient
{
    private readonly ILogger<CupsClient> _log;

    public CupsClient(ILogger<CupsClient> log)
    {
        _log = log;
    }

    /// <summary>
    /// Get all printers known to CUPS with their status.
    /// </summary>
    public async Task<List<PrinterInfo>> GetPrintersAsync()
    {
        var printers = new List<PrinterInfo>();

        try
        {
            // lpstat -p -d gives printer list and default
            var (exitCode, output) = await RunCommandAsync("lpstat", "-p -d");
            if (exitCode != 0)
            {
                _log.LogWarning("lpstat failed (exit {Code}): {Output}", exitCode, output);
                return printers;
            }

            string? defaultPrinter = null;
            var lines = output.Split('\n', StringSplitOptions.RemoveEmptyEntries);

            foreach (var line in lines)
            {
                // "system default destination: PrinterName"
                if (line.StartsWith("system default destination:"))
                {
                    defaultPrinter = line.Split(':').LastOrDefault()?.Trim();
                    continue;
                }

                // "printer PrinterName is idle. enabled since ..."
                // "printer PrinterName disabled since ..."
                var match = Regex.Match(line, @"^printer\s+(\S+)\s+(is\s+)?(\w+)");
                if (match.Success)
                {
                    var name = match.Groups[1].Value;
                    var status = match.Groups[3].Value; // idle, disabled, printing

                    printers.Add(new PrinterInfo
                    {
                        PrinterId = name,
                        DisplayName = name,
                        Status = status,
                        IsDefault = false, // set below
                        Enabled = !status.Equals("disabled", StringComparison.OrdinalIgnoreCase)
                    });
                }
            }

            // Get descriptions via lpoptions
            foreach (var printer in printers)
            {
                printer.IsDefault = printer.PrinterId == defaultPrinter;

                try
                {
                    // Only printer-info is wanted here. A "lpoptions -l" used to
                    // run first and its output was discarded — that flag makes
                    // CUPS parse and dump every option in the PPD (201 choices
                    // across 16 option groups on a BIXOLON BK3-3's 42KB PPD),
                    // once per printer, for nothing.
                    var (ec, info) = await RunCommandAsync("lpoptions", $"-p {printer.PrinterId}");
                    var infoMatch = Regex.Match(info, @"printer-info='([^']*)'");
                    if (infoMatch.Success)
                        printer.DisplayName = infoMatch.Groups[1].Value;
                }
                catch { /* description is optional */ }
            }
        }
        catch (Exception ex)
        {
            _log.LogError("Failed to get CUPS printers: {Msg}", ex.Message);
        }

        return printers;
    }

    /// <summary>
    /// How long to wait for a submitted CUPS job to leave the queue before giving up on it.
    /// Kept below the kiosk's own print timeout so the service decides the outcome, not the client.
    /// </summary>
    private static readonly TimeSpan JobWaitTimeout = TimeSpan.FromSeconds(20);

    /// <summary>
    /// Print a file (PDF, image, etc.) to a specific printer.
    /// Returns once CUPS has finished the job, so the caller knows the ticket is actually out.
    /// </summary>
    public async Task<(bool success, string message)> PrintFileAsync(string printerId, string filePath, string? jobTitle = null, Func<string, Task>? onJobQueued = null)
    {
        var args = $"-d {printerId}";
        if (!string.IsNullOrEmpty(jobTitle))
            args += $" -t \"{jobTitle}\"";
        args += $" \"{filePath}\"";

        var (exitCode, output) = await RunCommandAsync("lp", args);
        if (exitCode != 0)
        {
            _log.LogWarning("Print failed on {Printer} (exit {Code}): {Output}", printerId, exitCode, output);
            return (false, output.Trim());
        }

        var message = output.Trim();
        var jobId = ParseJobId(message);
        _log.LogInformation("Print job {Job} queued on {Printer}: {Output}", jobId, printerId, message);

        if (onJobQueued != null)
        {
            try { await onJobQueued(jobId); }
            catch (Exception ex) { _log.LogWarning("onJobQueued callback failed: {Msg}", ex.Message); }
        }

        // lp exiting 0 only means CUPS accepted the job. A job that dies in the filter chain
        // ("Filter failed") sits in the queue forever, so success is not known until it drains.
        if (!string.IsNullOrEmpty(jobId))
        {
            var (completed, reason) = await WaitForJobAsync(printerId, jobId);
            if (!completed)
            {
                _log.LogWarning("Print job {Job} did not complete: {Reason}", jobId, reason);
                return (false, $"Job {jobId} did not print: {reason}");
            }
        }

        return (true, message);
    }

    /// <summary>
    /// Pull the job id out of lp's "request id is Printer-42 (1 file(s))" response.
    /// </summary>
    private static string ParseJobId(string lpOutput)
    {
        var match = Regex.Match(lpOutput, @"request id is (\S+)");
        return match.Success ? match.Groups[1].Value : "";
    }

    /// <summary>
    /// Poll CUPS until the job drains out of the queue. Returns false if it is still sitting there
    /// when the timeout expires, or if the queue itself stopped (a failed filter disables it).
    /// </summary>
    private async Task<(bool completed, string reason)> WaitForJobAsync(string printerId, string jobId)
    {
        var deadline = DateTime.UtcNow + JobWaitTimeout;

        while (DateTime.UtcNow < deadline)
        {
            await Task.Delay(400);

            var (exitCode, output) = await RunCommandAsync("lpstat", "-o");
            if (exitCode != 0) return (true, ""); // can't tell — assume it printed rather than cry wolf

            // lpstat -o lists one line per not-yet-completed job, starting with the job id
            var stillQueued = output
                .Split('\n', StringSplitOptions.RemoveEmptyEntries)
                .Any(line => line.TrimStart().StartsWith(jobId + " ", StringComparison.Ordinal));

            if (!stillQueued)
            {
                _log.LogInformation("Print job {Job} finished.", jobId);
                return (true, "");
            }

            // CUPS disables the queue when a filter fails — no point waiting out the timeout
            var (stateCode, state) = await RunCommandAsync("lpstat", $"-p {printerId}");
            if (stateCode == 0 && state.Contains("disabled", StringComparison.OrdinalIgnoreCase))
                return (false, state.Trim());
        }

        return (false, $"still queued after {JobWaitTimeout.TotalSeconds:0}s");
    }

    /// <summary>
    /// Print from a URL (downloads then prints).
    /// </summary>
    public async Task<(bool success, string message)> PrintFromUrlAsync(string printerId, string url, string? jobTitle = null, HttpClient? http = null, Func<string, Task>? onJobQueued = null)
    {
        http ??= new HttpClient();
        var tempFile = Path.Combine(Path.GetTempPath(), $"print_{Guid.NewGuid():N}.pdf");

        try
        {
            // Timed separately from the spool below. The fetch covers DNS, the
            // TCP+TLS handshake and the server rendering the report; the spool is
            // just handing the file to CUPS. When an operator says the first
            // ticket after a lull is slow, this is the line that says whether the
            // wait was the connection or the printer.
            var sw = System.Diagnostics.Stopwatch.StartNew();

            var response = await http.GetAsync(url);
            if (!response.IsSuccessStatusCode)
                return (false, $"Failed to download: HTTP {(int)response.StatusCode}");

            await using var fs = File.Create(tempFile);
            await response.Content.CopyToAsync(fs);
            fs.Close();

            var fetchedMs = sw.ElapsedMilliseconds;

            // Spool now ends when the spooler accepts the job, not when PrintFileAsync
            // returns - it waits for the job to drain. Splitting the two keeps "spool"
            // meaning what it did before and puts the printer's own time in "print",
            // which is the number an operator feels as the wait for the ticket.
            long spooledMs = -1;
            var result = await PrintFileAsync(printerId, tempFile, jobTitle, async jobId =>
            {
                spooledMs = sw.ElapsedMilliseconds;
                if (onJobQueued != null) await onJobQueued(jobId);
            });

            var spoolEnd = spooledMs < 0 ? sw.ElapsedMilliseconds : spooledMs;
            _log.LogInformation("Print timing for {Printer}: fetch {FetchMs}ms, spool {SpoolMs}ms, print {PrintMs}ms",
                printerId, fetchedMs, spoolEnd - fetchedMs, sw.ElapsedMilliseconds - spoolEnd);
            return result;
        }
        finally
        {
            try { File.Delete(tempFile); } catch { }
        }
    }

    /// <summary>
    /// Get the status of a specific printer.
    /// </summary>
    public async Task<string> GetPrinterStatusAsync(string printerId)
    {
        var (exitCode, output) = await RunCommandAsync("lpstat", $"-p {printerId}");
        return exitCode == 0 ? output.Trim() : $"Error: {output.Trim()}";
    }

    /// <summary>
    /// Check if CUPS is available on this system.
    /// </summary>
    public async Task<bool> IsAvailableAsync()
    {
        try
        {
            var (exitCode, _) = await RunCommandAsync("lpstat", "-r");
            return exitCode == 0;
        }
        catch
        {
            return false;
        }
    }

    private static async Task<(int exitCode, string output)> RunCommandAsync(string command, string args)
    {
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = command,
                Arguments = args,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            }
        };

        process.Start();
        var stdout = await process.StandardOutput.ReadToEndAsync();
        var stderr = await process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();

        var output = string.IsNullOrEmpty(stderr) ? stdout : $"{stdout}\n{stderr}";
        return (process.ExitCode, output);
    }
}

// PrinterInfo is defined in IPrintClient.cs
