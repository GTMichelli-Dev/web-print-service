namespace WebPrintService.Services;

/// <summary>
/// Caches the printer list for a few seconds.
///
/// Enumerating printers is the expensive call on both platforms — CUPS shells
/// out once per printer on top of lpstat, and the Windows client pays a fresh
/// powershell.exe start. The web app asks for the list on every page load of
/// every ticket grid, and again for every client whenever a print service
/// connects or drops, so a scale house with a few tabs open re-ran all of that
/// work several times a second for an answer that had not changed.
///
/// The TTL is deliberately short: a printer that is switched off should still
/// disappear from the operator's list promptly. Everything except the listing
/// is passed straight through, so printing is never served from a cache.
/// </summary>
public class CachedPrintClient : IPrintClient
{
    private static readonly TimeSpan Ttl = TimeSpan.FromSeconds(10);

    private readonly IPrintClient _inner;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private List<PrinterInfo>? _cached;
    private DateTime _cachedAt = DateTime.MinValue;

    public CachedPrintClient(IPrintClient inner) => _inner = inner;

    public async Task<List<PrinterInfo>> GetPrintersAsync()
    {
        if (Fresh) return _cached!;

        // One enumeration at a time. Several page loads landing together used to
        // each start their own; now the first does the work and the rest take
        // its result from the re-check below.
        await _gate.WaitAsync();
        try
        {
            if (Fresh) return _cached!;

            var printers = await _inner.GetPrintersAsync();
            // An empty list is not cached: it is what a transient CUPS or
            // powershell failure looks like, and caching it would keep the
            // operator's print dialog empty for the whole TTL.
            if (printers.Count > 0)
            {
                _cached = printers;
                _cachedAt = DateTime.UtcNow;
            }
            return printers;
        }
        finally
        {
            _gate.Release();
        }
    }

    private bool Fresh => _cached != null && DateTime.UtcNow - _cachedAt < Ttl;

    /// <summary>Drop the cached list so the next caller re-enumerates. Used
    /// after an operation that changes what the list should say.</summary>
    public void Invalidate() => _cachedAt = DateTime.MinValue;

    public Task<(bool success, string message)> PrintFileAsync(string printerId, string filePath, string? jobTitle = null)
        => _inner.PrintFileAsync(printerId, filePath, jobTitle);

    public Task<(bool success, string message)> PrintFromUrlAsync(string printerId, string url, string? jobTitle = null, HttpClient? http = null)
        => _inner.PrintFromUrlAsync(printerId, url, jobTitle, http);

    public Task<string> GetPrinterStatusAsync(string printerId)
        => _inner.GetPrinterStatusAsync(printerId);

    public Task<bool> IsAvailableAsync() => _inner.IsAvailableAsync();
}
