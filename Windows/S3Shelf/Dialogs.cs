using System;
using System.Drawing;
using System.Windows.Forms;

namespace S3Shelf
{
    internal sealed class Dialog : Form
    {
        private readonly TableLayoutPanel fields = new TableLayoutPanel { ColumnCount = 2, Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(20, 5, 20, 10) };
        internal readonly ShelfButton Confirm = Theme.Button("确定");

        internal Dialog(string title)
        {
            Text = title;
            StartPosition = FormStartPosition.CenterParent;
            Font = SystemFonts.MessageBoxFont;
            AutoScaleMode = AutoScaleMode.Dpi;
            AutoScaleDimensions = new SizeF(96, 96);
            var layout = Theme.Paint(new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 1, RowCount = 3 }, Fill.Surface);
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 550));
            for (var i = 0; i < 3; i++) layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = MinimizeBox = ShowInTaskbar = false;
            Theme.Paint(this, Fill.Surface);
            var heading = Theme.Label(title);
            heading.Font = Theme.Heading;
            heading.Dock = DockStyle.Top;
            heading.TextAlign = ContentAlignment.MiddleLeft;
            heading.Height = 49;
            heading.Padding = new Padding(20, 8, 0, 0);
            heading.Margin = Padding.Empty;
            fields.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 112));
            fields.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            var cancel = Theme.Button("取消");
            cancel.DialogResult = DialogResult.Cancel;
            Confirm.Emphasized = true;
            var footer = Theme.Paint(new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                FlowDirection = FlowDirection.RightToLeft, Padding = new Padding(14, 8, 14, 10), Margin = Padding.Empty }, Fill.Toolbar);
            footer.Controls.AddRange(new Control[] { Confirm, cancel });
            layout.Controls.Add(heading, 0, 0);
            layout.Controls.Add(fields, 0, 1);
            layout.Controls.Add(footer, 0, 2);
            Controls.Add(layout);
            AcceptButton = Confirm;
            CancelButton = cancel;
        }

        internal void Field(string label, Control input)
        {
            var row = fields.RowCount++;
            fields.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            var fieldLabel = Theme.Label(label, true);
            fieldLabel.AutoSize = true;
            fieldLabel.Anchor = AnchorStyles.Left;
            fieldLabel.Margin = new Padding(3, 6, 3, 6);
            fields.Controls.Add(fieldLabel, 0, row);
            input.Anchor = AnchorStyles.Left | AnchorStyles.Right;
            Theme.Paint(input, input is TextBox || input is ComboBox ? Fill.Field : Fill.Surface);
            input.AccessibleName = label;
            if (input is TextBox text) text.BorderStyle = BorderStyle.FixedSingle;
            fields.Controls.Add(input, 1, row);
        }

        internal void Content(Control content)
        {
            var row = fields.RowCount++;
            fields.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            content.Anchor = AnchorStyles.Left | AnchorStyles.Right;
            content.Margin = Padding.Empty;
            fields.Controls.Add(content, 0, row);
            fields.SetColumnSpan(content, 2);
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
    }
}
