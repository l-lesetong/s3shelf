using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;
using Amazon.S3;
using Amazon.S3.Model;

namespace S3Shelf
{
    internal static class AclEditor
    {
        private const string Canonical = "CanonicalUser";
        private const string Group = "Group";
        private const string Email = "AmazonCustomerByEmail";
        private const string AllUsers = "http://acs.amazonaws.com/groups/global/AllUsers";
        private const string AuthenticatedUsers = "http://acs.amazonaws.com/groups/global/AuthenticatedUsers";
        private const string LogDelivery = "http://acs.amazonaws.com/groups/s3/LogDelivery";
        private static readonly string[] PresetGroupUris = { AllUsers, AuthenticatedUsers, LogDelivery };

        internal static bool Same(S3AccessControlList first, S3AccessControlList second) =>
            string.Equals(first.Owner?.Id, second.Owner?.Id, StringComparison.Ordinal) &&
            Signatures(first).SequenceEqual(Signatures(second));

        private static IEnumerable<(string Type, string Principal, string Permission)> Signatures(S3AccessControlList acl) =>
            (acl.Grants ?? new List<S3Grant>()).Select(Fields).OrderBy(item => item.Type, StringComparer.Ordinal)
                .ThenBy(item => item.Principal, StringComparer.Ordinal).ThenBy(item => item.Permission, StringComparer.Ordinal);

        private static (string Type, string Principal, string Permission) Fields(S3Grant grant) =>
            (grant.Grantee?.Type?.Value, grant.Grantee?.CanonicalUser ?? grant.Grantee?.URI ?? grant.Grantee?.EmailAddress, grant.Permission?.Value);

        internal static Task SaveAsync(IAmazonS3 client, string bucket, string key, S3AccessControlList acl, RequestPayer payer)
        {
            // The SDK's ACL XML writer qualifies the Grantee element with the xsi namespace.
            // Use S3's signed grant headers so endpoints receive the standard representation.
            var headers = acl.Grants.Select(Fields).GroupBy(grant => grant.Permission, StringComparer.Ordinal).ToDictionary(
                group => group.Key, group => string.Join(",", group.Select(grant => FormatGrantee(grant.Type, grant.Principal))),
                StringComparer.Ordinal);
            string Get(string permission) => headers.TryGetValue(permission, out var value) ? value : null;
            var canned = headers.Count == 0 ? S3CannedACL.Private : null;
            if (key == null)
                return client.PutBucketAclAsync(new PutBucketAclRequest
                {
                    BucketName = bucket, ACL = canned, GrantRead = Get("READ"), GrantWrite = Get("WRITE"),
                    GrantReadACP = Get("READ_ACP"), GrantWriteACP = Get("WRITE_ACP"), GrantFullControl = Get("FULL_CONTROL")
                });
            return client.PutObjectAclAsync(new PutObjectAclRequest
            {
                BucketName = bucket, Key = key, ACL = canned, GrantRead = Get("READ"),
                GrantReadACP = Get("READ_ACP"), GrantWriteACP = Get("WRITE_ACP"), GrantFullControl = Get("FULL_CONTROL"), RequestPayer = payer
            });
        }

        private static string FormatGrantee(string type, string principal)
        {
            var field = type == Canonical ? "id" : type == Group ? "uri" : "emailAddress";
            return field + "=\"" + principal + "\"";
        }

        internal static S3AccessControlList Edit(Form owner, string location, S3AccessControlList current, bool bucket)
        {
            var permissions = bucket
                ? new[] { "READ", "WRITE", "READ_ACP", "WRITE_ACP", "FULL_CONTROL" }
                : new[] { "READ", "READ_ACP", "WRITE_ACP", "FULL_CONTROL" };
            using (var dialog = new Dialog("编辑 ACL"))
            {
                var rows = new DataGridView
                {
                    Height = 218, AllowUserToAddRows = true, AllowUserToDeleteRows = true, RowHeadersVisible = false,
                    AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill
                };
                var type = new DataGridViewComboBoxColumn { HeaderText = "主体类型", FillWeight = 34, FlatStyle = FlatStyle.Flat };
                type.Items.AddRange(Canonical, Group, Email);
                var permission = new DataGridViewComboBoxColumn { HeaderText = "权限", FillWeight = 31, FlatStyle = FlatStyle.Flat };
                permission.Items.AddRange(permissions);
                rows.Columns.Add(type);
                rows.Columns.Add(new DataGridViewTextBoxColumn { HeaderText = "主体标识", FillWeight = 45 });
                rows.Columns.Add(permission);
                foreach (var grant in current.Grants ?? Enumerable.Empty<S3Grant>())
                {
                    var entry = Fields(grant);
                    if (!type.Items.Contains(entry.Type) || !permission.Items.Contains(entry.Permission) || string.IsNullOrEmpty(entry.Principal))
                        throw new InvalidOperationException("该端点返回了无法编辑的授权，已保留当前 ACL。");
                    rows.Rows.Add(entry.Type, entry.Principal, entry.Permission);
                }
                dialog.Field("位置", new TextBox { Text = location, ReadOnly = true });
                dialog.Field("所有者 ID", new TextBox { Text = current.Owner.Id, ReadOnly = true });
                dialog.Content(rows);
                Theme.Apply(rows);
                var remove = Theme.Button("删除所选行");
                remove.Click += (sender, args) => { if (rows.CurrentRow != null && !rows.CurrentRow.IsNewRow) rows.Rows.Remove(rows.CurrentRow); };
                var groups = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList };
                groups.Items.AddRange(new object[] { "所有人", "AWS 已认证用户", "S3 日志投递" });
                groups.SelectedIndexChanged += (sender, args) =>
                {
                    if (groups.SelectedIndex < 0) return;
                    rows.EndEdit();
                    rows.Rows.Add(Group, PresetGroupUris[groups.SelectedIndex], "READ");
                    groups.SelectedIndex = -1;
                };
                dialog.Field("添加预定义组", groups);
                dialog.Field("", remove);
                dialog.Confirm.Text = "保存";
                S3AccessControlList result = null;
                dialog.Confirm.Click += (sender, args) =>
                {
                    rows.EndEdit();
                    var grants = new List<S3Grant>();
                    var unique = new HashSet<(string, string, string)>();
                    foreach (var row in rows.Rows.Cast<DataGridViewRow>().Where(row => !row.IsNewRow))
                    {
                        var granteeType = Convert.ToString(row.Cells[0].Value);
                        var principal = Convert.ToString(row.Cells[1].Value).Trim();
                        var access = Convert.ToString(row.Cells[2].Value);
                        if (!type.Items.Contains(granteeType) || principal.Length == 0 ||
                            principal.Any(character => character <= ' ' || character > '~' || character == '"' || character == '\\' || character == ',') ||
                            !permission.Items.Contains(access) ||
                            !unique.Add((granteeType, principal, access)))
                        {
                            MessageBox.Show(dialog, $"第 {row.Index + 1} 行的主体和权限必须填写完整，授权不能重复。", "检查 ACL");
                            return;
                        }
                        var grantee = new S3Grantee();
                        if (granteeType == Canonical) grantee.CanonicalUser = principal;
                        else if (granteeType == Group) grantee.URI = principal;
                        else grantee.EmailAddress = principal;
                        grants.Add(new S3Grant { Grantee = grantee, Permission = S3Permission.FindValue(access) });
                    }
                    if (grants.Count > 100)
                    {
                        MessageBox.Show(dialog, "ACL 最多支持 100 条授权。", "检查 ACL");
                        return;
                    }
                    var draft = new S3AccessControlList { Owner = current.Owner, Grants = grants };
                    var warning = grants.Any(grant => grant.Grantee.URI == AllUsers || grant.Grantee.URI == AuthenticatedUsers)
                        ? "新 ACL 包含面向所有人或 AWS 已认证用户的授权。\n\n" : "";
                    if (grants.Count == 0) warning = "将移除其他授权，仅保留所有者的完全控制权限。\n\n";
                    if (!Same(current, draft) && MessageBox.Show(dialog, warning + "替换此资源的 ACL？\n\n" + location,
                        "保存 ACL", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.OK) return;
                    result = draft;
                    dialog.DialogResult = DialogResult.OK;
                };
                return dialog.ShowDialog(owner) == DialogResult.OK ? result : null;
            }
        }
    }
}
