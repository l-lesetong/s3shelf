using System;
using System.Drawing;
using System.Windows.Forms;

namespace S3Shelf
{
    internal sealed class ShelfListView : ListView
    {
        private readonly ImageList metrics = new ImageList();
        private readonly bool objectIcons;

        internal ShelfListView(bool objectIcons)
        {
            this.objectIcons = objectIcons;
            Dock = DockStyle.Fill;
            BorderStyle = BorderStyle.None;
            View = View.Details;
            FullRowSelect = true;
            HideSelection = false;
            MultiSelect = false;
            OwnerDraw = true;
            DoubleBuffered = true;
            SmallImageList = metrics;
            UpdateHeight();
        }

        private void UpdateHeight()
        {
            if (metrics != null) metrics.ImageSize = new Size(1, Math.Max(Font.Height + 7, (int)(25 * DeviceDpi / 96f)));
        }

        protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); UpdateHeight(); }
        protected override void OnDpiChangedAfterParent(EventArgs e) { base.OnDpiChangedAfterParent(e); UpdateHeight(); }
        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                SmallImageList = null;
                metrics.Dispose();
            }
            base.Dispose(disposing);
        }

        protected override void OnDrawColumnHeader(DrawListViewColumnHeaderEventArgs e)
        {
            using (var fill = new SolidBrush(Theme.Surface)) e.Graphics.FillRectangle(fill, e.Bounds);
            using (var pen = new Pen(Theme.Line))
            {
                e.Graphics.DrawLine(pen, e.Bounds.Left, e.Bounds.Bottom - 1, e.Bounds.Right, e.Bounds.Bottom - 1);
                if (e.ColumnIndex > 0) e.Graphics.DrawLine(pen, e.Bounds.Left, e.Bounds.Top + 5, e.Bounds.Left, e.Bounds.Bottom - 5);
            }
            TextRenderer.DrawText(e.Graphics, e.Header.Text, Font, Rectangle.Inflate(e.Bounds, -10, 0), Theme.Muted,
                Theme.SingleLine);
        }

        protected override void OnDrawSubItem(DrawListViewSubItemEventArgs e)
        {
            var bounds = e.Bounds;
            bounds.Width = Math.Min(bounds.Width, e.Header.Width);
            if (bounds.Width <= 1 || bounds.Height <= 1) return;
            var selected = SelectedIndices.Contains(e.ItemIndex);
            var fill = selected ? Theme.Highlight : Theme.ColorFor((e.ItemIndex & 1) == 0 ? Fill.Surface : Fill.Stripe);
            var ink = selected ? Theme.HighlightText : e.ColumnIndex == 0 ? Theme.Ink : Theme.Muted;
            using (var brush = new SolidBrush(fill)) e.Graphics.FillRectangle(brush, bounds);
            var text = Rectangle.Inflate(bounds, -10, 0);
            if (objectIcons && e.ColumnIndex == 0)
            {
                var size = Math.Min(e.Bounds.Height - 5, 14 * DeviceDpi / 96);
                var folder = e.Item.Tag is ObjectEntry entry && entry.Folder;
                ShelfGlyph.Draw(e.Graphics, folder ? Glyph.Folder : Glyph.File,
                    new Rectangle(text.X, e.Bounds.Y + (e.Bounds.Height - size) / 2, size, size), folder && !selected ? Theme.Accent : selected ? ink : Theme.Muted);
                text.X += size + 7;
                text.Width -= size + 7;
            }
            if (text.Width > 0) TextRenderer.DrawText(e.Graphics, e.SubItem?.Text ?? "", Font, text, ink,
                Theme.SingleLine);
        }
    }

    internal sealed class ShelfSidebarList : ListBox
    {
        private readonly Func<object, Glyph> glyph;
        internal ShelfSidebarList(string name, Func<object, Glyph> glyph)
        {
            this.glyph = glyph;
            AccessibleName = name;
            Dock = DockStyle.Fill;
            IntegralHeight = false;
            DrawMode = DrawMode.OwnerDrawFixed;
            BorderStyle = BorderStyle.None;
            ItemHeight = 30;
            Margin = Padding.Empty;
            Theme.Paint(this, Fill.Sidebar);
        }

        protected override void OnDpiChangedAfterParent(EventArgs e) { base.OnDpiChangedAfterParent(e); ItemHeight = 30 * DeviceDpi / 96; }

        protected override void OnDrawItem(DrawItemEventArgs e)
        {
            using (var brush = new SolidBrush(Theme.ColorFor(Fill.Sidebar))) e.Graphics.FillRectangle(brush, e.Bounds);
            if (e.Index < 0 || e.Index >= Items.Count) return;
            var selected = (e.State & DrawItemState.Selected) != 0;
            if (selected) Theme.Rounded(e.Graphics, Rectangle.Inflate(e.Bounds, -2, -2), 6, Theme.ColorFor(Fill.Selected));
            var size = Math.Min(e.Bounds.Height - 8, 15 * DeviceDpi / 96);
            var ink = selected && Theme.HighContrast ? Theme.HighlightText : Theme.Ink;
            var icon = selected && !Theme.HighContrast ? Theme.Accent : selected ? ink : Theme.Muted;
            ShelfGlyph.Draw(e.Graphics, glyph(Items[e.Index]), new Rectangle(e.Bounds.X + 9, e.Bounds.Y + (e.Bounds.Height - size) / 2, size, size), icon);
            var text = new Rectangle(e.Bounds.X + size + 17, e.Bounds.Y, Math.Max(0, e.Bounds.Width - size - 23), e.Bounds.Height);
            TextRenderer.DrawText(e.Graphics, GetItemText(Items[e.Index]), selected ? Theme.Semibold : Font, text, ink,
                Theme.SingleLine);
            if ((e.State & DrawItemState.Focus) != 0 && Focused && ShowFocusCues)
                Theme.Rounded(e.Graphics, Rectangle.Inflate(e.Bounds, -3, -3), 5, Color.Transparent, Theme.Accent);
        }
    }

    internal sealed class ActivitySpinner : Control
    {
        private readonly Timer timer = new Timer { Interval = 75 };
        private bool running;
        private int phase;

        internal ActivitySpinner()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.Opaque, true);
            Size = new Size(20, 20);
            AccessibleName = "传输进行中";
            TabStop = false;
            Visible = false;
            timer.Tick += (sender, args) => { phase = (phase + 1) % 12; Invalidate(); };
        }

        internal void SetRunning(bool value)
        {
            if (running == value) return;
            running = value;
            Visible = value;
            timer.Enabled = value;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            using (var background = new SolidBrush(BackColor)) e.Graphics.FillRectangle(background, ClientRectangle);
            if (!running) return;
            var size = Math.Min(Width, Height) - 8;
            if (size <= 0) return;
            e.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            var arc = new Rectangle((Width - size) / 2, (Height - size) / 2, size, size);
            using (var track = new Pen(Theme.Line, 2f)) e.Graphics.DrawEllipse(track, arc);
            using (var pen = new Pen(Theme.Accent, 2f)) e.Graphics.DrawArc(pen, arc, phase * 30, 245);
        }

        protected override void Dispose(bool disposing) { if (disposing) timer.Dispose(); base.Dispose(disposing); }
    }
}
