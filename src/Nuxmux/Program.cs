// Copyright (c) 2011-2026 Denis Kudelin
// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
// This Source Code Form is "Incompatible With Secondary Licenses", as defined by the Mozilla Public License, v. 2.0.

using System.Diagnostics;

namespace Itexoft.Nuxmux;

internal static class Program
{
    public static int Main(string[] args)
    {
        var processPath = Environment.ProcessPath;

        if (string.IsNullOrWhiteSpace(processPath))
        {
            Console.Error.WriteLine("nuxmux: unable to resolve process path");

            return 127;
        }

        var shimDir = Path.GetDirectoryName(processPath);

        if (string.IsNullOrWhiteSpace(shimDir))
        {
            Console.Error.WriteLine("nuxmux: unable to resolve shim directory");

            return 127;
        }

        var shimName = Path.GetFileName(processPath);

        if (string.IsNullOrWhiteSpace(shimName))
        {
            Console.Error.WriteLine("nuxmux: unable to resolve shim name");

            return 127;
        }

        var rootsFile = Path.Combine(shimDir, "nuxmux.config");

        if (!File.Exists(rootsFile))
        {
            Console.Error.WriteLine($"nuxmux: config file not found: {rootsFile}");

            return 127;
        }

        string[] roots;

        try
        {
            roots = File.ReadAllLines(rootsFile).Select(x => x.Trim()).Where(x => x.Length != 0).ToArray();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"nuxmux: failed to read roots file: {rootsFile}");
            Console.Error.WriteLine(ex.Message);

            return 127;
        }

        if (roots.Length == 0)
        {
            Console.Error.WriteLine($"nuxmux: no roots defined in: {rootsFile}");

            return 127;
        }

        var target = ResolveTarget(roots, shimName);

        if (target is null)
        {
            Console.Error.WriteLine($"nuxmux: unable to resolve target for '{shimName}' from: {rootsFile}");

            return 127;
        }

        try
        {
            using var p = new Process();

            p.StartInfo = new ProcessStartInfo
            {
                FileName = target,
                UseShellExecute = false,
                WorkingDirectory = Environment.CurrentDirectory,
            };

            var rewrite = Environment.GetEnvironmentVariable("NUXMUX_ARGS_REWRITE");

            if (!string.IsNullOrWhiteSpace(rewrite))
            {
                var fileName = Path.GetFileName(target);

                if (fileName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                    fileName = fileName[..^4];

                try
                {
                    args = NuxmuxArgsRewriter.Rewrite(rewrite, fileName, args);
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"nuxmux: {ex.Message}");

                    return 127;
                }
            }

            foreach (var a in args)
                p.StartInfo.ArgumentList.Add(a);

            p.Start();
            p.WaitForExit();

            return p.ExitCode;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"nuxmux: failed to start: {target}");
            Console.Error.WriteLine(ex.Message);

            return 127;
        }
    }

    private static string? ResolveTarget(string[] roots, string shimName)
    {
        foreach (var root in roots)
        {
            if (!Path.IsPathRooted(root))
            {
                Console.Error.WriteLine($"nuxmux: root is not an absolute path: {root}");

                return null;
            }

            var candidate = Path.Combine(root, shimName);

            if (File.Exists(candidate))
                return candidate;
        }

        return null;
    }
}
