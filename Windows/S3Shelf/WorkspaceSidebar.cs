using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace S3Shelf
{
    internal sealed class WorkspaceSidebar : Panel
    {
        private readonly ShelfSidebarList connections = new ShelfSidebarList("连接清单", item => ((Connection)item).Endpoint.Length == 0 ? Glyph.Cloud : Glyph.Server);
        private readonly ShelfSidebarList buckets = new ShelfSidebarList("存储桶清单", item => Glyph.Bucket);
        private readonly ShelfButton browse = Theme.Button("对象浏览", Glyph.Browser);
        private readonly ShelfButton transfers = Theme.Button("传输队列", Glyph.Transfer);
        private readonly ShelfButton configuration = Theme.Button("配置", Glyph.Settings);
        private readonly ShelfButton add = Theme.Button("新建连接", Glyph.Add, true);
        private readonly ShelfButton create = Theme.Button("创建存储桶", Glyph.Add, true);
        private readonly ShelfButton bucketActions = Theme.Button("存储桶操作", Glyph.More, true);
        private readonly ShelfButton edit = Theme.Button("连接设置", Glyph.Settings, true);
        private readonly ShelfButton split = Theme.Button("分屏", Glyph.Split);
        private readonly ShelfButton more = Theme.Button("加载更多存储桶");
        private readonly ActivitySpinner transferActivity = new ActivitySpinner();
        private readonly ActivitySpinner bucketActivity = new ActivitySpinner();
        private readonly ShelfLabel region = Theme.Label("", true);
        private readonly ShelfLabel bucketHint = Theme.Label("选择连接后显示存储桶", true);
        private readonly RowStyle connectionsHeight;
        private readonly RowStyle moreHeight;
        private bool updating;

        internal WorkspaceSidebar(MainWindow window)
        {
            Dock = DockStyle.Fill;
            Margin = Padding.Empty;
            Padding = new Padding(10, 9, 10, 0);
            Theme.Paint(this, Fill.Sidebar);
            foreach (var button in new[] { browse, transfers, configuration, add, create, bucketActions, edit, split, more })
            {
                button.Quiet = true;
                window.NameIcon(button);
            }
            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 10, Margin = Padding.Empty };
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 30));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 31));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 31));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 31));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
            connectionsHeight = new RowStyle(SizeType.Absolute, 30);
            layout.RowStyles.Add(connectionsHeight);
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            moreHeight = new RowStyle(SizeType.Absolute, 0);
            layout.RowStyles.Add(moreHeight);
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
            layout.Controls.Add(Group("工作区", split), 0, 0);
            layout.Controls.Add(Row(browse), 0, 1);
            layout.Controls.Add(Row(transfers, transferActivity), 0, 2);
            layout.Controls.Add(Row(configuration), 0, 3);
            layout.Controls.Add(Group("连接", add), 0, 4);
            layout.Controls.Add(connections, 0, 5);
            bucketActivity.AccessibleName = "正在加载存储桶";
            layout.Controls.Add(Group("存储桶", bucketActions, create, bucketActivity), 0, 6);
            var bucketArea = new Panel { Dock = DockStyle.Fill, Margin = Padding.Empty };
            bucketHint.Dock = DockStyle.Top;
            bucketHint.Height = 31;
            bucketHint.Padding = new Padding(9, 5, 0, 0);
            bucketArea.Controls.Add(buckets);
            bucketArea.Controls.Add(bucketHint);
            layout.Controls.Add(bucketArea, 0, 7);
            layout.Controls.Add(Row(more), 0, 8);
            region.Padding = new Padding(7, 0, 0, 0);
            region.Font = Theme.Semibold;
            layout.Controls.Add(Row(region, edit), 0, 9);
            Controls.Add(layout);

            browse.Click += (sender, args) => window.ShowTransfers(false);
            transfers.Click += (sender, args) => window.ShowTransfers(true);
            configuration.Click += async (sender, args) => await window.ShowConfigurationAsync();
            split.Click += async (sender, args) => await window.ToggleSplitAsync();
            add.Click += async (sender, args) => await window.ManageConnectionAsync(false, false);
            edit.Click += async (sender, args) => await window.ManageConnectionAsync(true, false);
            create.Click += async (sender, args) => await window.CreateBucketAsync();
            bucketActions.Click += (sender, args) => window.ShowBucketMenu(bucketActions);
            more.Click += async (sender, args) => await window.LoadMoreBucketsAsync();
            connections.SelectedIndexChanged += async (sender, args) =>
            {
                if (!updating && connections.SelectedItem is Connection value) await window.OpenConnectionAsync(value);
            };
            buckets.SelectedIndexChanged += async (sender, args) =>
            {
                if (!updating && buckets.SelectedItem is string name) await window.OpenBucketAsync(name);
            };
            connections.MouseClick += (sender, args) => { if (args.Button == MouseButtons.Left && connections.IndexFromPoint(args.Location) >= 0) window.ShowTransfers(false); };
            buckets.MouseClick += (sender, args) => { if (args.Button == MouseButtons.Left && buckets.IndexFromPoint(args.Location) >= 0) window.ShowTransfers(false); };
            var connectionMenu = new ContextMenuStrip();
            connectionMenu.Items.Add("编辑连接…", null, async (sender, args) => await window.ManageConnectionAsync(true, false));
            connectionMenu.Items.Add(new ToolStripSeparator());
            connectionMenu.Items.Add("移除连接…", null, async (sender, args) => await window.ManageConnectionAsync(true, true));
            connections.ContextMenuStrip = connectionMenu;
            connectionMenu.Opening += (sender, args) => { args.Cancel = !edit.Enabled; Theme.TintMenu(connectionMenu); };
            connections.MouseDown += (sender, args) => SelectContextRow(connections, args);
            buckets.MouseDown += (sender, args) => SelectContextRow(buckets, args);
            buckets.MouseUp += (sender, args) =>
            {
                if (args.Button == MouseButtons.Right && buckets.IndexFromPoint(args.Location) >= 0) window.ShowBucketMenu(buckets, args.Location);
            };
        }

        private static void SelectContextRow(ListBox list, MouseEventArgs args)
        {
            if (args.Button != MouseButtons.Right) return;
            var index = list.IndexFromPoint(args.Location);
            if (index >= 0) list.SelectedIndex = index;
        }

        internal void ShowPane(IReadOnlyList<Connection> values, BrowserPane pane)
        {
            updating = true;
            try
            {
                connectionsHeight.Height = Math.Min(values.Count, 5) * connections.ItemHeight;
                SyncList(connections, values.Cast<object>(), pane?.CurrentConnection);
                var names = pane?.BucketNames ?? Array.Empty<string>();
                if (pane?.Bucket is string selected && !names.Contains(selected)) names = new[] { selected }.Concat(names).ToArray();
                SyncList(buckets, names.Cast<object>(), pane?.Bucket);
                more.Visible = pane?.HasMoreBuckets == true;
                more.Enabled = pane?.BucketsLoading == false;
                moreHeight.Height = pane?.HasMoreBuckets == true ? more.PreferredSize.Height + 2 : 0;
                bucketActivity.SetRunning(pane?.BucketsLoading == true);
                bucketHint.Visible = pane?.CurrentConnection != null && names.Count == 0;
                bucketHint.Text = pane?.BucketsLoading == true ? "正在读取存储桶…" : "没有可显示的存储桶";
                region.Text = pane?.CurrentConnection?.RegionLabel ?? "";
            }
            finally { updating = false; }
        }

        internal void UpdateCommands(bool canAdd, bool canEdit, bool canCreate, bool hasConnection, bool showTransfers, bool splitOpen, bool transferring)
        {
            add.Enabled = canAdd;
            edit.Enabled = canEdit;
            edit.Visible = hasConnection;
            create.Enabled = canCreate;
            bucketActions.Enabled = hasConnection;
            browse.Selected = !showTransfers;
            transfers.Selected = showTransfers;
            split.Selected = splitOpen;
            transferActivity.SetRunning(transferring);
        }

        private static void SyncList(ListBox list, IEnumerable<object> values, object selected)
        {
            var items = values.ToArray();
            var top = Math.Max(0, list.TopIndex);
            if (!items.SequenceEqual(list.Items.Cast<object>()))
            {
                list.BeginUpdate();
                list.Items.Clear();
                list.Items.AddRange(items);
                list.EndUpdate();
            }
            var index = selected == null ? -1 : Array.IndexOf(items, selected);
            if (list.SelectedIndex != index) list.SelectedIndex = index;
            if (items.Length == 0) return;
            var visibleRows = Math.Max(1, list.ClientSize.Height / list.ItemHeight);
            if (items.Length <= visibleRows) list.TopIndex = 0;
            else if (index >= 0) list.TopIndex = Math.Max(0, Math.Min(Math.Max(top, index - visibleRows + 1), index));
        }

        private static Control Group(string title, params Control[] actions)
        {
            var heading = Theme.Label(title, true);
            heading.Font = Theme.Semibold;
            heading.Padding = new Padding(8, 1, 0, 0);
            return Row(heading, actions);
        }

        private static Control Row(Control main, params Control[] trailing)
        {
            var row = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1 + trailing.Length, RowCount = 1, Margin = Padding.Empty };
            row.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            foreach (var ignored in trailing) row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            if (main is ShelfLabel label) label.TextAlign = ContentAlignment.MiddleLeft;
            main.Dock = DockStyle.Fill;
            row.Controls.Add(main, 0, 0);
            for (var i = 0; i < trailing.Length; i++)
            {
                trailing[i].Anchor = AnchorStyles.Right;
                row.Controls.Add(trailing[i], i + 1, 0);
            }
            return row;
        }
    }

    internal sealed class PaneEmptyState : Panel
    {
        private readonly ShelfButton action = Theme.Button("");
        private string title = "";
        private string subtitle = "";
        private Glyph glyph;
        private Icon icon;
        private bool showAction;

        internal PaneEmptyState()
        {
            Theme.Paint(this, Fill.Surface);
            SetStyle(ControlStyles.ResizeRedraw | ControlStyles.OptimizedDoubleBuffer, true);
            action.Visible = false;
            action.Emphasized = true;
            Controls.Add(action);
        }

        internal event EventHandler ActionClicked
        {
            add { action.Click += value; }
            remove { action.Click -= value; }
        }

        internal void SetMessage(Glyph symbol, string heading, string message, string actionText = "", Icon appIcon = null, bool canAct = true)
        {
            glyph = symbol;
            icon = appIcon;
            title = heading;
            subtitle = message;
            AccessibleName = heading + " " + message;
            showAction = actionText.Length > 0;
            action.Text = action.AccessibleName = actionText;
            action.Enabled = canAct;
            action.Visible = showAction;
            PerformLayout();
            Invalidate();
        }

        private Rectangle IconBounds()
        {
            var scale = DeviceDpi / 96f;
            var size = (int)((icon == null ? 30 : 68) * scale);
            var textHeight = (subtitle.Length == 0 ? 34 : 60) * scale;
            var actionHeight = showAction ? action.PreferredSize.Height + 14 * scale : 0;
            var top = Math.Max(6, (int)((Height - size - textHeight - actionHeight) / 2));
            return new Rectangle((Width - size) / 2, top, size, size);
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            if (action == null || !showAction) return;
            var scale = DeviceDpi / 96f;
            var size = action.PreferredSize;
            var y = IconBounds().Bottom + (int)((subtitle.Length == 0 ? 44 : 68) * scale);
            action.SetBounds((Width - size.Width) / 2, y, size.Width, size.Height);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var scale = DeviceDpi / 96f;
            var picture = IconBounds();
            if (icon != null) e.Graphics.DrawIcon(icon, picture);
            else ShelfGlyph.Draw(e.Graphics, glyph, picture, Theme.Muted);
            var bounds = new Rectangle(10, picture.Bottom + (int)(8 * scale), Math.Max(1, Width - 20), (int)(27 * scale));
            const TextFormatFlags centered = Theme.SingleLine | TextFormatFlags.HorizontalCenter;
            TextRenderer.DrawText(e.Graphics, title, showAction ? Theme.Heading : Theme.Semibold, bounds, Theme.Ink, centered);
            bounds.Y += bounds.Height;
            TextRenderer.DrawText(e.Graphics, subtitle, Font, bounds, Theme.Muted, centered);
        }
    }
}
