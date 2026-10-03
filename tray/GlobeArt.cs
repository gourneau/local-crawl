using System;
using System.Drawing;
using System.Drawing.Drawing2D;

// Draws the globe glyph. Shared by the tray icons (LocalCrawlerTray.cs) and the
// .exe icon that install.ps1 renders, so both always match.
public static class GlobeArt
{
    public static void Draw(Graphics g, int size, Color fill)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Color.Transparent);

        float s = size;
        float pad = Math.Max(0.5f, s * 0.04f);
        RectangleF disc = new RectangleF(pad, pad, s - 2 * pad, s - 2 * pad);
        using (SolidBrush brush = new SolidBrush(fill))
        {
            g.FillEllipse(brush, disc);
        }

        using (Pen pen = new Pen(Color.White, Math.Max(1f, s / 16f)))
        {
            RectangleF ring = Inset(disc, s * 0.16f);
            g.DrawEllipse(pen, ring);
            g.DrawEllipse(pen, ring.X + ring.Width * 0.3f, ring.Y, ring.Width * 0.4f, ring.Height);
            float equator = ring.Y + ring.Height / 2f;
            g.DrawLine(pen, ring.X, equator, ring.Right, equator);
        }
    }

    static RectangleF Inset(RectangleF r, float d)
    {
        return new RectangleF(r.X + d, r.Y + d, r.Width - 2 * d, r.Height - 2 * d);
    }
}
