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
        private readonly PathBar path = new PathBar();
        private readonly TextBox filter;
        private readonly ListView objects = Theme.List(true);
        private readonly ShelfButton more = Theme.Button("加载下一页");
        private readonly ShelfButton detailsToggle = Theme.Button("查看详情", Glyph.Details, true);
        private readonly ShelfButton close = Theme.Button("关闭窗格", Glyph.Close, true);
        private readonly ShelfButton up = Theme.Button("上一级", Glyph.Up, true);
        private readonly ShelfButton reload = Theme.Button("刷新对象", Glyph.Refresh, true);
        private readonly ShelfButton objectMenu = Theme.Button("对象操作", Glyph.More, true);
        private readonly ShelfButton bucketMenu = Theme.Button("存储桶设置", Glyph.Settings, true);
        private readonly ShelfLabel status = Theme.Label("", true);
        private readonly TableLayoutPanel heading;
        private readonly ShelfLabel title;
        private readonly ShelfLabel subtitle;
        private readonly PaneEmptyState empty;
        private readonly RowStyle titleHeight;
        private readonly RowStyle navigationHeight;
        private readonly RowStyle searchHeight;
        private readonly RowStyle footerHeight;
        private readonly TableLayoutPanel navigation;
        private readonly Panel searchRow;
        private readonly ColumnStyle inlineSearch;
        private readonly FilterField search;
        private IReadOnlyList<string> bucketNames = Array.Empty<string>();
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
        private bool listingBusy;
        private bool bucketBusy;
        private bool active;
        private bool compact;
        private bool listingFailed;
        private bool cachedPage;

        internal BrowserPane(MainWindow window)
        {
            this.window = window;
            searchDelay = new TimerFilter(RenderObjects);
            Dock = DockStyle.Fill;
            Margin = Padding.Empty;
            Theme.Paint(this, Fill.Surface);
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);

            heading = Theme.Paint(new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1,
                Margin = Padding.Empty, Padding = new Padding(14, 1, 10, 1) }, Fill.Surface);
            heading.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            heading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            heading.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            var titlePanel = new Panel { Dock = DockStyle.Fill };
            title = Theme.Label();
            title.Dock = DockStyle.Fill;
            title.TextAlign = ContentAlignment.MiddleLeft;
            title.Padding = new Padding(10, 0, 0, 0);
            title.Paint += DrawTitleAccents;
            subtitle = Theme.Label("", true);
            subtitle.Dock = DockStyle.Bottom;
            subtitle.Height = 24;
            subtitle.TextAlign = ContentAlignment.TopLeft;
            subtitle.Padding = new Padding(10, 1, 0, 0);
            titlePanel.Controls.Add(title);
            titlePanel.Controls.Add(subtitle);
            heading.Controls.Add(titlePanel, 0, 0);

            var actions = new FlowLayoutPanel { Anchor = AnchorStyles.Right, AutoSize = true, WrapContents = false, Margin = Padding.Empty };
            actions.Controls.AddRange(new Control[] { objectMenu, bucketMenu, detailsToggle, close });
            foreach (ShelfButton button in actions.Controls)
            {
                button.Quiet = true;
                window.NameIcon(button);
            }
            heading.Controls.Add(actions, 1, 0);

            navigation = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 4, RowCount = 1, Margin = Padding.Empty, Padding = new Padding(11, 0, 10, 0) };
            navigation.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            navigation.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            navigation.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            navigation.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            inlineSearch = new ColumnStyle(SizeType.Absolute, 0);
            navigation.ColumnStyles.Add(inlineSearch);
            window.NameIcon(up);
            window.NameIcon(reload);
            navigation.Controls.Add(up, 0, 0);
            navigation.Controls.Add(reload, 1, 0);
            navigation.Controls.Add(path, 2, 0);

            search = new FilterField { Margin = new Padding(5, 2, 2, 2) };
            searchRow = new Panel { Dock = DockStyle.Fill, Margin = Padding.Empty, Padding = new Padding(8, 0, 10, 3) };
            navigation.Controls.Add(search, 3, 0);
            filter = search.Input;
            objects.AccessibleName = "对象清单";
            objects.VirtualMode = true;
            objects.Columns.Add("名称", 290);
            objects.Columns.Add("大小", 90);
            objects.Columns.Add("存储类别", 112);
            objects.Columns.Add("更新时间", 138);
            objects.RetrieveVirtualItem += (sender, args) =>
            {
                if (args.ItemIndex < 0 || args.ItemIndex >= visibleEntries.Count)
                {
                    args.Item = new ListViewItem(new[] { "", "", "", "" });
                    return;
                }
                var entry = visibleEntries[args.ItemIndex];
                var dateFormat = !compact ? "yyyy-MM-dd HH:mm 'UTC'" : objects.ClientSize.Width < 360 * DeviceDpi / 96 ? "MM-dd HH:mm" : "yyyy-MM-dd HH:mm";
                args.Item = new ListViewItem(new[] { DisplayKey(entry), entry.Size is long size ? Theme.Bytes(size) : "—",
                    entry.StorageClass ?? "—", entry.Modified?.ToUniversalTime().ToString(dateFormat) ?? "—" }) { Tag = entry };
            };
            objects.SelectedIndexChanged += (sender, args) => { window.UpdateCommands(); SelectionChanged(); };
            objects.DoubleClick += async (sender, args) =>
            {
                var entry = Selected;
                if (entry?.Folder == true) await OpenAsync(bucket, entry.Key);
                else if (entry != null) window.Download();
            };
            objects.KeyDown += async (sender, args) =>
            {
                if (args.KeyCode == Keys.Enter && Selected?.Folder == true) { args.SuppressKeyPress = true; await OpenAsync(bucket, Selected.Key); }
            };
            objects.Resize += (sender, args) => ResizeColumns();
            var context = new ContextMenuStrip();
            var download = context.Items.Add("下载…", null, (sender, args) => window.Download());
            var copy = context.Items.Add("复制 S3 URI", null, (sender, args) => window.CopyUri());
            var delete = context.Items.Add("删除对象…", null, async (sender, args) => await window.DeleteObjectAsync());
            void UpdateObjectMenu()
            {
                window.ActivatePane(this);
                download.Enabled = Selected != null && !Selected.Folder;
                copy.Enabled = HasBucket;
                delete.Enabled = CanWrite && download.Enabled;
                Theme.TintMenu(context);
            }
            context.Opening += (sender, args) => UpdateObjectMenu();
            objects.ContextMenuStrip = context;
            objectMenu.Click += (sender, args) => context.Show(objectMenu, new Point(0, objectMenu.Height));
            bucketMenu.Click += (sender, args) => { window.ActivatePane(this); window.ShowBucketMenu(bucketMenu); };

            var listingArea = Theme.Paint(new Panel { Dock = DockStyle.Fill }, Fill.Surface);
            empty = new PaneEmptyState { Dock = DockStyle.Fill, TabStop = false };
            empty.MouseDown += (sender, args) => window.ActivatePane(this);
            empty.ActionClicked += async (sender, args) =>
            {
                window.ActivatePane(this);
                if (connection == null) await window.ManageConnectionAsync(false, false);
                else if (!HasBucket) await window.OpenNamedBucketAsync(this);
            };
            listingArea.Controls.Add(objects);
            listingArea.Controls.Add(empty);
            body = Theme.Paint(new SplitContainer { Dock = DockStyle.Fill, Orientation = Orientation.Horizontal, Panel2Collapsed = true, SplitterWidth = 3, Margin = Padding.Empty }, Fill.Line);
            body.Panel1.Controls.Add(listingArea);
            body.Panel2.Controls.Add(MakeDetails());
            var footer = Theme.Paint(new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, Margin = Padding.Empty, Padding = new Padding(13, 0, 10, 0) }, Fill.Toolbar);
            footer.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            status.Dock = DockStyle.Fill;
            status.TextAlign = ContentAlignment.MiddleLeft;
            footer.Controls.Add(status, 0, 0);
            footer.Controls.Add(more, 1, 0);
            var paneLayout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 5, Margin = Padding.Empty };
            titleHeight = new RowStyle(SizeType.Absolute, 68);
            navigationHeight = new RowStyle(SizeType.Absolute, 34);
            searchHeight = new RowStyle(SizeType.Absolute, 0);
            footerHeight = new RowStyle(SizeType.Absolute, 31);
            paneLayout.RowStyles.Add(titleHeight);
            paneLayout.RowStyles.Add(navigationHeight);
            paneLayout.RowStyles.Add(searchHeight);
            paneLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            paneLayout.RowStyles.Add(footerHeight);
            paneLayout.Controls.Add(heading, 0, 0);
            paneLayout.Controls.Add(navigation, 0, 1);
            paneLayout.Controls.Add(searchRow, 0, 2);
            paneLayout.Controls.Add(body, 0, 3);
            paneLayout.Controls.Add(footer, 0, 4);
            Controls.Add(paneLayout);

            more.Visible = false;
            detailsToggle.Click += (sender, args) => ToggleDetails();
            close.Click += (sender, args) => window.ClosePane(this);
            more.Click += async (sender, args) => await LoadObjectsAsync(true);
            up.Click += async (sender, args) => await UpAsync();
            reload.Click += async (sender, args) => await RefreshAsync();
            path.Navigate += async target => { window.ActivatePane(this); await OpenAsync(bucket, target); };
            path.Go += async value => { window.ActivatePane(this); await GoAsync(value); };
            filter.TextChanged += (sender, args) => searchDelay.Restart();
            InstallFocusHandlers(paneLayout);
            status.Text = "请选择连接";
            UpdatePresentation();
            ResizeColumns();
        }

        private void ResizeColumns()
        {
            var available = Math.Max(1, objects.ClientSize.Width - SystemInformation.VerticalScrollBarWidth);
            var scale = DeviceDpi / 96f;
            var size = (int)((compact ? 76 : 90) * scale);
            var storage = compact ? 0 : (int)(110 * scale);
            var date = (int)((!compact ? 155 : objects.ClientSize.Width < 360 * scale ? 94 : 132) * scale);
            objects.Columns[0].Width = Math.Max(75, available - size - storage - date);
            objects.Columns[1].Width = size;
            objects.Columns[2].Width = storage;
            objects.Columns[3].Width = date;
        }

        internal IReadOnlyList<string> BucketNames => bucketNames;
        internal bool HasMoreBuckets => nextBucket != null;
        internal bool BucketsLoading => bucketBusy;
        internal bool DetailsVisible => !body.Panel2Collapsed;
        internal Task SelectConnectionAsync(Connection selected) => selected == connection ? Task.CompletedTask : ConnectAsync(selected);
        internal void EditPath() => path.StartEdit();

        private void DrawTitleAccents(object sender, PaintEventArgs e)
        {
            if (!compact) return;
            var selectedColor = active ? Theme.Accent : Theme.Muted;
            using (var brush = new SolidBrush(selectedColor))
            using (var pen = new Pen(selectedColor))
            {
                var dot = new Rectangle(1, (title.Height - 6) / 2, 6, 6);
                if (active) e.Graphics.FillEllipse(brush, dot); else e.Graphics.DrawEllipse(pen, dot);
                if (active) e.Graphics.FillRectangle(brush, 1, title.Height - 3, Math.Min(40, title.Width), 2);
            }
        }

        private void UpdatePresentation()
        {
            var scale = DeviceDpi / 96f;
            titleHeight.Height = (compact ? 36 : HasBucket ? 68 : 0) * scale;
            navigationHeight.Height = HasBucket ? 34 * scale : 0;
            searchHeight.Height = HasBucket && compact ? 31 * scale : 0;
            footerHeight.Height = HasBucket ? 32 * scale : 0;
            heading.Visible = compact || HasBucket;
            navigation.Visible = HasBucket;
            searchRow.Visible = HasBucket && compact;
            inlineSearch.Width = compact || !HasBucket ? 0 : 179 * scale;
            title.Text = compact && bucket != null ? connection.Name + " / " + bucket : bucket ?? connection?.Name ?? "对象浏览";
            title.Font = compact ? Theme.Semibold : Theme.Heading;
            title.Padding = new Padding(compact ? 14 : 10, 0, 0, 0);
            subtitle.Text = bucket != null ? connection.RegionLabel : "Amazon S3";
            subtitle.Visible = !compact;
            Theme.Paint(heading, compact && active ? Fill.Stripe : Fill.Surface);
            title.Invalidate();
            detailsToggle.Enabled = HasBucket;
            detailsToggle.Selected = DetailsVisible;
            detailTabs.Visible = !compact;
            detailPicker.Visible = compact;
            objectMenu.IconOnly = bucketMenu.IconOnly = compact;
            objectMenu.Visible = bucketMenu.Visible = detailsToggle.Visible = HasBucket;
            up.Enabled = HasBucket && prefix.Length > 0;
            reload.Enabled = connection != null;
            path.Enabled = HasBucket;
            filter.Enabled = HasBucket;
            close.Visible = compact;
            RefreshEmpty();
        }

        private void RefreshEmpty()
        {
            var show = !HasBucket || (!listingBusy && visibleEntries.Count == 0);
            empty.Visible = show;
            if (!show) return;
            empty.BringToFront();
            if (connection == null) empty.SetMessage(Glyph.Server, compact ? "从侧栏选择连接" : "连接到对象存储",
                compact ? "" : "添加 Amazon S3 或兼容端点。", "新建连接", compact ? null : window.AppMark);
            else if (!HasBucket) empty.SetMessage(Glyph.Bucket, "打开存储桶", "从侧栏选择存储桶，或按名称打开。", "按名称打开");
            else if (listingFailed) empty.SetMessage(Glyph.Refresh, "加载对象失败", "使用路径栏上的刷新按钮重试。");
            else if (filter.TextLength > 0) empty.SetMessage(Glyph.Search, "没有匹配的对象", "可清除筛选条件或加载更多对象。");
            else empty.SetMessage(Glyph.Folder, "此处没有对象", "");
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
            if (!compact || !active) return;
            var border = Math.Max(2, 3 * DeviceDpi / 96);
            using (var pen = new Pen(Theme.StrongBorder, border))
                args.Graphics.DrawRectangle(pen, Rectangle.Inflate(ClientRectangle, -border / 2, -border / 2));
        }

        internal void Active(bool value, bool isSplit)
        {
            if (active == value && compact == isSplit) return;
            active = value;
            if (compact != isSplit)
            {
                if (isSplit) searchRow.Controls.Add(search);
                else navigation.Controls.Add(search, 3, 0);
            }
            compact = isSplit;
            Padding = compact ? new Padding(Math.Max(2, 3 * DeviceDpi / 96)) : Padding.Empty;
            UpdatePresentation();
            ResizeColumns();
            Invalidate();
        }

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
            if (selected != previous) await ConnectAsync(selected);
        }

        private async Task ConnectAsync(Connection selected)
        {
            bucketListing.Cancel(); bucketListing.Dispose(); bucketListing = new CancellationTokenSource();
            connection = selected;
            bucket = null;
            bucketNames = Array.Empty<string>();
            nextBucket = null;
            bucketBusy = false;
            ClearLocation();
            status.Text = connection == null ? "请选择连接" : "正在读取存储桶…";
            UpdatePresentation();
            window.PaneLocationChanged(this);
            if (!string.IsNullOrWhiteSpace(selected?.PreferredBucket))
                await OpenAsync(selected.PreferredBucket.Trim(), "");
            else if (selected != null)
                await LoadBucketsAsync(false);
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
            window.PaneLocationChanged(this);
            try
            {
                using (var client = connection.Open())
                {
                    var response = await client.ListBucketsAsync(new ListBucketsRequest { MaxBuckets = 1000, ContinuationToken = nextBucket }, token);
                    if (capture != bucketListing || IsDisposed) return;
                    var names = (response.Buckets ?? new List<S3Bucket>()).Select(item => item.BucketName);
                    bucketNames = (append ? bucketNames.Concat(names) : names).Distinct(StringComparer.Ordinal)
                        .OrderBy(name => name, StringComparer.CurrentCulture).ToArray();
                    nextBucket = string.IsNullOrEmpty(response.ContinuationToken) || !bucketCursors.Add(response.ContinuationToken) ? null : response.ContinuationToken;
                    if (bucket == null) status.Text = bucketNames.Count == 0 ? "可以手动打开存储桶" : "选择存储桶以浏览对象";
                }
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { }
            catch (Exception ex)
            {
                if (capture != bucketListing || IsDisposed) return;
                bucketBusy = false;
                if (!HasBucket) status.Text = "无法列出存储桶，可手动打开";
                window.PaneLocationChanged(this);
                window.ShowError(ex, "无法列出存储桶，可手动打开");
            }
            finally { if (capture == bucketListing && !IsDisposed) { bucketBusy = false; window.PaneLocationChanged(this); } }
        }

        internal async Task OpenAsync(string name, string folder)
        {
            if (connection == null) return;
            ClearLocation();
            bucket = name;
            prefix = folder;
            path.SetLocation(bucket, prefix);
            UpdatePresentation();
            window.PaneLocationChanged(this);
            SelectionChanged();
            await LoadObjectsAsync(false);
        }

        internal void CloseBucket()
        {
            bucket = null;
            ClearLocation();
            status.Text = "选择存储桶以浏览对象";
            UpdatePresentation();
            window.PaneLocationChanged(this);
        }

        internal Task RefreshAsync()
        {
            if (!HasBucket) return LoadBucketsAsync(false);
            window.ListingCache.Invalidate(connection, bucket, prefix);
            return OpenAsync(bucket, prefix);
        }

        private void ClearLocation()
        {
            listing.Cancel(); listing.Dispose(); listing = new CancellationTokenSource();
            listingBusy = listingFailed = false;
            cachedPage = false;
            entries.Clear(); keys.Clear(); cursors.Clear(); next = null;
            path.SetLocation(null, "");
            more.Visible = false;
            RenderObjects();
            CancelDetails();
            detailText.Clear();
            detailStatus.Text = "";
            detailLocation.Text = "";
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
            listingFailed = false;
            RefreshEmpty();
            try
            {
                var scope = (connection, bucket, prefix);
                var page = append ? null : window.ListingCache.Read(scope);
                if (page == null)
                {
                    var revision = window.ListingCache.Revision;
                    using (var client = connection.Open())
                        page = await Storage.ListAsync(client, bucket, prefix, append ? next : null, connection.Payer, token);
                    if (capture != listing || IsDisposed) return;
                    if (!append) window.ListingCache.Store(scope, page, revision);
                }
                else cachedPage = true;
                foreach (var entry in page.Entries)
                    if (keys.Add((entry.Folder ? "P" : "O") + entry.Key)) entries.Add(entry);
                next = string.IsNullOrEmpty(page.Cursor) || !cursors.Add(page.Cursor) ? null : page.Cursor;
                RenderObjects();
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { }
            catch (Exception ex)
            {
                if (capture != listing || IsDisposed) return;
                listingFailed = !append;
                status.Text = "加载失败，可刷新重试";
                window.ShowError(ex, "无法加载对象");
            }
            finally { if (capture == listing && !IsDisposed) { listingBusy = false; more.Enabled = more.Visible = next != null; RefreshEmpty(); } }
        }

        private Task UpAsync()
        {
            if (!HasBucket || prefix.Length == 0) return Task.CompletedTask;
            var index = prefix.Length < 2 ? -1 : prefix.LastIndexOf('/', prefix.Length - 2);
            return OpenAsync(bucket, index < 0 ? "" : prefix.Substring(0, index + 1));
        }

        private Task GoAsync(string entered)
        {
            if (connection == null) return Task.CompletedTask;
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
            RefreshEmpty();
            if (HasBucket)
            {
                var count = query.Length == 0 ? $"已加载 {entries.Count:N0} 项" : $"匹配 {visibleEntries.Count:N0} 项 / {entries.Count:N0} 项";
                status.Text = cachedPage ? count + " · 首屏缓存" : count;
            }
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
