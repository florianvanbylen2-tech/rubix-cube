using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Newtonsoft.Json.Linq;

namespace TiaBridge
{
    /// <summary>
    /// Zet een JSON-beschrijving van LAD-netwerken om naar SimaticML (FlgNet).
    /// Namespaces/vormen zijn gebaseerd op V17+-exports en NIET tegen V19 geverifieerd:
    /// vergelijk de uitvoer met get_lad_template en pas de constanten hieronder aan als TIA de import weigert.
    /// </summary>
    internal sealed class LadBuilder
    {
        private static readonly XNamespace Flg = "http://www.siemens.com/automation/Openness/SW/NetworkSource/FlgNet/v4";
        private static readonly XNamespace Itf = "http://www.siemens.com/automation/Openness/SW/Interface/v5";
        private const string EngineeringVersion = "V19";

        private int _id;
        private readonly string _culture;
        private LadBuilder(int startId, string culture) { _id = startId; _culture = culture; }
        private string NextId() { return (++_id).ToString("X", CultureInfo.InvariantCulture); }

        // ===== publieke API =====
        public static string BuildBlockXml(JObject spec)
        {
            var b = new LadBuilder(0, (string)spec["culture"] ?? "en-US");
            return b.Block(spec).ToString();
        }

        /// <summary>Voegt netwerken toe aan een geëxporteerd blok; geeft de nieuwe XML terug.</summary>
        public static string AppendNetworks(XDocument doc, JArray networks)
        {
            var root = doc.Root.Elements().FirstOrDefault(e => e.Name.LocalName.StartsWith("SW.Blocks."));
            if (root == null) throw new InvalidOperationException("Geen SW.Blocks.* element in export.");
            var lang = root.Element("AttributeList")?.Element("ProgrammingLanguage")?.Value;
            if (lang != null && lang != "LAD" && lang != "FBD")
                throw new InvalidOperationException("Blok is " + lang + "; netwerken toevoegen kan alleen bij LAD/FBD.");
            var objectList = root.Element("ObjectList");
            if (objectList == null) { objectList = new XElement("ObjectList"); root.Add(objectList); }

            int max = 0;
            foreach (var at in doc.Descendants().Attributes("ID"))
            {
                int v;
                if (int.TryParse(at.Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out v) && v > max) max = v;
            }
            var b = new LadBuilder(max, "en-US");
            foreach (var n in networks.OfType<JObject>()) objectList.Add(b.CompileUnit(n));
            return doc.ToString();
        }

        public static string SampleXml()
        {
            var spec = JObject.Parse(@"{
              'type':'FC','name':'FC_Sample','number':900,
              'interface':{'Input':[{'name':'Start','type':'Bool'}],'Output':[{'name':'Run','type':'Bool'}]},
              'networks':[{'title':'Start -> Run','logic':[{'type':'contact','kind':'NO','operand':'#Start'},{'type':'coil','operand':'#Run'}]}]}");
            return BuildBlockXml(spec);
        }

        // ===== blok =====
        private XElement Block(JObject spec)
        {
            var type = ((string)spec["type"] ?? "FC").ToUpperInvariant();
            if (type != "FC" && type != "FB" && type != "OB") throw new ArgumentException("type moet FC, FB of OB zijn.");
            var name = (string)spec["name"];
            if (string.IsNullOrEmpty(name)) throw new ArgumentException("spec.name ontbreekt.");
            var lang = (string)spec["language"] ?? "LAD";
            if (lang != "LAD") throw new ArgumentException("Alleen LAD wordt door de generator ondersteund (FBD: schrijf XML met get_lad_template).");

            var attrs = new XElement("AttributeList", Interface(type, spec["interface"] as JObject), new XElement("Name", name));
            if (spec["number"] != null) attrs.Add(new XElement("Number", (int)spec["number"]));
            attrs.Add(new XElement("ProgrammingLanguage", lang));

            var objects = new XElement("ObjectList");
            foreach (var n in (spec["networks"] as JArray ?? new JArray()).OfType<JObject>())
                objects.Add(CompileUnit(n));

            return new XElement("Document",
                new XElement("Engineering", new XAttribute("version", EngineeringVersion)),
                new XElement("SW.Blocks." + type, new XAttribute("ID", "0"), attrs, objects));
        }

        private static XElement Interface(string type, JObject itf)
        {
            var sections = type == "FC" ? new[] { "Input", "Output", "InOut", "Temp", "Constant", "Return" }
                         : type == "FB" ? new[] { "Input", "Output", "InOut", "Static", "Temp", "Constant" }
                         : new[] { "Input", "Temp", "Constant" };
            var sec = new XElement(Itf + "Sections");
            foreach (var s in sections)
            {
                var section = new XElement(Itf + "Section", new XAttribute("Name", s));
                var members = itf == null ? null : itf[s] as JArray;
                if (s == "Return" && (members == null || members.Count == 0))
                    section.Add(new XElement(Itf + "Member", new XAttribute("Name", "Ret_Val"), new XAttribute("Datatype", "Void")));
                if (members != null)
                    foreach (var m in members.OfType<JObject>())
                    {
                        var mem = new XElement(Itf + "Member", new XAttribute("Name", (string)m["name"]), new XAttribute("Datatype", (string)m["type"] ?? "Bool"));
                        if (m["start"] != null) mem.Add(new XElement(Itf + "StartValue", (string)m["start"]));
                        section.Add(mem);
                    }
                sec.Add(section);
            }
            return new XElement("Interface", sec);
        }

        // ===== netwerk =====
        private sealed class Net
        {
            public int Uid = 20;
            public readonly List<XElement> Parts = new List<XElement>();
            public readonly List<XElement> Wires = new List<XElement>();
            public int New() { return ++Uid; }
        }

        private struct Src { public bool Rail; public int Uid; public string Pin; }

        private XElement CompileUnit(JObject net)
        {
            var n = new Net();
            var src = new Src { Rail = true };
            var coils = new List<int>();

            foreach (var node in (net["logic"] as JArray ?? new JArray()).OfType<JObject>())
            {
                var kind = ((string)node["type"] ?? "").ToLowerInvariant();
                if (coils.Count > 0) throw new ArgumentException("Na een coil mogen geen elementen meer komen in dezelfde reeks.");
                switch (kind)
                {
                    case "contact": src = Contact(n, node, src); break;
                    case "compare": src = Compare(n, node, src); break;
                    case "move": src = Move(n, node, src); break;
                    case "call": src = CallBox(n, node, src); break;
                    case "coil": coils.Add(Coil(n, node)); break;
                    default: throw new ArgumentException("Onbekend element type '" + kind + "' (contact, compare, move, call, coil).");
                }
            }
            if (coils.Count > 0) Wire(n, src, coils.Select(c => Tuple.Create(c, "in")).ToArray());

            var flg = new XElement(Flg + "FlgNet", new XElement(Flg + "Parts", n.Parts), new XElement(Flg + "Wires", n.Wires));
            var unit = new XElement("SW.Blocks.CompileUnit", new XAttribute("ID", NextId()), new XAttribute("CompositionName", "CompileUnits"),
                new XElement("AttributeList",
                    new XElement("NetworkSource", flg),
                    new XElement("ProgrammingLanguage", "LAD")));
            var objs = new List<XElement>();
            if (!string.IsNullOrEmpty((string)net["comment"])) objs.Add(Ml("Comment", (string)net["comment"]));
            if (!string.IsNullOrEmpty((string)net["title"])) objs.Add(Ml("Title", (string)net["title"]));
            if (objs.Count > 0) unit.Add(new XElement("ObjectList", objs));
            return unit;
        }

        private XElement Ml(string composition, string text)
        {
            return new XElement("MultilingualText", new XAttribute("ID", NextId()), new XAttribute("CompositionName", composition),
                new XElement("ObjectList",
                    new XElement("MultilingualTextItem", new XAttribute("ID", NextId()), new XAttribute("CompositionName", "Items"),
                        new XElement("AttributeList", new XElement("Culture", _culture), new XElement("Text", text)))));
        }

        // ----- bedrading -----
        private void Wire(Net n, Src from, params Tuple<int, string>[] to)
        {
            var w = new XElement(Flg + "Wire", new XAttribute("UId", n.New()));
            w.Add(from.Rail ? new XElement(Flg + "Powerrail") : NameCon(from.Uid, from.Pin));
            foreach (var t in to) w.Add(NameCon(t.Item1, t.Item2));
            n.Wires.Add(w);
        }
        private void Wire(Net n, Src from, int uid, string pin) { Wire(n, from, Tuple.Create(uid, pin)); }

        private static XElement NameCon(int uid, string name)
        {
            return new XElement(Flg + "NameCon", new XAttribute("UId", uid), new XAttribute("Name", name));
        }
        private static XElement IdentCon(int uid) { return new XElement(Flg + "IdentCon", new XAttribute("UId", uid)); }

        private void ToPin(Net n, int accessUid, int partUid, string pin)
        {
            n.Wires.Add(new XElement(Flg + "Wire", new XAttribute("UId", n.New()), IdentCon(accessUid), NameCon(partUid, pin)));
        }
        private void FromPin(Net n, int partUid, string pin, int accessUid)
        {
            n.Wires.Add(new XElement(Flg + "Wire", new XAttribute("UId", n.New()), NameCon(partUid, pin), IdentCon(accessUid)));
        }

        // ----- operanden -----
        private int Access(Net n, string operand, string literalType)
        {
            if (string.IsNullOrEmpty(operand)) throw new ArgumentException("Lege operand.");
            var uid = n.New();
            string lit = literalType;
            bool isLiteral = false;
            if (Regex.IsMatch(operand, @"^-?\d+$")) { isLiteral = true; lit = lit ?? "Int"; }
            else if (Regex.IsMatch(operand, @"^-?\d+\.\d+$")) { isLiteral = true; lit = lit ?? "Real"; }
            else if (Regex.IsMatch(operand, "^(TRUE|FALSE)$", RegexOptions.IgnoreCase)) { isLiteral = true; lit = "Bool"; }
            else if (Regex.IsMatch(operand, @"^(T|LT|TOD|D|DT)#", RegexOptions.IgnoreCase)) { isLiteral = true; lit = lit ?? operand.Split('#')[0].ToUpperInvariant(); operand = operand.Substring(operand.IndexOf('#') + 1); }

            if (isLiteral)
            {
                n.Parts.Add(new XElement(Flg + "Access", new XAttribute("Scope", "LiteralConstant"), new XAttribute("UId", uid),
                    new XElement(Flg + "Constant",
                        new XElement(Flg + "ConstantType", lit),
                        new XElement(Flg + "ConstantValue", operand.ToUpperInvariant() == "TRUE" ? "true" : operand.ToUpperInvariant() == "FALSE" ? "false" : operand))));
                return uid;
            }

            bool local = operand.StartsWith("#");
            var path = local ? operand.Substring(1) : operand;
            var names = Regex.Matches(path, "\"([^\"]+)\"|([^.\"]+)").Cast<Match>().Select(m => m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value).ToList();
            var sym = new XElement(Flg + "Symbol");
            foreach (var nm in names) sym.Add(new XElement(Flg + "Component", new XAttribute("Name", nm)));
            n.Parts.Add(new XElement(Flg + "Access", new XAttribute("Scope", local ? "LocalVariable" : "GlobalVariable"), new XAttribute("UId", uid), sym));
            return uid;
        }

        // ----- elementen -----
        private Src Contact(Net n, JObject node, Src src)
        {
            var uid = n.New();
            var part = new XElement(Flg + "Part", new XAttribute("Name", "Contact"), new XAttribute("UId", uid));
            if (((string)node["kind"] ?? "NO").ToUpperInvariant() == "NC") part.Add(new XElement(Flg + "Negated", new XAttribute("Name", "operand")));
            n.Parts.Add(part);
            Wire(n, src, uid, "in");
            ToPin(n, Access(n, (string)node["operand"], "Bool"), uid, "operand");
            return new Src { Uid = uid, Pin = "out" };
        }

        private static readonly Dictionary<string, string> CmpNames = new Dictionary<string, string>
        { { "==", "Eq" }, { "<>", "Ne" }, { "<", "Lt" }, { "<=", "Le" }, { ">", "Gt" }, { ">=", "Ge" } };

        private Src Compare(Net n, JObject node, Src src)
        {
            string name;
            if (!CmpNames.TryGetValue((string)node["op"] ?? "==", out name)) throw new ArgumentException("compare.op moet ==, <>, <, <=, > of >= zijn.");
            var dt = (string)node["dataType"] ?? "Int";
            var uid = n.New();
            n.Parts.Add(new XElement(Flg + "Part", new XAttribute("Name", name), new XAttribute("UId", uid),
                new XElement(Flg + "TemplateValue", new XAttribute("Name", "SrcType"), new XAttribute("Type", "Type"), dt)));
            Wire(n, src, uid, "pre");
            ToPin(n, Access(n, (string)node["in1"], dt), uid, "in1");
            ToPin(n, Access(n, (string)node["in2"], dt), uid, "in2");
            return new Src { Uid = uid, Pin = "out" };
        }

        private Src Move(Net n, JObject node, Src src)
        {
            var uid = n.New();
            n.Parts.Add(new XElement(Flg + "Part", new XAttribute("Name", "Move"), new XAttribute("UId", uid), new XAttribute("DisabledENO", "false")));
            Wire(n, src, uid, "en");
            ToPin(n, Access(n, (string)node["in"], (string)node["dataType"]), uid, "in");
            FromPin(n, uid, "out1", Access(n, (string)node["out"], null));
            return new Src { Uid = uid, Pin = "eno" };
        }

        private Src CallBox(Net n, JObject node, Src src)
        {
            var name = (string)node["name"];
            var bt = ((string)node["blockType"] ?? "FC").ToUpperInvariant();
            if (string.IsNullOrEmpty(name)) throw new ArgumentException("call.name ontbreekt.");
            var uid = n.New();
            var info = new XElement(Flg + "CallInfo", new XAttribute("Name", name), new XAttribute("BlockType", bt));
            if (bt == "FB")
            {
                var inst = (string)node["instance"];
                if (string.IsNullOrEmpty(inst)) throw new ArgumentException("FB-aanroep '" + name + "' heeft instance (instance-DB-naam) nodig.");
                var scope = (string)node["instanceScope"] ?? "GlobalDB";
                info.Add(new XElement(Flg + "Instance", new XAttribute("Scope", scope), new XAttribute("UId", n.New()),
                    new XElement(Flg + "Component", new XAttribute("Name", inst))));
            }
            var prms = (node["params"] as JArray ?? new JArray()).OfType<JObject>().ToList();
            foreach (var p in prms)
                info.Add(new XElement(Flg + "Parameter", new XAttribute("Name", (string)p["name"]),
                    new XAttribute("Section", (string)p["section"] ?? "Input"), new XAttribute("Type", (string)p["type"] ?? "Bool")));
            n.Parts.Add(new XElement(Flg + "Call", new XAttribute("UId", uid), info));
            Wire(n, src, uid, "en");
            foreach (var p in prms)
            {
                var section = (string)p["section"] ?? "Input";
                var pn = (string)p["name"];
                var acc = Access(n, (string)p["value"], (string)p["type"]);
                if (section == "Output") FromPin(n, uid, pn, acc); else ToPin(n, acc, uid, pn);
            }
            return new Src { Uid = uid, Pin = "eno" };
        }

        private int Coil(Net n, JObject node)
        {
            var kind = ((string)node["kind"] ?? "coil").ToLowerInvariant();
            var part = kind == "set" ? "SCoil" : kind == "reset" ? "RCoil" : "Coil";
            var uid = n.New();
            var el = new XElement(Flg + "Part", new XAttribute("Name", part), new XAttribute("UId", uid));
            if (kind == "negcoil") el.Add(new XElement(Flg + "Negated", new XAttribute("Name", "operand")));
            n.Parts.Add(el);
            ToPin(n, Access(n, (string)node["operand"], "Bool"), uid, "operand");
            return uid;
        }
    }
}
