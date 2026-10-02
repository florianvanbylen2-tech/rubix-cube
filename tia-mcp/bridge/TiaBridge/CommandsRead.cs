using System;
using System.IO;
using System.Linq;
using System.Text;
using Newtonsoft.Json.Linq;
using Siemens.Engineering.SW;
using Siemens.Engineering.SW.Tags;
using Siemens.Engineering.SW.Types;

namespace TiaBridge
{
    internal static partial class Commands
    {
        private static PlcSoftware PlcOf(JObject a)
        {
            return TiaSession.Plc(TiaSession.Project(Pid(a)), Str(a, "plcName"));
        }

        // ---------- tag tables ----------
        private static JToken ListTagTables(JObject a)
        {
            var plc = PlcOf(a);
            var rows = new JArray();
            WalkTables(plc.TagTableGroup, "", rows);
            return new JObject { ["plc"] = plc.Name, ["tagTables"] = rows };
        }

        private static void WalkTables(PlcTagTableGroup g, string path, JArray rows)
        {
            foreach (var t in g.TagTables)
                rows.Add(new JObject { ["name"] = t.Name, ["group"] = path, ["tagCount"] = t.Tags.Count });
            foreach (var sub in g.Groups)
                WalkTables(sub, path.Length == 0 ? sub.Name : path + "/" + sub.Name, rows);
        }

        private static PlcTagTable FindTable(PlcTagTableGroup g, string name)
        {
            var hit = g.TagTables.FirstOrDefault(t => string.Equals(t.Name, name, StringComparison.OrdinalIgnoreCase));
            if (hit != null) return hit;
            foreach (var sub in g.Groups)
            {
                hit = FindTable(sub, name);
                if (hit != null) return hit;
            }
            return null;
        }

        private static string CommentOf(PlcTag tag)
        {
            try
            {
                var item = tag.Comment.Items.FirstOrDefault(i => !string.IsNullOrEmpty(i.Text));
                return item != null ? item.Text : "";
            }
            catch { return ""; }
        }

        private static JToken ReadTagTable(JObject a)
        {
            var name = Str(a, "name");
            if (string.IsNullOrEmpty(name)) throw new ArgumentException("name is verplicht.");
            var plc = PlcOf(a);
            var table = FindTable(plc.TagTableGroup, name);
            if (table == null) throw new InvalidOperationException("Tag table '" + name + "' niet gevonden.");
            var tags = new JArray();
            foreach (var t in table.Tags)
                tags.Add(new JObject
                {
                    ["name"] = t.Name,
                    ["dataType"] = t.DataTypeName,
                    ["address"] = t.LogicalAddress,
                    ["comment"] = CommentOf(t)
                });
            return new JObject { ["table"] = table.Name, ["count"] = tags.Count, ["tags"] = tags };
        }

        // ---------- types (UDT) ----------
        private static JToken ListTypes(JObject a)
        {
            var plc = PlcOf(a);
            var rows = new JArray();
            WalkTypes(plc.TypeGroup, "", rows);
            return new JObject { ["plc"] = plc.Name, ["types"] = rows };
        }

        private static void WalkTypes(PlcTypeGroup g, string path, JArray rows)
        {
            foreach (var t in g.Types)
            {
                var o = new JObject { ["name"] = t.Name, ["group"] = path };
                try { o["isConsistent"] = t.IsConsistent; } catch { }
                rows.Add(o);
            }
            foreach (var sub in g.Groups)
                WalkTypes(sub, path.Length == 0 ? sub.Name : path + "/" + sub.Name, rows);
        }

        private static PlcType FindType(PlcTypeGroup g, string name)
        {
            var hit = g.Types.FirstOrDefault(t => string.Equals(t.Name, name, StringComparison.OrdinalIgnoreCase));
            if (hit != null) return hit;
            foreach (var sub in g.Groups)
            {
                hit = FindType(sub, name);
                if (hit != null) return hit;
            }
            return null;
        }

        private static JToken ReadType(JObject a)
        {
            var name = Str(a, "name");
            if (string.IsNullOrEmpty(name)) throw new ArgumentException("name is verplicht.");
            var plc = PlcOf(a);
            var type = FindType(plc.TypeGroup, name);
            if (type == null) throw new InvalidOperationException("Type '" + name + "' niet gevonden.");
            var dir = NewTempDir();
            try
            {
                var file = new FileInfo(Path.Combine(dir, "type.xml"));
                type.Export(file, Siemens.Engineering.ExportOptions.WithDefaults);
                return new JObject { ["name"] = type.Name, ["xml"] = File.ReadAllText(file.FullName, Encoding.UTF8) };
            }
            finally { DeleteDir(dir); }
        }

        // ---------- helpers ----------
        internal static string NewTempDir()
        {
            var dir = Path.Combine(Path.GetTempPath(), "tia-mcp-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            return dir;
        }

        internal static void DeleteDir(string dir)
        {
            try { Directory.Delete(dir, true); } catch { }
        }
    }
}
