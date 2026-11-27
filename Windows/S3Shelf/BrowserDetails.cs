using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Amazon.S3.Model;

namespace S3Shelf
{
    internal sealed partial class BrowserPane
    {
        private readonly ComboBox detailKind = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 100 };
        private readonly TextBox detailText = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, Dock = DockStyle.Fill, WordWrap = false, BorderStyle = BorderStyle.None };
        private readonly Label detailStatus = new Label { AutoSize = true, ForeColor = Theme.Muted, Padding = new Padding(0, 4, 0, 0) };
        private readonly Dictionary<(Connection, string, string, int), (DateTime Time, string Text)> details = new Dictionary<(Connection, string, string, int), (DateTime, string)>();
        private CancellationTokenSource detailRequest;

        private Control MakeDetails()
        {
            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, BackColor = Theme.Surface };
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            var row = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, BackColor = Theme.Chrome, WrapContents = true };
            var refresh = Theme.Button("强制刷新");
            var edit = Theme.Button("编辑标签…");
            detailKind.Items.AddRange(new object[] { "属性", "响应头", "权限", "标签" });
            detailKind.SelectedIndex = 0;
            detailKind.AccessibleName = "详情类型";
            detailText.AccessibleName = "对象详情";
            detailText.BackColor = detailKind.BackColor = Theme.Surface;
            detailText.ForeColor = detailKind.ForeColor = Theme.Ink;
            row.Controls.AddRange(new Control[] { detailKind, refresh, edit, detailStatus });
            layout.Controls.Add(row, 0, 0);
            layout.Controls.Add(detailText, 0, 1);
            detailKind.SelectedIndexChanged += async (sender, args) => await LoadDetailsAsync(false);
            refresh.Click += async (sender, args) => await LoadDetailsAsync(true);
            edit.Click += async (sender, args) => await EditTagsAsync();
            return layout;
        }

        internal void ToggleDetails()
        {
            body.Panel2Collapsed = !body.Panel2Collapsed;
            if (!body.Panel2Collapsed && body.Height > 150) body.SplitterDistance = body.Height * 2 / 3;
            SelectionChanged();
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

        internal void InvalidateObjectDetails(Connection source, string bucketName, string objectKey)
        {
            for (var kind = 1; kind <= 3; kind++) details.Remove((source, bucketName, objectKey, kind));
        }

        internal void InvalidateBucketDetails(Connection source, string bucketName)
        {
            foreach (var key in details.Keys.Where(key => key.Item1 == source && key.Item2 == bucketName).ToArray())
                details.Remove(key);
        }

        private async Task LoadDetailsAsync(bool force)
        {
            CancelDetails();
            var selected = Selected;
            var kind = detailKind.SelectedIndex;
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
                    (selected == null ? "区域  " + connection.Region : $"大小  {selected.Size:N0} 字节\r\n更新时间  {selected.Modified?.ToLocalTime()}\r\n存储类  {selected.StorageClass}");
                return;
            }
            if (kind == 1 && key == null) { detailText.Text = "请选择一个对象查看响应头。"; return; }
            var cacheKey = (connection, bucket, key, kind);
            if (!force && details.TryGetValue(cacheKey, out var cached) && DateTime.UtcNow - cached.Time < TimeSpan.FromSeconds(30))
            {
                detailText.Text = cached.Text;
                detailStatus.Text = "缓存 · " + cached.Time.ToLocalTime().ToString("HH:mm:ss");
                return;
            }
            details.Remove(cacheKey);
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
                        var response = await client.GetObjectMetadataAsync(cacheKey.bucket, key, token);
                        text = string.Join(Environment.NewLine, response.Headers.Keys.OrderBy(name => name)
                            .Select(name => name + "  " + response.Headers[name])
                            .Concat(response.Metadata.Keys.OrderBy(name => name).Select(name => name + "  " + response.Metadata[name])));
                    }
                    else if (kind == 2)
                    {
                        if (key == null)
                        {
                            var response = await client.GetBucketAclAsync(new GetBucketAclRequest { BucketName = cacheKey.bucket }, token);
                            text = FormatAcl(response.Owner, response.Grants);
                        }
                        else
                        {
                            var response = await client.GetObjectAclAsync(new GetObjectAclRequest { BucketName = cacheKey.bucket, Key = key }, token);
                            text = FormatAcl(response.Owner, response.Grants);
                        }
                    }
                    else
                    {
                        var tags = key == null
                            ? (await client.GetBucketTaggingAsync(new GetBucketTaggingRequest { BucketName = cacheKey.bucket }, token)).TagSet
                            : (await client.GetObjectTaggingAsync(new GetObjectTaggingRequest { BucketName = cacheKey.bucket, Key = key }, token)).Tagging;
                        text = tags?.Count > 0 ? string.Join(Environment.NewLine, tags.Select(tag => tag.Key + " = " + tag.Value)) : "暂无标签";
                    }
                    if (request != detailRequest || IsDisposed) return;
                    if (details.Count >= 128) details.Remove(details.OrderBy(pair => pair.Value.Time).First().Key);
                    if (text.Length == 0) text = "端点未提供数据。";
                    details[cacheKey] = (DateTime.UtcNow, text);
                    detailText.Text = text;
                    detailStatus.Text = "";
                }
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { }
            catch (Amazon.S3.AmazonS3Exception ex) when (kind == 3 && (ex.ErrorCode == "NoSuchTagSet" || ex.ErrorCode == "NoSuchTagSetError"))
            {
                if (request != detailRequest || IsDisposed) return;
                if (details.Count >= 128) details.Remove(details.OrderBy(pair => pair.Value.Time).First().Key);
                details[cacheKey] = (DateTime.UtcNow, "暂无标签");
                detailText.Text = "暂无标签";
                detailStatus.Text = "";
            }
            catch (Exception ex) { if (request == detailRequest && !IsDisposed) { detailStatus.Text = "读取失败"; detailText.Text = MainWindow.Describe(ex); } }
            finally { if (request == detailRequest) { detailRequest = null; request.Dispose(); } }
        }

        private static string FormatAcl(Owner owner, List<S3Grant> grants) =>
            string.Join(Environment.NewLine, new[] { "所有者  " + (owner?.DisplayName ?? owner?.Id ?? "—") }
                .Concat((grants ?? new List<S3Grant>()).Select(grant =>
                    grant.Permission + "  " + (grant.Grantee?.DisplayName ?? grant.Grantee?.CanonicalUser ?? grant.Grantee?.URI ?? grant.Grantee?.EmailAddress ?? "—"))));

        private async Task EditTagsAsync()
        {
            if (!HasBucket || !CanWrite || Selected?.Folder == true) return;
            var selection = (connection, bucket, Key: Selected?.Key);
            try
            {
                using (var client = selection.connection.Open())
                {
                    List<Tag> tags;
                    try
                    {
                        tags = selection.Key == null
                            ? (await client.GetBucketTaggingAsync(new GetBucketTaggingRequest { BucketName = selection.bucket })).TagSet
                            : (await client.GetObjectTaggingAsync(new GetObjectTaggingRequest { BucketName = selection.bucket, Key = selection.Key })).Tagging;
                    }
                    catch (Amazon.S3.AmazonS3Exception ex) when (ex.ErrorCode == "NoSuchTagSet" || ex.ErrorCode == "NoSuchTagSetError") { tags = new List<Tag>(); }
                    if (IsDisposed || selection != (connection, bucket, Selected?.Key)) return;
                    var update = TagDialog.Edit(window, "s3://" + selection.bucket + "/" + selection.Key, tags ?? new List<Tag>());
                    if (update == null) return;
                    if (selection.Key == null)
                    {
                        if (update.Count == 0) await client.DeleteBucketTaggingAsync(new DeleteBucketTaggingRequest { BucketName = selection.bucket });
                        else await client.PutBucketTaggingAsync(new PutBucketTaggingRequest { BucketName = selection.bucket, TagSet = update });
                    }
                    else
                    {
                        if (update.Count == 0) await client.DeleteObjectTaggingAsync(new DeleteObjectTaggingRequest { BucketName = selection.bucket, Key = selection.Key });
                        else await client.PutObjectTaggingAsync(new PutObjectTaggingRequest { BucketName = selection.bucket, Key = selection.Key, Tagging = new Tagging { TagSet = update } });
                    }
                    details.Remove((selection.connection, selection.bucket, selection.Key, 3));
                    if (!IsDisposed && selection == (connection, bucket, Selected?.Key)) { detailKind.SelectedIndex = 3; await LoadDetailsAsync(true); }
                }
            }
            catch (Exception ex) { if (!IsDisposed) window.ShowError(ex, "无法保存标签"); }
        }
    }

    internal static class TagDialog
    {
        internal static List<Tag> Edit(Form owner, string location, List<Tag> current)
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
                var remove = Theme.Button("删除所选行");
                remove.Click += (sender, args) => { if (rows.CurrentRow != null && !rows.CurrentRow.IsNewRow) rows.Rows.Remove(rows.CurrentRow); };
                dialog.Field("", remove);
                List<Tag> result = null;
                dialog.Confirm.Click += (sender, args) =>
                {
                    rows.EndEdit();
                    var tags = rows.Rows.Cast<DataGridViewRow>().Where(row => !row.IsNewRow)
                        .Select(row => new Tag { Key = Convert.ToString(row.Cells[0].Value), Value = Convert.ToString(row.Cells[1].Value) }).ToList();
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
