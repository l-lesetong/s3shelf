using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using Microsoft.Win32;

namespace S3Shelf
{
    internal enum Fill { Surface, Sidebar, Toolbar, Field, Stripe, Selected, Line }
    internal enum Glyph { None, Browser, Transfer, Settings, Cloud, Server, Bucket, Split, Upload, Download, Details, Add, More, Up, Refresh, Folder, Search, Edit, Close, Chevron, File, Check }
    internal enum Appearance { System, Light, Dark }

    internal static class Theme
    {
        private const string SettingsKey = @"HKEY_CURRENT_USER\Software\s3Shelf";
        internal static Appearance Preference { get; private set; } = LoadPreference();
        internal static bool Dark { get; private set; } = ResolveDark();
        internal static bool HighContrast { get; private set; } = SystemInformation.HighContrast;
        internal static Color Surface => ColorFor(Fill.Surface);
        internal static Color Chrome => ColorFor(Fill.Toolbar);
        internal static Color Line => ColorFor(Fill.Line);
        internal static Color Ink => HighContrast ? SystemColors.WindowText : ColorValue(0x222224, 0xeeeeef);
        internal static Color Muted => HighContrast ? SystemColors.WindowText : ColorValue(0x616267, 0xaaaab0);
        internal static Color Accent => HighContrast ? SystemColors.HotTrack : ColorValue(0x0067ca, 0x58aaff);
        internal static Color Highlight => HighContrast ? SystemColors.Highlight : ColorValue(0x086cda, 0x075bc0);
        internal static Color HighlightText => HighContrast ? SystemColors.HighlightText : Color.White;
        internal static Color StrongBorder => HighContrast ? SystemColors.WindowText : ColorValue(0x929297, 0x77777c);
        internal static readonly Font Semibold = new Font(SystemFonts.MessageBoxFont, FontStyle.Bold);
        internal static readonly Font Heading = new Font(SystemFonts.MessageBoxFont.FontFamily, 15f, FontStyle.Bold);
        internal const TextFormatFlags SingleLine = TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter |
            TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis |
            TextFormatFlags.PreserveGraphicsClipping | TextFormatFlags.PreserveGraphicsTranslateTransform;

        private static Appearance LoadPreference()
        {
            var value = Registry.GetValue(SettingsKey, "Appearance", "System") as string;
            return Enum.TryParse(value, out Appearance preference) && Enum.IsDefined(typeof(Appearance), preference) ? preference : Appearance.System;
        }

        private static bool ResolveDark() => Preference == Appearance.Dark || (Preference == Appearance.System &&
            Equals(Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1), 0));

        internal static void SetAppearance(Appearance preference)
        {
            Registry.SetValue(SettingsKey, "Appearance", preference.ToString());
            Preference = preference;
            RefreshSystem();
        }

        internal static bool RefreshSystem()
        {
            var dark = ResolveDark();
            var contrast = SystemInformation.HighContrast;
            if (dark == Dark && contrast == HighContrast) return false;
            Dark = dark;
            HighContrast = contrast;
            return true;
        }

        private static Color ColorValue(int light, int dark) => Color.FromArgb((int)(0xff000000u | (uint)(Dark ? dark : light)));

        internal static Color ColorFor(Fill fill)
        {
            if (HighContrast) return fill == Fill.Selected ? SystemColors.Highlight : fill == Fill.Line ? SystemColors.WindowText : SystemColors.Window;
            switch (fill)
            {
                case Fill.Sidebar: return ColorValue(0xefefef, 0x232323);
                case Fill.Toolbar: return ColorValue(0xf8f8f8, 0x242426);
                case Fill.Field: return ColorValue(0xeaeaea, 0x303033);
                case Fill.Stripe: return ColorValue(0xf3f3f3, 0x272727);
                case Fill.Selected: return ColorValue(0xdadada, 0x434343);
                case Fill.Line: return ColorValue(0xdadade, 0x39393e);
                default: return ColorValue(0xffffff, 0x1e1e20);
            }
        }

        internal static T Paint<T>(T control, Fill fill) where T : Control
        {
            control.Tag = fill;
            control.BackColor = ColorFor(fill);
            control.ForeColor = Ink;
            return control;
        }

        internal static void Apply(Control control)
        {
            if (control.Tag is Fill fill) control.BackColor = ColorFor(fill);
            control.ForeColor = control is ShelfLabel label && label.Secondary ? Muted : Ink;
            if (control is DataGridView grid)
            {
                grid.BackgroundColor = Surface;
                grid.GridColor = Line;
                grid.DefaultCellStyle.BackColor = Surface;
                grid.DefaultCellStyle.ForeColor = Ink;
                grid.DefaultCellStyle.SelectionBackColor = Highlight;
                grid.DefaultCellStyle.SelectionForeColor = HighlightText;
                grid.ColumnHeadersDefaultCellStyle.BackColor = Chrome;
                grid.ColumnHeadersDefaultCellStyle.ForeColor = Ink;
                grid.EnableHeadersVisualStyles = false;
            }
            if (control.ContextMenuStrip is ContextMenuStrip menu) TintMenu(menu);
            foreach (Control child in control.Controls) Apply(child);
            control.Invalidate();
        }

        internal static void TintMenu(ContextMenuStrip menu)
        {
            menu.Renderer = new ToolStripProfessionalRenderer(new MenuColors());
            menu.BackColor = Chrome;
            menu.ForeColor = Ink;
            foreach (ToolStripItem item in menu.Items) item.ForeColor = Ink;
        }

        internal static ShelfButton Button(string text, Glyph glyph = Glyph.None, bool iconOnly = false) => new ShelfButton(text, glyph, iconOnly);
        internal static ListView List(bool objectIcons = false) => Paint(new ShelfListView(objectIcons), Fill.Surface);
        internal static ShelfLabel Label(string text = "", bool secondary = false) => new ShelfLabel { Text = text, Secondary = secondary, ForeColor = secondary ? Muted : Ink };

        internal static void Rounded(Graphics graphics, Rectangle rectangle, int radius, Color fill, Color outline = default)
        {
            if (rectangle.Width <= radius * 2 || rectangle.Height <= radius * 2) return;
            var smoothing = graphics.SmoothingMode;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var size = radius * 2;
            using (var path = new GraphicsPath())
            using (var brush = new SolidBrush(fill))
            {
                path.AddArc(rectangle.Left, rectangle.Top, size, size, 180, 90);
                path.AddArc(rectangle.Right - size, rectangle.Top, size, size, 270, 90);
                path.AddArc(rectangle.Right - size, rectangle.Bottom - size, size, size, 0, 90);
                path.AddArc(rectangle.Left, rectangle.Bottom - size, size, size, 90, 90);
                path.CloseFigure();
                graphics.FillPath(brush, path);
                if (!outline.IsEmpty) using (var pen = new Pen(outline)) graphics.DrawPath(pen, path);
            }
            graphics.SmoothingMode = smoothing;
        }

        internal static string Bytes(long size)
        {
            if (size < 1024) return $"{size:N0} 字节";
            var unit = 0;
            double value = size;
            var units = new[] { "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" };
            do { value /= 1024; } while (value >= 1024 && ++unit < units.Length - 1);
            return $"{value:0.#} {units[unit]}";
        }

        private sealed class MenuColors : ProfessionalColorTable
        {
            internal MenuColors() { UseSystemColors = HighContrast; }
            public override Color ToolStripDropDownBackground => Chrome;
            public override Color ImageMarginGradientBegin => Chrome;
            public override Color ImageMarginGradientMiddle => Chrome;
            public override Color ImageMarginGradientEnd => Chrome;
            public override Color MenuBorder => Line;
            public override Color MenuItemBorder => StrongBorder;
            public override Color MenuItemSelected => ColorFor(Fill.Selected);
            public override Color SeparatorDark => Line;
            public override Color SeparatorLight => Line;
        }
    }

    internal sealed class ShelfLabel : Label
    {
        internal bool Secondary { get; set; }
        internal ShelfLabel() { UseMnemonic = false; AutoEllipsis = true; }
    }

    internal sealed class ShelfButton : Button
    {
        private bool iconOnly;
        private bool hovering;
        private bool pressing;
        private bool selected;
        private readonly Glyph glyph;
        internal bool Quiet { get; set; }
        internal bool Emphasized { get; set; }
        internal bool Selected { get => selected; set { if (value != selected) { selected = value; Invalidate(); } } }
        internal bool IconOnly
        {
            get => iconOnly;
            set
            {
                if (iconOnly == value) return;
                iconOnly = value;
                Parent?.PerformLayout(this, nameof(PreferredSize));
                Invalidate();
            }
        }

        internal ShelfButton(string text, Glyph glyph, bool iconOnly)
        {
            this.glyph = glyph;
            this.iconOnly = iconOnly;
            Text = AccessibleName = text;
            UseMnemonic = false;
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            // Parent-background painting can replay sibling drawing when a themed child is transparent.
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.Opaque | ControlStyles.ResizeRedraw, true);
            SetStyle(ControlStyles.SupportsTransparentBackColor, false);
            AutoSize = true;
            Size = new Size(30, 29);
            Margin = new Padding(2);
            if (iconOnly) Cursor = Cursors.Hand;
        }

        public override Size GetPreferredSize(Size proposedSize)
        {
            var scale = DeviceDpi / 96f;
            var width = iconOnly ? 30 * scale : TextRenderer.MeasureText(Text, Font).Width + (glyph == Glyph.None ? 22 : 44) * scale;
            return new Size((int)Math.Ceiling(width), Math.Max((int)(29 * scale), Font.Height + (int)(8 * scale)));
        }

        protected override void OnPaint(PaintEventArgs args)
        {
            using (var background = new SolidBrush(BackColor)) args.Graphics.FillRectangle(background, ClientRectangle);
            var rect = Rectangle.Inflate(ClientRectangle, -1, -1);
            var fill = pressing || selected || hovering ? Theme.ColorFor(Fill.Selected) : Theme.ColorFor(Fill.Field);
            if (Emphasized && Enabled) fill = Theme.Highlight;
            if (hovering || selected || pressing || Emphasized || !Quiet)
                Theme.Rounded(args.Graphics, rect, 6, fill, Theme.HighContrast ? Theme.Line : default);
            if (Focused && ShowFocusCues)
                Theme.Rounded(args.Graphics, Rectangle.Inflate(rect, -2, -2), 5, Color.Transparent, Theme.Accent);
            var ink = Enabled ? Emphasized || (Theme.HighContrast && (selected || hovering || pressing)) ? Theme.HighlightText : Theme.Ink : Theme.Muted;
            var iconColor = selected && !Theme.HighContrast ? Theme.Accent : ink;
            var iconSize = Math.Min(Height - 10, (int)(15 * DeviceDpi / 96f));
            var x = iconOnly ? (Width - iconSize) / 2 : (int)(11 * DeviceDpi / 96f);
            if (glyph != Glyph.None) ShelfGlyph.Draw(args.Graphics, glyph, new Rectangle(x, (Height - iconSize) / 2, iconSize, iconSize), iconColor);
            if (!iconOnly)
            {
                var left = glyph == Glyph.None ? 0 : x + iconSize + 6;
                TextRenderer.DrawText(args.Graphics, Text, Selected ? Theme.Semibold : Font,
                    new Rectangle(left, 0, Math.Max(1, Width - left - (glyph == Glyph.None ? 0 : 8)), Height), ink,
                    Theme.SingleLine | (glyph == Glyph.None ? TextFormatFlags.HorizontalCenter : TextFormatFlags.Left));
            }
        }
        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); hovering = true; Invalidate(); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hovering = pressing = false; Invalidate(); }
        protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); pressing = e.Button == MouseButtons.Left; Invalidate(); }
        protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); pressing = false; Invalidate(); }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); pressing = false; Invalidate(); }
    }
}
