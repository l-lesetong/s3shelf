using System.Drawing;
using System.Drawing.Drawing2D;

namespace S3Shelf
{
    internal static class ShelfGlyph
    {
        internal static void Draw(Graphics graphics, Glyph glyph, Rectangle bounds, Color color)
        {
            if (glyph == Glyph.None || bounds.Width <= 0 || bounds.Height <= 0) return;
            var state = graphics.Save();
            graphics.TranslateTransform(bounds.X, bounds.Y);
            graphics.ScaleTransform(bounds.Width / 16f, bounds.Height / 16f);
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var pen = new Pen(color, 1.3f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
            using (var brush = new SolidBrush(color))
            {
                void Line(int x1, int y1, int x2, int y2) => graphics.DrawLine(pen, x1, y1, x2, y2);
                void Shape(params Point[] points) => graphics.DrawLines(pen, points);
                Point P(int x, int y) => new Point(x, y);
                switch (glyph)
                {
                    case Glyph.Browser:
                    case Glyph.Split:
                    case Glyph.Details:
                        graphics.DrawRectangle(pen, 1, 2, 14, 12);
                        if (glyph == Glyph.Browser) { Line(1, 6, 15, 6); Line(1, 10, 15, 10); Line(6, 2, 6, 14); }
                        if (glyph == Glyph.Split) Line(8, 2, 8, 14);
                        if (glyph == Glyph.Details) Line(1, 10, 15, 10);
                        break;
                    case Glyph.Transfer:
                        Shape(P(1, 6), P(4, 3), P(7, 6)); Line(4, 3, 4, 13);
                        Shape(P(9, 10), P(12, 13), P(15, 10)); Line(12, 3, 12, 13);
                        break;
                    case Glyph.Upload:
                    case Glyph.Download:
                        Shape(P(2, 8), P(2, 14), P(14, 14), P(14, 8));
                        Line(8, 2, 8, 11);
                        if (glyph == Glyph.Upload) Shape(P(5, 5), P(8, 2), P(11, 5));
                        else Shape(P(5, 8), P(8, 11), P(11, 8));
                        break;
                    case Glyph.Cloud:
                        using (var cloud = new GraphicsPath())
                        {
                            cloud.AddBezier(4, 12, 0, 12, 0, 7, 4, 7);
                            cloud.AddBezier(4, 7, 5, 1, 12, 2, 12, 7);
                            cloud.AddBezier(12, 7, 16, 7, 16, 12, 12, 12);
                            cloud.CloseFigure(); graphics.DrawPath(pen, cloud);
                        }
                        break;
                    case Glyph.Server:
                        graphics.DrawRectangle(pen, 1, 3, 14, 10); Line(1, 8, 15, 8);
                        graphics.FillEllipse(brush, 3, 5, 1.6f, 1.6f); graphics.FillEllipse(brush, 3, 10, 1.6f, 1.6f);
                        break;
                    case Glyph.Bucket:
                        Shape(P(2, 5), P(8, 2), P(14, 5), P(14, 11), P(8, 14), P(2, 11), P(2, 5), P(8, 8), P(14, 5)); Line(8, 8, 8, 14);
                        break;
                    case Glyph.Folder:
                        Shape(P(1, 13), P(1, 3), P(6, 3), P(8, 5), P(15, 5), P(15, 13), P(1, 13));
                        break;
                    case Glyph.File:
                        Shape(P(4, 2), P(9, 2), P(13, 6), P(13, 14), P(4, 14), P(4, 2)); Shape(P(9, 2), P(9, 6), P(13, 6));
                        break;
                    case Glyph.Add: Line(3, 8, 13, 8); Line(8, 3, 8, 13); break;
                    case Glyph.Close: Line(4, 4, 12, 12); Line(4, 12, 12, 4); break;
                    case Glyph.Up: Shape(P(3, 7), P(8, 2), P(13, 7)); Line(8, 2, 8, 14); break;
                    case Glyph.Chevron: Shape(P(6, 4), P(10, 8), P(6, 12)); break;
                    case Glyph.Refresh:
                        graphics.DrawArc(pen, 2, 2, 12, 12, -40, 290); Shape(P(9, 2), P(13, 4), P(13, 1)); break;
                    case Glyph.Edit:
                        Shape(P(3, 10), P(11, 2), P(14, 5), P(6, 13), P(2, 14), P(3, 10)); Line(9, 4, 12, 7); break;
                    case Glyph.Search: graphics.DrawEllipse(pen, 2, 2, 8, 8); Line(9, 9, 14, 14); break;
                    case Glyph.More:
                        graphics.DrawEllipse(pen, 1, 1, 14, 14);
                        for (int x = 4; x <= 10; x += 3) graphics.FillEllipse(brush, x, 7, 2, 2);
                        break;
                    case Glyph.Settings:
                        Line(1, 4, 15, 4); Line(1, 8, 15, 8); Line(1, 12, 15, 12);
                        Line(5, 2, 5, 6); Line(11, 6, 11, 10); Line(6, 10, 6, 14); break;
                    case Glyph.Check:
                        graphics.DrawEllipse(pen, 1, 1, 14, 14); Shape(P(4, 8), P(7, 11), P(12, 5)); break;
                }
            }
            graphics.Restore(state);
        }
    }
}
