using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace WebPrintService.Services;

/// <summary>
/// Print client for Windows using PowerShell/WMI to enumerate printers
/// and native Windows print commands to send jobs.
/// </summary>
public class WindowsPrintClient : IPrintClient
{
    private readonly ILogger<WindowsPrintClient> _log;

    public WindowsPrintClient(ILogger<WindowsPrintClient> log)
    {
        _log = log;
    }

    public async Task<List<PrinterInfo>> GetPrintersAsync()
    {
        var printers = new List<PrinterInfo>();

        try
        {
            // Get default printer name first
            var (defEc, defOutput) = await RunPowerShellAsync(
                "(Get-CimInstance -ClassName Win32_Printer -Filter \\\"Default=True\\\").Name");
            var defaultPrinterName = defEc == 0 ? defOutput.Trim() : "";

            // Get all printers
            var (exitCode, output) = await RunPowerShellAsync(
                "Get-Printer | Select-Object Name, PrinterStatus | ConvertTo-Json -Compress");

            if (exitCode != 0)
            {
                _log.LogWarning("Get-Printer failed (exit {Code}): {Output}", exitCode, output);
                return printers;
            }

            if (string.IsNullOrWhiteSpace(output)) return printers;

            // PowerShell returns a single object (not array) if there's only one printer
            var json = output.Trim();
            if (!json.StartsWith("[")) json = $"[{json}]";

            _log.LogInformation("Printer JSON: {Json}", json);

            using var doc = System.Text.Json.JsonDocument.Parse(json);
            foreach (var elem in doc.RootElement.EnumerateArray())
            {
                var name = elem.TryGetProperty("Name", out var n) && n.ValueKind == System.Text.Json.JsonValueKind.String ? n.GetString() ?? "" : "";
                var statusNum = elem.TryGetProperty("PrinterStatus", out var ps) && ps.ValueKind == System.Text.Json.JsonValueKind.Number ? ps.GetInt32() : 0;
                var isDefault = name.Equals(defaultPrinterName, StringComparison.OrdinalIgnoreCase);

                // PrinterStatus: 0=Normal, 1=Paused, 2=Error, 3=PendingDeletion, 4=PaperJam, 5=PaperOut, 6=ManualFeed, 7=PaperProblem
                var status = statusNum switch
                {
                    0 => "idle",
                    1 => "paused",
                    2 => "error",
                    3 => "deleting",
                    4 => "paper jam",
                    5 => "paper out",
                    _ => "unknown"
                };

                printers.Add(new PrinterInfo
                {
                    PrinterId = name,
                    DisplayName = name,
                    Status = status,
                    IsDefault = isDefault,
                    Enabled = statusNum != 1 && statusNum != 3
                });
            }
        }
        catch (Exception ex)
        {
            _log.LogError("Failed to get Windows printers: {Msg}", ex.Message);
        }

        return printers;
    }

    public async Task<(bool success, string message)> PrintFileAsync(string printerId, string filePath, string? jobTitle = null)
    {
        try
        {
            var ext = Path.GetExtension(filePath).ToLowerInvariant();

            // For PDF files, use SumatraPDF if available, otherwise PowerShell Out-Printer
            if (ext == ".pdf")
            {
                return await PrintPdfAsync(printerId, filePath, jobTitle);
            }

            // For text files, use PowerShell Out-Printer
            if (ext is ".txt" or ".csv" or ".log")
            {
                var (ec, output) = await RunPowerShellAsync(
                    $"Get-Content \"{filePath}\" | Out-Printer -Name \"{printerId}\"");
                return ec == 0
                    ? (true, $"Sent to {printerId}")
                    : (false, output);
            }

            // For images, use Windows print verb
            if (ext is ".jpg" or ".jpeg" or ".png" or ".bmp" or ".gif")
            {
                return await PrintImageAsync(printerId, filePath);
            }

            // Default: try Start-Process with print verb
            var (exitCode, result) = await RunPowerShellAsync(
                $"Start-Process -FilePath \"{filePath}\" -Verb Print -ArgumentList '\"/d:{printerId}\"' -Wait -PassThru | Select-Object ExitCode");
            return exitCode == 0
                ? (true, $"Sent to {printerId}")
                : (false, result);
        }
        catch (Exception ex)
        {
            _log.LogError("Print failed: {Msg}", ex.Message);
            return (false, ex.Message);
        }
    }

    public async Task<(bool success, string message)> PrintFromUrlAsync(string printerId, string url, string? jobTitle = null, HttpClient? http = null)
    {
        http ??= new HttpClient();
        var tempFile = Path.Combine(Path.GetTempPath(), $"print_{Guid.NewGuid():N}.pdf");

        try
        {
            var response = await http.GetAsync(url);
            if (!response.IsSuccessStatusCode)
                return (false, $"Failed to download: HTTP {(int)response.StatusCode}");

            await using var fs = File.Create(tempFile);
            await response.Content.CopyToAsync(fs);
            fs.Close();

            return await PrintFileAsync(printerId, tempFile, jobTitle);
        }
        finally
        {
            try { File.Delete(tempFile); } catch { }
        }
    }

    public async Task<string> GetPrinterStatusAsync(string printerId)
    {
        var (exitCode, output) = await RunPowerShellAsync(
            $"Get-Printer -Name \"{printerId}\" | Select-Object Name, PrinterStatus, JobCount | ConvertTo-Json -Compress");
        return exitCode == 0 ? output.Trim() : $"Error: {output.Trim()}";
    }

    public async Task<bool> IsAvailableAsync()
    {
        try
        {
            var (exitCode, _) = await RunPowerShellAsync("Get-Printer | Select-Object -First 1 Name");
            return exitCode == 0;
        }
        catch
        {
            return false;
        }
    }

    private async Task<(bool success, string message)> PrintPdfAsync(string printerId, string filePath, string? jobTitle)
    {
        // Try SumatraPDF (common free PDF printer tool)
        var sumatraPath = FindSumatraPdf();
        if (sumatraPath != null)
        {
            var args = $"-print-to \"{printerId}\" -silent \"{filePath}\"";
            var (ec, output) = await RunCommandAsync(sumatraPath, args);
            return ec == 0
                ? (true, $"Sent to {printerId} via SumatraPDF")
                : (false, $"SumatraPDF error: {output}");
        }

        // Fallback: PowerShell + .NET PrintDocument (basic, may not format well)
        var (exitCode, result) = await RunPowerShellAsync(
            $"Start-Process -FilePath \"{filePath}\" -Verb PrintTo -ArgumentList '\"{printerId}\"' -Wait");
        return exitCode == 0
            ? (true, $"Sent to {printerId}")
            : (false, result);
    }

    private async Task<(bool success, string message)> PrintImageAsync(string printerId, string filePath)
    {
        // Use rundll32 to print images
        var args = $"shimgvw.dll,ImageView_PrintTo /pt \"{filePath}\" \"{printerId}\"";
        var (exitCode, output) = await RunCommandAsync("rundll32.exe", args);
        return exitCode == 0
            ? (true, $"Sent to {printerId}")
            : (false, output);
    }

    private static string? FindSumatraPdf()
    {
        var paths = new[]
        {
            @"C:\Program Files\SumatraPDF\SumatraPDF.exe",
            @"C:\Program Files (x86)\SumatraPDF\SumatraPDF.exe",
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"SumatraPDF\SumatraPDF.exe")
        };

        return paths.FirstOrDefault(File.Exists);
    }

    private static async Task<(int exitCode, string output)> RunPowerShellAsync(string script)
    {
        return await RunCommandAsync("powershell.exe",
            $"-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"{script.Replace("\"", "\\\"")}\"");
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
