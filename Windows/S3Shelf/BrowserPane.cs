using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Amazon.S3;
using Amazon.S3.Model;

namespace S3Shelf
{
    internal sealed partial class BrowserPane : Panel
    {
        private readonly MainWindow window;
        private readonly ComboBox connections = new ComboBox { Width = 150, DropDownStyle = ComboBoxStyle.DropDownList };
        private readonly ComboBox buckets = new ComboBox { Width = 180, DropDownStyle = ComboBoxStyle.DropDownList };
        private readonly TextBox path = new TextBox { Dock = DockStyle.Fill };
        private readonly TextBox filter = new TextBox { Dock = DockStyle.Fill };
        private readonly ListView objects = Theme.List();
        private readonly Button more = Theme.Button("加载下一页");
        private readonly Button moreBuckets = Theme.Button("更多桶");
        private readonly Button detailsToggle = Theme.Button("详情");
        private readonly Label status = new Label { AutoSize = true, ForeColor = Theme.Muted, Padding = new Padding(0, 4, 0, 0) };
        private readonly List<ObjectEntry> entries = new List<ObjectEntry>();
        private readonly HashSet<string> keys = new HashSet<string>(StringComparer.Ordinal);
        private readonly HashSet<string> cursors = new HashSet<string>(StringComparer.Ordinal);
        private readonly HashSet<string> bucketCursors = new HashSet<string>(StringComparer.Ordinal);
        private readonly TimerFilter searchDelay;
        private SplitContainer body;
        private IReadOnlyList<ObjectEntry> visibleEntries = Array.Empty<ObjectEntry>();
        private CancellationTokenSource listing = new CancellationTokenSource();
        private CancellationTokenSource bucketListing = new CancellationTokenSource();
        private Connection connection;
        private string bucket;
        private string prefix = "";
        private string next;
        private string nextBucket;
        private bool changingMenus;
        private bool listingBusy;
        private bool bucketBusy;
        private bool active;

        internal BrowserPane(MainWindow window)
        {
            this.window = window;
            searchDelay = new TimerFilter(RenderObjects);
            Dock = DockStyle.Fill;
            BackColor = Theme.Surface;
            Padding = new Padding(3);
            var toolbar = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, WrapContents = true, Margin = Padding.Empty, Padding = new Padding(5, 3, 5, 1), BackColor = Theme.Chrome };
            var manual = Theme.Button("打开桶…");
            moreBuckets.Enabled = more.Enabled = false;
            connections.AccessibleName = "连接";
            buckets.AccessibleName = "存储桶";
            toolbar.Controls.AddRange(new Control[] { connections, buckets, moreBuckets, manual, detailsToggle });
            foreach (var combo in new[] { connections, buckets }) { combo.BackColor = Theme.Surface; combo.ForeColor = Theme.Ink; }

            var navigation = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 4, RowCount = 1, Height = 36, Padding = new Padding(5, 2, 5, 1), BackColor = Theme.Chrome };
            navigation.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            navigation.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            navigation.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            navigation.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            var up = Theme.Button("上一级");
            var reload = Theme.Button("刷新");
            var go = Theme.Button("转到");
            path.AccessibleName = "对象路径";
            path.BackColor = filter.BackColor = Theme.Surface;
            path.ForeColor = filter.ForeColor = Theme.Ink;
            navigation.Controls.Add(up, 0, 0);
            navigation.Controls.Add(reload, 1, 0);
            navigation.Controls.Add(path, 2, 0);
            navigation.Controls.Add(go, 3, 0);

            var search = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, Height = 34, Padding = new Padding(7, 2, 5, 1), BackColor = Theme.Chrome };
            search.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            search.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            search.Controls.Add(new Label { Text = "筛选已加载对象", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 0);
            filter.AccessibleName = "筛选已加载对象";
            search.Controls.Add(filter, 1, 0);

            objects.VirtualMode = true;
            objects.Columns.Add("名称", 310);
            objects.Columns.Add("大小", 86);
            objects.Columns.Add("更新时间", 156);
            objects.Columns.Add("存储类", 99);
            objects.RetrieveVirtualItem += (sender, args) =>
            {
                if (args.ItemIndex < 0 || args.ItemIndex >= visibleEntries.Count)
                {
                    args.Item = new ListViewItem();
                    return;
                }
                var entry = visibleEntries[args.ItemIndex];
                args.Item = new ListViewItem(new[] { DisplayKey(entry), entry.Size?.ToString("N0") ?? "", entry.Modified?.ToLocalTime().ToString("yyyy-MM-dd HH:mm") ?? "", entry.StorageClass ?? "" });
                if (args.ItemIndex % 2 == 1) args.Item.BackColor = Theme.Chrome;
            };
            objects.SelectedIndexChanged += (sender, args) => { window.UpdateCommands(); SelectionChanged(); };
            objects.DoubleClick += async (sender, args) => { var entry = Selected; if (entry?.Folder == true) await OpenAsync(bucket, entry.Key); else if (entry != null) window.Download(); };
            objects.KeyDown += async (sender, args) =>
            {
                if (args.KeyCode == Keys.Enter && Selected?.Folder == true) { args.SuppressKeyPress = true; await OpenAsync(bucket, Selected.Key); }
            };
            objects.Resize += (sender, args) => objects.Columns[0].Width = Math.Max(135, objects.ClientSize.Width - 367);
            var context = new ContextMenuStrip();
            var download = context.Items.Add("下载…", null, (sender, args) => window.Download());
            var copy = context.Items.Add("复制 S3 URI", null, (sender, args) => window.CopyUri());
            var delete = context.Items.Add("删除对象…", null, async (sender, args) => await window.DeleteObjectAsync());
            context.Opening += (sender, args) =>
            {
                window.ActivatePane(this);
                download.Enabled = Selected != null && !Selected.Folder;
                copy.Enabled = HasBucket;
                delete.Enabled = CanWrite && download.Enabled;
            };
            objects.ContextMenuStrip = context;

            body = new SplitContainer { Dock = DockStyle.Fill, Orientation = Orientation.Horizontal, Panel2Collapsed = true, BackColor = Theme.Chrome, SplitterWidth = 5 };
            body.Panel1.Controls.Add(objects);
            body.Panel2.Controls.Add(MakeDetails());
            var footer = new FlowLayoutPanel { Dock = DockStyle.Fill, Height = 36, WrapContents = false, BackColor = Theme.Chrome, Padding = new Padding(6, 2, 0, 0) };
            footer.Controls.AddRange(new Control[] { status, more });
            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 5, Margin = Padding.Empty, Padding = Padding.Empty };
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
            layout.Controls.Add(toolbar, 0, 0);
            layout.Controls.Add(navigation, 0, 1);
            layout.Controls.Add(search, 0, 2);
            layout.Controls.Add(body, 0, 3);
            layout.Controls.Add(footer, 0, 4);
            Controls.Add(layout);

            connections.SelectedIndexChanged += async (sender, args) => { if (!changingMenus) await ConnectAsync((Connection)connections.SelectedItem); };
            buckets.SelectedIndexChanged += async (sender, args) => { if (!changingMenus && buckets.SelectedItem is string name) await OpenAsync(name, ""); };
            moreBuckets.Click += async (sender, args) => await LoadBucketsAsync(true);
            more.Click += async (sender, args) => await LoadObjectsAsync(true);
            manual.Click += async (sender, args) =>
            {
                if (connection == null) { window.ShowError("请先选择连接。", "打开存储桶"); return; }
                var name = Dialog.Ask(window, "打开存储桶", "存储桶名称");
                if (!string.IsNullOrWhiteSpace(name)) await OpenAsync(name.Trim(), "");
            };
            detailsToggle.Click += (sender, args) => ToggleDetails();
            up.Click += async (sender, args) => await UpAsync();
            reload.Click += async (sender, args) => await RefreshAsync();
            go.Click += async (sender, args) => await GoAsync();
            path.KeyDown += async (sender, args) => { if (args.KeyCode == Keys.Enter) { args.SuppressKeyPress = true; await GoAsync(); } };
            filter.TextChanged += (sender, args) => searchDelay.Restart();
            InstallFocusHandlers(layout);
            status.Text = "选择连接以打开存储桶";
        }

        internal Connection CurrentConnection => connection;
        internal string Bucket => bucket;
        internal string Prefix => prefix;
        internal bool HasBucket => connection != null && bucket != null;
        internal bool CanWrite => connection != null && connection.Authentication != Authentication.Anonymous;
        internal ObjectEntry Selected
        {
            get
            {
                if (IsDisposed || objects.SelectedIndices.Count == 0) return null;
                var index = objects.SelectedIndices[0];
                return index >= 0 && index < visibleEntries.Count ? visibleEntries[index] : null;
            }
        }

        protected override void OnPaint(PaintEventArgs args)
        {
            base.OnPaint(args);
            if (active) ControlPaint.DrawBorder(args.Graphics, ClientRectangle, Theme.Line, 3, ButtonBorderStyle.Solid,
                Theme.Line, 3, ButtonBorderStyle.Solid, Theme.Line, 3, ButtonBorderStyle.Solid, Theme.Line, 3, ButtonBorderStyle.Solid);
        }

        internal void Active(bool value) { active = value; Invalidate(); }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                listing.Cancel(); listing.Dispose();
                bucketListing.Cancel(); bucketListing.Dispose();
                searchDelay.Dispose();
                CancelDetails();
            }
            base.Dispose(disposing);
        }

        private void InstallFocusHandlers(Control root)
        {
            root.Enter += (sender, args) => window.ActivatePane(this);
            root.MouseDown += (sender, args) => window.ActivatePane(this);
            foreach (Control child in root.Controls) InstallFocusHandlers(child);
        }

        internal async Task SetConnectionsAsync(IReadOnlyList<Connection> values, Connection preferred = null)
        {
            var previous = connection;
            var selected = preferred ?? (values.Contains(previous) ? previous : values.FirstOrDefault());
            changingMenus = true;
            connections.Items.Clear();
            connections.Items.AddRange(values.Cast<object>().ToArray());
            connections.SelectedItem = selected;
            changingMenus = false;
            if (selected != previous) await ConnectAsync(selected);
        }

        private async Task ConnectAsync(Connection selected)
        {
            bucketListing.Cancel(); bucketListing.Dispose(); bucketListing = new CancellationTokenSource();
            connection = selected;
            bucket = null;
            changingMenus = true;
            buckets.Items.Clear();
            changingMenus = false;
            ClearLocation();
            if (connection != null) await LoadBucketsAsync(false);
            else { status.Text = "选择连接以打开存储桶"; moreBuckets.Enabled = false; }
        }

        internal async Task LoadBucketsAsync(bool append)
        {
            if (connection == null || (append && (bucketBusy || nextBucket == null))) return;
            if (!append)
            {
                bucketListing.Cancel(); bucketListing.Dispose(); bucketListing = new CancellationTokenSource();
                nextBucket = null;
                bucketCursors.Clear();
            }
            var capture = bucketListing;
            var token = capture.Token;
            bucketBusy = true;
            moreBuckets.Enabled = false;
            try
            {
                using (var client = connection.Open())
                {
                    var response = await client.ListBucketsAsync(new ListBucketsRequest { MaxBuckets = 1000, ContinuationToken = nextBucket }, token);
                    if (capture != bucketListing || IsDisposed) return;
                    changingMenus = true;
                    if (!append) buckets.Items.Clear();
                    foreach (var item in response.Buckets ?? new List<S3Bucket>()) if (!buckets.Items.Contains(item.BucketName)) buckets.Items.Add(item.BucketName);
                    if (bucket != null) { if (!buckets.Items.Contains(bucket)) buckets.Items.Add(bucket); buckets.SelectedItem = bucket; }
                    changingMenus = false;
                    nextBucket = string.IsNullOrEmpty(response.ContinuationToken) || !bucketCursors.Add(response.ContinuationToken) ? null : response.ContinuationToken;
                    if (bucket == null) status.Text = buckets.Items.Count == 0 ? "可以手动打开存储桶" : "选择存储桶以浏览对象";
                }
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { }
            catch (Exception ex) { if (capture == bucketListing && !IsDisposed) window.ShowError(ex, "无法列出存储桶，可手动打开"); }
            finally { if (capture == bucketListing && !IsDisposed) { bucketBusy = false; moreBuckets.Enabled = nextBucket != null; } }
        }

        internal async Task OpenAsync(string name, string folder)
        {
            if (connection == null) return;
            ClearLocation();
            bucket = name;
            prefix = folder;
            changingMenus = true;
            if (!buckets.Items.Contains(name)) buckets.Items.Add(name);
            buckets.SelectedItem = name;
            changingMenus = false;
            path.Text = "s3://" + bucket + "/" + prefix;
            window.UpdateCommands();
            SelectionChanged();
            await LoadObjectsAsync(false);
        }

        internal void CloseBucket()
        {
            bucket = null;
            changingMenus = true;
            buckets.SelectedIndex = -1;
            changingMenus = false;
            ClearLocation();
            status.Text = "选择存储桶以浏览对象";
        }

        internal Task RefreshAsync() => HasBucket ? OpenAsync(bucket, prefix) : LoadBucketsAsync(false);

        private void ClearLocation()
        {
            listing.Cancel(); listing.Dispose(); listing = new CancellationTokenSource();
            listingBusy = false;
            entries.Clear(); keys.Clear(); cursors.Clear(); next = null;
            path.Clear();
            more.Enabled = false;
            RenderObjects();
            CancelDetails();
            detailText.Clear();
            detailStatus.Text = "";
            window.UpdateCommands();
        }

        private async Task LoadObjectsAsync(bool append)
        {
            if (listingBusy || !HasBucket || (append && next == null)) return;
            var capture = listing;
            var token = capture.Token;
            listingBusy = true;
            more.Enabled = false;
            status.Text = "正在加载对象…";
            try
            {
                using (var client = connection.Open())
                {
                    var page = await Storage.ListAsync(client, bucket, prefix, append ? next : null, token);
                    if (capture != listing || IsDisposed) return;
                    foreach (var entry in page.Entries)
                        if (keys.Add((entry.Folder ? "P" : "O") + entry.Key)) entries.Add(entry);
                    next = string.IsNullOrEmpty(page.Cursor) || !cursors.Add(page.Cursor) ? null : page.Cursor;
                    RenderObjects();
                }
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { }
            catch (Exception ex)
            {
                if (capture != listing || IsDisposed) return;
                status.Text = "加载失败，可刷新重试";
                window.ShowError(ex, "无法加载对象");
            }
            finally { if (capture == listing && !IsDisposed) { listingBusy = false; more.Enabled = next != null; } }
        }

        private Task UpAsync()
        {
            if (!HasBucket || prefix.Length == 0) return Task.CompletedTask;
            var index = prefix.Length < 2 ? -1 : prefix.LastIndexOf('/', prefix.Length - 2);
            return OpenAsync(bucket, index < 0 ? "" : prefix.Substring(0, index + 1));
        }

        private Task GoAsync()
        {
            if (connection == null) return Task.CompletedTask;
            var entered = path.Text;
            var targetBucket = bucket;
            if (entered.StartsWith("s3://", StringComparison.OrdinalIgnoreCase))
            {
                var separator = entered.IndexOf('/', 5);
                targetBucket = separator < 0 ? entered.Substring(5) : entered.Substring(5, separator - 5);
                entered = separator < 0 ? "" : entered.Substring(separator + 1);
            }
            if (string.IsNullOrWhiteSpace(targetBucket)) return Task.CompletedTask;
            if (entered.Length > 0 && !entered.EndsWith("/", StringComparison.Ordinal)) entered += "/";
            return OpenAsync(targetBucket, entered);
        }

        private string DisplayKey(ObjectEntry entry)
        {
            return entry.Key.StartsWith(prefix, StringComparison.Ordinal) ? entry.Key.Substring(prefix.Length) : entry.Key;
        }

        private void RenderObjects()
        {
            var query = filter.Text;
            objects.BeginUpdate();
            objects.SelectedIndices.Clear();
            visibleEntries = query.Length == 0 ? (IReadOnlyList<ObjectEntry>)entries : entries.Where(item => DisplayKey(item).IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0).ToArray();
            objects.VirtualListSize = visibleEntries.Count;
            objects.Invalidate();
            objects.EndUpdate();
            if (HasBucket) status.Text = query.Length == 0 ? $"已加载 {entries.Count:N0} 项" : $"匹配 {visibleEntries.Count:N0} 项 / {entries.Count:N0} 项";
        }

        private sealed class TimerFilter : IDisposable
        {
            private readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 160 };
            internal TimerFilter(Action onTick) { timer.Tick += (sender, args) => { timer.Stop(); onTick(); }; }
            internal void Restart() { timer.Stop(); timer.Start(); }
            public void Dispose() { timer.Dispose(); }
        }
    }
}
