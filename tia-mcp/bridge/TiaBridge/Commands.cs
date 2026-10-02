using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Text;
using Newtonsoft.Json.Linq;
using Siemens.Engineering;
using Siemens.Engineering.HW;
using Siemens.Engineering.HW.Features;
using Siemens.Engineering.SW;
using Siemens.Engineering.SW.Blocks;

namespace TiaBridge
{
    internal static partial class Commands
    {
        public static JToken Dispatch(string cmd, JObject a)
        {
            switch (cmd)
            {
                case "ping": return new JObject { ["pong"] = true };
                case "get_project_info": return GetProjectInfo(a);
                case "list_blocks": return ListBlocks(a);
                case "read_block": return ReadBlock(a);
                case "list_tag_tables": return ListTagTables(a);
                case "read_tag_table": return ReadTagTable(a);
                case "list_types": return ListTypes(a);
                case "read_type": return ReadType(a);
                case "create_tag_table": return CreateTagTable(a);
                case "upsert_tags": return UpsertTags(a);
                case "create_udt": return CreateFromSource(a, "udt");
                case "create_global_db": return CreateFromSource(a, "db");
                case "create_instance_db": return CreateInstanceDb(a);
                case "import_block_xml": return ImportBlockXml(a);
                case "compile_plc": return CompilePlc(a);
                case "get_fbd_template": return GetFbdTemplate(a);
                case "build_fbd_block": return BuildFbdBlock(a);
                case "append_networks": return AppendNetworks(a);
                default: throw new InvalidOperationException("Onbekend commando: " + cmd);
            }
        }

        private static int? Pid(JObject a) { var t = a["processId"]; return t == null || t.Type == JTokenType.Null ? (int?)null : (int)t; }
        private static string Str(JObject a, string k) { var t = a[k]; return t == null || t.Type == JTokenType.Null ? null : (string)t; }

        // ---------- get_project_info ----------
        private static JToken GetProjectInfo(JObject a)
        {
            var result = new JObject();
            result["opennessGroup"] = CheckGroup();
            result["opennessDll"] = Resolver.ResolvedPath;

            var procs = new JArray();
            foreach (var p in TiaSession.Processes())
            {
                var o = new JObject { ["processId"] = p.Id };
                try { o["mode"] = p.Mode.ToString(); } catch { }
                try { o["projectPath"] = p.ProjectPath != null ? p.ProjectPath.FullName : null; } catch { }
                procs.Add(o);
            }
            result["tiaProcesses"] = procs;

            var project = TiaSession.Project(Pid(a));
            result["projectName"] = project.Name;
            try { result["projectPath"] = project.Path != null ? project.Path.FullName : null; } catch { }

            var plcs = new JArray();
            foreach (var kv in TiaSession.PlcSoftwares(project))
            {
                var o = new JObject { ["plcName"] = kv.Value.Name, ["deviceName"] = kv.Key.Name };
                try { o["deviceType"] = kv.Key.TypeIdentifier; } catch { }
                // CPU-type: orderingnummer staat op het DeviceItem met de PlcSoftware.
                try { o["cpuTypeIdentifier"] = CpuTypeOf(kv.Key); } catch { }
                plcs.Add(o);
            }
            result["plcs"] = plcs;
            return result;
        }

        private static string CpuTypeOf(Device dev)
        {
            return FindCpuItem(dev.DeviceItems);
        }
        private static string FindCpuItem(DeviceItemComposition items)
        {
            foreach (var it in items)
            {
                var sc = it.GetService<SoftwareContainer>();
                if (sc != null && sc.Software is PlcSoftware) return it.TypeIdentifier;
                var nested = FindCpuItem(it.DeviceItems);
                if (nested != null) return nested;
            }
            return null;
        }

        private static string CheckGroup()
        {
            try
            {
                var id = WindowsIdentity.GetCurrent();
                var pr = new WindowsPrincipal(id);
                const string g = "Siemens TIA Openness";
                if (pr.IsInRole(g) || pr.IsInRole(Environment.MachineName + "\\" + g)) return "ok";
                return "NIET LID van groep '" + g + "'. Voeg jezelf toe (lusrmgr.msc) en log opnieuw in.";
            }
            catch (Exception ex) { return "kon groepslidmaatschap niet controleren: " + ex.Message; }
        }

        // ---------- list_blocks ----------
        private static JToken ListBlocks(JObject a)
        {
            var plc = TiaSession.Plc(TiaSession.Project(Pid(a)), Str(a, "plcName"));
            var rows = new JArray();
            Walk(plc.BlockGroup, "", rows);
            return new JObject { ["plc"] = plc.Name, ["count"] = rows.Count, ["blocks"] = rows };
        }

        private static void Walk(PlcBlockGroup group, string path, JArray rows)
        {
            foreach (var b in group.Blocks)
            {
                var o = new JObject { ["name"] = b.Name, ["group"] = path, ["type"] = KindOf(b) };
                try { o["number"] = b.Number; } catch { }
                try { o["language"] = b.ProgrammingLanguage.ToString(); } catch { }
                try { o["consistent"] = b.IsConsistent; } catch { }
                rows.Add(o);
            }
            foreach (var g in group.Groups)
                Walk(g, path.Length == 0 ? g.Name : path + "/" + g.Name, rows);
        }

        private static string KindOf(PlcBlock b)
        {
            if (b is OB) return "OB";
            if (b is FB) return "FB";
            if (b is FC) return "FC";
            return b.GetType().Name; // GlobalDB, InstanceDB, ArrayDB, ...
        }

        // ---------- read_block ----------
        private static JToken ReadBlock(JObject a)
        {
            var name = Str(a, "name");
            if (string.IsNullOrEmpty(name)) throw new ArgumentException("name is verplicht (bv. 'Main' of 'Groep/Sub/FB_Motor').");
            var plc = TiaSession.Plc(TiaSession.Project(Pid(a)), Str(a, "plcName"));
            var block = FindBlock(plc.BlockGroup, name);
            if (block == null) throw new InvalidOperationException("Blok '" + name + "' niet gevonden.");

            var dir = Path.Combine(Path.GetTempPath(), "tia-mcp-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            try
            {
                var file = new FileInfo(Path.Combine(dir, "block.xml"));
                block.Export(file, ExportOptions.WithDefaults);
                var xml = File.ReadAllText(file.FullName, Encoding.UTF8);
                int max = a["maxChars"] != null ? (int)a["maxChars"] : 400000;
                bool trunc = xml.Length > max;
                return new JObject
                {
                    ["name"] = block.Name,
                    ["type"] = KindOf(block),
                    ["xmlLength"] = xml.Length,
                    ["truncated"] = trunc,
                    ["xml"] = trunc ? xml.Substring(0, max) : xml
                };
            }
            finally { try { Directory.Delete(dir, true); } catch { } }
        }

        /// <summary>Zoekt op naam of op pad 'Groep/Sub/Naam' (hoofdletterongevoelig).</summary>
        private static PlcBlock FindBlock(PlcBlockGroup root, string path)
        {
            var parts = path.Split(new[] { '/', '\\' }, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length > 1)
            {
                var g = root;
                for (int i = 0; i < parts.Length - 1; i++)
                {
                    g = g.Groups.FirstOrDefault(x => string.Equals(x.Name, parts[i], StringComparison.OrdinalIgnoreCase));
                    if (g == null) return null;
                }
                return g.Blocks.FirstOrDefault(x => string.Equals(x.Name, parts[parts.Length - 1], StringComparison.OrdinalIgnoreCase));
            }
            return FindAnywhere(root, parts[0]);
        }

        private static PlcBlock FindAnywhere(PlcBlockGroup g, string name)
        {
            var hit = g.Blocks.FirstOrDefault(x => string.Equals(x.Name, name, StringComparison.OrdinalIgnoreCase));
            if (hit != null) return hit;
            foreach (var sub in g.Groups)
            {
                hit = FindAnywhere(sub, name);
                if (hit != null) return hit;
            }
            return null;
        }

        // ---------- foutmeldingen ----------
        public static string Describe(Exception ex)
        {
            var sb = new StringBuilder();
            for (var e = ex; e != null; e = e.InnerException)
            {
                if (sb.Length > 0) sb.Append(" | ");
                sb.Append(e.GetType().Name).Append(": ").Append(e.Message);
            }
            return sb.ToString();
        }
    }
}
