using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("Avtar Cooks POS Setup")]
[assembly: AssemblyProduct("Avtar Cooks POS")]
[assembly: AssemblyCompany("Zelovix")]
// Replaced by the release script so Explorer and Control Panel show the
// customer-facing setup version too.
[assembly: AssemblyVersion("0.0.0.0")]
[assembly: AssemblyFileVersion("0.0.0.0")]

// Client-facing, single-file launcher. The Flutter runtime is an embedded ZIP
// resource and is unpacked only into the user's LocalAppData at launch; the
// customer never needs to open or extract an archive manually.
internal static class AvtarPosSelfInstaller
{
    private const string PayloadResource = "AvtarPOS.Payload";
    private const string VcRedistResource = "AvtarPOS.VCRedist";
    private const string ProductName = "Avtar Cooks POS";
    private const string RuntimeExe = "AvtarPOS.exe";
    // Replaced in a temporary source copy by tools/release/build_local.ps1.
    private const string ProductVersion = "0.0.0";
    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\AvtarCooksPOS";

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length == 1 && string.Equals(args[0], "/uninstall", StringComparison.OrdinalIgnoreCase))
            return Uninstall();

        // The running POS starts the downloaded installer with its process id,
        // then exits. Waiting here prevents DLL/file locks while preserving the
        // same install root and %APPDATA% SQLite data.
        var updateProcessId = 0;
        if (args.Length == 2 && string.Equals(args[0], "/update", StringComparison.OrdinalIgnoreCase))
            int.TryParse(args[1], out updateProcessId);

        var installRoot = InstallRoot();
        var isUpdate = updateProcessId > 0 || File.Exists(Path.Combine(installRoot, RuntimeExe));
        if (!isUpdate)
        {
            var confirm = MessageBox.Show(
                "Install Avtar Cooks POS on this computer?\r\n\r\nThe app will create a desktop shortcut and open its login screen after setup.",
                "Avtar Cooks POS setup",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Information,
                MessageBoxDefaultButton.Button1);
            if (confirm != DialogResult.Yes) return 0;
            // A copied/development build can leave only a cached login behind.
            // A genuine first setup must always open the login page, but the
            // account's SQLite order data is deliberately kept untouched.
            ClearSavedSession();
        }
        var staging = Path.Combine(Path.GetTempPath(), "AvtarPOS-" + Guid.NewGuid().ToString("N"));

        try
        {
            Directory.CreateDirectory(staging);
            ExtractPayload(staging);
            EnsureVisualCppRuntime(staging);
            WaitForUpdateProcess(updateProcessId);
            if (updateProcessId > 0)
            {
                // An automatic update must never kill another counter process
                // which may still own unsaved work or an in-flight sync.
                foreach (var process in Process.GetProcessesByName("AvtarPOS"))
                {
                    using (process)
                    {
                        if (!process.HasExited)
                            throw new InvalidOperationException("Another AvtarPOS window is still open. Close it safely, then retry the update.");
                    }
                }
            }
            else StopPreviousApp();
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
            "Avtar Cooks POS could not start. Please run this file again.\r\n\r\n" + error.Message,
            "Avtar Cooks POS setup",
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
            "com.avtarcook",
            "avtar_pos");
    }

    // Flutter's Windows shared-preferences plugin uses the runner's Company
    // and Product metadata, whereas SQLite uses the application-support path
    // above. They are intentionally kept separate and both need correct
    // lifecycle handling.
    private static string PreferencesRoot()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Zelovix",
            "AvtarPOS Client");
    }

    private static void ClearSavedSession()
    {
        try
        {
            var preferenceFiles = new[]
            {
                // Current Flutter Windows location.
                Path.Combine(PreferencesRoot(), "shared_preferences.json"),
                // Kept for a build produced with newer runner metadata.
                Path.Combine(DataRoot(), "shared_preferences.json"),
            };
            foreach (var preferences in preferenceFiles)
            {
                if (File.Exists(preferences)) File.Delete(preferences);
            }
        }
        catch
        {
            // A locked preferences file must never block installation. The
            // app still validates every saved token before opening a session.
        }
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
            "Uninstall Avtar Cooks POS and permanently delete all local orders, bills, settings and offline data for this Windows user?\r\n\r\nThis cannot be undone.",
            "Uninstall Avtar Cooks POS",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning,
            MessageBoxDefaultButton.Button2);
        if (confirm != DialogResult.Yes) return 0;

        StopPreviousApp();
        try { File.Delete(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Avtar Cooks POS.lnk")); }
        catch { /* A missing shortcut is harmless. */ }
        try { Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false); }
        catch { /* Continue with application/data cleanup. */ }

        var script = Path.Combine(Path.GetTempPath(), "avtarpos-uninstall-" + Guid.NewGuid().ToString("N") + ".cmd");
        File.WriteAllText(script,
            "@echo off\r\n" +
            "ping 127.0.0.1 -n 3 >nul\r\n" +
            "rmdir /s /q " + Quote(InstallRoot()) + "\r\n" +
            "rmdir /s /q " + Quote(DataRoot()) + "\r\n" +
            "rmdir /s /q " + Quote(PreferencesRoot()) + "\r\n" +
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

    private static bool HasVisualCppRuntime()
    {
        var system = Environment.SystemDirectory;
        return File.Exists(Path.Combine(system, "VCRUNTIME140.dll")) &&
               File.Exists(Path.Combine(system, "VCRUNTIME140_1.dll")) &&
               File.Exists(Path.Combine(system, "MSVCP140.dll"));
    }

    // Flutter's Windows runner needs the Microsoft Visual C++ 2015-2022 x64
    // runtime. Bundle the official redistributable so a fresh client PC never
    // has to find VCRUNTIME140/MSVCP140 DLL files by hand.
    private static void EnsureVisualCppRuntime(string staging)
    {
        if (HasVisualCppRuntime()) return;

        var setup = Path.Combine(staging, "vc_redist.x64.exe");
        using (var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(VcRedistResource))
        {
            if (resource == null)
                throw new InvalidOperationException("The Microsoft Visual C++ runtime setup is missing from this installer.");
            using (var output = File.Create(setup)) resource.CopyTo(output);
        }

        using (var process = Process.Start(new ProcessStartInfo(setup, "/install /quiet /norestart")
        {
            UseShellExecute = true,
            Verb = "runas",
        }))
        {
            if (process == null) throw new InvalidOperationException("Could not start the Microsoft Visual C++ runtime setup.");
            process.WaitForExit();
            if (process.ExitCode != 0 && process.ExitCode != 3010 && !HasVisualCppRuntime())
                throw new InvalidOperationException("Microsoft Visual C++ runtime setup did not finish. Please approve the Windows permission prompt and run setup again.");
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
        dynamic shortcut = shell.CreateShortcut(Path.Combine(desktop, "Avtar Cooks POS.lnk"));
        shortcut.TargetPath = Path.Combine(installRoot, RuntimeExe);
        shortcut.WorkingDirectory = installRoot;
        // The Flutter runner embeds the branded icon in the executable.  A
        // separate .ico file is not present in the unpacked runtime, so using
        // the executable here makes the desktop shortcut render reliably.
        shortcut.IconLocation = Path.Combine(installRoot, RuntimeExe) + ",0";
        shortcut.Save();
    }
}
