// SysOpt.Diagnostics.cs — Motor de diagnóstico del sistema
// Compatible con C# 5 / .NET Framework 4.x
using System;
using System.Collections.Generic;

namespace SysOpt.Diagnostics
{
    // ═══════════════════════════════════════════════════════════════════════
    // DTOs
    // ═══════════════════════════════════════════════════════════════════════

    /// <summary>Datos de entrada recogidos por el Optimizer (dry-run).</summary>
    public class DiagInput
    {
        public double TempFilesMB    { get; set; }
        public double UserTempMB     { get; set; }
        public double RecycleBinMB   { get; set; }
        public double WUCacheMB      { get; set; }
        public double BrowserCacheMB { get; set; }
        public double DnsEntries     { get; set; }
        public double OrphanedKeys   { get; set; }
        public double EventLogsMB    { get; set; }
        public double RamUsedPct     { get; set; }
        public double DiskCUsedPct   { get; set; }
    }

    /// <summary>Elemento individual del informe (fila o cabecera de sección).</summary>
    public class DiagItem
    {
        /// <summary>true = cabecera de sección; false = fila de datos.</summary>
        public bool   IsSection   { get; set; }
        public string SectionTitle{ get; set; }
        public string SectionIcon { get; set; }

        /// <summary>OK | WARN | CRIT | INFO</summary>
        public string Status      { get; set; }
        public string Label       { get; set; }
        public string Detail      { get; set; }
        public string Action      { get; set; }
        public int    Deduction   { get; set; }
        public string ExportLine  { get; set; }
    }

    /// <summary>Resultado completo del análisis diagnóstico.</summary>
    public class DiagResult
    {
        public List<DiagItem> Items     { get; set; }
        public int    Score             { get; set; }
        public int    CritCount         { get; set; }
        public int    WarnCount         { get; set; }
        public string ScoreLabel        { get; set; }
        public string ScoreColor        { get; set; }
        public List<string> ExportLines { get; set; }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Motor
    // ═══════════════════════════════════════════════════════════════════════

    public static class DiagnosticsEngine
    {
        /// <summary>
        /// Analiza los datos del sistema y devuelve el informe completo
        /// con secciones, filas, puntuación y texto exportable.
        /// </summary>
        public static DiagResult Analyze(DiagInput report)
        {
            if (report == null) report = new DiagInput();

            List<DiagItem> items = new List<DiagItem>();
            List<string> export  = new List<string>();
            int deductions = 0;
            int critCount  = 0;
            int warnCount  = 0;

            string dateStr = DateTime.Now.ToString("dd/MM/yyyy HH:mm:ss");
            export.Add("INFORME DE DIAGNÓSTICO DEL SISTEMA — SysOpt v1.0");
            export.Add(string.Format("Fecha: {0}", dateStr));
            export.Add("");

            // ── ALMACENAMIENTO ──────────────────────────────────────────
            AddSection(items, export, "ALMACENAMIENTO", "\U0001F5C4\uFE0F");

            double tempTotal = report.TempFilesMB + report.UserTempMB;
            if (tempTotal > 1000)
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "CRIT", "Archivos temporales acumulados",
                    string.Format("{0} MB en carpetas Temp", Math.Round(tempTotal, 0)),
                    "Limpiar Temp Windows + Usuario", 15);
            }
            else if (tempTotal > 200)
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "WARN", "Archivos temporales moderados",
                    string.Format("{0} MB — recomendable limpiar", Math.Round(tempTotal, 0)),
                    "Limpiar carpetas Temp", 7);
            }
            else
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "OK", "Carpetas temporales limpias",
                    string.Format("{0} MB — nivel óptimo", Math.Round(tempTotal, 1)),
                    "", 0);
            }

            double recycleSize = report.RecycleBinMB;
            if (recycleSize > 500)
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "WARN", "Papelera de reciclaje llena",
                    string.Format("{0} MB ocupados", Math.Round(recycleSize, 0)),
                    "Vaciar papelera", 5);
            }
            else if (recycleSize > 0)
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "INFO", "Papelera con contenido",
                    string.Format("{0} MB", Math.Round(recycleSize, 1)),
                    "", 0);
            }
            else
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "OK", "Papelera vacía",
                    "Sin archivos pendientes de eliminar", "", 0);
            }

            double wuSize = report.WUCacheMB;
            if (wuSize > 2000)
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "WARN", "Caché de Windows Update grande",
                    string.Format("{0} MB en SoftwareDistribution", Math.Round(wuSize, 0)),
                    "Limpiar WU Cache", 8);
            }
            else if (wuSize > 0)
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "INFO", "Caché Windows Update presente",
                    string.Format("{0} MB", Math.Round(wuSize, 1)),
                    "", 0);
            }
            else
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "OK", "Caché de Windows Update limpia",
                    "Sin residuos de actualización", "", 0);
            }

            // ── MEMORIA Y RENDIMIENTO ───────────────────────────────────
            AddSection(items, export, "MEMORIA Y RENDIMIENTO", "\U0001F4BE");

            double ramPct = report.RamUsedPct;
            if (ramPct > 85)
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "CRIT", "Memoria RAM crítica",
                    string.Format("{0}% en uso — riesgo de lentitud severa", ramPct),
                    "Liberar RAM urgente", 20);
            }
            else if (ramPct > 70)
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "WARN", "Uso de RAM elevado",
                    string.Format("{0}% en uso", ramPct),
                    "Liberar RAM recomendado", 10);
            }
            else
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "OK", "Memoria RAM en niveles normales",
                    string.Format("{0}% en uso", ramPct),
                    "", 0);
            }

            double diskPct = report.DiskCUsedPct;
            if (diskPct > 90)
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "CRIT", "Disco C: casi lleno",
                    string.Format("{0}% ocupado — rendimiento muy degradado", diskPct),
                    "Liberar espacio urgente", 20);
            }
            else if (diskPct > 75)
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "WARN", "Disco C: con poco espacio libre",
                    string.Format("{0}% ocupado", diskPct),
                    "Limpiar archivos", 10);
            }
            else
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "OK", "Espacio en disco C: saludable",
                    string.Format("{0}% ocupado", diskPct),
                    "", 0);
            }

            // ── RED Y NAVEGADORES ───────────────────────────────────────
            AddSection(items, export, "RED Y NAVEGADORES", "\U0001F310");

            double dnsCount = report.DnsEntries;
            if (dnsCount > 500)
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "WARN", "Caché DNS muy grande",
                    string.Format("{0} entradas — puede ralentizar resolución", dnsCount),
                    "Limpiar caché DNS", 5);
            }
            else
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "OK", "Caché DNS normal",
                    string.Format("{0} entradas", dnsCount),
                    "", 0);
            }

            double browserMB = report.BrowserCacheMB;
            if (browserMB > 1000)
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "WARN", "Caché de navegadores muy grande",
                    string.Format("{0} MB — recomendable limpiar", Math.Round(browserMB, 0)),
                    "Limpiar caché navegadores", 5);
            }
            else if (browserMB > 200)
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "INFO", "Caché de navegadores presente",
                    string.Format("{0} MB", Math.Round(browserMB, 1)),
                    "", 0);
            }
            else
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "OK", "Caché de navegadores limpia",
                    string.Format("{0} MB", Math.Round(browserMB, 1)),
                    "", 0);
            }

            // ── REGISTRO DE WINDOWS ─────────────────────────────────────
            AddSection(items, export, "REGISTRO DE WINDOWS", "\U0001F4CB");

            double orphaned = report.OrphanedKeys;
            if (orphaned > 20)
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "WARN", "Claves huérfanas en el registro",
                    string.Format("{0} claves de programas desinstalados", orphaned),
                    "Limpiar registro", 5);
            }
            else if (orphaned > 0)
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "INFO", "Algunas claves huérfanas",
                    string.Format("{0} claves — impacto mínimo", orphaned),
                    "", 0);
            }
            else
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "OK", "Registro sin claves huérfanas",
                    "No se detectaron entradas obsoletas", "", 0);
            }

            // ── REGISTROS DE EVENTOS ────────────────────────────────────
            AddSection(items, export, "REGISTROS DE EVENTOS", "\U0001F4F0");

            double eventMB = report.EventLogsMB;
            if (eventMB > 100)
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "WARN", "Logs de eventos grandes",
                    string.Format("{0} MB en System+Application+Setup", Math.Round(eventMB, 1)),
                    "Limpiar Event Logs", 3);
            }
            else
            {
                AddRow(items, ref deductions, ref critCount, ref warnCount, export,
                    "OK", "Logs de eventos dentro de límites",
                    string.Format("{0} MB", Math.Round(eventMB, 1)),
                    "", 0);
            }

            // ── PUNTUACIÓN ──────────────────────────────────────────────
            int finalScore = Math.Max(0, 100 - deductions);
            string scoreColor;
            string scoreLabel;
            if (finalScore >= 80)
            {
                scoreColor = "#4AE896";
                scoreLabel = "Sistema en buen estado";
            }
            else if (finalScore >= 55)
            {
                scoreColor = "#FFB547";
                scoreLabel = "Mantenimiento recomendado";
            }
            else
            {
                scoreColor = "#FF6B84";
                scoreLabel = "Atención urgente";
            }

            export.Add("");
            export.Add("=== RESUMEN ===");
            export.Add(string.Format("Puntuación: {0} / 100", finalScore));
            export.Add(string.Format("Críticos: {0}  |  Avisos: {1}", critCount, warnCount));
            export.Add(string.Format("Estado: {0}", scoreLabel));

            return new DiagResult
            {
                Items      = items,
                Score      = finalScore,
                CritCount  = critCount,
                WarnCount  = warnCount,
                ScoreLabel = scoreLabel,
                ScoreColor = scoreColor,
                ExportLines = export
            };
        }

        // ── Helpers privados ────────────────────────────────────────────

        private static void AddSection(List<DiagItem> items, List<string> export,
            string title, string icon)
        {
            items.Add(new DiagItem
            {
                IsSection    = true,
                SectionTitle = title,
                SectionIcon  = icon
            });
            if (export.Count > 3) export.Add(""); // separador entre secciones
            export.Add(string.Format("=== {0} ===", title));
        }

        private static void AddRow(List<DiagItem> items,
            ref int deductions, ref int critCount, ref int warnCount,
            List<string> export,
            string status, string label, string detail, string action,
            int deduction)
        {
            items.Add(new DiagItem
            {
                IsSection  = false,
                Status     = status,
                Label      = label,
                Detail     = detail,
                Action     = action,
                Deduction  = deduction
            });

            deductions += deduction;
            if (status == "CRIT") critCount++;
            else if (status == "WARN") warnCount++;

            // Línea de exportación
            string prefix;
            if (status == "CRIT") prefix = "[CRÍTICO]";
            else if (status == "WARN") prefix = "[AVISO]";
            else if (status == "INFO") prefix = "[INFO]";
            else prefix = "[OK]";

            string exportLine = string.Format("{0} {1}: {2}", prefix, label, detail);
            if (!string.IsNullOrEmpty(action))
            {
                exportLine = string.Format("{0} — {1}", exportLine, action);
            }
            export.Add(exportLine);
        }
    }
}
