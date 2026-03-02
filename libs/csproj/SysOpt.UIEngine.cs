// =============================================================================
// SysOpt.UIEngine — v1.0.0
// Motor gráfico completo para SysOpt:
//   · XamlStore      — carga XAML desde disco con caché + fallback a embedded resource
//   · ThemeApplicator — aplica colores a ResourceDictionary y ventanas registradas
//   · SplashEngine   — ciclo de vida del splash programático (sin XAML en PS)
//   · DialogBuilder  — construye XAML de diálogos temáticos en C# (no en PS)
//   · WindowRegistry — registro de ventanas que deben recibir el tema
//   · ThemeColorTable — color math para derive dark/light accent backgrounds
//   · UiDispatch     — helpers Dispatcher.Invoke / BeginInvoke seguros
//
// Compilar (NET 4.x / PowerShell 5.1):
//   csc /target:library /out:SysOpt.UIEngine.dll SysOpt.UIEngine.cs
//       /r:System.dll /r:System.Core.dll
//       /r:PresentationCore.dll /r:PresentationFramework.dll
//       /r:WindowsBase.dll /r:System.Xaml.dll
//
// Uso en PS:
//   Add-Type -Path ".\libs\SysOpt.UIEngine.dll"
//   [XamlStore]::SetBaseFolder($script:XamlFolder)
//   [SplashEngine]::Show()
//   [SplashEngine]::Progress(15, "Cargando DLLs...")
//   [WindowRegistry]::Register($window)
//   [ThemeApplicator]::Apply($window, $colorDict)
//   $xaml = [XamlStore]::Get("MainWindow")
//   $result = [DialogBuilder]::ShowDialog($owner, "Título", "Mensaje", "warning", "YesNo")
// =============================================================================

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows;
using System.Windows.Media;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Xml;

// ─────────────────────────────────────────────────────────────────────────────
// XamlStore — carga XAML desde disco con caché en memoria.
// Soporta token placeholders {TC:Key:Default} para colores de tema.
// ─────────────────────────────────────────────────────────────────────────────
public static class XamlStore
{
    private static string _baseFolder = "";
    private static readonly Dictionary<string, string> _cache
        = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    private static readonly object _lock = new object();

    /// <summary>Establece la carpeta raíz de archivos XAML.</summary>
    public static void SetBaseFolder(string folder)
    {
        lock (_lock)
        {
            _baseFolder = folder ?? "";
            _cache.Clear();  // invalida caché si cambia la carpeta
        }
    }

    /// <summary>
    /// Lee un archivo XAML por nombre (con o sin extensión .xaml).
    /// Aplica sustitución de tokens {TC:Key:Default} con el diccionario de colores dado.
    /// Los tokens sin diccionario se reemplazan con el valor Default.
    /// Lanza FileNotFoundException si el archivo no existe.
    /// </summary>
    public static string Get(string name, IDictionary<string, string> colors = null)
    {
        if (string.IsNullOrEmpty(name)) throw new ArgumentNullException("name");

        string fileName = name.EndsWith(".xaml", StringComparison.OrdinalIgnoreCase)
            ? name : name + ".xaml";
        string path = Path.Combine(_baseFolder, fileName);

        if (!File.Exists(path))
            throw new FileNotFoundException("SysOpt.UIEngine: XAML no encontrado: " + path);

        string raw;
        lock (_lock)
        {
            if (!_cache.TryGetValue(fileName, out raw))
            {
                raw = File.ReadAllText(path, Encoding.UTF8);
                _cache[fileName] = raw;
            }
        }

        // Sustituir tokens {TC:Key:Default}
        if (colors != null && raw.IndexOf("{TC:", StringComparison.Ordinal) >= 0)
            raw = ApplyColorTokens(raw, colors);

        return raw;
    }

    /// <summary>Invalida la caché de un XAML concreto (útil en desarrollo).</summary>
    public static void Invalidate(string name)
    {
        string fileName = name.EndsWith(".xaml", StringComparison.OrdinalIgnoreCase)
            ? name : name + ".xaml";
        lock (_lock) { _cache.Remove(fileName); }
    }

    /// <summary>Invalida toda la caché.</summary>
    public static void InvalidateAll()
    {
        lock (_lock) { _cache.Clear(); }
    }

    // ── Token substitution: {TC:ColorKey:FallbackHex} ─────────────────────
    private static string ApplyColorTokens(string xaml, IDictionary<string, string> colors)
    {
        var sb = new StringBuilder(xaml.Length);
        int i = 0;
        while (i < xaml.Length)
        {
            int start = xaml.IndexOf("{TC:", i, StringComparison.Ordinal);
            if (start < 0)
            {
                sb.Append(xaml, i, xaml.Length - i);
                break;
            }
            sb.Append(xaml, i, start - i);
            int end = xaml.IndexOf('}', start + 4);
            if (end < 0)
            {
                sb.Append(xaml, start, xaml.Length - start);
                break;
            }
            // Parsear {TC:Key:Default}
            string inner = xaml.Substring(start + 4, end - start - 4);
            int colon = inner.IndexOf(':');
            string key = colon >= 0 ? inner.Substring(0, colon) : inner;
            string def = colon >= 0 ? inner.Substring(colon + 1) : "";
            string val;
            if (!colors.TryGetValue(key, out val) || string.IsNullOrEmpty(val))
                val = def;
            sb.Append(val);
            i = end + 1;
        }
        return sb.ToString();
    }

    /// <summary>
    /// Helper de conveniencia: carga un XAML y lo parsea directamente en un WPF Object.
    /// Equivale a XamlReader.Load(XmlNodeReader(Get(name, colors))).
    /// </summary>
    public static object Load(string name, IDictionary<string, string> colors = null)
    {
        string xaml = Get(name, colors);
        using (var sr = new StringReader(xaml))
        using (var xr = XmlReader.Create(sr))
            return XamlReader.Load(xr);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ThemeColorTable — matemáticas de color para SysOpt
// Centraliza DarkAccent() y derivación de colores de estado.
// ─────────────────────────────────────────────────────────────────────────────
public static class ThemeColorTable
{
    // ── Oscurecer un color hex por un factor (0.0 → negro, 1.0 → sin cambio) ──
    public static string DarkAccent(string hex, double factor)
    {
        try
        {
            var c = (Color)ColorConverter.ConvertFromString(hex);
            int r = Clamp((int)(c.R * factor));
            int g = Clamp((int)(c.G * factor));
            int b = Clamp((int)(c.B * factor));
            return string.Format("#{0:X2}{1:X2}{2:X2}", r, g, b);
        }
        catch { return hex; }
    }

    private static int Clamp(int v) { return v < 0 ? 0 : v > 255 ? 255 : v; }

    // ── Derivar colores de estado desde el diccionario de tema ────────────────
    /// <summary>
    /// Enriquece el diccionario con StatusRunningBg/Fg, StatusDoneBg/Fg,
    /// StatusErrorBg/Fg, StatusCancelBg/Fg, IconRunning/Done/Error/CancelBg.
    /// Respeta claves BgStatus* y FgStatus* del tema si existen.
    /// </summary>
    public static void DeriveStatusColors(IDictionary<string, string> tc)
    {
        string blue   = GetOrDefault(tc, "AccentBlue",   "#5BA3FF");
        string green  = GetOrDefault(tc, "AccentGreen",  "#4AE896");
        string red    = GetOrDefault(tc, "AccentRed",    "#FF6B84");
        string amber  = GetOrDefault(tc, "AccentAmber",  "#FFB547");

        tc["StatusRunningBg"] = GetOrDefault(tc, "BgStatusInfo", DarkAccent(blue,  0.18));
        tc["StatusRunningFg"] = GetOrDefault(tc, "FgStatusInfo", blue);
        tc["StatusDoneBg"]    = GetOrDefault(tc, "BgStatusOk",   DarkAccent(green, 0.18));
        tc["StatusDoneFg"]    = GetOrDefault(tc, "FgStatusOk",   green);
        tc["StatusErrorBg"]   = GetOrDefault(tc, "BgStatusErr",  DarkAccent(red,   0.22));
        tc["StatusErrorFg"]   = GetOrDefault(tc, "FgStatusErr",  red);
        tc["StatusCancelBg"]  = GetOrDefault(tc, "BgStatusWarn", DarkAccent(amber, 0.22));
        tc["StatusCancelFg"]  = GetOrDefault(tc, "FgStatusWarn", amber);

        tc["IconRunningBg"]   = tc["StatusRunningBg"];
        tc["IconDoneBg"]      = tc["StatusDoneBg"];
        tc["IconErrorBg"]     = tc["StatusErrorBg"];
        tc["IconCancelBg"]    = tc["StatusCancelBg"];
    }

    private static string GetOrDefault(IDictionary<string, string> d, string key, string def)
    {
        string v;
        return (d.TryGetValue(key, out v) && !string.IsNullOrEmpty(v)) ? v : def;
    }

    /// <summary>Convierte un hex string en SolidColorBrush. Devuelve null si falla.</summary>
    public static SolidColorBrush ToBrush(string hex)
    {
        try { return new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex)); }
        catch { return null; }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// WindowRegistry — registro de ventanas que deben recibir cambios de tema
// ─────────────────────────────────────────────────────────────────────────────
public static class WindowRegistry
{
    private static readonly List<WeakReference> _windows = new List<WeakReference>();
    private static readonly object _lock = new object();

    /// <summary>Registra una ventana para recibir actualizaciones de tema.</summary>
    public static void Register(Window w)
    {
        if (w == null) return;
        lock (_lock)
        {
            Prune();
            _windows.Add(new WeakReference(w));
        }
    }

    /// <summary>Elimina una ventana del registro (al cerrarla).</summary>
    public static void Unregister(Window w)
    {
        if (w == null) return;
        lock (_lock)
        {
            _windows.RemoveAll(wr =>
            {
                var t = wr.Target as Window;
                return t == null || t == w;
            });
        }
    }

    /// <summary>Devuelve todas las ventanas vivas registradas.</summary>
    public static IList<Window> GetAll()
    {
        lock (_lock)
        {
            Prune();
            var alive = new List<Window>();
            foreach (var wr in _windows)
            {
                var w = wr.Target as Window;
                if (w != null) alive.Add(w);
            }
            return alive;
        }
    }

    private static void Prune()
    {
        _windows.RemoveAll(wr => wr.Target == null);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ThemeApplicator — aplica un diccionario de colores a ventanas WPF
// ─────────────────────────────────────────────────────────────────────────────
public static class ThemeApplicator
{
    /// <summary>
    /// Aplica todos los colores del diccionario como SolidColorBrush con clave "TB_RRGGBB"
    /// al ResourceDictionary de la ventana y a Application.Current.Resources.
    /// También enriquece con colores de estado derivados.
    /// </summary>
    public static void Apply(Window window, IDictionary<string, string> colors)
    {
        if (window == null) throw new ArgumentNullException("window");
        if (colors == null) throw new ArgumentNullException("colors");

        // Derivar colores de estado
        ThemeColorTable.DeriveStatusColors(colors);

        // Aplicar a ventana principal
        ApplyToResources(window.Resources, colors);

        // Propagar a Application.Current.Resources (para popups y ContextMenus)
        if (Application.Current != null)
            ApplyToResources(Application.Current.Resources, colors);

        // Propagar a todas las ventanas registradas
        foreach (var w in WindowRegistry.GetAll())
        {
            if (w != window)
                ApplyToResources(w.Resources, colors);
        }
    }

    /// <summary>
    /// Aplica colores a un ResourceDictionary.
    /// Crea claves "TB_RRGGBB" (sin #) para cada valor hex.
    /// </summary>
    public static void ApplyToResources(ResourceDictionary rd, IDictionary<string, string> colors)
    {
        if (rd == null || colors == null) return;
        foreach (var kv in colors)
        {
            var hex = kv.Value;
            if (string.IsNullOrEmpty(hex) || hex[0] != '#') continue;
            string rkey = "TB_" + hex.TrimStart('#').ToUpperInvariant();
            var brush = ThemeColorTable.ToBrush(hex);
            if (brush != null)
                rd[rkey] = brush;
        }
    }

    /// <summary>
    /// Crea un ResourceDictionary con los TB_* brushes actuales clonados desde
    /// la ventana principal. Listo para asignarse a una nueva ventana flotante.
    /// </summary>
    public static ResourceDictionary CloneForWindow(ResourceDictionary source)
    {
        var rd = new ResourceDictionary();
        foreach (var key in source.Keys)
        {
            string ks = key as string;
            if (ks != null && ks.StartsWith("TB_", StringComparison.Ordinal))
            {
                var brush = source[key] as SolidColorBrush;
                if (brush != null)
                    rd[ks] = new SolidColorBrush(brush.Color);
            }
        }
        return rd;
    }

    /// <summary>
    /// Obtiene un color del diccionario. Devuelve el fallback si no existe.
    /// </summary>
    public static string GetColor(IDictionary<string, string> colors, string key, string fallback)
    {
        if (colors == null) return fallback;
        string v;
        return (colors.TryGetValue(key, out v) && !string.IsNullOrEmpty(v)) ? v : fallback;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SplashEngine — ciclo de vida del splash 100% en C#
// El splash NO necesita un .xaml externo: está construido aquí.
// ─────────────────────────────────────────────────────────────────────────────
public static class SplashEngine
{
    private static Window _splash     = null;
    private static TextBlock _msgTb   = null;
    private static System.Windows.Shapes.Rectangle _bar = null;
    private const double BAR_MAX_W    = 408.0;
    private static readonly object _lock = new object();

    // ── XAML del splash (hardcoded — no depende de archivos externos) ─────────
    private const string SPLASH_XAML = @"
<Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
        xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        WindowStyle='None' AllowsTransparency='True' Background='Transparent'
        Width='480' Height='160' WindowStartupLocation='CenterScreen' Topmost='True'>
    <Border CornerRadius='12' BorderThickness='1' BorderBrush='#252B40'>
        <Border.Background>
            <LinearGradientBrush StartPoint='0,0' EndPoint='1,1'>
                <GradientStop Color='#1A2035' Offset='0'/>
                <GradientStop Color='#131625' Offset='1'/>
            </LinearGradientBrush>
        </Border.Background>
        <StackPanel VerticalAlignment='Center' Margin='36,0'>
            <TextBlock FontFamily='Segoe UI' FontSize='20' FontWeight='Bold'
                       Foreground='#E8ECF4' Margin='0,0,0,6'>
                <Run Text='SYS'/><Run Foreground='#5BA3FF' Text='OPT'/>
                <Run Foreground='#8B96B8' FontSize='11' FontWeight='Normal'
                     Text='   Windows Optimizer GUI'/>
            </TextBlock>
            <TextBlock Name='SplashMsg' Text='Iniciando...'
                       FontFamily='Segoe UI' FontSize='11'
                       Foreground='#7880A0' Margin='0,0,0,12'/>
            <Border Height='5' CornerRadius='2.5' Background='#1A1E2F'>
                <Rectangle Name='SplashBar' HorizontalAlignment='Left'
                           Width='0' Height='5'>
                    <Rectangle.Fill>
                        <LinearGradientBrush StartPoint='0,0' EndPoint='1,0'>
                            <GradientStop Color='#5BA3FF' Offset='0'/>
                            <GradientStop Color='#4AE896' Offset='1'/>
                        </LinearGradientBrush>
                    </Rectangle.Fill>
                </Rectangle>
            </Border>
        </StackPanel>
    </Border>
</Window>";

    /// <summary>Muestra el splash. Llama desde el hilo UI antes de cargar DLLs.</summary>
    public static void Show()
    {
        lock (_lock)
        {
            if (_splash != null) return;
            try
            {
                using (var sr = new StringReader(SPLASH_XAML))
                using (var xr = XmlReader.Create(sr))
                {
                    _splash = (Window)XamlReader.Load(xr);
                }
                _msgTb = _splash.FindName("SplashMsg") as TextBlock;
                _bar   = _splash.FindName("SplashBar")
                         as System.Windows.Shapes.Rectangle;
                _splash.Show();
            }
            catch { _splash = null; }
        }
    }

    /// <summary>
    /// Actualiza progreso (0-100) y mensaje opcional.
    /// Thread-safe: usa Dispatcher.Invoke si es llamado desde otro hilo.
    /// </summary>
    public static void Progress(int pct, string message = null)
    {
        lock (_lock)
        {
            if (_splash == null) return;
        }
        Action update = () =>
        {
            lock (_lock) { if (_splash == null) return; }
            if (_msgTb != null && message != null) _msgTb.Text = message;
            if (_bar   != null)
                _bar.Width = Math.Round(BAR_MAX_W * Math.Min(100, Math.Max(0, pct)) / 100.0);
        };
        try
        {
            if (_splash.Dispatcher.CheckAccess()) update();
            else _splash.Dispatcher.Invoke(update);
        }
        catch { }
    }

    /// <summary>Cierra y descarta el splash.</summary>
    public static void Close()
    {
        lock (_lock)
        {
            if (_splash == null) return;
            try { _splash.Dispatcher.Invoke(() => { _splash.Close(); }); }
            catch { }
            _splash = null;
            _msgTb  = null;
            _bar    = null;
        }
    }

    /// <summary>True si el splash está visible.</summary>
    public static bool IsVisible
    {
        get { lock (_lock) { return _splash != null; } }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// DialogBuilder — construye y muestra diálogos temáticos desde C#
// Elimina la generación dinámica de XAML en PowerShell (Show-ThemedDialog).
// ─────────────────────────────────────────────────────────────────────────────
public static class DialogBuilder
{
    /// <summary>
    /// Construye y muestra un diálogo temático modal.
    /// type:    "info" | "warning" | "error" | "success" | "question"
    /// buttons: "OK" | "YesNo"
    /// Devuelve true si el usuario pulsó OK o Sí; false en otro caso.
    /// </summary>
    public static bool ShowDialog(
        Window owner,
        string title,
        string message,
        string type    = "info",
        string buttons = "OK",
        IDictionary<string, string> colors = null)
    {
        string accentColor = AccentForType(type);
        string iconChar    = IconForType(type);
        string accentBg    = AccentBgForType(type, colors);

        string bgCard    = Tc(colors, "BgCardDark",   "#131625");
        string bgDeep    = Tc(colors, "BgDeep",        "#0D0F1A");
        string textPrim  = Tc(colors, "TextPrimary",   "#E8ECF4");
        string textSec   = Tc(colors, "TextSecondary", "#B0BACC");
        string btnSecBg  = Tc(colors, "BtnSecondaryBg","#1A1E2F");
        string textMuted = Tc(colors, "TextMuted",     "#7880A0");
        string borderSub = Tc(colors, "BorderSubtle",  "#252B40");

        // Escapar XML
        title   = XmlEscape(title);
        message = XmlEscape(message);
        iconChar = XmlEscape(iconChar);

        string btnXaml = buttons == "YesNo"
            ? BuildYesNoButtons(accentColor, bgDeep, btnSecBg, textMuted, borderSub, colors)
            : BuildOkButton(accentColor, bgDeep);

        string xaml = string.Format(@"
<Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
        xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Title='' Width='420' SizeToContent='Height'
        WindowStartupLocation='CenterOwner'
        ResizeMode='NoResize' WindowStyle='None'
        AllowsTransparency='True' Background='Transparent' Topmost='True'>
    <Border Background='{0}' CornerRadius='12' BorderBrush='{1}' BorderThickness='1'>
        <Border.Effect>
            <DropShadowEffect BlurRadius='30' ShadowDepth='0' Opacity='0.6' Color='#000000'/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height='Auto'/>
                <RowDefinition Height='Auto'/>
                <RowDefinition Height='Auto'/>
            </Grid.RowDefinitions>
            <Border Grid.Row='0' Background='{2}' CornerRadius='11,11,0,0'
                    BorderBrush='{1}' BorderThickness='0,0,0,1' Padding='20,16'>
                <StackPanel Orientation='Horizontal'>
                    <Border Width='32' Height='32' CornerRadius='8'
                            Background='{1}' Margin='0,0,14,0' VerticalAlignment='Center'>
                        <TextBlock Text='{3}' FontSize='16' FontWeight='Bold'
                                   Foreground='{4}' HorizontalAlignment='Center' VerticalAlignment='Center'/>
                    </Border>
                    <TextBlock Text='{5}' FontSize='14' FontWeight='Bold'
                               Foreground='{6}' VerticalAlignment='Center' FontFamily='Segoe UI'/>
                </StackPanel>
            </Border>
            <Border Grid.Row='1' Padding='22,18,22,14'>
                <TextBlock Text='{7}' Foreground='{8}' FontSize='12.5'
                           TextWrapping='Wrap' LineHeight='20' FontFamily='Segoe UI'/>
            </Border>
            <Border Grid.Row='2' Padding='22,0,22,18'>
                {9}
            </Border>
        </Grid>
    </Border>
</Window>",
            bgCard, accentColor, accentBg, iconChar, bgDeep,
            title, textPrim, message, textSec, btnXaml);

        bool result = false;
        Window dlg = null;
        try
        {
            using (var sr = new StringReader(xaml))
            using (var xr = XmlReader.Create(sr))
                dlg = (Window)XamlReader.Load(xr);

            if (owner != null)
            {
                try { dlg.Owner = owner; } catch { }
            }

            if (buttons == "OK")
            {
                var btnOk = dlg.FindName("btnDlgOK") as Button;
                if (btnOk != null) btnOk.Click += (s, e) => { dlg.DialogResult = true; dlg.Close(); };
            }
            else
            {
                var btnYes = dlg.FindName("btnDlgYes") as Button;
                var btnNo  = dlg.FindName("btnDlgNo")  as Button;
                if (btnYes != null) btnYes.Click += (s, e) => { result = true;  dlg.Close(); };
                if (btnNo  != null) btnNo.Click  += (s, e) => { result = false; dlg.Close(); };
            }

            dlg.MouseLeftButtonDown += (s, e) => { try { dlg.DragMove(); } catch { } };
            dlg.ShowDialog();
            if (buttons == "OK") result = dlg.DialogResult == true;
        }
        catch { }
        finally
        {
            if (dlg != null) try { dlg.Close(); } catch { }
        }
        return result;
    }

    // ── Builder de diálogo de entrada de texto ─────────────────────────────
    /// <summary>
    /// Muestra un diálogo con TextBox de entrada.
    /// Devuelve el texto ingresado, o null si el usuario canceló.
    /// </summary>
    public static string ShowInput(
        Window owner,
        string title,
        string prompt,
        string defaultValue = "",
        IDictionary<string, string> colors = null)
    {
        string blue    = Tc(colors, "AccentBlue",     "#5BA3FF");
        string bgCard  = Tc(colors, "BgCardDark",     "#131625");
        string bgDeep  = Tc(colors, "BgDeep",         "#0D0F1A");
        string dryBg   = Tc(colors, "DryRunBg",       "#0D1E35");
        string textP   = Tc(colors, "TextPrimary",    "#E8ECF4");
        string textS   = Tc(colors, "TextSecondary",  "#B0BACC");
        string textM   = Tc(colors, "TextMuted",      "#7880A0");
        string brdSub  = Tc(colors, "BorderSubtle",   "#2A3448");
        string bgInput = Tc(colors, "BgInput",        "#1A1E2F");
        string brd252  = Tc(colors, "BorderSubtle2",  "#252B40");
        string caret   = blue;
        string selBg   = Tc(colors, "ComboSelected",  "#1A3A5C");

        string xaml = string.Format(@"
<Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
        xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Title='' Width='440' SizeToContent='Height'
        WindowStartupLocation='CenterOwner'
        ResizeMode='NoResize' WindowStyle='None'
        AllowsTransparency='True' Background='Transparent' Topmost='True'>
    <Border Background='{0}' CornerRadius='12' BorderBrush='{1}' BorderThickness='1'>
        <Border.Effect>
            <DropShadowEffect BlurRadius='30' ShadowDepth='0' Opacity='0.6' Color='#000000'/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height='Auto'/>
                <RowDefinition Height='Auto'/>
                <RowDefinition Height='Auto'/>
                <RowDefinition Height='Auto'/>
            </Grid.RowDefinitions>
            <Border Grid.Row='0' Background='{2}' CornerRadius='11,11,0,0'
                    BorderBrush='{1}' BorderThickness='0,0,0,1' Padding='20,16'>
                <StackPanel Orientation='Horizontal'>
                    <Border Width='32' Height='32' CornerRadius='8'
                            Background='{1}' Margin='0,0,14,0' VerticalAlignment='Center'>
                        <TextBlock Text='&#x270E;' FontSize='16' FontWeight='Bold'
                                   Foreground='{3}' HorizontalAlignment='Center' VerticalAlignment='Center'/>
                    </Border>
                    <TextBlock Text='{4}' FontSize='14' FontWeight='Bold'
                               Foreground='{5}' VerticalAlignment='Center' FontFamily='Segoe UI'/>
                </StackPanel>
            </Border>
            <Border Grid.Row='1' Padding='22,16,22,8'>
                <TextBlock Text='{6}' Foreground='{7}' FontSize='12' TextWrapping='Wrap' FontFamily='Segoe UI'/>
            </Border>
            <Border Grid.Row='2' Padding='22,0,22,16'>
                <TextBox Name='txtInput' Text='{8}'
                         Background='{9}' Foreground='{5}'
                         BorderBrush='{10}' BorderThickness='1'
                         CaretBrush='{1}' FontSize='13' Padding='10,8'
                         FontFamily='JetBrains Mono, Consolas'/>
            </Border>
            <Border Grid.Row='3' Padding='22,0,22,18'>
                <StackPanel Orientation='Horizontal' HorizontalAlignment='Right'>
                    <Button Name='btnInputCancel' Content='Cancelar' Width='100' Height='34' Margin='0,0,8,0'
                            Background='{11}' Foreground='{12}' BorderBrush='{13}' BorderThickness='1'
                            FontSize='12' Cursor='Hand' IsCancel='True' FontFamily='Segoe UI'/>
                    <Button Name='btnInputOK' Content='Aceptar' Width='100' Height='34'
                            Background='{1}' Foreground='{3}' BorderThickness='0'
                            FontWeight='Bold' FontSize='12' Cursor='Hand' IsDefault='True' FontFamily='Segoe UI'/>
                </StackPanel>
            </Border>
        </Grid>
    </Border>
</Window>",
            bgCard, blue, dryBg, bgDeep,
            XmlEscape(title), textP,
            XmlEscape(prompt), textS,
            XmlEscape(defaultValue ?? ""),
            bgInput, brdSub,
            bgInput, textM, brd252);

        string inputResult = null;
        Window dlg = null;
        try
        {
            using (var sr = new StringReader(xaml))
            using (var xr = XmlReader.Create(sr))
                dlg = (Window)XamlReader.Load(xr);

            if (owner != null) try { dlg.Owner = owner; } catch { }

            var txt  = dlg.FindName("txtInput")       as TextBox;
            var btnOk= dlg.FindName("btnInputOK")     as Button;
            var btnCx= dlg.FindName("btnInputCancel") as Button;

            if (btnOk != null) btnOk.Click += (s, e) =>
            {
                inputResult = txt != null ? txt.Text : "";
                dlg.Close();
            };
            if (btnCx != null) btnCx.Click += (s, e) => { dlg.Close(); };

            dlg.MouseLeftButtonDown += (s, e) => { try { dlg.DragMove(); } catch { } };
            dlg.ShowDialog();
        }
        catch { }
        finally
        {
            if (dlg != null) try { dlg.Close(); } catch { }
        }
        return inputResult;
    }

    // ── Helpers privados ──────────────────────────────────────────────────────
    private static string AccentForType(string type)
    {
        switch ((type ?? "info").ToLower())
        {
            case "warning":  return "#FFB547";
            case "error":    return "#FF6B84";
            case "success":  return "#4AE896";
            case "question": return "#9B7EFF";
            default:         return "#5BA3FF";
        }
    }

    private static string IconForType(string type)
    {
        switch ((type ?? "info").ToLower())
        {
            case "warning":  return "\u26A0";   // ⚠
            case "error":    return "\u2715";   // ✕
            case "success":  return "\u2713";   // ✓
            case "question": return "?";
            default:         return "\u2139";   // ℹ
        }
    }

    private static string AccentBgForType(string type, IDictionary<string, string> colors)
    {
        switch ((type ?? "info").ToLower())
        {
            case "warning":  return Tc(colors, "BgStatusWarn", "#2B1E0A");
            case "error":    return Tc(colors, "BgStatusErr",  "#2B0D12");
            case "success":  return Tc(colors, "BgStatusOk",   "#0D2B1A");
            case "question": return Tc(colors, "BgStatusWarn", "#2A2010");
            default:         return Tc(colors, "DryRunBg",     "#0D1E35");
        }
    }

    private static string BuildOkButton(string accent, string bgDeep)
    {
        return string.Format(
            "<Button Name='btnDlgOK' Content='Aceptar' Width='100' Height='34'" +
            " Background='{0}' Foreground='{1}' BorderThickness='0'" +
            " FontWeight='Bold' FontSize='12' Cursor='Hand' IsDefault='True'" +
            " HorizontalAlignment='Right' FontFamily='Segoe UI'/>",
            accent, bgDeep);
    }

    private static string BuildYesNoButtons(
        string accent, string bgDeep, string secBg, string muted, string border,
        IDictionary<string, string> colors)
    {
        return string.Format(
            "<StackPanel Orientation='Horizontal' HorizontalAlignment='Right' Margin='0'>" +
            "<Button Name='btnDlgNo'  Content='No'  Width='90' Height='34' Margin='0,0,8,0'" +
            " Background='{0}' Foreground='{1}' BorderBrush='{2}' BorderThickness='1'" +
            " FontSize='12' Cursor='Hand' IsCancel='True' FontFamily='Segoe UI'/>" +
            "<Button Name='btnDlgYes' Content='Si'  Width='90' Height='34'" +
            " Background='{3}' Foreground='{4}' BorderThickness='0'" +
            " FontWeight='Bold' FontSize='12' Cursor='Hand' IsDefault='True' FontFamily='Segoe UI'/>" +
            "</StackPanel>",
            secBg, muted, border, accent, bgDeep);
    }

    private static string Tc(IDictionary<string, string> d, string key, string def)
    {
        if (d == null) return def;
        string v;
        return (d.TryGetValue(key, out v) && !string.IsNullOrEmpty(v)) ? v : def;
    }

    private static string XmlEscape(string s)
    {
        if (string.IsNullOrEmpty(s)) return "";
        return s.Replace("&", "&amp;").Replace("\"", "&quot;")
                .Replace("'", "&apos;").Replace("<", "&lt;").Replace(">", "&gt;");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// UiDispatch — helpers Dispatcher thread-safe
// ─────────────────────────────────────────────────────────────────────────────
public static class UiDispatch
{
    /// <summary>
    /// Ejecuta una acción en el Dispatcher de la ventana.
    /// Si ya está en el hilo UI, la ejecuta directamente.
    /// </summary>
    public static void Invoke(Window w, Action action)
    {
        if (w == null || action == null) return;
        try
        {
            if (w.Dispatcher.CheckAccess()) action();
            else w.Dispatcher.Invoke(action);
        }
        catch { }
    }

    /// <summary>Encola una acción en el Dispatcher (no bloqueante).</summary>
    public static void BeginInvoke(Window w, Action action)
    {
        if (w == null || action == null) return;
        try { w.Dispatcher.BeginInvoke(action); }
        catch { }
    }

    /// <summary>Pump de mensajes sin runspace (reemplaza DoEvents).</summary>
    public static void DoEvents()
    {
        try { System.Windows.Forms.Application.DoEvents(); }
        catch { }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// DynamicXamlBuilder — construye XAML de ventanas temáticas con colores inyectados
// Reemplaza los here-strings de Show-OptionsWindow y Show-AboutWindow en PS.
// Los XAML de Options y About tienen colores dinámicos (Get-TC) — aquí los
// generamos en C# en lugar de hacerlo con string interpolation en PowerShell.
// ─────────────────────────────────────────────────────────────────────────────
public static class DynamicXamlBuilder
{
    // ── Options Window ────────────────────────────────────────────────────────
    /// <summary>
    /// Construye el XAML de la ventana de Opciones con colores del tema inyectados.
    /// El PS carga el XAML retornado con XamlReader.Load().
    /// </summary>
    public static string BuildOptionsXaml(
        IDictionary<string, string> colors,
        string titleText      = "Opciones — SysOpt",
        string themeLabelText = "Tema visual",
        string langLabelText  = "Idioma",
        string hintText       = "Algunos cambios de idioma requieren reiniciar SysOpt.",
        string applyText      = "Aplicar",
        string closeText      = "Cerrar")
    {
        string bgDeep  = Tc(colors, "BgDeep",        "#0D0F1A");
        string textP   = Tc(colors, "TextPrimary",   "#E8ECF4");
        string textS   = Tc(colors, "TextSecondary", "#9BA4C0");
        string textM   = Tc(colors, "TextMuted",     "#5A6080");
        string purple  = Tc(colors, "AccentPurple",  "#A47CFF");
        string blue    = Tc(colors, "AccentBlue",    "#5BA3FF");
        string btnBg   = Tc(colors, "BtnSecondaryBg","#1A4A8A");
        string hdrBg   = Tc(colors, "HdrBtnBg",     "#1A2040");
        string hdrBdr  = Tc(colors, "HdrBtnBorder",  "#3D5080");
        string hover   = Tc(colors, "HdrBtnHover",   "#253060");

        return string.Format(@"
<Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
        xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Title='{0}' Width='460' Height='360'
        WindowStartupLocation='CenterOwner' ResizeMode='NoResize'
        Background='{1}' WindowStyle='SingleBorderWindow'>
    <Grid>
        <Rectangle Fill='{1}'/>
        <Ellipse Width='300' Height='300' Opacity='0.08'
                 HorizontalAlignment='Left' VerticalAlignment='Top' Margin='-80,-60,0,0'>
            <Ellipse.Fill>
                <RadialGradientBrush>
                    <GradientStop Color='{2}' Offset='0'/>
                    <GradientStop Color='Transparent' Offset='1'/>
                </RadialGradientBrush>
            </Ellipse.Fill>
        </Ellipse>
        <StackPanel Margin='28,24,28,24'>
            <TextBlock FontFamily='Segoe UI' FontSize='20' FontWeight='Bold'
                       Foreground='{3}' Margin='0,0,0,20'>
                <Run Text='&#x2699; '/><Run Foreground='{2}' Text='{4}'/>
            </TextBlock>
            <TextBlock FontFamily='Segoe UI' FontSize='12' FontWeight='SemiBold'
                       Foreground='{5}' Margin='0,0,0,6' Text='{6}'/>
            <ComboBox Name='cmbTheme' Height='32' Margin='0,0,0,16'/>
            <TextBlock FontFamily='Segoe UI' FontSize='12' FontWeight='SemiBold'
                       Foreground='{5}' Margin='0,0,0,6' Text='{7}'/>
            <ComboBox Name='cmbLang' Height='32' Margin='0,0,0,20'/>
            <TextBlock FontFamily='Segoe UI' FontSize='10' FontStyle='Italic'
                       Foreground='{8}' Text='{9}' Margin='0,0,0,16' TextWrapping='Wrap'/>
            <StackPanel Orientation='Horizontal' HorizontalAlignment='Right'>
                <Button Name='btnOptApply' Content='{10}'
                        Width='110' Height='34' Margin='0,0,10,0'
                        Background='{11}' BorderBrush='{12}' BorderThickness='1'
                        Foreground='{12}' FontFamily='Segoe UI' FontSize='12'
                        FontWeight='SemiBold' Cursor='Hand'>
                    <Button.Template>
                        <ControlTemplate TargetType='Button'>
                            <Border x:Name='bd' CornerRadius='8'
                                    Background='{{TemplateBinding Background}}'
                                    BorderBrush='{{TemplateBinding BorderBrush}}'
                                    BorderThickness='{{TemplateBinding BorderThickness}}'>
                                <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property='IsMouseOver' Value='True'>
                                    <Setter TargetName='bd' Property='Background' Value='{13}'/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button Name='btnOptClose' Content='{14}'
                        Width='110' Height='34'
                        Background='{15}' BorderBrush='{16}' BorderThickness='1'
                        Foreground='{5}' FontFamily='Segoe UI' FontSize='12'
                        FontWeight='SemiBold' Cursor='Hand'>
                    <Button.Template>
                        <ControlTemplate TargetType='Button'>
                            <Border x:Name='bd' CornerRadius='8'
                                    Background='{{TemplateBinding Background}}'
                                    BorderBrush='{{TemplateBinding BorderBrush}}'
                                    BorderThickness='{{TemplateBinding BorderThickness}}'>
                                <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property='IsMouseOver' Value='True'>
                                    <Setter TargetName='bd' Property='Background' Value='{13}'/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
            </StackPanel>
        </StackPanel>
    </Grid>
</Window>",
            XE(titleText), bgDeep, purple, textP, XE(titleText),
            textS, XE(themeLabelText), XE(langLabelText),
            textM, XE(hintText),
            XE(applyText), btnBg, blue, hover,
            XE(closeText), hdrBg, hdrBdr);
    }

    // ── About Window ──────────────────────────────────────────────────────────
    /// <summary>
    /// Construye el XAML de la ventana About con colores del tema y versión.
    /// </summary>
    public static string BuildAboutXaml(
        IDictionary<string, string> colors,
        string version,
        string changelogXamlBody)
    {
        string bgDeep  = Tc(colors, "BgDeep",        "#0D0F1A");
        string bgCard  = Tc(colors, "BgCardDark",    "#131625");
        string textP   = Tc(colors, "TextPrimary",   "#E8ECF4");
        string textS   = Tc(colors, "TextSecondary", "#9BA4C0");
        string textM   = Tc(colors, "TextMuted",     "#7880A0");
        string blue    = Tc(colors, "AccentBlue",    "#5BA3FF");
        string bdrSub  = Tc(colors, "BorderSubtle",  "#252B40");
        string hdrBg   = Tc(colors, "HdrBtnBg",     "#1A2040");
        string btnFg   = Tc(colors, "BtnSecondaryFg","#3D8EFF");
        string hover   = Tc(colors, "HdrBtnHover",   "#253060");
        string bdrHov  = Tc(colors, "BorderHover",   "#4A5068");

        return string.Format(@"
<Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
        xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Title='Acerca de SysOpt' Width='560' Height='760'
        WindowStartupLocation='CenterOwner' ResizeMode='NoResize'
        Background='{0}' WindowStyle='SingleBorderWindow'>
    <Grid>
        <Rectangle Fill='{0}'/>
        <Ellipse Width='400' Height='400' Opacity='0.09'
                 HorizontalAlignment='Left' VerticalAlignment='Top' Margin='-120,-80,0,0'>
            <Ellipse.Fill>
                <RadialGradientBrush>
                    <GradientStop Color='{1}' Offset='0'/>
                    <GradientStop Color='Transparent' Offset='1'/>
                </RadialGradientBrush>
            </Ellipse.Fill>
        </Ellipse>
        <ScrollViewer VerticalScrollBarVisibility='Auto'>
            <StackPanel Margin='28,24,28,24'>
                <StackPanel Orientation='Horizontal' Margin='0,0,0,18'>
                    <Image Name='aboutLogo' Width='56' Height='56' Margin='0,0,14,0'
                           VerticalAlignment='Center' RenderOptions.BitmapScalingMode='HighQuality'/>
                    <StackPanel VerticalAlignment='Center'>
                        <TextBlock FontFamily='Segoe UI' FontSize='26' FontWeight='Bold' Foreground='{2}'>
                            <Run Text='SYS'/><Run Foreground='{1}' Text='OPT'/>
                        </TextBlock>
                        <TextBlock FontFamily='Segoe UI' FontSize='11' Foreground='{3}'>Windows Optimizer GUI</TextBlock>
                    </StackPanel>
                    <Border CornerRadius='6' Background='#1A5BA3FF' BorderBrush='#405BA3FF'
                            BorderThickness='1' Padding='10,4' Margin='14,0,0,0' VerticalAlignment='Center'>
                        <TextBlock FontFamily='Consolas' FontSize='11' FontWeight='Bold'
                                   Foreground='{1}' Text='v{4}'/>
                    </Border>
                </StackPanel>
                <Rectangle Height='1' Fill='{5}' Margin='0,0,0,16'/>
                {6}
                <Rectangle Height='1' Fill='{5}' Margin='0,4,0,12'/>
                <StackPanel Orientation='Horizontal' HorizontalAlignment='Center'>
                    <TextBlock FontFamily='Segoe UI' FontSize='10' Foreground='{7}'
                               Text='2026 &#169; Danew Malavita | '/>
                    <TextBlock FontFamily='Segoe UI' FontSize='10'>
                        <Hyperlink Name='lnkGithub' NavigateUri='https://github.com/Danewmalavita/'
                                   Foreground='{1}' TextDecorations='None'>
                            github.com/Danewmalavita
                        </Hyperlink>
                    </TextBlock>
                </StackPanel>
                <Button Name='btnAboutClose' Content='Cerrar'
                        Width='120' Height='34' Margin='0,16,0,0'
                        HorizontalAlignment='Center'
                        Background='{8}' BorderBrush='{9}' BorderThickness='1'
                        Foreground='{1}' FontFamily='Segoe UI' FontSize='12'
                        FontWeight='SemiBold' Cursor='Hand'>
                    <Button.Template>
                        <ControlTemplate TargetType='Button'>
                            <Border x:Name='bd' CornerRadius='8'
                                    Background='{{TemplateBinding Background}}'
                                    BorderBrush='{{TemplateBinding BorderBrush}}'
                                    BorderThickness='{{TemplateBinding BorderThickness}}'>
                                <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property='IsMouseOver' Value='True'>
                                    <Setter TargetName='bd' Property='Background' Value='{10}'/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
            </StackPanel>
        </ScrollViewer>
    </Grid>
</Window>",
            bgDeep, blue, textP, textM, XE(version),
            bdrSub, changelogXamlBody ?? "",
            bdrHov, hdrBg, btnFg, hover);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────
    private static string Tc(IDictionary<string, string> d, string key, string def)
    {
        if (d == null) return def;
        string v;
        return (d.TryGetValue(key, out v) && !string.IsNullOrEmpty(v)) ? v : def;
    }

    private static string XE(string s)
    {
        if (string.IsNullOrEmpty(s)) return "";
        return s.Replace("&","&amp;").Replace("'","&apos;")
                .Replace("<","&lt;").Replace(">","&gt;");
    }
}
