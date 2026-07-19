using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Cleanup;

// One isolated project workspace: Documents\Cleanup\projects\<slug>\
//
// Each project owns its OWN working directory, so the agent's cwd = the project dir.
// That single fact buys per-project isolation for free: Claude Code keys its own
// auto-memory + conversation history to the cwd path, so every project gets a private
// long-term memory and a private resumable conversation, and nothing from one project's
// dir is ever visible in another's session.
//
// On disk each project holds: generated CLAUDE.md + AGENTS.md (agent instructions),
// a reserved sessions\ dir (whiteboard summary export, future), and project.json below.
public sealed class Project
{
    // Directory name — never serialized into project.json (it IS the key). Set from the
    // folder name on load.
    [JsonIgnore] public string Slug { get; set; } = "default";

    public string Name { get; set; } = "Default";
    public string Brief { get; set; } = "";
    // Codex session/thread id captured from `codex exec --json` on the first turn, so
    // follow-ups (including across app restarts) can `codex exec resume <id>` this
    // project's own conversation. Null until captured.
    public string? CodexSessionId { get; set; }
    // True once this project has had a CLI turn this or a prior session. Drives per-project
    // resume: claude --continue / codex resume are passed only when this is set. Cleared by
    // the "⊕ new session" affordance to start a fresh conversation in the project.
    public bool HasSession { get; set; }

    [JsonIgnore] public string Dir => Path.Combine(ProjectStore.ProjectsRoot, Slug);
    [JsonIgnore] public string SessionsDir => Path.Combine(Dir, "sessions");
    [JsonIgnore] public string JsonPath => Path.Combine(Dir, "project.json");
}

// Registry + lifecycle for project workspaces. Enumerates projects\, tracks the current
// one (Settings.CurrentProject), migrates the legacy single agent\ dir into projects\default
// on first run, and (re)generates the per-project CLAUDE.md / AGENTS.md.
public static class ProjectStore
{
    public static string ProjectsRoot =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Cleanup", "projects");

    // Pre-projects single workdir; its role is migrated into projects\default on first run.
    private static string LegacyAgentDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Cleanup", "agent");

    private static readonly JsonSerializerOptions JsonOpts = new() { WriteIndented = true };

    // lowercase-kebab: alnum runs kept, everything else collapses to a single '-'.
    public static string Slugify(string name)
    {
        var sb = new StringBuilder();
        bool lastDash = false;
        foreach (var ch in (name ?? "").Trim().ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(ch)) { sb.Append(ch); lastDash = false; }
            else if (!lastDash && sb.Length > 0) { sb.Append('-'); lastDash = true; }
        }
        var s = sb.ToString().Trim('-');
        return s.Length == 0 ? "project" : s;
    }

    // ---- bootstrap / migration ----

    // Called once at app start: migrate legacy agent\ → projects\default (if needed),
    // guarantee a "Default" project exists, then regenerate every project's instruction
    // files from the (possibly changed) global personal context.
    public static void Bootstrap()
    {
        try { EnsureDefault(); RegenerateAll(); }
        catch (Exception ex) { Log.Write("projects: bootstrap failed — " + ex.Message); }
    }

    // Guarantee projects\default exists. First run migrates the legacy agent\ dir's role
    // (its files + Claude's per-cwd memory) into it; the old dir is left in place, unused.
    public static Project EnsureDefault()
    {
        Directory.CreateDirectory(ProjectsRoot);
        var defDir = Path.Combine(ProjectsRoot, "default");
        var p = new Project { Slug = "default", Name = "Default" };
        if (!Directory.Exists(defDir))
        {
            Directory.CreateDirectory(defDir);
            Directory.CreateDirectory(Path.Combine(defDir, "sessions"));
            if (Directory.Exists(LegacyAgentDir))
            {
                try { CopyDirInto(LegacyAgentDir, defDir); Log.Write("projects: migrated legacy agent\\ → projects\\default"); }
                catch (Exception ex) { Log.Write("projects: legacy migration failed — " + ex.Message); }
            }
            Save(p);
        }
        else p = Load("default") ?? p;
        return p;
    }

    private static void CopyDirInto(string src, string dst)
    {
        Directory.CreateDirectory(dst);
        foreach (var f in Directory.GetFiles(src))
        {
            var target = Path.Combine(dst, Path.GetFileName(f));
            if (!File.Exists(target)) File.Copy(f, target);
        }
        foreach (var d in Directory.GetDirectories(src))
            CopyDirInto(d, Path.Combine(dst, Path.GetFileName(d)));
    }

    // ---- enumeration / lookup ----

    public static List<Project> List()
    {
        var result = new List<Project>();
        try
        {
            Directory.CreateDirectory(ProjectsRoot);
            foreach (var dir in Directory.GetDirectories(ProjectsRoot).OrderBy(d => d))
            {
                var slug = Path.GetFileName(dir);
                var p = Load(slug) ?? new Project { Slug = slug, Name = slug };
                result.Add(p);
            }
        }
        catch (Exception ex) { Log.Write("projects: list failed — " + ex.Message); }
        if (result.Count == 0) result.Add(EnsureDefault());
        // Default always first, then the rest as enumerated.
        return result.OrderByDescending(p => p.Slug == "default").ToList();
    }

    public static Project? Find(string slug) => Load(slug);

    private static Project? Load(string slug)
    {
        try
        {
            var path = Path.Combine(ProjectsRoot, slug, "project.json");
            if (!File.Exists(path)) return null;
            var p = JsonSerializer.Deserialize<Project>(File.ReadAllText(path));
            if (p == null) return null;
            p.Slug = slug;   // authoritative — the folder name IS the slug
            return p;
        }
        catch { return null; }
    }

    // The current project (Settings.CurrentProject), falling back to Default.
    public static Project Current()
    {
        var slug = Settings.Current.CurrentProject;
        return Find(slug) ?? EnsureDefault();
    }

    public static void SetCurrent(string slug)
    {
        Settings.Current.CurrentProject = slug;
        Settings.Current.Save();
    }

    // ---- create / persist ----

    // Create a new project (unique slug), write its dir + files, and return it.
    public static Project Create(string name, string brief)
    {
        Directory.CreateDirectory(ProjectsRoot);
        var display = string.IsNullOrWhiteSpace(name) ? "Untitled" : name.Trim();
        var baseSlug = Slugify(display);
        var slug = baseSlug;
        int n = 2;
        while (Directory.Exists(Path.Combine(ProjectsRoot, slug))) slug = baseSlug + "-" + n++;
        var p = new Project { Slug = slug, Name = display, Brief = (brief ?? "").Trim() };
        Directory.CreateDirectory(p.Dir);
        Directory.CreateDirectory(p.SessionsDir);
        Save(p);
        WriteInstructionFiles(p);
        Log.Write($"projects: created {slug} ({display})");
        return p;
    }

    public static void Save(Project p)
    {
        try
        {
            Directory.CreateDirectory(p.Dir);
            var tmp = p.JsonPath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(p, JsonOpts));
            File.Move(tmp, p.JsonPath, overwrite: true);
        }
        catch (Exception ex) { Log.Write($"projects: save {p.Slug} failed — " + ex.Message); }
    }

    // Create the project dir (+ sessions\) on demand; used as the CLI cwd. Falls back to
    // the user profile so an agent run never dies over a missing dir.
    public static string EnsureDir(Project p)
    {
        try
        {
            Directory.CreateDirectory(p.Dir);
            Directory.CreateDirectory(p.SessionsDir);
            return p.Dir;
        }
        catch (Exception ex)
        {
            Log.Write("projects: ensure dir failed — " + ex.Message);
            return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        }
    }

    // ---- instruction files ----

    private static string BuildInstructions(Project p)
    {
        var sb = new StringBuilder();
        sb.Append("# Cleanup Agent — ").Append(p.Name).Append('\n');
        sb.Append("You are the agent inside the Cleanup app, working in the project \"")
          .Append(p.Name).Append("\". Session summaries may live in ./sessions/.");
        var brief = (p.Brief ?? "").Trim();
        if (brief.Length > 0) sb.Append("\n\n## Project\n").Append(brief);
        var ctx = (Settings.Current.AgentContext ?? "").Trim();   // personal context is GLOBAL — every project gets it
        if (ctx.Length > 0) sb.Append("\n\n## About the user\n").Append(ctx);
        sb.Append('\n');
        return sb.ToString();
    }

    // Write CLAUDE.md + AGENTS.md (identical) into the project — both Claude Code and Codex
    // auto-load these. Atomic (temp + move) and only when the content actually changed.
    public static void WriteInstructionFiles(Project p)
    {
        try
        {
            EnsureDir(p);
            var body = BuildInstructions(p);
            WriteIfChanged(Path.Combine(p.Dir, "CLAUDE.md"), body);
            WriteIfChanged(Path.Combine(p.Dir, "AGENTS.md"), body);
        }
        catch (Exception ex) { Log.Write($"projects: write instructions {p.Slug} failed — " + ex.Message); }
    }

    // Regenerate every project's instruction files (on personal-context save + app start).
    public static void RegenerateAll()
    {
        foreach (var p in List()) WriteInstructionFiles(p);
    }

    private static void WriteIfChanged(string path, string content)
    {
        try
        {
            if (File.Exists(path) && File.ReadAllText(path) == content) return;
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, content);
            File.Move(tmp, path, overwrite: true);
        }
        catch (Exception ex) { Log.Write($"projects: write {Path.GetFileName(path)} failed — " + ex.Message); }
    }
}
