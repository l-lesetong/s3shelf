using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Amazon.S3;
using Amazon.S3.Model;

namespace S3Shelf
{
    internal sealed class MainWindow : Form
    {
        private readonly ShelfButton addConnection = Theme.Button("新建连接", Glyph.Add);
        private readonly ShelfButton upload = Theme.Button("上传", Glyph.Upload);
        private readonly ShelfButton download = Theme.Button("下载", Glyph.Download);
        private readonly ShelfButton details = Theme.Button("详情", Glyph.Details);
        private readonly ShelfButton cancel = Theme.Button("取消当前传输");
        private readonly ToolTip tips = new ToolTip();
        private readonly ListView history = Theme.List();
        private readonly Panel transferPanel = Theme.Paint(new Panel { Dock = DockStyle.Fill, Margin = Padding.Empty }, Fill.Surface);
        private readonly PaneEmptyState transferEmpty = new PaneEmptyState { Dock = DockStyle.Fill, TabStop = false };
        private readonly SplitContainer browser = Theme.Paint(new SplitContainer { Dock = DockStyle.Fill, Panel2Collapsed = true,
            SplitterWidth = 3, Margin = Padding.Empty }, Fill.Line);
        private readonly WorkspaceSidebar sidebar;
        private BrowserPane left;
        private BrowserPane right;
        private BrowserPane active;
        private List<Connection> connections = new List<Connection>();
        private CancellationTokenSource transfer;
        private bool closeWhenIdle;
        private bool transfersVisible;
        private bool changingConnections;
        private bool connectionStoreAvailable = true;
        private bool mutating;
        internal Icon AppMark { get; }
        internal DetailCache InspectorCache { get; } = new DetailCache();
        internal ObjectPageCache ListingCache { get; } = new ObjectPageCache();
        private TransferPreferences transferPreferences = TransferPreferences.Load();

        internal MainWindow()
        {
            Text = "s3Shelf";
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(810, 510);
            ClientSize = new Size(1190, 720);
            AutoScaleMode = AutoScaleMode.Dpi;
            AutoScaleDimensions = new SizeF(96, 96);
            Font = SystemFonts.MessageBoxFont;
            Theme.Paint(this, Fill.Surface);
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            using (var resource = typeof(MainWindow).Assembly.GetManifestResourceStream("S3Shelf.AppIcon.ico"))
                AppMark = new Icon(resource, 64, 64);

            var toolbar = Theme.Paint(new TableLayoutPanel { Dock = DockStyle.Top, Height = 40, ColumnCount = 5, RowCount = 1,
                Margin = Padding.Empty, Padding = new Padding(10, 2, 12, 2) }, Fill.Toolbar);
            toolbar.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            var actions = new[] { upload, download, details, addConnection };
            for (var i = 0; i < actions.Length; i++)
            {
                var button = actions[i];
                button.Quiet = true;
                button.Anchor = AnchorStyles.Right;
                toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
                toolbar.Controls.Add(button, i + 1, 0);
                NameIcon(button);
            }
            toolbar.Paint += (sender, args) => { using (var pen = new Pen(Theme.Line)) args.Graphics.DrawLine(pen, 0, toolbar.Height - 1, toolbar.Width, toolbar.Height - 1); };

            history.AccessibleName = "当前会话传输历史";
            history.Columns.Add("操作", 70);
            history.Columns.Add("对象", 370);
            history.Columns.Add("进度", 180);
            history.Columns.Add("状态", 200);
            var transferHeader = new TableLayoutPanel { Dock = DockStyle.Top, Height = 64, Margin = Padding.Empty, ColumnCount = 2, RowCount = 1, Padding = new Padding(20, 0, 16, 0) };
            transferHeader.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            transferHeader.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            transferHeader.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            var transferTitle = Theme.Label("传输队列");
            transferTitle.Font = Theme.Heading;
            transferTitle.Dock = DockStyle.Fill;
            transferTitle.TextAlign = ContentAlignment.MiddleLeft;
            cancel.Anchor = AnchorStyles.Right;
            transferHeader.Controls.Add(transferTitle, 0, 0);
            transferHeader.Controls.Add(cancel, 1, 0);
            transferEmpty.SetMessage(Glyph.Transfer, "暂无传输", "上传和下载任务会显示在这里。");
            transferPanel.Controls.Add(history);
            transferPanel.Controls.Add(transferEmpty);
            transferPanel.Controls.Add(transferHeader);
            transferPanel.Visible = false;

            left = new BrowserPane(this);
            browser.Panel1.Controls.Add(left);
            var workspace = Theme.Paint(new Panel { Dock = DockStyle.Fill, Margin = Padding.Empty }, Fill.Surface);
            workspace.Controls.Add(browser);
            workspace.Controls.Add(transferPanel);
            var content = new Panel { Dock = DockStyle.Fill, Margin = Padding.Empty };
            content.Controls.Add(workspace);
            content.Controls.Add(toolbar);
            sidebar = new WorkspaceSidebar(this);
            var layout = Theme.Paint(new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 1, Margin = Padding.Empty }, Fill.Line);
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 222));
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 1));
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            layout.Controls.Add(sidebar, 0, 0);
            layout.Controls.Add(content, 2, 0);
            Controls.Add(layout);

            addConnection.Click += async (sender, args) => await ManageConnectionAsync(false, false);
            upload.Click += async (sender, args) => await UploadAsync();
            download.Click += (sender, args) => Download();
            details.Click += (sender, args) => active.ToggleDetails();
            cancel.Click += (sender, args) => { cancel.Enabled = false; transfer?.Cancel(); };
            Shown += async (sender, args) => await LoadConnectionsAsync();
            ActivatePane(left);
        }

        internal void NameIcon(Control control) => tips.SetToolTip(control, control.AccessibleName ?? control.Text);

        internal void ActivatePane(BrowserPane pane)
        {
            if (pane.IsDisposed || (pane != left && pane != right) || active == pane) return;
            active = pane;
            UpdatePaneFocus();
            PaneLocationChanged(pane);
        }

        private void UpdatePaneFocus()
        {
            var isSplit = right != null;
            left.Active(active == left, isSplit);
            right?.Active(active == right, isSplit);
        }

        internal void PaneLocationChanged(BrowserPane pane)
        {
            if (pane != active || IsDisposed) return;
            sidebar.ShowPane(connections, active);
            UpdateCommands();
        }

        internal void UpdateCommands()
        {
            var selected = active?.Selected;
            var hasConnection = active?.CurrentConnection != null;
            var hasBucket = active?.HasBucket == true;
            var canWrite = active?.CanWrite == true;
            addConnection.Enabled = connectionStoreAvailable && !changingConnections;
            upload.Visible = download.Visible = details.Visible = !transfersVisible && hasBucket;
            upload.Enabled = !transfersVisible && transfer == null && hasBucket && canWrite;
            download.Enabled = !transfersVisible && transfer == null && hasBucket && selected != null && !selected.Folder;
            details.Enabled = !transfersVisible && hasBucket;
            details.Selected = !transfersVisible && active?.DetailsVisible == true;
            cancel.Enabled = transfer != null && !transfer.IsCancellationRequested;
            sidebar.UpdateCommands(addConnection.Enabled, addConnection.Enabled && hasConnection, canWrite && !mutating,
                hasConnection, transfersVisible, right != null, transfer != null);
        }

        private async Task LoadConnectionsAsync()
        {
            try { connections = ConnectionStore.Load(); }
            catch (Exception ex)
            {
                connectionStoreAvailable = false;
                ShowError(ex, "无法读取已保存的连接");
            }
            PaneLocationChanged(left);
            await left.SetConnectionsAsync(connections);
        }

        internal async Task ToggleSplitAsync()
        {
            ShowTransfers(false);
            if (right != null) { ClosePane(active); return; }
            var source = left.CurrentConnection;
            var bucket = left.Bucket;
            var prefix = left.Prefix;
            var newPane = new BrowserPane(this);
            right = newPane;
            browser.Panel2.Controls.Add(newPane);
            browser.Panel2Collapsed = false;
            browser.SplitterDistance = Math.Max(browser.Panel1MinSize, (browser.ClientSize.Width - browser.SplitterWidth) / 2);
            UpdatePaneFocus();
            UpdateCommands();
            await newPane.SetConnectionsAsync(connections, source);
            if (!newPane.IsDisposed && newPane.CurrentConnection == source && bucket != null &&
                (newPane.Bucket != bucket || newPane.Prefix != prefix))
                await newPane.OpenAsync(bucket, prefix);
        }

        internal void ClosePane(BrowserPane pane)
        {
            if (right == null || (pane != left && pane != right)) return;
            var remaining = pane == left ? right : left;
            if (pane == left)
            {
                browser.Panel2.Controls.Remove(remaining);
                browser.Panel1.Controls.Add(remaining);
                left = remaining;
            }
            right = null;
            active = remaining;
            pane.Dispose();
            browser.Panel2Collapsed = true;
            UpdatePaneFocus();
            PaneLocationChanged(active);
        }

        internal Task OpenConnectionAsync(Connection value)
        {
            ShowTransfers(false);
            return active.SelectConnectionAsync(value);
        }

        internal Task OpenBucketAsync(string name)
        {
            ShowTransfers(false);
            return active.Bucket == name ? Task.CompletedTask : active.OpenAsync(name, "");
        }

        internal Task LoadMoreBucketsAsync() => active.LoadBucketsAsync(true);

        internal void ShowBucketMenu(Control anchor, Point? location = null)
        {
            var pane = active;
            if (pane?.CurrentConnection == null) return;
            var menu = new ContextMenuStrip();
            menu.Items.Add("刷新存储桶", null, async (sender, args) => await pane.LoadBucketsAsync(false));
            menu.Items.Add("按名称打开…", null, async (sender, args) => await OpenNamedBucketAsync(pane));
            menu.Items.Add("创建存储桶…", null, async (sender, args) => await CreateBucketAsync()).Enabled = pane.CanWrite && !mutating;
            if (pane.HasBucket)
            {
                menu.Items.Add(new ToolStripSeparator());
                menu.Items.Add("删除当前存储桶…", null, async (sender, args) => await DeleteBucketAsync()).Enabled = pane.CanWrite && !mutating;
            }
            menu.Closed += (sender, args) => menu.Dispose();
            Theme.TintMenu(menu);
            menu.Show(anchor, location ?? new Point(0, anchor.Height));
        }

        internal async Task OpenNamedBucketAsync(BrowserPane pane)
        {
            if (pane.CurrentConnection == null) return;
            var name = Dialog.Ask(this, "打开存储桶", "存储桶名称");
            if (!string.IsNullOrWhiteSpace(name) && !pane.IsDisposed)
            {
                ShowTransfers(false);
                await pane.OpenAsync(name.Trim(), "");
            }
        }

        internal async Task ShowConfigurationAsync()
        {
            using (var dialog = new Dialog("配置"))
            {
                var appearance = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList };
                appearance.Items.AddRange(new object[] { "跟随系统", "浅色", "深色" });
                appearance.SelectedIndex = (int)Theme.Preference;
                var lifetime = new NumericUpDown { Minimum = 1, Maximum = 3600, Value = InspectorCache.Lifetime == 0 ? 30 : InspectorCache.Lifetime };
                var capacity = new NumericUpDown { Minimum = 1, Maximum = 64, Value = InspectorCache.Capacity };
                var disabled = new CheckBox { Text = "从不缓存", Checked = InspectorCache.Lifetime == 0, AutoSize = true };
                void UpdateCacheFields() => lifetime.Enabled = capacity.Enabled = !disabled.Checked;
                disabled.CheckedChanged += (sender, args) => UpdateCacheFields();
                UpdateCacheFields();
                var appearancePage = new Panel();
                var cachePage = new Panel();
                var transferPage = new Panel();
                var part = new NumericUpDown { Minimum = 5, Maximum = 5120, Value = transferPreferences.PartMiB };
                var limit = new NumericUpDown { Minimum = 0, Maximum = 1000000, Value = transferPreferences.LimitMiB,
                    DecimalPlaces = 2, Increment = 0.1m, ThousandsSeparator = true };
                AddSettingRows(appearancePage, ("外观", appearance));
                AddSettingRows(cachePage, ("缓存时间（秒）", lifetime), ("空间上限（MiB）", capacity), ("缓存方式", disabled));
                AddSettingRows(transferPage, ("全局限速（MiB/s）", limit), ("分片大小（MiB）", part),
                    ("", Theme.Label("限速为 0 时不限速。设置从下一项传输生效。", true)));
                dialog.Content(MakeSettingsTabs(("外观", appearancePage), ("详情缓存", cachePage), ("传输", transferPage)));
                dialog.Confirm.Text = "保存";
                dialog.Confirm.DialogResult = DialogResult.OK;
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                try
                {
                    var preferences = new TransferPreferences((int)part.Value, limit.Value);
                    preferences.Save();
                    transferPreferences = preferences;
                    InspectorCache.Configure(disabled.Checked ? 0 : (int)lifetime.Value, (int)capacity.Value);
                    Theme.SetAppearance((Appearance)appearance.SelectedIndex);
                    Theme.Apply(this);
                    await Task.WhenAll(new[] { left, right }.Where(pane => pane != null).Select(pane => pane.RefreshDetailsAsync()));
                }
                catch (Exception ex) { ShowError(ex, "无法保存配置"); }
            }
        }

        private static Control MakeSettingsTabs(params (string Label, Panel Page)[] tabs)
        {
            var root = new Panel { Height = 163 };
            var content = Theme.Paint(new Panel { Dock = DockStyle.Fill }, Fill.Surface);
            var buttons = Theme.Paint(new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, WrapContents = false,
                Padding = new Padding(0, 0, 0, 7) }, Fill.Surface);
            var tabButtons = tabs.Select(tab => Theme.Button(tab.Label)).ToArray();
            void Select(int index)
            {
                for (var i = 0; i < tabs.Length; i++)
                {
                    tabs[i].Page.Visible = i == index;
                    tabButtons[i].Selected = i == index;
                }
            }
            for (var i = 0; i < tabs.Length; i++)
            {
                var index = i;
                tabs[i].Page.Dock = DockStyle.Fill;
                content.Controls.Add(tabs[i].Page);
                tabButtons[i].Quiet = true;
                tabButtons[i].Click += (sender, args) => Select(index);
                buttons.Controls.Add(tabButtons[i]);
            }
            Select(0);
            root.Controls.Add(content);
            root.Controls.Add(buttons);
            return root;
        }

        private static void AddSettingRows(Panel page, params (string Label, Control Input)[] rows)
        {
            Theme.Paint(page, Fill.Surface);
            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Padding = new Padding(2, 6, 2, 8) };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 135));
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            foreach (var row in rows)
            {
                var index = layout.RowCount++;
                layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
                var label = Theme.Label(row.Label, true);
                label.AutoSize = true;
                label.Anchor = AnchorStyles.Left;
                row.Input.Anchor = AnchorStyles.Left | AnchorStyles.Right;
                row.Input.Margin = new Padding(0, 4, 0, 4);
                if (!string.IsNullOrEmpty(row.Label)) row.Input.AccessibleName = row.Label;
                if (row.Input is ShelfLabel hint) hint.AutoSize = true;
                else Theme.Paint(row.Input, row.Input is CheckBox ? Fill.Surface : Fill.Field);
                if (row.Input is NumericUpDown number) number.BorderStyle = BorderStyle.FixedSingle;
                layout.Controls.Add(label, 0, index);
                layout.Controls.Add(row.Input, 1, index);
            }
            page.Controls.Add(layout);
        }

        internal void ShowTransfers(bool visible)
        {
            if (transfersVisible == visible) return;
            transfersVisible = visible;
            browser.Visible = !visible;
            transferPanel.Visible = visible;
            if (visible) transferPanel.BringToFront();
            UpdateCommands();
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys key)
        {
            if (!transfersVisible && active?.HasBucket == true)
            {
                if (key == (Keys.Control | Keys.L)) { active.EditPath(); return true; }
                if (key == (Keys.Control | Keys.Alt | Keys.I)) { active.ToggleDetails(); return true; }
            }
            return base.ProcessCmdKey(ref msg, key);
        }

        protected override void WndProc(ref Message message)
        {
            base.WndProc(ref message);
            const int SettingChange = 0x001a;
            const int ThemeChange = 0x031a;
            if (sidebar != null && (message.Msg == SettingChange || message.Msg == ThemeChange) && Theme.RefreshSystem()) Theme.Apply(this);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                tips.Dispose();
                AppMark?.Dispose();
            }
            base.Dispose(disposing);
        }

        internal async Task ManageConnectionAsync(bool existing, bool remove)
        {
            if (changingConnections || !connectionStoreAvailable) return;
            var pane = active;
            var previous = existing ? pane.CurrentConnection : null;
            if (existing && previous == null) return;
            if (remove && MessageBox.Show(this, "移除本机保存的连接「" + previous.Name + "」？", "移除连接", MessageBoxButtons.OKCancel,
                MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.OK) return;

            try
            {
                var replacement = remove ? null : ConnectionEditor.Edit(this, previous);
                if (!remove && replacement == null) return;
                var updated = new List<Connection>(connections);
                if (remove) updated.Remove(previous);
                else if (existing) updated[updated.IndexOf(previous)] = replacement;
                else updated.Add(replacement);
                ConnectionStore.Save(updated);
                connections = updated;
                if (previous != null)
                {
                    InspectorCache.Invalidate(previous);
                    ListingCache.Invalidate(previous);
                }
                changingConnections = true;
                UpdateCommands();
                var panes = new[] { left, right }.Where(item => item != null);
                await Task.WhenAll(panes.Select(item => item.SetConnectionsAsync(connections,
                    item == pane || (existing && item.CurrentConnection == previous) ? replacement : null)));
            }
            catch (Exception ex) { ShowError(ex, "无法保存连接"); }
            finally { changingConnections = false; if (!IsDisposed) PaneLocationChanged(active); }
        }

        internal async Task CreateBucketAsync()
        {
            var pane = active;
            var connection = pane.CurrentConnection;
            if (connection == null || !pane.CanWrite || mutating) return;
            var name = Dialog.Ask(this, "创建存储桶", "存储桶名称")?.Trim();
            if (string.IsNullOrEmpty(name)) return;
            await ChangeStorageAsync("无法创建存储桶", async () =>
            {
                using (var client = connection.Open())
                    await client.PutBucketAsync(new PutBucketRequest { BucketName = name, UseClientRegion = string.IsNullOrEmpty(connection.Endpoint) });
                ListingCache.Invalidate(connection, name);
                if (!IsDisposed && !pane.IsDisposed && pane.CurrentConnection == connection) await pane.OpenAsync(name, "");
                await RefreshBucketsAsync(connection);
            });
        }

        private async Task DeleteBucketAsync()
        {
            var pane = active;
            var connection = pane.CurrentConnection;
            var name = pane.Bucket;
            if (!pane.HasBucket || !pane.CanWrite || mutating) return;
            using (var dialog = new Dialog("永久删除存储桶"))
            {
                var input = new TextBox();
                dialog.Field("存储桶", new TextBox { Text = name, ReadOnly = true });
                dialog.Field("删除条件", new Label { Text = "须先清空对象、版本和删除标记。删除后无法撤销。", AutoSize = true });
                dialog.Field("再次输入桶名", input);
                dialog.Confirm.Text = "永久删除";
                dialog.Confirm.Enabled = false;
                dialog.Confirm.DialogResult = DialogResult.OK;
                input.TextChanged += (sender, args) => dialog.Confirm.Enabled = input.Text == name;
                if (dialog.ShowDialog(this) != DialogResult.OK || input.Text != name) return;
            }
            await ChangeStorageAsync("无法删除存储桶", async () =>
            {
                using (var client = connection.Open()) await client.DeleteBucketAsync(name);
                if (IsDisposed) return;
                InspectorCache.Invalidate(connection, name, entireBucket: true);
                ListingCache.Invalidate(connection, name);
                foreach (var item in new[] { left, right }.Where(item => item != null))
                {
                    if (item.CurrentConnection == connection && item.Bucket == name) item.CloseBucket();
                }
                await RefreshBucketsAsync(connection);
            });
        }

        private Task RefreshBucketsAsync(Connection connection)
        {
            if (IsDisposed) return Task.CompletedTask;
            return Task.WhenAll(new[] { left, right }.Where(pane => pane?.CurrentConnection == connection).Select(pane => pane.LoadBucketsAsync(false)));
        }

        internal async Task DeleteObjectAsync()
        {
            var pane = active;
            var entry = pane.Selected;
            var connection = pane.CurrentConnection;
            var bucket = pane.Bucket;
            var prefix = pane.Prefix;
            if (!pane.HasBucket || !pane.CanWrite || entry == null || entry.Folder || mutating) return;
            if (MessageBox.Show(this, "删除此对象的当前版本？\n\ns3://" + bucket + "/" + entry.Key, "删除对象", MessageBoxButtons.OKCancel,
                MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.OK) return;
            await ChangeStorageAsync("无法删除对象", async () =>
            {
                using (var client = connection.Open())
                    await client.DeleteObjectAsync(new DeleteObjectRequest { BucketName = bucket, Key = entry.Key, RequestPayer = connection.Payer });
                await RefreshObjectAsync(connection, bucket, prefix, entry.Key);
            });
        }

        private async Task ChangeStorageAsync(string title, Func<Task> operation)
        {
            mutating = true;
            UpdateCommands();
            try { await operation(); }
            catch (Exception ex) { if (!IsDisposed) ShowError(ex, title); }
            finally { mutating = false; if (!IsDisposed) UpdateCommands(); }
        }

        internal void CopyUri()
        {
            if (!active.HasBucket) return;
            try { Clipboard.SetText("s3://" + active.Bucket + "/" + (active.Selected?.Key ?? active.Prefix)); }
            catch (Exception ex) { ShowError(ex, "无法复制 S3 URI"); }
        }

        private async Task UploadAsync()
        {
            var pane = active;
            var connection = pane.CurrentConnection;
            var bucket = pane.Bucket;
            var prefix = pane.Prefix;
            if (!pane.HasBucket || !pane.CanWrite || transfer != null) return;
            using (var picker = new OpenFileDialog { Title = "选择上传文件", CheckFileExists = true })
            {
                if (picker.ShowDialog(this) != DialogResult.OK) return;
                var path = picker.FileName;
                var key = prefix + Path.GetFileName(path);
                var prompt = "上传到以下位置？如果对象已存在，可能会覆盖当前版本。\n\ns3://" + bucket + "/" + key;
                if (MessageBox.Show(this, prompt, "上传文件", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.OK) return;
                var preferences = transferPreferences;
                if (await RunTransferAsync("上传", connection, bucket, key,
                    (client, progress, token) => Storage.UploadAsync(client, bucket, key, path, connection.Payer, preferences, progress, token)))
                    await RefreshObjectAsync(connection, bucket, prefix, key);
            }
        }

        private Task RefreshObjectAsync(Connection connection, string bucket, string prefix, string key)
        {
            if (IsDisposed) return Task.CompletedTask;
            var panes = new[] { left, right }.Where(pane => pane != null);
            InspectorCache.Invalidate(connection, bucket, key);
            ListingCache.Invalidate(connection, bucket);
            return Task.WhenAll(panes.Where(pane => pane.CurrentConnection == connection && pane.Bucket == bucket && pane.Prefix == prefix)
                .Select(pane => pane.RefreshAsync()));
        }

        internal Task RefreshAccessDetailsAsync(Connection connection, string bucket, string key)
        {
            if (IsDisposed) return Task.CompletedTask;
            InspectorCache.Invalidate(connection, bucket, key);
            return Task.WhenAll(new[] { left, right }.Where(pane => pane?.CurrentConnection == connection &&
                pane.Bucket == bucket && pane.Selected?.Key == key).Select(pane => pane.RefreshDetailsAsync()));
        }

        internal async void Download()
        {
            var pane = active;
            var entry = pane.Selected;
            var connection = pane.CurrentConnection;
            var bucket = pane.Bucket;
            if (!pane.HasBucket || entry == null || entry.Folder || transfer != null) return;
            var name = entry.Key.Substring(entry.Key.LastIndexOf('/') + 1);
            var invalid = Path.GetInvalidFileNameChars();
            name = new string(name.Select(character => invalid.Contains(character) ? '_' : character).ToArray()).TrimEnd(' ', '.');
            using (var picker = new SaveFileDialog { Title = "保存对象", FileName = name, OverwritePrompt = true })
            {
                if (picker.ShowDialog(this) != DialogResult.OK) return;
                var preferences = transferPreferences;
                await RunTransferAsync("下载", connection, bucket, entry.Key,
                    (client, progress, token) => Storage.DownloadAsync(client, bucket, entry.Key, picker.FileName, connection.Payer, preferences, progress, token));
            }
        }

        private async Task<bool> RunTransferAsync(string action, Connection connection, string bucket, string key,
            Func<IAmazonS3, Action<long, long>, CancellationToken, Task> start)
        {
            if (transfer != null) return false;
            using (var request = new CancellationTokenSource())
            {
                transfer = request;
                UpdateCommands();
                var item = new ListViewItem(new[] { action, "s3://" + bucket + "/" + key, "0 字节", "进行中" });
                history.Items.Insert(0, item);
                transferEmpty.Visible = false;
                long currentBytes = 0;
                long totalBytes = 0;
                using (var timer = new System.Windows.Forms.Timer { Interval = 200 })
                {
                    void UpdateProgress()
                    {
                        var current = Interlocked.Read(ref currentBytes);
                        var total = Interlocked.Read(ref totalBytes);
                        item.SubItems[2].Text = total > 0 ? $"{current:N0} / {total:N0} 字节" : $"{current:N0} 字节";
                    }
                    timer.Tick += (sender, args) => UpdateProgress();
                    timer.Start();
                    try
                    {
                        using (var client = connection.Open())
                            await start(client, (current, total) =>
                            {
                                Interlocked.Exchange(ref currentBytes, current);
                                Interlocked.Exchange(ref totalBytes, total);
                            }, request.Token);
                        item.SubItems[3].Text = "已完成";
                        return true;
                    }
                    catch (OperationCanceledException) when (request.IsCancellationRequested) { item.SubItems[3].Text = "已取消"; }
                    catch (Exception ex)
                    {
                        item.SubItems[3].Text = Describe(ex);
                        if (!closeWhenIdle) ShowError(ex, "传输失败");
                    }
                    finally
                    {
                        timer.Stop();
                        transfer = null;
                        UpdateProgress();
                        UpdateCommands();
                        if (closeWhenIdle) Close();
                    }
                }
            }
            return false;
        }

        protected override void OnFormClosing(FormClosingEventArgs args)
        {
            if (transfer != null && args.CloseReason == CloseReason.UserClosing)
            {
                args.Cancel = true;
                if (!closeWhenIdle && MessageBox.Show(this, "取消当前传输并退出？", "退出 s3Shelf", MessageBoxButtons.OKCancel,
                    MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) == DialogResult.OK)
                {
                    closeWhenIdle = true;
                    transfer.Cancel();
                }
            }
            base.OnFormClosing(args);
        }

        internal void ShowError(string message, string title)
        {
            if (!IsDisposed) MessageBox.Show(this, message, title, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        internal void ShowError(Exception error, string title) => ShowError(Describe(error), title);

        internal static string Describe(Exception error)
        {
            for (var cause = error; cause != null; cause = cause.InnerException)
                if (cause is WebException web && web.Status == WebExceptionStatus.TrustFailure)
                    return "无法验证服务器证书。请检查端点域名，或在连接设置中选择自定义 CA。可信测试环境也可启用「忽略 TLS 证书验证」。";
            if (error is AmazonS3Exception s3)
            {
                switch (s3.ErrorCode)
                {
                    case "AccessDenied": return "访问被拒绝。请检查当前连接的凭据和存储权限。";
                    case "AccessControlListNotSupported": return "此存储桶禁用了 ACL，请通过存储桶策略管理权限。";
                    case "BucketNotEmpty": return "存储桶仍有对象、版本或删除标记。请清空后重试。";
                    case "BucketAlreadyExists": return "该桶名已被占用，请换一个名称。";
                    case "BucketAlreadyOwnedByYou": return "当前账户已拥有同名存储桶。";
                    case "InvalidBucketName": return "存储桶名称不符合服务端命名规则。";
                    case "NoSuchBucket": return "存储桶不存在或已删除。";
                    case "NoSuchKey": return "对象不存在或已删除。";
                    case "ExpiredToken": return "临时会话令牌已过期，请更新连接凭据。";
                }
                if (!string.IsNullOrEmpty(s3.ErrorCode)) return s3.ErrorCode + " — " + s3.Message;
            }
            return error.GetBaseException().Message;
        }
    }
}
