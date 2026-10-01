using System;
using System.IO;
using System.Reflection;
using Microsoft.Win32;

namespace TiaBridge
{
    /// <summary>
    /// Laadt Siemens.Engineering.dll vanaf de TIA-installatie (Private=false in de csproj).
    /// Moet geregistreerd zijn VOORDAT code die Openness-types gebruikt wordt gejit.
    /// </summary>
    internal static class Resolver
    {
        // Hardcoded fallback voor V19.
        private const string FallbackDir =
            @"C:\Program Files\Siemens\Automation\Portal V19\PublicAPI\V19\net48";

        public static string ResolvedPath { get; private set; }

        public static void Install()
        {
            AppDomain.CurrentDomain.AssemblyResolve += OnResolve;
        }

        private static Assembly OnResolve(object sender, ResolveEventArgs args)
        {
            var name = new AssemblyName(args.Name).Name;
            if (!name.StartsWith("Siemens.Engineering", StringComparison.OrdinalIgnoreCase))
                return null;

            var dir = FindOpennessDir();
            var file = Path.Combine(dir, name + ".dll");
            if (!File.Exists(file)) return null;
            ResolvedPath = file;
            return Assembly.LoadFrom(file);
        }

        private static string FindOpennessDir()
        {
            // Register: HKLM\SOFTWARE\Siemens\Automation\Openness\19.0\PublicAPI\<versie>
            // De exacte waardenamen verschillen per versie; we scannen alle string-waarden
            // en nemen de eerste map die Siemens.Engineering.dll bevat.
            try
            {
                foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
                using (var hklm = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view))
                using (var root = hklm.OpenSubKey(@"SOFTWARE\Siemens\Automation\Openness\19.0\PublicAPI"))
                {
                    if (root == null) continue;
                    foreach (var sub in root.GetSubKeyNames())
                    using (var k = root.OpenSubKey(sub))
                    {
                        if (k == null) continue;
                        foreach (var v in k.GetValueNames())
                        {
                            var s = k.GetValue(v) as string;
                            if (string.IsNullOrEmpty(s)) continue;
                            var dir = File.Exists(s) ? Path.GetDirectoryName(s) : s;
                            if (Directory.Exists(dir) && File.Exists(Path.Combine(dir, "Siemens.Engineering.dll")))
                                return dir;
                        }
                    }
                }
            }
            catch { /* val terug op hardcoded pad */ }
            return FallbackDir;
        }
    }
}
