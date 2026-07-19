namespace Cleanup;

// Compatibility shim. The single shared workdir this class used to own has been replaced
// by per-project workspaces (see Project.cs / ProjectStore) — each project is its own
// app-owned dir with its own generated CLAUDE.md / AGENTS.md, isolated from the user's
// real home ($HOME would make Claude auto-load the user's personal ~/CLAUDE.md + global
// memory into every run). These wrappers delegate to ProjectStore so existing call sites
// keep working.
public static class AgentWorkspace
{
    // App start: migrate the legacy agent\ dir, ensure Default, regenerate all instruction files.
    public static void WriteInstructionFiles() => ProjectStore.Bootstrap();

    // The current project's working directory (created on demand).
    public static string Ensure() => ProjectStore.EnsureDir(ProjectStore.Current());
}
