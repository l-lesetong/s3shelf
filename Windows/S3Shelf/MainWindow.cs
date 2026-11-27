using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Amazon.S3;
using Amazon.S3.Model;

namespace S3Shelf
{
    internal sealed class MainWindow : Form
    {
        private readonly Button addConnection = Theme.Button("新建连接…");
        private readonly Button editConnection = Theme.Button("编辑连接…");
        private readonly Button removeConnection = Theme.Button("移除连接…");
        private readonly Button newBucket = Theme.Button("创建桶…");
        private readonly Button deleteBucket = Theme.Button("删除桶…");
        private readonly Button upload = Theme.Button("上传…");
        private readonly Button download = Theme.Button("下载…");
        private readonly Button details = Theme.Button("详情");
        private readonly Button split = Theme.Button("左右分屏");
        private readonly Button transfers = Theme.Button("传输历史");
        private readonly Button cancel = Theme.Button("取消当前传输");
        private readonly ProgressBar activity = new ProgressBar { Height = 15, Width = 90, Style = ProgressBarStyle.Marquee, MarqueeAnimationSpeed = 30, Visible = false };
        private readonly ListView history = Theme.List();
        private readonly TableLayoutPanel layout = new TableLayoutPanel { ColumnCount = 1, RowCount = 3, Dock = DockStyle.Fill };
        private readonly SplitContainer browser = new SplitContainer { Dock = DockStyle.Fill, Panel2Collapsed = true, SplitterWidth = 6, BackColor = Theme.Chrome };
        private readonly BrowserPane left;
        private BrowserPane right;
        private BrowserPane active;
        private List<Connection> connections = new List<Connection>();
        private CancellationTokenSource transfer;
        private bool closeWhenIdle;
        private bool transfersVisible;
        private bool changingConnections;
        private bool connectionStoreAvailable = true;
        private bool mutating;

        internal MainWindow()
        {
            Text = "s3Shelf";
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(810, 510);
            ClientSize = new Size(1190, 720);
            AutoScaleMode = AutoScaleMode.Dpi;
            Font = SystemFonts.MessageBoxFont;
            BackColor = Theme.Chrome;
            ForeColor = Theme.Ink;
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);

            var commands = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, Padding = new Padding(7, 4, 7, 4), BackColor = Theme.Chrome };
            commands.Controls.AddRange(new Control[] { addConnection, editConnection, removeConnection, newBucket, deleteBucket, upload, download, details, split, transfers, activity });
            activity.Margin = new Padding(4, 10, 4, 4);
            activity.AccessibleName = "传输进行中";
            history.AccessibleName = "当前会话传输历史";
            history.Columns.Add("操作", 70);
            history.Columns.Add("对象", 370);
            history.Columns.Add("进度", 200);
            history.Columns.Add("状态", 290);
            var transferHeader = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 37, Padding = new Padding(3) };
            transferHeader.Controls.AddRange(new Control[] { new Label { Text = "当前会话传输历史", AutoSize = true, Margin = new Padding(8, 9, 8, 3) }, cancel });
            var transferPanel = new Panel { Dock = DockStyle.Fill, Margin = Padding.Empty, Padding = new Padding(3, 0, 3, 3) };
            transferPanel.Controls.Add(history);
            transferPanel.Controls.Add(transferHeader);
            transferPanel.Visible = false;
            transfers.Click += (sender, args) => SetTransfersVisible(!transfersVisible, transferPanel);

            left = new BrowserPane(this);
            browser.Panel1.Controls.Add(left);
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 0));
            layout.Controls.Add(commands, 0, 0);
            layout.Controls.Add(browser, 0, 1);
            layout.Controls.Add(transferPanel, 0, 2);
            Controls.Add(layout);

            addConnection.Click += async (sender, args) => await ManageConnectionAsync(false, false);
            editConnection.Click += async (sender, args) => await ManageConnectionAsync(true, false);
            removeConnection.Click += async (sender, args) => await ManageConnectionAsync(true, true);
            newBucket.Click += async (sender, args) => await CreateBucketAsync();
            deleteBucket.Click += async (sender, args) => await DeleteBucketAsync();
            upload.Click += async (sender, args) => await UploadAsync();
            download.Click += (sender, args) => Download();
            details.Click += (sender, args) => active.ToggleDetails();
            split.Click += async (sender, args) => await ToggleSplitAsync();
            cancel.Click += (sender, args) => { cancel.Enabled = false; transfer?.Cancel(); };
            Shown += async (sender, args) => await LoadConnectionsAsync();
            ActivatePane(left);
        }

        internal void ActivatePane(BrowserPane pane)
        {
            if (active == pane || (pane != left && pane != right) || pane.IsDisposed) return;
            active?.Active(false);
            active = pane;
            active.Active(!browser.Panel2Collapsed);
            UpdateCommands();
        }

        internal void UpdateCommands()
        {
            var selected = active?.Selected;
            var hasConnection = active?.CurrentConnection != null;
            var hasBucket = active?.HasBucket == true;
            var canWrite = active?.CanWrite == true;
            addConnection.Enabled = connectionStoreAvailable && !changingConnections;
            editConnection.Enabled = removeConnection.Enabled = addConnection.Enabled && hasConnection;
            newBucket.Enabled = canWrite && !mutating;
            deleteBucket.Enabled = hasBucket && newBucket.Enabled;
            upload.Enabled = transfer == null && hasBucket && canWrite;
            download.Enabled = transfer == null && hasBucket && selected != null && !selected.Folder;
            details.Enabled = hasBucket;
            cancel.Enabled = transfer != null && !transfer.IsCancellationRequested;
        }

        private async Task LoadConnectionsAsync()
        {
            try { connections = ConnectionStore.Load(); }
            catch (Exception ex)
            {
                connectionStoreAvailable = false;
                ShowError(ex, "无法读取已保存的连接");
            }
            UpdateCommands();
            await left.SetConnectionsAsync(connections);
        }

        private async Task ToggleSplitAsync()
        {
            if (!browser.Panel2Collapsed)
            {
                ActivatePane(left);
                browser.Panel2Collapsed = true;
                var closingPane = right;
                right = null;
                closingPane.Dispose();
                left.Active(false);
                split.Text = "左右分屏";
                return;
            }
            right = new BrowserPane(this);
            var newPane = right;
            var source = left.CurrentConnection;
            var bucket = left.Bucket;
            var prefix = left.Prefix;
            browser.Panel2.Controls.Add(newPane);
            browser.Panel2Collapsed = false;
            browser.SplitterDistance = (browser.ClientSize.Width - browser.SplitterWidth) / 2;
            left.Active(true);
            split.Text = "关闭右栏";
            await newPane.SetConnectionsAsync(connections, source);
            if (!newPane.IsDisposed && newPane.CurrentConnection == source && newPane.Bucket == null && bucket != null)
                await newPane.OpenAsync(bucket, prefix);
        }

        private async Task ManageConnectionAsync(bool existing, bool remove)
        {
            if (changingConnections || !connectionStoreAvailable) return;
            var pane = active;
            var previous = existing ? pane.CurrentConnection : null;
            if (existing && previous == null) return;
            if (remove && MessageBox.Show(this, "移除本机保存的连接「" + previous.Name + "」？", "移除连接", MessageBoxButtons.OKCancel,
                MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.OK) return;

            try
            {
                var replacement = remove ? null : Dialog.EditConnection(this, previous);
                if (!remove && replacement == null) return;
                var updated = new List<Connection>(connections);
                if (remove) updated.Remove(previous);
                else if (existing) updated[updated.IndexOf(previous)] = replacement;
                else updated.Add(replacement);
                ConnectionStore.Save(updated);
                connections = updated;
                changingConnections = true;
                UpdateCommands();
                var panes = new[] { left, right }.Where(item => item != null);
                await Task.WhenAll(panes.Select(item => item.SetConnectionsAsync(connections,
                    item == pane || (existing && item.CurrentConnection == previous) ? replacement : null)));
            }
            catch (Exception ex) { ShowError(ex, "无法保存连接"); }
            finally { changingConnections = false; if (!IsDisposed) UpdateCommands(); }
        }

        private async Task CreateBucketAsync()
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
                foreach (var item in new[] { left, right }.Where(item => item != null))
                {
                    item.InvalidateBucketDetails(connection, name);
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
                using (var client = connection.Open()) await client.DeleteObjectAsync(bucket, entry.Key);
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
                if (await RunTransferAsync("上传", connection, bucket, key, (client, progress, token) => Storage.UploadAsync(client, bucket, key, path, progress, token)))
                    await RefreshObjectAsync(connection, bucket, prefix, key);
            }
        }

        private Task RefreshObjectAsync(Connection connection, string bucket, string prefix, string key)
        {
            if (IsDisposed) return Task.CompletedTask;
            var panes = new[] { left, right }.Where(pane => pane != null);
            foreach (var pane in panes) pane.InvalidateObjectDetails(connection, bucket, key);
            return Task.WhenAll(panes.Where(pane => pane.CurrentConnection == connection && pane.Bucket == bucket && pane.Prefix == prefix)
                .Select(pane => pane.RefreshAsync()));
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
                await RunTransferAsync("下载", connection, bucket, entry.Key,
                    (client, progress, token) => Storage.DownloadAsync(client, bucket, entry.Key, picker.FileName, progress, token));
            }
        }

        private void SetTransfersVisible(bool value, Control panel)
        {
            transfersVisible = value;
            layout.RowStyles[2].Height = value ? 170 : 0;
            panel.Visible = value;
        }

        private async Task<bool> RunTransferAsync(string action, Connection connection, string bucket, string key,
            Func<IAmazonS3, Action<long, long>, CancellationToken, Task> start)
        {
            if (transfer != null) return false;
            using (var request = new CancellationTokenSource())
            {
                transfer = request;
                activity.Visible = true;
                UpdateCommands();
                if (!transfersVisible) transfers.PerformClick();
                var item = new ListViewItem(new[] { action, "s3://" + bucket + "/" + key, "0 字节", "进行中" });
                history.Items.Insert(0, item);
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
                        activity.Visible = false;
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
            if (error is AmazonS3Exception s3)
            {
                switch (s3.ErrorCode)
                {
                    case "AccessDenied": return "访问被拒绝。请检查当前连接的凭据和存储权限。";
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
