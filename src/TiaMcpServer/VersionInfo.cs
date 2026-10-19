using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;

namespace TiaMcpServer
{
    public class GitVersionStatus
    {
        public string? BuiltCommit { get; set; }
        public string? BuiltCommitShort { get; set; }
        public string? BuiltBranch { get; set; }
        public string? BuiltCommitDate { get; set; }
        public bool BuiltDirty { get; set; }
        public string? CurrentSourceCommit { get; set; }
        public bool? CurrentSourceDirty { get; set; }
        public bool? BuiltMatchesCurrentSource { get; set; }
        public string? RemoteMainCommit { get; set; }
        public bool? CurrentSourceMatchesRemote { get; set; }
        public string? RemoteCheckError { get; set; }
        public string? RepoRoot { get; set; }
    }

    // Answers "what commit is this running exe actually built from, and is that stale" -
    // independent of BuildInfo.g.cs alone, since a stale build can leave the exe silently out of
    // date with no way to tell from outside it (see CHANGES.md 2026-10-09). BuiltCommit/Branch/
    // CommitDate/Dirty come from BuildInfo.g.cs (baked in at compile time, zero runtime cost).
    // Everything else is a live, on-demand git check - never run automatically, only when this
    // tool is called - and is fully independent of the process's current working directory
    // (the repo root is located by walking up from the exe's own directory, and every git call
    // is pinned to that root via "-C") since the host that launches this server does not
    // necessarily control that (confirmed: Claude Desktop runs it from C:\WINDOWS\System32).
    public static class VersionInfo
    {
        public static GitVersionStatus Get(bool checkRemote = true)
        {
            var result = new GitVersionStatus
            {
                BuiltCommit = BuildInfo.GitCommit,
                BuiltCommitShort = BuildInfo.GitCommit.Length >= 7 ? BuildInfo.GitCommit.Substring(0, 7) : BuildInfo.GitCommit,
                BuiltBranch = BuildInfo.GitBranch,
                BuiltDirty = BuildInfo.GitDirty
            };

            var repoRoot = FindRepoRoot();
            result.RepoRoot = repoRoot;
            if (repoRoot == null)
            {
                result.RemoteCheckError = "Could not locate a .git repository root by walking up from the running exe's directory.";
                return result;
            }

            if (!string.IsNullOrEmpty(result.BuiltCommit) && result.BuiltCommit != "unknown")
            {
                result.BuiltCommitDate = RunGit(repoRoot, $"log -1 --format=%cI {result.BuiltCommit}")?.Trim();
            }

            result.CurrentSourceCommit = RunGit(repoRoot, "rev-parse HEAD")?.Trim();
            var statusOutput = RunGit(repoRoot, "status --porcelain");
            result.CurrentSourceDirty = statusOutput != null ? !string.IsNullOrWhiteSpace(statusOutput) : (bool?)null;

            if (!string.IsNullOrEmpty(result.BuiltCommit) && !string.IsNullOrEmpty(result.CurrentSourceCommit))
            {
                result.BuiltMatchesCurrentSource = string.Equals(result.BuiltCommit, result.CurrentSourceCommit, StringComparison.OrdinalIgnoreCase);
            }

            if (checkRemote)
            {
                try
                {
                    var lsRemote = RunGit(repoRoot, "ls-remote origin refs/heads/main", timeoutMs: 10000);
                    if (!string.IsNullOrWhiteSpace(lsRemote))
                    {
                        var remoteCommit = lsRemote.Split(new[] { '\t', ' ' }, StringSplitOptions.RemoveEmptyEntries)[0].Trim();
                        result.RemoteMainCommit = remoteCommit;
                        if (!string.IsNullOrEmpty(result.CurrentSourceCommit))
                        {
                            result.CurrentSourceMatchesRemote = string.Equals(result.CurrentSourceCommit, remoteCommit, StringComparison.OrdinalIgnoreCase);
                        }
                    }
                    else
                    {
                        result.RemoteCheckError = "'git ls-remote origin' returned nothing - no network access, or 'origin' isn't configured as expected.";
                    }
                }
                catch (Exception ex)
                {
                    result.RemoteCheckError = $"Could not reach the 'origin' remote: {ex.Message}";
                }
            }

            return result;
        }

        /// <summary>Days after which 'Connect' mentions that the running build may be outdated.</summary>
        public const int StaleBuildDays = 7;

        /// <summary>
        /// A one-sentence nudge to update when this exe was built more than StaleBuildDays ago,
        /// otherwise null. Uses the exe's file time: no git or network call, so it is free to run on
        /// every 'Connect'. People rarely update on their own, and bug reports against old builds
        /// waste everybody's time; this only informs, it never blocks.
        /// </summary>
        public static string? StaleBuildHint()
        {
            try
            {
                var exe = typeof(VersionInfo).Assembly.Location;
                if (string.IsNullOrEmpty(exe) || !File.Exists(exe))
                {
                    return null;
                }

                var built = File.GetLastWriteTime(exe);
                var days = (int)(DateTime.Now - built).TotalDays;
                if (days < StaleBuildDays)
                {
                    return null;
                }

                var commit = BuildInfo.GitCommit.Length >= 7 ? BuildInfo.GitCommit.Substring(0, 7) : BuildInfo.GitCommit;
                return $"This server build is {days} days old (built {built:yyyy-MM-dd}, commit {commit}); newer versions with fixes may exist. " +
                       "Tell the user once that they can update by closing this MCP client and running install\\install-tiaportal-mcp.ps1 again " +
                       "(or 'git pull' and rebuild), then carry on with the task.";
            }
            catch
            {
                return null;
            }
        }

        private static string? FindRepoRoot()
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            while (dir != null)
            {
                if (Directory.Exists(Path.Combine(dir.FullName, ".git")))
                {
                    return dir.FullName;
                }
                dir = dir.Parent;
            }
            return null;
        }

        // Reads stdout/stderr concurrently via ReadToEndAsync - reading only one of the two
        // synchronously (e.g. stdout.ReadToEnd() then WaitForExit()) risks a classic pipe
        // deadlock if the child fills the other stream's OS buffer while nobody is draining it;
        // confirmed live that this hung 'git ls-remote' calls indefinitely.
        private static string? RunGit(string repoRoot, string arguments, int timeoutMs = 5000)
        {
            var psi = new ProcessStartInfo
            {
                FileName = "git",
                Arguments = $"-C \"{repoRoot}\" {arguments}",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            // Never let git prompt interactively (e.g. for credentials) and hang - fail fast instead.
            psi.EnvironmentVariables["GIT_TERMINAL_PROMPT"] = "0";

            try
            {
                using var process = Process.Start(psi);
                if (process == null)
                {
                    return null;
                }

                process.StandardInput.Close();
                var stdoutTask = process.StandardOutput.ReadToEndAsync();
                var stderrTask = process.StandardError.ReadToEndAsync();
                var exited = Task.WaitAll(new Task[] { stdoutTask, stderrTask }, timeoutMs) && process.WaitForExit(timeoutMs);

                if (!exited)
                {
                    try { process.Kill(); } catch { /* best effort */ }
                    return null;
                }

                return process.ExitCode == 0 ? stdoutTask.Result : null;
            }
            catch
            {
                return null;
            }
        }
    }
}
