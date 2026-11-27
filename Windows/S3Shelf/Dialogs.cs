using System;
using System.Drawing;
using System.Windows.Forms;

namespace S3Shelf
{
    internal sealed class Dialog : Form
    {
        private readonly TableLayoutPanel fields = new TableLayoutPanel { ColumnCount = 2, Dock = DockStyle.Fill, AutoSize = true, Padding = new Padding(12) };
        internal readonly Button Confirm = Theme.Button("确定");

        internal Dialog(string title)
        {
            Text = title;
            StartPosition = FormStartPosition.CenterParent;
            Size = new Size(550, 100);
            AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = MinimizeBox = ShowInTaskbar = false;
            BackColor = Theme.Chrome;
            ForeColor = Theme.Ink;
            fields.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 112));
            fields.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 390));
            var cancel = Theme.Button("取消");
            cancel.DialogResult = DialogResult.Cancel;
            var footer = new FlowLayoutPanel { Dock = DockStyle.Bottom, FlowDirection = FlowDirection.RightToLeft, Height = 44, Padding = new Padding(6) };
            footer.Controls.AddRange(new Control[] { Confirm, cancel });
            Controls.Add(fields);
            Controls.Add(footer);
            AcceptButton = Confirm;
            CancelButton = cancel;
        }

        internal void Field(string label, Control input)
        {
            var row = fields.RowCount++;
            fields.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            fields.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(3, 6, 3, 6) }, 0, row);
            input.Anchor = AnchorStyles.Left | AnchorStyles.Right;
            input.BackColor = Theme.Surface;
            input.ForeColor = Theme.Ink;
            input.AccessibleName = label;
            fields.Controls.Add(input, 1, row);
        }

        internal static string Ask(IWin32Window owner, string title, string label, string value = "", string required = null)
        {
            using (var dialog = new Dialog(title))
            {
                var input = new TextBox { Text = value };
                dialog.Field(label, input);
                Action enable = () => dialog.Confirm.Enabled = required == null ? input.Text.Length > 0 : input.Text == required;
                input.TextChanged += (sender, args) => enable();
                dialog.Confirm.DialogResult = DialogResult.OK;
                enable();
                return dialog.ShowDialog(owner) == DialogResult.OK ? input.Text : null;
            }
        }

        internal static Connection EditConnection(IWin32Window owner, Connection value)
        {
            using (var dialog = new Dialog(value == null ? "新建 S3 连接" : "编辑 S3 连接"))
            {
                var name = new TextBox { Text = value?.Name ?? "" };
                var region = new TextBox { Text = value?.Region ?? "us-east-1" };
                var endpoint = new TextBox { Text = value?.Endpoint ?? "" };
                var auth = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList };
                auth.Items.AddRange(new object[] { "访问密钥", "AWS 配置档案", "匿名" });
                auth.SelectedIndex = (int)(value?.Authentication ?? Authentication.AccessKeys);
                var keys = value?.Credentials() ?? new[] { "", "", "" };
                var access = new TextBox { Text = keys[0] };
                var secret = new TextBox { Text = keys[1], UseSystemPasswordChar = true };
                var token = new TextBox { Text = keys[2], UseSystemPasswordChar = true };
                var profile = new TextBox { Text = value?.Profile ?? "default" };
                var path = new CheckBox { Checked = value?.PathStyle ?? false, AutoSize = true, Text = "兼容端点可启用" };
                dialog.Field("名称", name);
                dialog.Field("区域", region);
                dialog.Field("自定义端点", endpoint);
                dialog.Field("认证方式", auth);
                dialog.Field("访问密钥 ID", access);
                dialog.Field("访问密钥", secret);
                dialog.Field("临时会话令牌", token);
                dialog.Field("AWS 配置档案", profile);
                dialog.Field("路径式访问", path);

                void SetAuthFields()
                {
                    access.Enabled = secret.Enabled = token.Enabled = auth.SelectedIndex == (int)Authentication.AccessKeys;
                    profile.Enabled = auth.SelectedIndex == (int)Authentication.AwsProfile;
                }
                auth.SelectedIndexChanged += (sender, args) => SetAuthFields();
                SetAuthFields();
                Connection result = null;
                dialog.Confirm.Click += (sender, args) =>
                {
                    var url = endpoint.Text.Trim();
                    if (string.IsNullOrWhiteSpace(name.Text) || string.IsNullOrWhiteSpace(region.Text))
                    {
                        MessageBox.Show(dialog, "请填写连接名称和区域。", "连接设置");
                        return;
                    }
                    if (url.Length > 0 && (!Uri.TryCreate(url, UriKind.Absolute, out var uri) ||
                        (uri.Scheme != "http" && uri.Scheme != "https") || string.IsNullOrEmpty(uri.Host) ||
                        uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0))
                    {
                        MessageBox.Show(dialog, "请输入有效的 HTTP 或 HTTPS 端点。", "连接设置");
                        return;
                    }
                    var method = (Authentication)auth.SelectedIndex;
                    if ((method == Authentication.AccessKeys && (string.IsNullOrWhiteSpace(access.Text) || string.IsNullOrWhiteSpace(secret.Text))) ||
                        (method == Authentication.AwsProfile && string.IsNullOrWhiteSpace(profile.Text)))
                    {
                        MessageBox.Show(dialog, "请填写所选认证方式所需的资料。", "连接设置");
                        return;
                    }
                    try
                    {
                        result = new Connection { Name = name.Text.Trim(), Region = region.Text.Trim(), Endpoint = url.TrimEnd('/'),
                            Authentication = method, PathStyle = path.Checked, Profile = profile.Text.Trim() };
                        if (method == Authentication.AccessKeys) result.SetCredentials(access.Text.Trim(), secret.Text.Trim(), token.Text.Trim());
                        dialog.DialogResult = DialogResult.OK;
                    }
                    catch (Exception ex) { MessageBox.Show(dialog, ex.Message, "无法保存连接"); }
                };
                return dialog.ShowDialog(owner) == DialogResult.OK ? result : null;
            }
        }
    }
}
