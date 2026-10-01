using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Newtonsoft.Json.Linq;
using Siemens.Engineering;
using Siemens.Engineering.Compiler;
using Siemens.Engineering.SW;
using Siemens.Engineering.SW.Blocks;
using Siemens.Engineering.SW.Tags;

namespace TiaBridge
{
    internal static partial class Commands
    {
        private static bool Flag(JObject a, string k) { var t = a[k]; return t != null && t.Type == JTokenType.Boolean && (bool)t; }

        /// <summary>Elke schrijfactie: ExclusiveAccess + Transaction (commit alleen bij succes -> één Undo in TIA).</summary>
        private static JToken Write(JObject a, string label, Func<PlcSoftware, JToken> body)
        {
            var tia = TiaSession.Tia(Pid(a));
            var project = TiaSession.Project(Pid(a));
            var plc = TiaSession.Plc(project, Str(a, "plcName"));
            using (var ea = tia.ExclusiveAccess("MCP: " + label))
            using (var tx = ea.Transaction(project, "MCP: " + label))
            {
                var result = body(plc);
                tx.CommitOnDispose();
                return result;
            }
        }

        // ---------- tag tables ----------
        private static JToken CreateTagTable(JObject a)
        {
            var name = Str(a, "name");
            if (string.IsNullOrEmpty(name)) throw new ArgumentException("name is verplicht.");
            return Write(a, "create_tag_table " + name, plc =>
            {
                var existing = FindTable(plc.TagTableGroup, name);
                if (existing != null) return new JObject { ["table"] = existing.Name, ["created"] = false };
                var t = plc.TagTableGroup.TagTables.Create(name);
                return new JObject { ["table"] = t.Name, ["created"] = true };
            });
        }

        private static JToken UpsertTags(JObject a)
        {
            var tableName = Str(a, "tableName");
            var tags = a["tags"] as JArray;
            if (string.IsNullOrEmpty(tableName) || tags == null)
                throw new ArgumentException("tableName en tags (lijst van {name, dataType, address, comment}) zijn verplicht.");
            return Write(a, "upsert_tags " + tableName, plc =>
            {
                var table = FindTable(plc.TagTableGroup, tableName);
                if (table == null) throw new InvalidOperationException("Tag table '" + tableName + "' bestaat niet; maak hem eerst aan.");
                int created = 0, updated = 0;
                foreach (var jt in tags.OfType<JObject>())
                {
                    var n = (string)jt["name"];
                    var type = (string)jt["dataType"];
                    var addr = (string)jt["address"];
                    var comment = (string)jt["comment"];
                    if (string.IsNullOrEmpty(n)) throw new ArgumentException("Tag zonder name.");
                    var tag = table.Tags.Find(n);
                    if (tag == null)
                    {
                        if (string.IsNullOrEmpty(type)) throw new ArgumentException("Nieuwe tag '" + n + "' heeft een dataType nodig.");
                        if (string.IsNullOrEmpty(addr)) { tag = table.Tags.Create(n); tag.DataTypeName = type; }
                        else tag = table.Tags.Create(n, type, addr);
                        created++;
                    }
                    else
                    {
                        if (!string.IsNullOrEmpty(type)) tag.DataTypeName = type;
                        if (!string.IsNullOrEmpty(addr)) tag.LogicalAddress = addr;
                        updated++;
                    }
                    if (comment != null)
                        foreach (var item in tag.Comment.Items) item.Text = comment;
                }
                return new JObject { ["table"] = table.Name, ["created"] = created, ["updated"] = updated };
            });
        }

        // ---------- UDT / DB vanuit SCL-bron ----------
        private static JToken CreateFromSource(JObject a, string kind)
        {
            var source = Str(a, "source");
            if (string.IsNullOrWhiteSpace(source)) throw new ArgumentException("source (SCL-brontekst) is verplicht.");
            var rx = kind == "udt" ? @"^\s*TYPE\s+(?:""([^""]+)""|(\S+))" : @"^\s*DATA_BLOCK\s+(?:""([^""]+)""|(\S+))";
            var m = Regex.Match(source, rx, RegexOptions.Multiline | RegexOptions.IgnoreCase);
            if (!m.Success) throw new ArgumentException(kind == "udt" ? "Bron moet beginnen met TYPE \"naam\" ... END_TYPE." : "Bron moet beginnen met DATA_BLOCK \"naam\" ... END_DATA_BLOCK.");
            var name = m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value;
            bool overwrite = Flag(a, "overwrite");

            return Write(a, "create_" + kind + " " + name, plc =>
            {
                bool exists = kind == "udt" ? FindType(plc.TypeGroup, name) != null : FindAnywhere(plc.BlockGroup, name) != null;
                if (exists && !overwrite)
                    throw new InvalidOperationException("'" + name + "' bestaat al. Geef overwrite: true om te overschrijven.");
                GenerateFromSource(plc, source, kind == "udt" ? ".udt" : ".db");
                return new JObject { ["name"] = name, ["kind"] = kind == "udt" ? "UDT" : "GlobalDB", ["replaced"] = exists };
            });
        }

        private static void GenerateFromSource(PlcSoftware plc, string text, string ext)
        {
            var dir = NewTempDir();
            try
            {
                var file = Path.Combine(dir, "src" + ext);
                File.WriteAllText(file, text, new UTF8Encoding(false));
                var srcName = "mcp_" + Guid.NewGuid().ToString("N").Substring(0, 8);
                var ext1 = plc.ExternalSourceGroup.ExternalSources.CreateFromFile(srcName, file);
                try { ext1.GenerateBlocksFromSource(); }
                finally { try { ext1.Delete(); } catch { } }
            }
            finally { DeleteDir(dir); }
        }

        private static JToken CreateInstanceDb(JObject a)
        {
            var name = Str(a, "name");
            var fb = Str(a, "fbName");
            if (string.IsNullOrEmpty(name) || string.IsNullOrEmpty(fb)) throw new ArgumentException("name en fbName zijn verplicht.");
            int? number = a["number"] != null && a["number"].Type != JTokenType.Null ? (int?)a["number"] : null;
            return Write(a, "create_instance_db " + name, plc =>
            {
                if (FindAnywhere(plc.BlockGroup, name) != null)
                    throw new InvalidOperationException("Blok '" + name + "' bestaat al.");
                if (FindAnywhere(plc.BlockGroup, fb) == null)
                    throw new InvalidOperationException("FB '" + fb + "' bestaat niet.");
                var db = plc.BlockGroup.Blocks.CreateInstanceDB(name, number == null, number ?? 0, fb);
                return new JObject { ["name"] = db.Name, ["number"] = db.Number, ["instanceOf"] = fb };
            });
        }

        // ---------- SimaticML import ----------
        private static PlcBlockGroup GroupAt(PlcBlockGroup root, string path)
        {
            if (string.IsNullOrEmpty(path)) return root;
            var g = root;
            foreach (var part in path.Split(new[] { '/', '\\' }, StringSplitOptions.RemoveEmptyEntries))
                g = g.Groups.FirstOrDefault(x => string.Equals(x.Name, part, StringComparison.OrdinalIgnoreCase)) ?? g.Groups.Create(part);
            return g;
        }

        private static string BlockNameInXml(XDocument doc)
        {
            var root = doc.Root.Elements().FirstOrDefault(e => e.Name.LocalName.StartsWith("SW.Blocks."));
            var n = root == null ? null : root.Element("AttributeList")?.Element("Name");
            return n == null ? null : n.Value;
        }

        private static JToken ImportBlockXml(JObject a)
        {
            var xml = Str(a, "xml");
            if (string.IsNullOrWhiteSpace(xml)) throw new ArgumentException("xml (SimaticML) is verplicht.");
            return Write(a, "import_block_xml", plc => ImportXml(plc, xml, Flag(a, "overwrite"), Str(a, "groupPath")));
        }

        private static JToken ImportXml(PlcSoftware plc, string xml, bool overwrite, string groupPath)
        {
            XDocument doc;
            try { doc = XDocument.Parse(xml); }
            catch (Exception ex) { throw new ArgumentException("Ongeldige XML: " + ex.Message); }
            var name = BlockNameInXml(doc);
            var existing = name == null ? null : FindAnywhere(plc.BlockGroup, name);
            if (existing != null && !overwrite)
                throw new InvalidOperationException("Blok '" + name + "' bestaat al. Geef overwrite: true om te overschrijven.");

            var dir = NewTempDir();
            try
            {
                var file = new FileInfo(Path.Combine(dir, "block.xml"));
                File.WriteAllText(file.FullName, xml, new UTF8Encoding(false));
                var group = GroupAt(plc.BlockGroup, groupPath);
                var imported = group.Blocks.Import(file, overwrite ? ImportOptions.Override : ImportOptions.None);
                var arr = new JArray();
                foreach (var b in imported) arr.Add(b.Name);
                return new JObject { ["imported"] = arr, ["replaced"] = existing != null };
            }
            finally { DeleteDir(dir); }
        }

        // ---------- compile ----------
        private static JToken CompilePlc(JObject a)
        {
            var plc = PlcOf(a);
            var compilable = plc.GetService<ICompilable>();
            if (compilable == null) throw new InvalidOperationException("ICompilable niet beschikbaar op deze PlcSoftware.");
            var res = compilable.Compile();
            var msgs = new JArray();
            Flatten(res.Messages, msgs);
            int max = a["maxMessages"] != null ? (int)a["maxMessages"] : 300;
            var ordered = new JArray(msgs.OrderBy(m => (string)m["severity"] == "Error" ? 0 : (string)m["severity"] == "Warning" ? 1 : 2).Take(max));
            return new JObject
            {
                ["plc"] = plc.Name,
                ["state"] = res.State.ToString(),
                ["errors"] = res.ErrorCount,
                ["warnings"] = res.WarningCount,
                ["messageCount"] = msgs.Count,
                ["messages"] = ordered
            };
        }

        private static void Flatten(CompilerResultMessageComposition list, JArray into)
        {
            foreach (var m in list)
            {
                if (!string.IsNullOrEmpty(m.Description))
                    into.Add(new JObject { ["severity"] = m.State.ToString(), ["path"] = m.Path, ["description"] = m.Description });
                Flatten(m.Messages, into);
            }
        }

        // ---------- LAD ----------
        private static JToken GetLadTemplate(JObject a)
        {
            var plc = PlcOf(a);
            var name = Str(a, "blockName");
            PlcBlock block = null;
            if (!string.IsNullOrEmpty(name)) block = FindAnywhere(plc.BlockGroup, name);
            else block = AllBlocks(plc.BlockGroup).FirstOrDefault(b => b.ProgrammingLanguage == ProgrammingLanguage.LAD);
            if (block == null)
                return new JObject
                {
                    ["found"] = false,
                    ["note"] = "Geen LAD-blok in het project. Maak in TIA een FC met één netwerk (contact -> coil) en een FB-aanroep, of gebruik build_lad_block; onderstaande XML is door onze eigen generator gemaakt en NIET tegen TIA geverifieerd.",
                    ["xml"] = LadBuilder.SampleXml()
                };
            var dir = NewTempDir();
            try
            {
                var file = new FileInfo(Path.Combine(dir, "t.xml"));
                block.Export(file, ExportOptions.WithDefaults);
                return new JObject { ["found"] = true, ["name"] = block.Name, ["type"] = KindOf(block), ["xml"] = File.ReadAllText(file.FullName, Encoding.UTF8) };
            }
            finally { DeleteDir(dir); }
        }

        private static System.Collections.Generic.IEnumerable<PlcBlock> AllBlocks(PlcBlockGroup g)
        {
            foreach (var b in g.Blocks) yield return b;
            foreach (var sub in g.Groups)
                foreach (var b in AllBlocks(sub)) yield return b;
        }

        private static JToken BuildLadBlock(JObject a)
        {
            var spec = a["spec"] as JObject;
            if (spec == null) throw new ArgumentException("spec (JSON-beschrijving van het blok) is verplicht.");
            var xml = LadBuilder.BuildBlockXml(spec);
            if (!Flag(a, "import")) return new JObject { ["xml"] = xml, ["imported"] = false };
            var res = (JObject)Write(a, "build_lad_block", plc => ImportXml(plc, xml, Flag(a, "overwrite"), Str(a, "groupPath")));
            res["imported"] = true;
            res["xml"] = xml;
            return res;
        }

        /// <summary>Exporteert een bestaand LAD-blok (bv. Main), voegt netwerken toe en importeert met Override.</summary>
        private static JToken AppendNetworks(JObject a)
        {
            var name = Str(a, "blockName");
            var nets = a["networks"] as JArray;
            if (string.IsNullOrEmpty(name) || nets == null) throw new ArgumentException("blockName en networks zijn verplicht.");
            if (!Flag(a, "overwrite"))
                throw new InvalidOperationException("append_networks vervangt het bestaande blok '" + name + "' (met extra netwerken). Geef overwrite: true.");
            return Write(a, "append_networks " + name, plc =>
            {
                var block = FindAnywhere(plc.BlockGroup, name);
                if (block == null) throw new InvalidOperationException("Blok '" + name + "' niet gevonden.");
                var dir = NewTempDir();
                try
                {
                    var file = new FileInfo(Path.Combine(dir, "b.xml"));
                    block.Export(file, ExportOptions.WithDefaults);
                    var doc = XDocument.Load(file.FullName);
                    var xml = LadBuilder.AppendNetworks(doc, nets);
                    var path = GroupPathOf(plc.BlockGroup, block);
                    return ImportXml(plc, xml, true, path);
                }
                finally { DeleteDir(dir); }
            });
        }

        private static string GroupPathOf(PlcBlockGroup root, PlcBlock block)
        {
            string Rec(PlcBlockGroup g, string path)
            {
                if (g.Blocks.Any(b => b.Name == block.Name)) return path;
                foreach (var sub in g.Groups)
                {
                    var r = Rec(sub, path.Length == 0 ? sub.Name : path + "/" + sub.Name);
                    if (r != null) return r;
                }
                return null;
            }
            return Rec(root, "") ?? "";
        }
    }
}
