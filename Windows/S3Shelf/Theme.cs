using System.Drawing;
using System.Windows.Forms;
using Microsoft.Win32;

namespace S3Shelf
{
    internal static class Theme
    {
        internal static readonly bool Dark = !SystemInformation.HighContrast &&
            Equals(Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1), 0);
        internal static readonly Color Surface = SystemInformation.HighContrast ? SystemColors.Window : Dark ? Color.FromArgb(32, 33, 35) : Color.White;
        internal static readonly Color Chrome = SystemInformation.HighContrast ? SystemColors.Control : Dark ? Color.FromArgb(42, 43, 46) : Color.FromArgb(244, 245, 247);
        internal static readonly Color Ink = SystemInformation.HighContrast ? SystemColors.WindowText : Dark ? Color.FromArgb(237, 238, 240) : Color.FromArgb(29, 31, 34);
        internal static readonly Color Muted = SystemInformation.HighContrast ? SystemColors.GrayText : Dark ? Color.FromArgb(175, 178, 185) : Color.FromArgb(86, 92, 104);
        internal static readonly Color Line = SystemInformation.HighContrast ? SystemColors.WindowText : Dark ? Color.FromArgb(130, 133, 140) : Color.FromArgb(105, 111, 122);

        internal static Button Button(string text)
        {
            var button = new Button { Text = text, AutoSize = true, Height = 28, FlatStyle = FlatStyle.Flat, BackColor = Chrome, ForeColor = Ink };
            button.FlatAppearance.BorderColor = Line;
            return button;
        }

        internal static ListView List()
        {
            return new ListView { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, HideSelection = false,
                MultiSelect = false, BackColor = Surface, ForeColor = Ink, BorderStyle = BorderStyle.None };
        }
    }
}
