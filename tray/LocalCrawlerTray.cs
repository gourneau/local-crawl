using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

// System tray launcher for the local crawler.
// Start/stop is delegated to crawl.ps1 next to this exe; status comes from polling
// the API's /health endpoint and the browser's DevTools port.
static class Program
{
    [STAThread]
    static void Main()
    {
        bool isFirstInstance;
        using (Mutex mutex = new Mutex(true, "LocalCrawlerTray", out isFirstInstance))
        {
            if (!isFirstInstance)
            {
                MessageBox.Show(
                    "Local Crawler is already running.\n\nLook for the globe icon in the system tray. " +
                    "If you don't see it, click the ^ arrow on the taskbar.",
                    "Local Crawler", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new TrayContext());
        }
    }
}

enum CrawlerState { Checking, Running, Stopped, Busy }

class TrayContext : ApplicationContext
{
    const int PollMs = 4000;

    readonly string _root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
    readonly string _apiUrl;
    readonly string _cdpUrl;
    readonly string _modeFile;        // written by crawl.ps1: mode of the running browser
    readonly string _preferenceFile;  // the tray's saved choice for the next start
    readonly NotifyIcon _icon;
    readonly Control _ui;             // hidden control, used to get back onto the UI thread
    readonly System.Windows.Forms.Timer _poll;
    readonly ToolStripMenuItem _statusItem;
    readonly ToolStripMenuItem _toggleItem;
    readonly ToolStripMenuItem _restartItem;
    readonly ToolStripMenuItem _optionsItem;
    readonly ToolStripMenuItem _headlessItem;
    readonly ToolStripMenuItem _headedItem;
    readonly Icon _runningIcon = MakeIcon(Color.FromArgb(46, 160, 67));
    readonly Icon _stoppedIcon = MakeIcon(Color.FromArgb(130, 139, 150));
    readonly Icon _attentionIcon = MakeIcon(Color.FromArgb(212, 160, 23));

    CrawlerState _state = CrawlerState.Checking;
    bool _busy;
    int _checking;
    bool _preferHeaded;
    bool _browserUp;
    string _runningMode;   // "headed", "headless", or null when unknown

    public TrayContext()
    {
        _apiUrl = "http://127.0.0.1:" + ReadSetting("ApiPort", "3002");
        _cdpUrl = "http://127.0.0.1:" + ReadSetting("CdpPort", "9223");
        _modeFile = Path.Combine(_root, @"run\browser.mode");
        _preferenceFile = Path.Combine(_root, @"run\tray-browser-mode");
        _preferHeaded = ReadFile(_preferenceFile) == "headed";

        _ui = new Control();
        IntPtr forceHandle = _ui.Handle;

        _statusItem = new ToolStripMenuItem("Checking...");
        _statusItem.Enabled = false;
        _toggleItem = new ToolStripMenuItem("Start crawler", null, delegate { Toggle(); });
        _toggleItem.Font = new Font(_toggleItem.Font, FontStyle.Bold);
        _restartItem = new ToolStripMenuItem("Restart", null,
            delegate { RunAction("restart", "Restarting...", "Crawler restarted."); });

        _headlessItem = new ToolStripMenuItem("Hidden browser (headless)", null, delegate { SetBrowserMode(false); });
        _headedItem = new ToolStripMenuItem("Visible browser (for debugging)", null, delegate { SetBrowserMode(true); });
        _optionsItem = new ToolStripMenuItem("Options");
        _optionsItem.DropDownItems.Add(_headlessItem);
        _optionsItem.DropDownItems.Add(_headedItem);

        ContextMenuStrip menu = new ContextMenuStrip();
        menu.Items.Add(_statusItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_toggleItem);
        menu.Items.Add(_restartItem);
        menu.Items.Add(_optionsItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Show live log", null, delegate { ShowLiveLog(); });
        menu.Items.Add("Open logs folder", null, delegate { OpenFolder(Path.Combine(_root, "logs")); });
        menu.Items.Add("Open crawler folder", null, delegate { OpenFolder(_root); });
        menu.Items.Add("Copy API URL", null, delegate
        {
            Clipboard.SetText(_apiUrl);
            Notify("Copied " + _apiUrl, ToolTipIcon.Info);
        });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit", null, delegate { ExitTray(); });

        _icon = new NotifyIcon();
        _icon.Icon = _stoppedIcon;
        _icon.Text = "Local Crawler";
        _icon.ContextMenuStrip = menu;
        _icon.MouseUp += delegate (object sender, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left) ShowMenu();
        };
        _icon.Visible = true;

        _poll = new System.Windows.Forms.Timer();
        _poll.Interval = PollMs;
        _poll.Tick += delegate { CheckHealth(); };
        _poll.Start();

        UpdateUi(CrawlerState.Checking, null);
        CheckHealth();
    }

    // --- Status -----------------------------------------------------------------

    void CheckHealth()
    {
        if (_busy || Interlocked.Exchange(ref _checking, 1) == 1) return;
        ThreadPool.QueueUserWorkItem(delegate
        {
            bool apiUp = IsUp(_apiUrl + "/health");
            bool browserUp = apiUp && IsUp(_cdpUrl + "/json/version");
            string mode = ReadFile(_modeFile);
            _ui.BeginInvoke((Action)delegate
            {
                _checking = 0;
                if (_busy) return;
                _browserUp = browserUp;
                _runningMode = mode;
                UpdateUi(apiUp ? CrawlerState.Running : CrawlerState.Stopped, null);
            });
        });
    }

    static bool IsUp(string url)
    {
        try
        {
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(url);
            request.Timeout = 1500;
            request.ReadWriteTimeout = 1500;
            request.Proxy = null;
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            {
                return response.StatusCode == HttpStatusCode.OK;
            }
        }
        catch
        {
            return false;
        }
    }

    void UpdateUi(CrawlerState state, string busyText)
    {
        _state = state;
        if (state == CrawlerState.Running && _browserUp)
        {
            _icon.Icon = _runningIcon;
            SetTooltip("running" + (_runningMode != null ? " (" + _runningMode + ")" : ""));
            _statusItem.Text = "Running at " + _apiUrl;
            _toggleItem.Text = "Stop crawler";
        }
        else if (state == CrawlerState.Running)
        {
            // The API is up but the browser is gone, e.g. its visible window was closed.
            _icon.Icon = _attentionIcon;
            SetTooltip("browser closed, restart to fix");
            _statusItem.Text = "Running, but the browser is closed. Restart to fix JS pages.";
            _toggleItem.Text = "Stop crawler";
        }
        else if (state == CrawlerState.Stopped)
        {
            _icon.Icon = _stoppedIcon;
            SetTooltip("stopped");
            _statusItem.Text = "Stopped";
            _toggleItem.Text = "Start crawler";
        }
        else
        {
            _icon.Icon = _attentionIcon;
            SetTooltip(busyText ?? "checking...");
            _statusItem.Text = busyText ?? "Checking...";
        }

        bool settled = state == CrawlerState.Running || state == CrawlerState.Stopped;
        _toggleItem.Enabled = settled;
        _restartItem.Enabled = state == CrawlerState.Running;
        _optionsItem.Enabled = settled;

        // While running, show the mode actually in use; otherwise the one the next start will use.
        bool headed = (state == CrawlerState.Running && _runningMode != null) ? _runningMode == "headed" : _preferHeaded;
        _headedItem.Checked = headed;
        _headlessItem.Checked = !headed;
    }

    void SetTooltip(string status)
    {
        string text = "Local Crawler: " + status;
        _icon.Text = text.Length > 63 ? text.Substring(0, 63) : text;
    }

    // --- Actions ----------------------------------------------------------------

    void Toggle()
    {
        if (_state == CrawlerState.Running)
            RunAction("stop", "Stopping...", "Crawler stopped.");
        else
            RunAction("start", "Starting...", "Crawler is running at " + _apiUrl);
    }

    void SetBrowserMode(bool headed)
    {
        _preferHeaded = headed;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_preferenceFile));
            File.WriteAllText(_preferenceFile, headed ? "headed" : "headless");
        }
        catch
        {
        }

        string wanted = headed ? "headed" : "headless";
        if (_state == CrawlerState.Running && _runningMode != wanted)
        {
            RunAction("restart",
                headed ? "Opening the browser window..." : "Hiding the browser...",
                headed ? "Browser is visible. Closing its window stops JS rendering until you restart."
                       : "Browser is hidden again.");
        }
        else
        {
            UpdateUi(_state, null);
        }
    }

    void RunAction(string command, string busyText, string doneText)
    {
        if (_busy) return;
        _busy = true;
        if (command != "stop" && _preferHeaded) command += " -Headed";
        UpdateUi(CrawlerState.Busy, busyText);
        ThreadPool.QueueUserWorkItem(delegate
        {
            string error = RunCrawlScript(command);
            _ui.BeginInvoke((Action)delegate
            {
                _busy = false;
                if (error == null) Notify(doneText, ToolTipIcon.Info);
                else Notify(error, ToolTipIcon.Error);
                CheckHealth();
            });
        });
    }

    static string PowerShellExe
    {
        get { return Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"); }
    }

    // Runs crawl.ps1 with no visible window. Returns null on success, or an error message.
    string RunCrawlScript(string command)
    {
        string script = Path.Combine(_root, "crawl.ps1");
        string errorFile = Path.Combine(_root, @"run\last-error.txt");

        ProcessStartInfo psi = new ProcessStartInfo(PowerShellExe,
            string.Format("-NoProfile -ExecutionPolicy Bypass -File \"{0}\" {1}", script, command));
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = _root;
        try
        {
            using (Process p = Process.Start(psi))
            {
                if (!p.WaitForExit(180000)) return "Timed out waiting for crawl.ps1 " + command + ".";
                if (p.ExitCode == 0) return null;
            }
            string saved = ReadFile(errorFile);
            return saved ?? "crawl.ps1 " + command + " failed. Check the logs folder.";
        }
        catch (Exception ex)
        {
            return ex.Message;
        }
    }

    // Opens a normal console window that follows the server log.
    void ShowLiveLog()
    {
        ProcessStartInfo psi = new ProcessStartInfo(PowerShellExe, string.Format(
            "-NoProfile -ExecutionPolicy Bypass -NoExit -File \"{0}\" logs", Path.Combine(_root, "crawl.ps1")));
        psi.UseShellExecute = true;
        psi.WorkingDirectory = _root;
        try
        {
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            Notify(ex.Message, ToolTipIcon.Error);
        }
    }

    void ExitTray()
    {
        if (_busy) return;
        if (_state == CrawlerState.Running)
        {
            DialogResult answer = MessageBox.Show(
                "Stop the crawler too?\n\nYes: stop it, then exit.\nNo: leave it running in the background.",
                "Local Crawler", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
            if (answer == DialogResult.Cancel) return;
            if (answer == DialogResult.Yes)
            {
                UpdateUi(CrawlerState.Busy, "Stopping...");
                string error = RunCrawlScript("stop");
                if (error != null)
                    MessageBox.Show(error, "Local Crawler", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
        _poll.Stop();
        _icon.Visible = false;
        _icon.Dispose();
        ExitThread();
    }

    // --- Helpers ----------------------------------------------------------------

    void Notify(string text, ToolTipIcon kind)
    {
        if (text.Length > 250) text = text.Substring(0, 247) + "...";
        _icon.ShowBalloonTip(4000, "Local Crawler", text, kind);
    }

    // NotifyIcon only opens its menu on right-click; reuse the same code path for left-click.
    void ShowMenu()
    {
        MethodInfo show = typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic);
        if (show != null) show.Invoke(_icon, null);
    }

    static void OpenFolder(string path)
    {
        Directory.CreateDirectory(path);
        Process.Start("explorer.exe", "\"" + path + "\"");
    }

    static string ReadFile(string path)
    {
        try
        {
            return File.Exists(path) ? File.ReadAllText(path).Trim() : null;
        }
        catch
        {
            return null;
        }
    }

    // Ports live at the top of crawl.ps1 ($ApiPort, $CdpPort); read them so the two never disagree.
    string ReadSetting(string name, string fallback)
    {
        string text = ReadFile(Path.Combine(_root, "crawl.ps1"));
        if (text != null)
        {
            Match m = Regex.Match(text, @"^\$" + name + @"\s*=\s*(\d+)", RegexOptions.Multiline);
            if (m.Success) return m.Groups[1].Value;
        }
        return fallback;
    }

    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr handle);

    static Icon MakeIcon(Color fill)
    {
        Size size = SystemInformation.SmallIconSize;
        using (Bitmap bmp = new Bitmap(size.Width, size.Height))
        {
            using (Graphics g = Graphics.FromImage(bmp))
            {
                GlobeArt.Draw(g, size.Width, fill);
            }
            IntPtr handle = bmp.GetHicon();
            Icon icon = (Icon)Icon.FromHandle(handle).Clone();
            DestroyIcon(handle);
            return icon;
        }
    }
}
