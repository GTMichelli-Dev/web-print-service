using System.Text;

namespace WebPrintService.Services;

/// <summary>
/// Builds a minimal one-page PDF for test prints. Plain-text test pages go
/// through CUPS's text filter, which the BIXOLON raster path mangles (title
/// lines overprint each other on receipt stock); a PDF exercises the exact
/// same pipeline real tickets use — which is what a test print is for.
/// Hand-rolled so the service needs no PDF dependency.
/// </summary>
public static class TestPagePdf
{
    /// <summary>One text line per entry; empty strings render as blank lines.</summary>
    public static byte[] Build(IEnumerable<string> lines)
    {
        // 204 x 400 pt ≈ a 72mm-wide receipt strip.
        var content = new StringBuilder();
        content.Append("BT /F1 11 Tf 14 370 Td 16 TL\n");
        var first = true;
        foreach (var line in lines)
        {
            if (!first) content.Append("T*\n");
            content.Append('(').Append(Escape(line)).Append(") Tj\n");
            first = false;
        }
        content.Append("ET\n");
        var stream = content.ToString();

        var objects = new[]
        {
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 204 400] " +
                "/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            $"<< /Length {Encoding.ASCII.GetByteCount(stream)} >>\nstream\n{stream}endstream",
        };

        // All content is ASCII, so char positions == byte offsets.
        var pdf = new StringBuilder("%PDF-1.4\n");
        var offsets = new int[objects.Length];
        for (var i = 0; i < objects.Length; i++)
        {
            offsets[i] = pdf.Length;
            pdf.Append(i + 1).Append(" 0 obj\n").Append(objects[i]).Append("\nendobj\n");
        }
        var xrefPos = pdf.Length;
        pdf.Append("xref\n0 ").Append(objects.Length + 1).Append('\n');
        pdf.Append("0000000000 65535 f \n");
        foreach (var off in offsets)
            pdf.Append(off.ToString("D10")).Append(" 00000 n \n");
        pdf.Append("trailer\n<< /Size ").Append(objects.Length + 1)
           .Append(" /Root 1 0 R >>\nstartxref\n").Append(xrefPos).Append("\n%%EOF");
        return Encoding.ASCII.GetBytes(pdf.ToString());
    }

    private static string Escape(string s) =>
        s.Replace("\\", "\\\\").Replace("(", "\\(").Replace(")", "\\)");
}
