using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Text.Json;
using System.Threading.Tasks;

namespace Cleanup;

// Result of a "check for updates" call against the GitHub Releases API.
public sealed class UpdateInfo
{
    public string LatestVersion = "";   // raw tag, e.g. "v1.0.1"
    public string DownloadUrl = "";     // CleanupSetup.exe browser_download_url
    public bool UpdateAvailable;
    public string? Error;               // set when the check failed (offline / rate-limited)
}

// In-app updater: reads the running version, checks GitHub's latest release,
// downloads the installer and hands off to it silently. All transitions log to
// Log.cs (%APPDATA%\Cleanup\log.txt).
public static class Updater
{
    public const string Repo = "AbhiPoluri/cleanup-app";
    private const string LatestApi =
        "https://api.github.com/repos/AbhiPoluri/cleanup-app/releases/latest";
    private const string AssetName = "CleanupSetup.exe";
    private const long MinInstallerBytes = 10L * 1024 * 1024; // sanity floor: >10 MB

    // Version stamped by the CI publish (-p:InformationalVersion). Unstamped local
    // builds default to "1.0.0"/"1.0.0.0" — treated as a dev build.
    public static string CurrentVersion { get; } = ReadCurrentVersion();
    public static bool IsDevBuild => CurrentVersion == "dev";

    // Label for the tray tooltip / settings row.
    public static string DisplayVersion => IsDevBuild ? "dev" : "v" + CurrentVersion;

    private static string ReadCurrentVersion()
    {
        try
        {
            var info = Assembly.GetEntryAssembly()
                ?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()
                ?.InformationalVersion;
            if (string.IsNullOrWhiteSpace(info)) return "dev";
            // strip +metadata (e.g. "1.2.3+abc123")
            var plus = info.IndexOf('+');
            if (plus >= 0) info = info.Substring(0, plus);
            info = info.Trim();
            // unstamped default builds report 1.0.0 / 0.0.0-ci — not a real release
            if (info is "1.0.0" or "1.0.0.0" || info.StartsWith("0.0.0", StringComparison.Ordinal))
                return "dev";
            return info;
        }
        catch { return "dev"; }
    }

    public static async Task<UpdateInfo> CheckAsync()
    {
        var result = new UpdateInfo();
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
            // GitHub requires a User-Agent or it returns 403.
            http.DefaultRequestHeaders.UserAgent.ParseAdd("Cleanup-Updater");
            http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");

            var json = await http.GetStringAsync(LatestApi);
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            result.LatestVersion = root.TryGetProperty("tag_name", out var tag)
                ? tag.GetString() ?? "" : "";

            if (root.TryGetProperty("assets", out var assets)
                && assets.ValueKind == JsonValueKind.Array)
            {
                foreach (var a in assets.EnumerateArray())
                {
                    var name = a.TryGetProperty("name", out var n) ? n.GetString() : null;
                    if (string.Equals(name, AssetName, StringComparison.OrdinalIgnoreCase))
                    {
                        result.DownloadUrl = a.TryGetProperty("browser_download_url", out var u)
                            ? u.GetString() ?? "" : "";
                        break;
                    }
                }
            }

            result.UpdateAvailable = IsNewer(result.LatestVersion);
            Log.Write($"updater: current={CurrentVersion} latest={result.LatestVersion} " +
                      $"available={result.UpdateAvailable} asset={(result.DownloadUrl.Length > 0)}");
        }
        catch (Exception ex)
        {
            result.Error = ex.Message;
            Log.Write("updater: check failed — " + ex.Message);
        }
        return result;
    }

    // Download the installer to %TEMP%, verify a non-trivial size, then launch it
    // silently. Caller must Application.Current.Shutdown() on success so the exe
    // isn't locked (per-user install, no elevation). The installer's silent [Run]
    // entry relaunches the freshly installed app.
    public static async Task<bool> DownloadAndRunAsync(UpdateInfo info)
    {
        if (string.IsNullOrEmpty(info.DownloadUrl))
        {
            Log.Write("updater: no installer asset URL — abort");
            return false;
        }
        try
        {
            var ver = info.LatestVersion.TrimStart('v', 'V');
            var dest = Path.Combine(Path.GetTempPath(), $"CleanupSetup-v{ver}.exe");

            using (var http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) })
            {
                http.DefaultRequestHeaders.UserAgent.ParseAdd("Cleanup-Updater");
                var bytes = await http.GetByteArrayAsync(info.DownloadUrl);
                if (bytes.LongLength < MinInstallerBytes)
                {
                    Log.Write($"updater: download too small ({bytes.LongLength} bytes) — abort");
                    return false;
                }
                await File.WriteAllBytesAsync(dest, bytes);
                Log.Write($"updater: downloaded {bytes.LongLength} bytes -> {dest}");
            }

            Process.Start(new ProcessStartInfo
            {
                FileName = dest,
                // /SILENT: no wizard UI. /CLOSEAPPLICATIONS: let Restart Manager close us.
                Arguments = "/SILENT /CLOSEAPPLICATIONS",
                UseShellExecute = true,
            });
            Log.Write("updater: launched silent installer — shutting down for handoff");
            return true;
        }
        catch (Exception ex)
        {
            Log.Write("updater: download/run failed — " + ex.Message);
            return false;
        }
    }

    private static bool IsNewer(string tag)
    {
        // Dev builds can't be compared meaningfully — offer any real release for
        // manual install, but log it so it's clear this isn't an auto-upgrade.
        if (IsDevBuild)
        {
            Log.Write("updater: dev build — offering latest release for manual install");
            return TryParseVersion(tag, out _);
        }
        if (!TryParseVersion(tag, out var latest)) return false;
        if (!TryParseVersion(CurrentVersion, out var current)) return false;
        return latest > current;
    }

    // Parse the numeric part of a semver-ish string ("v1.2.3", "1.2.3-rc1").
    private static bool TryParseVersion(string s, out Version version)
    {
        version = new Version(0, 0);
        if (string.IsNullOrWhiteSpace(s)) return false;
        s = s.TrimStart('v', 'V');
        int i = 0;
        while (i < s.Length && (char.IsDigit(s[i]) || s[i] == '.')) i++;
        s = s.Substring(0, i);
        if (Version.TryParse(s, out var parsed))
        {
            version = parsed;
            return true;
        }
        return false;
    }
}
