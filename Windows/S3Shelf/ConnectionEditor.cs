using System;
using System.Drawing;
using System.IO;
using System.Windows.Forms;

namespace S3Shelf
{
    internal sealed class ConnectionEditor : Form
    {
        private readonly TableLayoutPanel fields = new TableLayoutPanel
        {
            ColumnCount = 2, Dock = DockStyle.Top, AutoSize = true, Margin = Padding.Empty
        };
        private readonly TextBox name = new TextBox();
        private readonly ComboBox auth = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, FlatStyle = FlatStyle.Flat };
        private readonly TextBox access = new TextBox();
        private readonly TextBox secret = new TextBox { UseSystemPasswordChar = true };
        private readonly TextBox token = new TextBox { UseSystemPasswordChar = true };
        private readonly TextBox profile = new TextBox();
        private readonly TextBox region = new TextBox();
        private readonly TextBox endpoint = new TextBox();
        private readonly TextBox preferredBucket = new TextBox();
        private readonly ShelfLabel caLabel = Theme.Label("沿用系统配置", true);
        private readonly ShelfButton chooseCa = Theme.Button("选择…");
        private readonly ShelfButton clearCa = Theme.Button("清除");
        private readonly CheckBox skipTls = new CheckBox { Text = "忽略 TLS 证书验证", AutoSize = true, Anchor = AnchorStyles.Left };
        private readonly ShelfLabel tlsHint = Theme.Label();
        private readonly CheckBox path = new CheckBox { Text = "强制使用路径式地址", AutoSize = true, Anchor = AnchorStyles.Left };
        private readonly CheckBox requesterPays = new CheckBox { Text = "Requester Pays（由请求方付费）", AutoSize = true, Anchor = AnchorStyles.Left };
        private readonly ShelfLabel feedback = Theme.Label();
        private Connection result;
        private Control invalidField;
        private string caBundle;

        private ConnectionEditor(Connection value)
        {
            Text = value == null ? "新建连接" : "编辑连接";
            StartPosition = FormStartPosition.CenterParent;
            Font = SystemFonts.MessageBoxFont;
            AutoScaleMode = AutoScaleMode.Dpi;
            AutoScaleDimensions = new SizeF(96, 96);
            AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = MinimizeBox = ShowInTaskbar = false;
            Theme.Paint(this, Fill.Toolbar);

            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, AutoSize = true, Padding = new Padding(25) };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 490));
            var heading = Theme.Label(Text);
            heading.Font = Theme.Heading;
            heading.AutoSize = true;
            heading.Margin = Padding.Empty;
            var subtitle = Theme.Label("Amazon S3 和兼容对象存储", true);
            subtitle.AutoSize = true;
            subtitle.Margin = new Padding(0, 4, 0, 20);
            layout.Controls.Add(heading, 0, 0);
            layout.Controls.Add(subtitle, 0, 1);
            layout.Controls.Add(fields, 0, 2);

            name.Text = value?.Name ?? "";
            region.Text = value?.Region ?? "";
            endpoint.Text = value?.Endpoint ?? "";
            preferredBucket.Text = value?.PreferredBucket ?? "";
            caBundle = value?.CaBundle ?? "";
            profile.Text = string.IsNullOrWhiteSpace(value?.Profile) ? "default" : value.Profile;
            path.Checked = value?.PathStyle ?? false;
            requesterPays.Checked = value?.RequesterPays ?? false;
            var previousEndpoint = endpoint.Text.Trim().TrimEnd('/');
            skipTls.Checked = value?.SkipTlsVerification == true && Connection.ParseEndpoint(previousEndpoint)?.Scheme == Uri.UriSchemeHttps;
            if (value?.Authentication == Authentication.AccessKeys)
            {
                var keys = value.Credentials();
                access.Text = keys[0];
                secret.Text = keys[1];
                token.Text = keys[2];
            }

            Theme.Paint(auth, Fill.Surface);
            auth.DrawMode = DrawMode.OwnerDrawFixed;
            auth.DrawItem += (sender, args) =>
            {
                if (args.Index < 0) return;
                var selected = (args.State & DrawItemState.Selected) != 0;
                var editing = (args.State & DrawItemState.ComboBoxEdit) != 0;
                using (var brush = new SolidBrush(selected && !editing ? Theme.Highlight : Theme.Surface))
                    args.Graphics.FillRectangle(brush, args.Bounds);
                TextRenderer.DrawText(args.Graphics, auth.GetItemText(auth.Items[args.Index]), auth.Font,
                    Rectangle.Inflate(args.Bounds, -5, 0), selected && !editing ? Theme.HighlightText : Theme.Ink, Theme.SingleLine);
            };
            auth.Items.AddRange(new object[] { "访问密钥", "AWS Profile", "匿名" });
            auth.SelectedIndex = (int)(value?.Authentication ?? Authentication.AccessKeys);

            fields.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 156));
            fields.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            AddInput("连接名称", name);
            AddField("身份验证", auth, auth);
            var accessRow = AddInput("Access Key ID", access);
            var secretRow = AddInput("Secret Access Key", secret);
            var tokenRow = AddInput("Session Token（可选）", token);
            var profileRow = AddInput("AWS Profile", profile);
            AddInput("区域（可选）", region);
            var regionHint = Theme.Label("留空时使用 AWS 区域配置，缺省为 us-east-1。", true);
            regionHint.AutoSize = true;
            regionHint.Margin = new Padding(0, 0, 0, 8);
            fields.Controls.Add(regionHint, 1, fields.RowCount++);
            AddInput("自定义端点（可选）", endpoint);
            AddInput("首选存储桶 / ARN", preferredBucket);
            var caRow = new TableLayoutPanel { ColumnCount = 3, AutoSize = true, Margin = Padding.Empty };
            caRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            caRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            caRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            caLabel.Dock = DockStyle.Fill;
            caLabel.TextAlign = ContentAlignment.MiddleLeft;
            caLabel.Margin = new Padding(0, 0, 6, 0);
            caRow.Controls.Add(caLabel, 0, 0);
            caRow.Controls.Add(chooseCa, 1, 0);
            caRow.Controls.Add(clearCa, 2, 0);
            AddField("自定义 CA", caRow, chooseCa);
            AddOption(skipTls, 9);
            tlsHint.AutoSize = true;
            tlsHint.MaximumSize = new Size(440, 0);
            tlsHint.Margin = new Padding(20, 2, 0, 4);
            fields.Controls.Add(tlsHint, 0, fields.RowCount++);
            fields.SetColumnSpan(tlsHint, 2);
            AddOption(path, 5);
            AddOption(requesterPays, 5);

            void UpdateTlsOptions()
            {
                var https = Connection.ParseEndpoint(endpoint.Text.Trim())?.Scheme == Uri.UriSchemeHttps;
                skipTls.Enabled = https;
                chooseCa.Enabled = https && !skipTls.Checked;
                clearCa.Enabled = chooseCa.Enabled && caBundle.Length > 0;
                clearCa.Visible = caBundle.Length > 0;
                caLabel.Text = caBundle.Length == 0 ? "沿用系统配置" : Path.GetFileName(caBundle);
                tlsHint.Text = skipTls.Checked
                    ? "连接仍会加密，但无法验证服务器身份。请仅用于可信测试环境。"
                    : "仅适用于当前连接的自定义 HTTPS 端点。";
                tlsHint.ForeColor = Theme.HighContrast ? Theme.Ink : skipTls.Checked
                    ? (Theme.Dark ? Color.SandyBrown : Color.SaddleBrown) : Theme.Muted;
            }
            endpoint.TextChanged += (sender, args) =>
            {
                var currentEndpoint = endpoint.Text.Trim().TrimEnd('/');
                if (!string.Equals(previousEndpoint, currentEndpoint, StringComparison.Ordinal)) skipTls.Checked = false;
                previousEndpoint = currentEndpoint;
                UpdateTlsOptions();
            };
            skipTls.CheckedChanged += (sender, args) => UpdateTlsOptions();
            chooseCa.Click += (sender, args) =>
            {
                using (var picker = new OpenFileDialog { Title = "选择自定义 CA", Filter = "PEM 证书 (*.pem;*.crt)|*.pem;*.crt|所有文件 (*.*)|*.*" })
                {
                    if (picker.ShowDialog(this) != DialogResult.OK) return;
                    try
                    {
                        EndpointCaBundle.Load(picker.FileName);
                        caBundle = picker.FileName;
                        UpdateTlsOptions();
                        if (invalidField == chooseCa) ClearFeedback();
                    }
                    catch (InvalidOperationException error) { ShowFeedback(error.Message, chooseCa); }
                }
            };
            clearCa.Click += (sender, args) => { caBundle = ""; UpdateTlsOptions(); };
            UpdateTlsOptions();

            void UpdateAuthFields()
            {
                fields.SuspendLayout();
                var method = (Authentication)auth.SelectedIndex;
                foreach (var control in accessRow) control.Visible = method == Authentication.AccessKeys;
                foreach (var control in secretRow) control.Visible = method == Authentication.AccessKeys;
                foreach (var control in tokenRow) control.Visible = method == Authentication.AccessKeys;
                foreach (var control in profileRow) control.Visible = method == Authentication.AwsProfile;
                requesterPays.Enabled = method != Authentication.Anonymous;
                fields.ResumeLayout(true);
            }
            auth.SelectedIndexChanged += (sender, args) =>
            {
                UpdateAuthFields();
                if (invalidField == access || invalidField == secret) ClearFeedback();
            };
            UpdateAuthFields();

            feedback.Visible = false;
            feedback.AutoSize = true;
            feedback.MaximumSize = new Size(490, 0);
            feedback.Margin = new Padding(0, 12, 0, 0);
            feedback.ForeColor = Theme.HighContrast ? Theme.Ink : Theme.Dark ? Color.LightCoral : Color.Firebrick;
            feedback.AccessibleRole = AccessibleRole.Alert;
            layout.Controls.Add(feedback, 0, 3);

            var footer = new FlowLayoutPanel
            {
                Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                FlowDirection = FlowDirection.RightToLeft, WrapContents = false, Margin = new Padding(0, 18, 0, 0)
            };
            var confirm = Theme.Button("保存并连接");
            confirm.Emphasized = true;
            confirm.Click += (sender, args) => Save();
            var cancel = Theme.Button("取消");
            cancel.DialogResult = DialogResult.Cancel;
            footer.Controls.AddRange(new Control[] { confirm, cancel });
            layout.Controls.Add(footer, 0, 4);
            Controls.Add(layout);
            AcceptButton = confirm;
            CancelButton = cancel;
            ActiveControl = name;
        }

        internal static Connection Edit(IWin32Window owner, Connection value)
        {
            using (var editor = new ConnectionEditor(value))
                return editor.ShowDialog(owner) == DialogResult.OK ? editor.result : null;
        }

        private Control[] AddInput(string label, TextBox input)
        {
            var frame = new InputFrame(input);
            input.TextChanged += (sender, args) => { if (invalidField == input) ClearFeedback(); };
            return AddField(label, frame, input);
        }

        private Control[] AddField(string label, Control frame, Control input)
        {
            var row = fields.RowCount++;
            var caption = Theme.Label(label);
            caption.AutoSize = true;
            caption.Anchor = AnchorStyles.Left;
            caption.Margin = new Padding(0, 0, 8, 0);
            frame.Anchor = AnchorStyles.Left | AnchorStyles.Right;
            frame.Margin = new Padding(0, 0, 0, 6);
            input.AccessibleName = label;
            fields.Controls.Add(caption, 0, row);
            fields.Controls.Add(frame, 1, row);
            return new[] { caption, frame };
        }

        private void AddOption(CheckBox checkBox, int topMargin)
        {
            checkBox.Margin = new Padding(0, topMargin, 0, 0);
            checkBox.ForeColor = Theme.Ink;
            fields.Controls.Add(checkBox, 0, fields.RowCount++);
            fields.SetColumnSpan(checkBox, 2);
        }

        private void ClearFeedback()
        {
            invalidField = null;
            feedback.Visible = false;
        }

        private void ShowFeedback(string message, Control field = null)
        {
            invalidField = field;
            feedback.Text = message;
            feedback.Visible = true;
            field?.Focus();
        }

        private void Save()
        {
            var url = endpoint.Text.Trim();
            var method = (Authentication)auth.SelectedIndex;
            if (string.IsNullOrWhiteSpace(name.Text))
            {
                ShowFeedback("请输入连接名称。", name);
                return;
            }
            if (method == Authentication.AccessKeys && string.IsNullOrWhiteSpace(access.Text))
            {
                ShowFeedback("请输入 Access Key ID。", access);
                return;
            }
            if (method == Authentication.AccessKeys && string.IsNullOrWhiteSpace(secret.Text))
            {
                ShowFeedback("请输入 Secret Access Key。", secret);
                return;
            }
            var uri = Connection.ParseEndpoint(url);
            if (url.Length > 0 && uri == null)
            {
                ShowFeedback("请输入有效的 HTTP 或 HTTPS 端点。", endpoint);
                return;
            }

            try
            {
                var draft = new Connection
                {
                    Name = name.Text.Trim(),
                    Authentication = method,
                    Profile = string.IsNullOrWhiteSpace(profile.Text) ? "default" : profile.Text.Trim(),
                    Region = region.Text.Trim(),
                    Endpoint = url.TrimEnd('/'),
                    PreferredBucket = preferredBucket.Text.Trim(),
                    CaBundle = uri?.Scheme == Uri.UriSchemeHttps ? caBundle : "",
                    SkipTlsVerification = skipTls.Checked && uri?.Scheme == Uri.UriSchemeHttps,
                    RequesterPays = requesterPays.Checked && method != Authentication.Anonymous,
                    PathStyle = path.Checked
                };
                if (method == Authentication.AccessKeys) draft.SetCredentials(access.Text.Trim(), secret.Text.Trim(), token.Text.Trim());
                result = draft;
                DialogResult = DialogResult.OK;
            }
            catch (Exception error) { ShowFeedback("无法保存连接。 " + error.Message); }
        }

        private sealed class InputFrame : Panel
        {
            private readonly TextBox input;

            internal InputFrame(TextBox input)
            {
                this.input = input;
                SetStyle(ControlStyles.ResizeRedraw, true);
                Height = 27;
                input.BorderStyle = BorderStyle.None;
                Theme.Paint(input, Fill.Surface);
                input.GotFocus += (sender, args) => Invalidate();
                input.LostFocus += (sender, args) => Invalidate();
                Controls.Add(input);
            }

            protected override void OnLayout(LayoutEventArgs args)
            {
                base.OnLayout(args);
                var inset = (int)Math.Round(8 * DeviceDpi / 96f);
                input.SetBounds(inset, (Height - input.PreferredHeight) / 2,
                    Math.Max(0, Width - 2 * inset), input.PreferredHeight);
            }

            protected override void OnPaint(PaintEventArgs args)
            {
                base.OnPaint(args);
                var bounds = new Rectangle(0, 0, Width - 1, Height - 1);
                var radius = (int)Math.Round(6 * DeviceDpi / 96f);
                Theme.Rounded(args.Graphics, bounds, radius, Theme.Surface, input.Focused ? Theme.Accent : Theme.Line);
            }

            protected override void OnMouseDown(MouseEventArgs args)
            {
                base.OnMouseDown(args);
                input.Focus();
            }
        }
    }
}
