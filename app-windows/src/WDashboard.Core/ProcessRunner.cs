// Subprocess wrapper for git / chezmoi (ADR-003): no console window, UTF-8
// output, hard timeout that kills the whole process tree, and "command not
// found" kept distinct from a non-zero exit.

using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace WDashboard.Core;

public enum ProcessErrorKind { CommandNotFound, Timeout, Io }

public sealed class ProcessException(ProcessErrorKind kind, string message) : Exception(message)
{
    public ProcessErrorKind Kind { get; } = kind;
}

public sealed record ProcessResult(int ExitCode, string Stdout, string Stderr)
{
    public bool Succeeded => ExitCode == 0;
}

public static class ProcessRunner
{
    private const int ErrorFileNotFound = 2;

    /// <exception cref="ProcessException">Command missing, timed out, or failed to start.</exception>
    public static async Task<ProcessResult> RunAsync(
        string fileName,
        IEnumerable<string> args,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        var psi = new ProcessStartInfo(fileName)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var arg in args) psi.ArgumentList.Add(arg);
        // Never block on an interactive credential prompt in a hidden console.
        psi.Environment["GIT_TERMINAL_PROMPT"] = "0";

        using var process = new Process { StartInfo = psi };
        try
        {
            process.Start();
        }
        catch (Win32Exception e) when (e.NativeErrorCode == ErrorFileNotFound)
        {
            throw new ProcessException(ProcessErrorKind.CommandNotFound, "command not found");
        }
        catch (Win32Exception e)
        {
            throw new ProcessException(ProcessErrorKind.Io, $"command failed: {e.Message}");
        }
        process.StandardInput.Close();

        var stdoutTask = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
        var stderrTask = process.StandardError.ReadToEndAsync(CancellationToken.None);

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cts.CancelAfter(timeout);
        try
        {
            await process.WaitForExitAsync(cts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
                // Exited between the timeout and the kill.
            }
            cancellationToken.ThrowIfCancellationRequested();
            throw new ProcessException(ProcessErrorKind.Timeout, "command timed out");
        }

        var stdout = await stdoutTask.ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);
        return new ProcessResult(process.ExitCode, stdout, stderr);
    }
}
