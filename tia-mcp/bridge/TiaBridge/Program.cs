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
            var protocolOut = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true };
            Console.SetOut(Console.Error);      // verdwaalde Console.WriteLine's mogen het protocol niet vervuilen
            var stdin = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false));
            return Loop(stdin, protocolOut);
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
