using System;
using System.Collections.Generic;
using System.Linq;
using Siemens.Engineering;
using Siemens.Engineering.HW;
using Siemens.Engineering.HW.Features;
using Siemens.Engineering.SW;

namespace TiaBridge
{
    /// <summary>Koppelt aan een DRAAIENDE TIA Portal (nooit zelf starten) en vindt PlcSoftware.</summary>
    internal static class TiaSession
    {
        private static TiaPortal _tia;
        private static int _pid = -1;

        public static IList<TiaPortalProcess> Processes()
        {
            return TiaPortal.GetProcesses();
        }

        public static TiaPortal Tia(int? processId)
        {
            if (_tia != null && (processId == null || processId == _pid))
            {
                try { var _ = _tia.Projects.Count; return _tia; }   // levend?
                catch { _tia = null; }
            }

            var procs = TiaPortal.GetProcesses();
            if (procs.Count == 0)
                throw new InvalidOperationException("Geen draaiende TIA Portal gevonden. Start TIA Portal en open een project.");

            TiaPortalProcess p;
            if (processId != null)
            {
                p = procs.FirstOrDefault(x => x.Id == processId.Value);
                if (p == null) throw new InvalidOperationException("Geen TIA-proces met id " + processId);
            }
            else if (procs.Count == 1) p = procs[0];
            else throw new InvalidOperationException(
                "Meerdere TIA Portal-instanties draaien (" + string.Join(", ", procs.Select(x => x.Id)) +
                "). Geef processId mee (zie get_project_info).");

            // Eerste keer toont TIA hier het Openness-toestemmingsvenster.
            _tia = p.Attach();
            _pid = p.Id;
            return _tia;
        }

        public static Project Project(int? processId)
        {
            var tia = Tia(processId);
            var proj = tia.Projects.FirstOrDefault();
            if (proj == null) throw new InvalidOperationException("TIA Portal draait, maar er is geen project geopend.");
            return proj;
        }

        public static IEnumerable<Device> Devices(Project project)
        {
            var seen = new HashSet<string>();
            foreach (var d in project.Devices) if (seen.Add(d.Name)) yield return d;
            foreach (var d in GroupDevices(project.DeviceGroups)) if (seen.Add(d.Name)) yield return d;
            DeviceUserGroup ungrouped = null;
            try { ungrouped = project.UngroupedDevicesGroup; } catch { }
            if (ungrouped != null)
                foreach (var d in ungrouped.Devices) if (seen.Add(d.Name)) yield return d;
        }

        private static IEnumerable<Device> GroupDevices(DeviceUserGroupComposition groups)
        {
            foreach (var g in groups)
            {
                foreach (var d in g.Devices) yield return d;
                foreach (var d in GroupDevices(g.Groups)) yield return d;
            }
        }

        public static IEnumerable<KeyValuePair<Device, PlcSoftware>> PlcSoftwares(Project project)
        {
            foreach (var dev in Devices(project))
                foreach (var plc in FindPlc(dev.DeviceItems))
                    yield return new KeyValuePair<Device, PlcSoftware>(dev, plc);
        }

        private static IEnumerable<PlcSoftware> FindPlc(DeviceItemComposition items)
        {
            foreach (var item in items)
            {
                var sc = item.GetService<SoftwareContainer>();
                var plc = sc != null ? sc.Software as PlcSoftware : null;
                if (plc != null) yield return plc;
                foreach (var nested in FindPlc(item.DeviceItems)) yield return nested;
            }
        }

        public static PlcSoftware Plc(Project project, string plcName)
        {
            var all = PlcSoftwares(project).ToList();
            if (all.Count == 0) throw new InvalidOperationException("Geen PLC-software gevonden in dit project.");
            if (string.IsNullOrEmpty(plcName))
            {
                if (all.Count == 1) return all[0].Value;
                throw new InvalidOperationException("Meerdere PLC's (" +
                    string.Join(", ", all.Select(x => x.Value.Name)) + "). Geef plcName mee.");
            }
            var hit = all.FirstOrDefault(x => string.Equals(x.Value.Name, plcName, StringComparison.OrdinalIgnoreCase)
                                           || string.Equals(x.Key.Name, plcName, StringComparison.OrdinalIgnoreCase));
            if (hit.Value == null)
                throw new InvalidOperationException("PLC '" + plcName + "' niet gevonden. Beschikbaar: " +
                    string.Join(", ", all.Select(x => x.Value.Name)));
            return hit.Value;
        }
    }
}
