using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace S3Shelf
{
    internal sealed class PathBar : Panel
    {
        private readonly TextBox input = new TextBox { BorderStyle = BorderStyle.None, AccessibleName = "S3 路径" };
        private readonly ShelfButton edit = Theme.Button("编辑路径", Glyph.Edit, true);
        private readonly ShelfButton root = Theme.Button("存储桶根目录", Glyph.Folder, true);
        private readonly ShelfButton overflow = Theme.Button("上级路径", Glyph.More, true);
        private readonly List<ShelfButton> segments = new List<ShelfButton>();
        private string location = "";
        private bool editing;
        internal event Action<string> Go;
        internal event Action<string> Navigate;

        internal PathBar()
        {
            Dock = DockStyle.Fill;
            SetStyle(ControlStyles.OptimizedDoubleBuffer, true);
            Theme.Paint(this, Fill.Stripe);
            Margin = new Padding(4, 2, 4, 2);
            Theme.Paint(input, Fill.Stripe);
            Controls.AddRange(new Control[] { edit, root, overflow, input });
            edit.AutoSize = root.AutoSize = overflow.AutoSize = false;
            edit.Quiet = root.Quiet = overflow.Quiet = true;
            root.Click += (sender, args) => Navigate?.Invoke("");
            edit.Click += (sender, args) => StartEdit();
            overflow.Click += (sender, args) => ShowAncestors();
            MouseClick += (sender, args) => { if (args.Button == MouseButtons.Left) StartEdit(); };
            AccessibleName = "对象路径";
            input.KeyDown += (sender, args) =>
            {
                if (args.KeyCode != Keys.Enter && args.KeyCode != Keys.Escape) return;
                args.SuppressKeyPress = true;
                var value = input.Text;
                StopEdit();
                if (args.KeyCode == Keys.Enter) Go?.Invoke(value);
            };
            input.LostFocus += (sender, args) => StopEdit();
            SetLocation(null, "");
        }

        internal void SetLocation(string bucket, string prefix)
        {
            location = bucket == null ? "" : "s3://" + bucket + "/" + prefix;
            editing = false;
            SuspendLayout();
            foreach (var segment in segments) { Controls.Remove(segment); segment.Dispose(); }
            segments.Clear();
            var start = 0;
            while (start < prefix.Length)
            {
                var next = prefix.IndexOf('/', start);
                if (next < 0) break;
                var path = prefix.Substring(0, next + 1);
                var name = next == start ? "/" : prefix.Substring(start, next - start);
                var button = Theme.Button("›  " + name);
                button.AutoSize = false;
                button.AccessibleName = name;
                button.Quiet = true;
                button.Click += (sender, args) => Navigate?.Invoke(path);
                button.Tag = path;
                segments.Add(button);
                Controls.Add(button);
                start = next + 1;
            }
            ResumeLayout(true);
            PerformLayout();
        }

        internal void StartEdit()
        {
            if (!Enabled) return;
            editing = true;
            input.Text = location;
            PerformLayout();
            input.Focus(); input.SelectAll();
        }

        private void StopEdit()
        {
            if (!editing) return;
            editing = false;
            PerformLayout();
        }

        private void ShowAncestors()
        {
            var menu = new ContextMenuStrip();
            for (var i = 0; i < segments.Count; i++)
            {
                if (segments[i].Visible) continue;
                var path = (string)segments[i].Tag;
                menu.Items.Add(path.Replace("&", "&&"), null, (sender, args) => Navigate?.Invoke(path));
            }
            menu.Closed += (sender, args) => menu.Dispose();
            Theme.TintMenu(menu);
            menu.Show(overflow, new Point(0, overflow.Height));
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            if (edit == null) return;
            var controlWidth = edit.PreferredSize.Width;
            var y = 2;
            var height = Math.Max(1, Height - 4);
            var right = Math.Max(4, Width - controlWidth - 3);
            edit.SetBounds(right, y, controlWidth, height);
            root.SetBounds(3, y, controlWidth, height);
            overflow.SetBounds(controlWidth + 3, y, controlWidth, height);
            input.SetBounds(9, (Height - input.PreferredHeight) / 2, Math.Max(1, Width - 18), input.PreferredHeight);
            input.Visible = editing;
            edit.Visible = root.Visible = !editing;
            var start = controlWidth + 3;
            var first = 0;
            var offset = start;
            var free = right - start - 6;
            if (!editing && segments.Count > 0)
            {
                var reserve = Math.Min(Math.Max(0, free), controlWidth);
                var remaining = free;
                first = segments.Count;
                while (first > 0)
                {
                    var width = segments[first - 1].PreferredSize.Width;
                    if (width > remaining) break;
                    first--;
                    remaining -= width;
                }
                while (first > 0 && first < segments.Count && remaining < reserve)
                {
                    remaining += segments[first].PreferredSize.Width;
                    first++;
                }
                if (first > 0) offset += reserve;
            }
            overflow.Visible = !editing && first > 0 && free >= controlWidth;
            for (var i = 0; i < segments.Count; i++)
            {
                var segment = segments[i];
                var show = !editing && (i >= first || i == segments.Count - 1) && right - offset >= 18;
                segment.Visible = show;
                if (!show) continue;
                var width = Math.Min(right - offset, segment.PreferredSize.Width);
                segment.SetBounds(offset, y, width, height);
                offset += width;
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            using (var background = new SolidBrush(Parent?.BackColor ?? Theme.Surface))
                e.Graphics.FillRectangle(background, ClientRectangle);
            Theme.Rounded(e.Graphics, Rectangle.Inflate(ClientRectangle, -1, -1), 6, BackColor, editing ? Theme.Accent : default);
        }
    }

    internal sealed class FilterField : Panel
    {
        private readonly ShelfLabel placeholder = Theme.Label("筛选已加载对象", true);
        internal TextBox Input { get; } = Theme.Paint(new TextBox { BorderStyle = BorderStyle.None, AccessibleName = "筛选已加载对象" }, Fill.Surface);

        internal FilterField()
        {
            Dock = DockStyle.Fill;
            SetStyle(ControlStyles.OptimizedDoubleBuffer, true);
            Controls.AddRange(new Control[] { placeholder, Input });
            placeholder.Click += (sender, args) => Input.Focus();
            MouseClick += (sender, args) => Input.Focus();
            Input.TextChanged += (sender, args) => Sync();
            Input.GotFocus += (sender, args) => Sync();
            Input.LostFocus += (sender, args) => Sync();
        }

        private void Sync() { placeholder.Visible = Input.TextLength == 0 && !Input.Focused; Invalidate(); }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            if (Input == null || placeholder == null) return;
            var left = 27 * DeviceDpi / 96;
            var width = Math.Max(1, Width - left - 8);
            Input.SetBounds(left, (Height - Input.PreferredHeight) / 2, width, Input.PreferredHeight);
            placeholder.SetBounds(left, 2, width, Math.Max(1, Height - 4));
            placeholder.TextAlign = ContentAlignment.MiddleLeft;
            placeholder.BringToFront();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Theme.Rounded(e.Graphics, Rectangle.Inflate(ClientRectangle, -1, -1), 6, Theme.Surface, Input.Focused ? Theme.Accent : Theme.Line);
            var size = Math.Min(Height - 6, 14 * DeviceDpi / 96);
            ShelfGlyph.Draw(e.Graphics, Glyph.Search, new Rectangle(7, (Height - size) / 2, size, size), Theme.Muted);
        }
    }
}
