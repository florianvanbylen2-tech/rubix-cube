using System;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text;
using Newtonsoft.Json.Linq;

namespace TiaBridge
{
    /// <summary>
    /// Protocol: één JSON-object per regel op stdin: {"id":1,"cmd":"list_blocks","args":{...}}
    /// Antwoord op stdout, één regel:                {"id":1,"ok":true,"result":...} of {"id":1,"ok":false,"error":"..."}
    /// Alles wat geen protocol is (logging) gaat naar stderr.
    /// </summary>
    internal static class Program
    {
        private static int Main(string[] argv)
        {
            Resolver.Install();                 // eerst de resolver, dan pas Openness-types aanraken
            if (argv.Length > 0 && argv[0].StartsWith("--")) return Cli(argv);
            var protocolOut = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true };
            Console.SetOut(Console.Error);      // verdwaalde Console.WriteLine's mogen het protocol niet vervuilen
            var stdin = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false));
            return Loop(stdin, protocolOut);
        }

        /// <summary>Handmatig gebruik zonder MCP: TiaBridge.exe --list | --export NAAM [uitvoer.xml] [PLCNAAM]</summary>
        [MethodImpl(MethodImplOptions.NoInlining)]
        private static int Cli(string[] argv)
        {
            try
            {
                if (argv[0] == "--list")
                {
                    Console.Error.WriteLine(Commands.Dispatch("list_blocks", new JObject()).ToString());
                    return 0;
                }
                if (argv[0] == "--export" && argv.Length >= 2)
                {
                    var args = new JObject { ["name"] = argv[1], ["maxChars"] = int.MaxValue };
                    if (argv.Length >= 4) args["plcName"] = argv[3];
                    var res = (JObject)Commands.Dispatch("read_block", args);
                    var file = argv.Length >= 3 ? argv[2] : argv[1].Replace('/', '_') + ".xml";
                    File.WriteAllText(file, (string)res["xml"], new UTF8Encoding(false));
                    Console.Error.WriteLine("Geschreven: " + Path.GetFullPath(file));
                    return 0;
                }
                Console.Error.WriteLine("Gebruik: TiaBridge.exe --list | --export BLOKNAAM [uitvoer.xml] [PLCNAAM]");
                return 2;
            }
            catch (Exception ex) { Console.Error.WriteLine("FOUT: " + Commands.Describe(ex)); return 1; }
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private static int Loop(TextReader stdin, TextWriter stdout)
        {
            string line;
            while ((line = stdin.ReadLine()) != null)
            {
                if (line.Trim().Length == 0) continue;
                JToken id = null;
                JObject reply;
                try
                {
                    var req = JObject.Parse(line);
                    id = req["id"];
                    var cmd = (string)req["cmd"];
                    var args = req["args"] as JObject ?? new JObject();
                    var result = Commands.Dispatch(cmd, args);
                    reply = new JObject { ["id"] = id, ["ok"] = true, ["result"] = result };
                }
                catch (Exception ex)
                {
                    reply = new JObject { ["id"] = id, ["ok"] = false, ["error"] = Commands.Describe(ex) };
                }
                stdout.WriteLine(reply.ToString(Newtonsoft.Json.Formatting.None));
            }
            return 0;
        }
    }
}
