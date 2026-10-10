using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

// Client-facing, single-file launcher. The Flutter runtime is an embedded ZIP
// resource and is unpacked only into the user's LocalAppData at launch; the
// customer never needs to open or extract an archive manually.
internal static class AvtarPosSelfInstaller
{
    private const string PayloadResource = "AvtarPOS.Payload";
    private const string ProductName = "AvtarPOS Client";
    private const string RuntimeExe = "AvtarPOS.exe";
    // Replaced in a temporary source copy by tools/release/build_local.ps1.
    private const string ProductVersion = "0.0.0";
    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\AvtarPOSClient";

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length == 1 && string.Equals(args[0], "/uninstall", StringComparison.OrdinalIgnoreCase))
            return Uninstall();

        var updateProcessId = 0;
        if (args.Length == 2 && string.Equals(args[0], "/update", StringComparison.OrdinalIgnoreCase))
            int.TryParse(args[1], out updateProcessId);

        var installRoot = InstallRoot();
        var staging = Path.Combine(Path.GetTempPath(), "AvtarPOS-" + Guid.NewGuid().ToString("N"));

        try
        {
            Directory.CreateDirectory(staging);
            ExtractPayload(staging);
            WaitForUpdateProcess(updateProcessId);
            StopPreviousApp();
            CopyDirectory(staging, installRoot);
            var installedSetup = Path.Combine(installRoot, "AvtarPOS Client Setup.exe");
            File.Copy(Assembly.GetExecutingAssembly().Location, installedSetup, true);
            RegisterUninstaller(installedSetup, installRoot);
            CreateDesktopShortcut(installRoot);

            var app = Path.Combine(installRoot, RuntimeExe);
            if (!File.Exists(app)) throw new FileNotFoundException("AvtarPOS runtime was not installed.", app);
            Process.Start(new ProcessStartInfo(app) { WorkingDirectory = installRoot, UseShellExecute = true });
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show(
                "AvtarPOS could not start. Please run this file again.\r\n\r\n" + error.Message,
                "AvtarPOS setup",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
        finally
        {
            try { if (Directory.Exists(staging)) Directory.Delete(staging, true); }
            catch { /* Temporary files are safe to clean on the next launch. */ }
        }
    }

    private static string InstallRoot()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            ProductName);
    }

    private static string DataRoot()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Zelovix",
            ProductName);
    }

    private static void RegisterUninstaller(string setupPath, string installRoot)
    {
        using (var key = Registry.CurrentUser.CreateSubKey(UninstallKey))
        {
            if (key == null) return;
            key.SetValue("DisplayName", ProductName);
            key.SetValue("DisplayVersion", ProductVersion);
            key.SetValue("Publisher", "Zelovix");
            key.SetValue("DisplayIcon", setupPath);
            key.SetValue("InstallLocation", installRoot);
            key.SetValue("UninstallString", Quote(setupPath) + " /uninstall");
            key.SetValue("NoModify", 1, RegistryValueKind.DWord);
            key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        }
    }

    private static int Uninstall()
    {
        var confirm = MessageBox.Show(
            "Uninstall AvtarPOS and permanently delete all local orders, bills, settings and offline data for this Windows user?\r\n\r\nThis cannot be undone.",
            "Uninstall AvtarPOS",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning,
            MessageBoxDefaultButton.Button2);
        if (confirm != DialogResult.Yes) return 0;

        StopPreviousApp();
        try { File.Delete(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "AvtarPOS Client.lnk")); }
        catch { /* A missing shortcut is harmless. */ }
        try { Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false); }
        catch { /* Continue with application/data cleanup. */ }

        var script = Path.Combine(Path.GetTempPath(), "avtarpos-uninstall-" + Guid.NewGuid().ToString("N") + ".cmd");
        File.WriteAllText(script,
            "@echo off\r\n" +
            "ping 127.0.0.1 -n 3 >nul\r\n" +
            "rmdir /s /q " + Quote(InstallRoot()) + "\r\n" +
            "rmdir /s /q " + Quote(DataRoot()) + "\r\n" +
            "del /f /q " + Quote(script) + "\r\n");
        Process.Start(new ProcessStartInfo(script)
        {
            CreateNoWindow = true,
            UseShellExecute = false,
            WindowStyle = ProcessWindowStyle.Hidden,
        });
        return 0;
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\"\"") + "\"";
    }

    private static void ExtractPayload(string destination)
    {
        using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(PayloadResource))
        {
            if (stream == null) throw new InvalidOperationException("Embedded AvtarPOS setup files are missing.");
            using (var zip = new ZipArchive(stream, ZipArchiveMode.Read))
            {
                foreach (var entry in zip.Entries)
                {
                    var relative = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
                    var target = Path.GetFullPath(Path.Combine(destination, relative));
                    if (!target.StartsWith(Path.GetFullPath(destination), StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("Invalid embedded setup path.");
                    if (String.IsNullOrEmpty(entry.Name))
                    {
                        Directory.CreateDirectory(target);
                        continue;
                    }
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    entry.ExtractToFile(target, true);
                }
            }
        }
    }

    private static void StopPreviousApp()
    {
        foreach (var process in Process.GetProcessesByName("AvtarPOS"))
        {
            try
            {
                process.CloseMainWindow();
                process.WaitForExit(2000);
                if (!process.HasExited) process.Kill();
            }
            catch { /* A stale process must not block an update. */ }
            finally { process.Dispose(); }
        }
    }

    private static void WaitForUpdateProcess(int processId)
    {
        if (processId <= 0) return;
        try
        {
            using (var process = Process.GetProcessById(processId))
                process.WaitForExit(30000);
        }
        catch (ArgumentException) { /* The app already exited. */ }
        catch { /* StopPreviousApp still protects the install below. */ }
    }

    private static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var directory in Directory.GetDirectories(source, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(destination, directory.Substring(source.Length).TrimStart(Path.DirectorySeparatorChar)));
        foreach (var file in Directory.GetFiles(source, "*", SearchOption.AllDirectories))
        {
            var relative = file.Substring(source.Length).TrimStart(Path.DirectorySeparatorChar);
            var target = Path.Combine(destination, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(target));
            File.Copy(file, target, true);
        }
    }

    private static void CreateDesktopShortcut(string installRoot)
    {
        var desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        var shellType = Type.GetTypeFromProgID("WScript.Shell");
        if (shellType == null) return;
        dynamic shell = Activator.CreateInstance(shellType);
        dynamic shortcut = shell.CreateShortcut(Path.Combine(desktop, "AvtarPOS Client.lnk"));
        shortcut.TargetPath = Path.Combine(installRoot, RuntimeExe);
        shortcut.WorkingDirectory = installRoot;
        shortcut.IconLocation = Path.Combine(installRoot, "AvtarPOS.ico") + ",0";
        shortcut.Save();
    }
}
