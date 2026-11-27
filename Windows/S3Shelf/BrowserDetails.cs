using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Amazon.S3;
using Amazon.S3.Model;

namespace S3Shelf
{
    internal sealed partial class BrowserPane
    {
        private static readonly string[] DetailKinds = { "属性", "响应头", "权限", "标签" };
        private int detailKind;
        private readonly ShelfButton detailPicker = Theme.Button("属性 ▾");
        private readonly FlowLayoutPanel detailTabs = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(9, 1, 9, 4) };
        private readonly ShelfButton detailEdit = Theme.Button("编辑标签", Glyph.Edit, true);
        private readonly ShelfLabel detailLocation = Theme.Label("", true);
        private readonly RichTextBox detailText = new RichTextBox { ReadOnly = true, ScrollBars = RichTextBoxScrollBars.Both,
            Dock = DockStyle.Fill, WordWrap = false, BorderStyle = BorderStyle.None, DetectUrls = false };
        private readonly ShelfLabel detailStatus = Theme.Label("", true);
        private CancellationTokenSource detailRequest;

        private Control MakeDetails()
        {
            var layout = Theme.Paint(new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 4, Margin = Padding.Empty }, Fill.Surface);
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 23));
            var row = Theme.Paint(new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 4, RowCount = 1,
                Margin = Padding.Empty, Padding = new Padding(8, 1, 7, 1) }, Fill.Surface);
            row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            var refresh = Theme.Button("强制刷新", Glyph.Refresh, true);
            refresh.Quiet = detailEdit.Quiet = true;
            window.NameIcon(refresh);
            window.NameIcon(detailEdit);
            detailPicker.AccessibleName = "详情类型";
            detailLocation.Dock = DockStyle.Fill;
            detailLocation.TextAlign = ContentAlignment.MiddleLeft;
            detailLocation.Padding = new Padding(5, 0, 0, 0);
            detailText.AccessibleName = "对象详情";
            detailText.Margin = new Padding(11, 7, 9, 1);
            Theme.Paint(detailText, Fill.Surface);
            detailStatus.Dock = DockStyle.Fill;
            detailStatus.Padding = new Padding(11, 0, 0, 0);
            detailStatus.TextAlign = ContentAlignment.MiddleLeft;
            row.Controls.Add(detailPicker, 0, 0);
            row.Controls.Add(detailLocation, 1, 0);
            row.Controls.Add(detailEdit, 2, 0);
            row.Controls.Add(refresh, 3, 0);
            layout.Controls.Add(row, 0, 0);
            layout.Controls.Add(detailTabs, 0, 1);
            layout.Controls.Add(detailText, 0, 2);
            layout.Controls.Add(detailStatus, 0, 3);
            var menu = new ContextMenuStrip();
            for (var i = 0; i < DetailKinds.Length; i++)
            {
                var index = i;
                var tab = Theme.Button(DetailKinds[i]);
                tab.Margin = new Padding(1, 0, 1, 0);
                tab.Emphasized = tab.Selected = index == 0;
                tab.Click += async (sender, args) => await SelectDetailAsync(index, false);
                detailTabs.Controls.Add(tab);
                menu.Items.Add(DetailKinds[i], null, async (sender, args) => await SelectDetailAsync(index, false));
            }
            detailPicker.ContextMenuStrip = menu;
            menu.Opening += (sender, args) =>
            {
                for (var i = 0; i < menu.Items.Count; i++) ((ToolStripMenuItem)menu.Items[i]).Checked = i == detailKind;
                Theme.TintMenu(menu);
            };
            detailPicker.Click += (sender, args) => menu.Show(detailPicker, new Point(0, detailPicker.Height));
            refresh.Click += async (sender, args) => await LoadDetailsAsync(true);
            detailEdit.Click += async (sender, args) =>
            {
                if (detailKind == 2) await EditAclAsync();
                else await EditTagsAsync();
            };
            return layout;
        }

        internal void ToggleDetails()
        {
            body.Panel2Collapsed = !body.Panel2Collapsed;
            if (!body.Panel2Collapsed && body.Height > 150) body.SplitterDistance = body.Height * 2 / 3;
            detailsToggle.Selected = DetailsVisible;
            window.UpdateCommands();
            SelectionChanged();
        }

        private Task SelectDetailAsync(int kind, bool fresh)
        {
            detailKind = kind;
            detailPicker.Text = DetailKinds[kind] + " ▾";
            for (var index = 0; index < detailTabs.Controls.Count; index++)
            {
                var tab = (ShelfButton)detailTabs.Controls[index];
                tab.Emphasized = tab.Selected = detailKind == index;
            }
            return LoadDetailsAsync(fresh);
        }

        private async void SelectionChanged()
        {
            if (body == null || body.Panel2Collapsed) { CancelDetails(); return; }
            await LoadDetailsAsync(false);
        }

        private void CancelDetails()
        {
            if (detailRequest == null) return;
            detailRequest.Cancel();
            detailRequest.Dispose();
            detailRequest = null;
        }

        internal Task RefreshDetailsAsync() => DetailsVisible ? LoadDetailsAsync(false) : Task.CompletedTask;

        private async Task LoadDetailsAsync(bool force)
        {
            CancelDetails();
            var selected = Selected;
            var kind = detailKind;
            detailLocation.Text = HasBucket ? "s3://" + bucket + "/" + (selected?.Key ?? prefix) : "";
            detailEdit.Visible = (kind == 2 || kind == 3) && HasBucket && CanWrite && selected?.Folder != true;
            detailEdit.Text = detailEdit.AccessibleName = kind == 2 ? "编辑 ACL" : "编辑标签";
            window.NameIcon(detailEdit);
            detailStatus.Text = "";
            detailText.Clear();
            if (body.Panel2Collapsed || !HasBucket) return;
            if (selected?.Folder == true)
            {
                detailText.Text = "前缀  " + selected.Key;
                return;
            }
            var key = selected?.Key;
            if (kind == 0)
            {
                detailText.Text = "位置  s3://" + bucket + "/" + (key ?? prefix) + Environment.NewLine +
                    (selected == null ? "区域  " + connection.RegionLabel : $"大小  {selected.Size:N0} 字节\r\n更新时间  {selected.Modified?.ToLocalTime()}\r\n存储类  {selected.StorageClass}");
                return;
            }
            if (kind == 1 && key == null) { detailText.Text = "请选择一个对象查看响应头。"; return; }
            var cacheKey = (connection, bucket, key, kind);
            var cache = window.InspectorCache;
            if (!force && cache.TryRead(cacheKey, out var cached, out var cacheTime))
            {
                detailText.Text = cached;
                detailStatus.Text = "缓存 · " + cacheTime.ToString("HH:mm:ss");
                return;
            }
            if (force) cache.Refresh(cacheKey);
            var revision = cache.Revision;
            var started = Stopwatch.GetTimestamp();
            var request = new CancellationTokenSource();
            detailRequest = request;
            var token = request.Token;
            detailStatus.Text = "正在读取…";
            try
            {
                // Debounce rapid navigation through object rows.
                await Task.Delay(180, token);
                using (var client = cacheKey.connection.Open())
                {
                    string text;
                    if (kind == 1)
                    {
                        var response = await client.GetObjectMetadataAsync(new GetObjectMetadataRequest
                            { BucketName = cacheKey.bucket, Key = key, RequestPayer = cacheKey.connection.Payer }, token);
                        text = string.Join(Environment.NewLine, response.Headers.Keys.OrderBy(name => name)
                            .Select(name => name + "  " + response.Headers[name])
                            .Concat(response.Metadata.Keys.OrderBy(name => name).Select(name => name + "  " + response.Metadata[name])));
                    }
                    else if (kind == 2)
                    {
                        var acl = await ReadAclAsync(client, cacheKey.bucket, key, cacheKey.connection.Payer, token);
                        text = FormatAcl(acl.Owner, acl.Grants);
                    }
                    else
                    {
                        var tags = await ReadTagsAsync(client, cacheKey.bucket, key, cacheKey.connection.Payer, token);
                        text = tags.Count > 0 ? string.Join(Environment.NewLine, tags.Select(tag => tag.Key + " = " + tag.Value)) : "暂无标签";
                    }
                    if (request != detailRequest || IsDisposed) return;
                    if (text.Length == 0) text = "端点未提供数据。";
                    cache.Store(cacheKey, text, revision, started);
                    detailText.Text = text;
                    detailStatus.Text = "";
                }
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { }
            catch (Exception ex) { if (request == detailRequest && !IsDisposed) { detailStatus.Text = "读取失败"; detailText.Text = MainWindow.Describe(ex); } }
            finally { if (request == detailRequest) { detailRequest = null; request.Dispose(); } }
        }

        private static string FormatAcl(Owner owner, List<S3Grant> grants) =>
            string.Join(Environment.NewLine, new[] { "所有者  " + (owner?.DisplayName ?? owner?.Id ?? "—") }
                .Concat((grants ?? new List<S3Grant>()).Select(grant =>
                    grant.Permission + "  " + (grant.Grantee?.DisplayName ?? grant.Grantee?.CanonicalUser ?? grant.Grantee?.URI ?? grant.Grantee?.EmailAddress ?? "—"))));

        private static async Task<S3AccessControlList> ReadAclAsync(IAmazonS3 client, string bucket, string key, RequestPayer payer, CancellationToken token = default)
        {
            if (key == null)
            {
                var response = await client.GetBucketAclAsync(new GetBucketAclRequest { BucketName = bucket }, token);
                return new S3AccessControlList { Owner = response.Owner, Grants = response.Grants };
            }
            var result = await client.GetObjectAclAsync(new GetObjectAclRequest { BucketName = bucket, Key = key, RequestPayer = payer }, token);
            return new S3AccessControlList { Owner = result.Owner, Grants = result.Grants };
        }

        private async Task EditAclAsync()
        {
            if (!HasBucket || !CanWrite || Selected?.Folder == true) return;
            var selection = (connection, bucket, Key: Selected?.Key);
            try
            {
                using (var client = selection.connection.Open())
                {
                    var original = await ReadAclAsync(client, selection.bucket, selection.Key, selection.connection.Payer);
                    if (IsDisposed || selection != (connection, bucket, Selected?.Key)) return;
                    if (string.IsNullOrWhiteSpace(original.Owner?.Id))
                        throw new InvalidOperationException("端点未返回所有者 ID，无法编辑 ACL。");
                    var update = AclEditor.Edit(window, "s3://" + selection.bucket + "/" + selection.Key, original, selection.Key == null);
                    if (update == null || AclEditor.Same(original, update)) return;
                    var latest = await ReadAclAsync(client, selection.bucket, selection.Key, selection.connection.Payer);
                    if (!AclEditor.Same(original, latest))
                        throw new InvalidOperationException("端点上的 ACL 已变更，请刷新后重新编辑。");
                    await AclEditor.SaveAsync(client, selection.bucket, selection.Key, update, selection.connection.Payer);
                    await window.RefreshAccessDetailsAsync(selection.connection, selection.bucket, selection.Key);
                }
            }
            catch (Exception ex) { if (!IsDisposed) window.ShowError(ex, "无法保存 ACL"); }
        }

        private static async Task<List<Tag>> ReadTagsAsync(IAmazonS3 client, string bucket, string key, RequestPayer payer, CancellationToken token = default)
        {
            try
            {
                var tags = key == null
                    ? (await client.GetBucketTaggingAsync(new GetBucketTaggingRequest { BucketName = bucket }, token)).TagSet
                    : (await client.GetObjectTaggingAsync(new GetObjectTaggingRequest { BucketName = bucket, Key = key, RequestPayer = payer }, token)).Tagging;
                return tags ?? new List<Tag>();
            }
            catch (AmazonS3Exception ex) when (ex.ErrorCode == "NoSuchTagSet" || ex.ErrorCode == "NoSuchTagSetError") { return new List<Tag>(); }
        }

        private static bool SameTags(List<Tag> first, List<Tag> second) =>
            first.Select(tag => (tag.Key, tag.Value)).OrderBy(tag => tag.Key, StringComparer.Ordinal).ThenBy(tag => tag.Value, StringComparer.Ordinal)
                .SequenceEqual(second.Select(tag => (tag.Key, tag.Value)).OrderBy(tag => tag.Key, StringComparer.Ordinal).ThenBy(tag => tag.Value, StringComparer.Ordinal));

        private async Task EditTagsAsync()
        {
            if (!HasBucket || !CanWrite || Selected?.Folder == true) return;
            var selection = (connection, bucket, Key: Selected?.Key);
            try
            {
                using (var client = selection.connection.Open())
                {
                    var tags = await ReadTagsAsync(client, selection.bucket, selection.Key, selection.connection.Payer);
                    if (IsDisposed || selection != (connection, bucket, Selected?.Key)) return;
                    var update = TagDialog.Edit(window, "s3://" + selection.bucket + "/" + selection.Key, tags, selection.Key == null ? 50 : 10);
                    if (update == null || SameTags(tags, update)) return;
                    var latest = await ReadTagsAsync(client, selection.bucket, selection.Key, selection.connection.Payer);
                    if (!SameTags(tags, latest)) throw new InvalidOperationException("端点上的标签已变更，请刷新后重新编辑。");
                    if (selection.Key == null)
                    {
                        if (update.Count == 0) await client.DeleteBucketTaggingAsync(new DeleteBucketTaggingRequest { BucketName = selection.bucket });
                        else await client.PutBucketTaggingAsync(new PutBucketTaggingRequest { BucketName = selection.bucket, TagSet = update });
                    }
                    else
                    {
                        if (update.Count == 0) await client.DeleteObjectTaggingAsync(new DeleteObjectTaggingRequest { BucketName = selection.bucket, Key = selection.Key });
                        else await client.PutObjectTaggingAsync(new PutObjectTaggingRequest
                            { BucketName = selection.bucket, Key = selection.Key, Tagging = new Tagging { TagSet = update }, RequestPayer = selection.connection.Payer });
                    }
                    await window.RefreshAccessDetailsAsync(selection.connection, selection.bucket, selection.Key);
                }
            }
            catch (Exception ex) { if (!IsDisposed) window.ShowError(ex, "无法保存标签"); }
        }
    }

    internal static class TagDialog
    {
        internal static List<Tag> Edit(Form owner, string location, List<Tag> current, int limit)
        {
            using (var dialog = new Dialog("编辑标签"))
            {
                var rows = new DataGridView { Height = 220, AllowUserToAddRows = true, AllowUserToDeleteRows = true,
                    RowHeadersVisible = false, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill };
                rows.Columns.Add("key", "键");
                rows.Columns.Add("value", "值");
                foreach (var tag in current) rows.Rows.Add(tag.Key, tag.Value);
                dialog.Field("位置", new TextBox { Text = location, ReadOnly = true });
                dialog.Field("标签", rows);
                Theme.Apply(rows);
                var remove = Theme.Button("删除所选行");
                remove.Click += (sender, args) => { if (rows.CurrentRow != null && !rows.CurrentRow.IsNewRow) rows.Rows.Remove(rows.CurrentRow); };
                dialog.Field("", remove);
                List<Tag> result = null;
                dialog.Confirm.Click += (sender, args) =>
                {
                    rows.EndEdit();
                    var tags = rows.Rows.Cast<DataGridViewRow>().Where(row => !row.IsNewRow)
                        .Select(row => new Tag { Key = Convert.ToString(row.Cells[0].Value), Value = Convert.ToString(row.Cells[1].Value) }).ToList();
                    if (tags.Count > limit)
                    {
                        MessageBox.Show(dialog, $"此资源最多支持 {limit} 个标签。", "标签");
                        return;
                    }
                    if (tags.Any(tag => string.IsNullOrWhiteSpace(tag.Key) || tag.Key.Length > 128 || tag.Value.Length > 256) || tags.Select(tag => tag.Key).Distinct(StringComparer.Ordinal).Count() != tags.Count)
                    {
                        MessageBox.Show(dialog, "标签键不能为空或重复。键最多 128 个字符，值最多 256 个字符。", "标签");
                        return;
                    }
                    if (tags.Count == 0 && current.Count > 0 && MessageBox.Show(dialog, "删除此资源的全部标签？", "删除标签", MessageBoxButtons.OKCancel,
                        MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.OK) return;
                    result = tags;
                    dialog.DialogResult = DialogResult.OK;
                };
                return dialog.ShowDialog(owner) == DialogResult.OK ? result : null;
            }
        }
    }
}
