#﻿Requires -RunAsAdministrator
<#
.SYNOPSIS
    Optimizador de Sistema Windows con Interfaz Gráfica
.DESCRIPTION
    Script completo de optimización con GUI, limpieza avanzada, verificación de sistema y registro.
#>

# ─────────────────────────────────────────────────────────────────────────────
# Metadatos de versión — mostrados en el About (Show-AboutWindow)
# ─────────────────────────────────────────────────────────────────────────────
$script:AppVersion = "3.2.0"
$script:AppNotes   = @{
    RequiresAdmin = $true
    Cambios = [ordered]@{
        "v3.2.0" = @{
            Titulo = "CTK + DAL + Agent hooks en SysOpt.Core.dll"
            Items  = @(
                "[CTK] ScanTokenManager — CancellationToken global, reemplaza flag ScanCtl211.Stop",
                "[CTK] RequestNew() + Cancel() + Dispose() en Add_Closed — cancelación limpia de runspaces",
                "[DAL] SystemDataCollector — GetCpuSnapshot/GetRamSnapshot/GetDiskSnapshot/GetNetworkSnapshot/GetGpuSnapshot/GetPortSnapshot",
                "[DAL] GetFullSnapshot() — SystemSnapshot completo serializable para modo agente",
                "[DAL] Modelos puros: CpuSnapshot, RamSnapshot, DiskSnapshot, NetworkSnapshot, GpuSnapshot, PortSnapshot",
                "[AGENT] AgentBus + IAgentTransport + AgentThresholds — hooks preparados, standalone safe",
                "[DLL] compile-dlls.ps1 renovado — auto-descubre todos los .cs de .\libs\ con referencias correctas",
                "[DLL] WseTrim cargado al inicio (junto al resto) en lugar de bajo demanda",
                "[DLL] Load-SysOptDll helper unificado — un punto de carga para las 5 DLLs",
                "[DLL] SysOpt.Optimizer.dll — 15 tareas de optimización en C#",
                "[DLL] SysOpt.StartupManager.dll — gestión de inicio de Windows",
                "[DLL] SysOpt.Diagnostics.dll — motor de diagnóstico del sistema",
                "[THEME] 33 temas preinstalados (expansión de 11 a 33)",
                "[UI] Toggle switch Win11 en ventana de opciones",
                "[DBG] Auditoría y carga de 8 DLLs en debug/splash",
                "[OPT] PS1 reducido de 6924 a ~6241 líneas (-9.9%)",
                "[OPT] Compactación: $taskMap, reflexión $diagHash"
            )
        }
        "v3.1.0" = @{
            Titulo = "Temas visuales + Internacionalización + DLLs modulares"
            Items  = @(
                "[THEME] Sistema de temas dinámicos cargado desde .\assets\themes\ vía SysOpt.ThemeEngine.dll",
                "[THEME] Barra de progreso animada al aplicar temas — parsing en runspace background",
                "[THEME] 11 temas incluidos: Default Dark/Light, IceBlue, IceCream, Manga, Matrix, PipBoy, Simpsons, Votorantim, Windows Dark/Light",
                "[I18N] Sistema de idiomas cargado desde .\assets\lang\ vía SysOpt.Core.dll (LangEngine)",
                "[I18N] Idiomas incluidos: Español, English, Português (Brasil)",
                "[I18N] Función T() — traducción centralizada con fallback al texto XAML original",
                "[DLL] SysOpt.Core.dll — LangEngine + SettingsHelper compilados como ensamblado externo en .\libs\",
                "[DLL] SysOpt.ThemeEngine.dll — ThemeEngine compilado como ensamblado externo en .\libs\",
                "[UI] Botón ⚙ Opciones en la barra superior (entre Tareas y About)",
                "[UI] Ventana de Opciones con selectores de tema e idioma + vista previa",
                "[CFG] Tema e idioma seleccionados se persisten en settings.json (%APPDATA%\SysOpt)",
                "[FIX] Símbolo © correcto en la ventana About (antes mostraba '(c)')"
            )
        }
        "v3.0.0" = @{
            Titulo = "DLL externos nativos + arquitectura modular"
            Items  = @(
                "[DLL] SysOpt.MemoryHelper.dll y SysOpt.DiskEngine.dll como ensamblados externos en .\libs\",
                "[DLL] Eliminada la compilación inline C# — tipos cargados con Add-Type -Path una sola vez",
                "[DLL] Guard de tipo compartido: DiskItem_v211, DiskItemToggle_v230, ScanCtl211, PScanner211",
                "[ARCH] Ruta de libs normalizada a .\libs\ relativa al script (PSScriptRoot)"
            )
        }
        "v2.5.0" = @{
            Titulo = "Estabilidad + Deduplicación + TaskPool"
            Items  = @(
                "[LOG] Write-Log centralizado con rotación diaria y Mutex thread-safe",
                "[ERR] Error boundary global: AppDomain + Dispatcher",
                "[B5] Deduplicación SHA256 archivos >10 MB en background",
                "[TASKPOOL] Panel de tareas async estilo torrent"
            )
        }
    }
}

# ── Alias de acceso rápido para el resto del script
$script:AppDir = $PSScriptRoot

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName WindowsBase

# ─────────────────────────────────────────────────────────────────────────────
$splashXaml = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "assets\xaml\SplashWindow.xaml"))
$splashReader = [System.Xml.XmlNodeReader]::new([xml]$splashXaml)
$splashWin    = [Windows.Markup.XamlReader]::Load($splashReader)
$splashMsg    = $splashWin.FindName("SplashMsg")
$splashBar    = $splashWin.FindName("SplashBar")
$splashWin.Show()
[System.Windows.Forms.Application]::DoEvents()   # pump WPF sin necesitar runspace

function Set-SplashProgress([int]$Pct, [string]$Msg = "") {
    if ($Msg) { $splashMsg.Text = $Msg }
    $splashBar.Width = [math]::Round(408 * [math]::Min(100,$Pct) / 100)
    [System.Windows.Forms.Application]::DoEvents()   # pump messages sin runspace
}
Set-SplashProgress 10 "Cargando ensamblados .NET..."

# =============================================================================
# CARGA DE DLL EXTERNAS  —  todas en .\libs\  relativas a PSScriptRoot
# Orden: MemoryHelper → DiskEngine → Core (CTK+DAL+i18n) → ThemeEngine → WseTrim → Optimizer → StartupManager → Diagnostics
# compile-dlls.ps1 en .\libs\ recompila todas si modificas los .cs
# =============================================================================

function script:Load-SysOptDll {
    param(
        [string]$DllPath,
        [string]$GuardType,    # tipo C# que confirma que el DLL ya está cargado
        [string]$Label,
        [switch]$Hard          # si presente, falla con throw en lugar de warn
    )

    # ── Ruta 1: SysOptFallbacks disponible → delegar completamente ───────────────
    if (([System.Management.Automation.PSTypeName]"SysOptFallbacks").Type) {
        try {
            [SysOptFallbacks]::LoadDll($DllPath, $GuardType, [bool]$Hard) | Out-Null
            Write-Verbose "SysOpt: DLL cargada: $Label"
            # Write-Log no existe aun en bootstrap; se registra en el log completo mas adelante
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log "DLL cargada: $Label" -Level DBG
            }
        } catch {
            $errMsg = "Error cargando $Label — $($_.Exception.Message)"
            Write-Warning $errMsg
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log $errMsg -Level ERR
            }
            if ($Hard) { throw }
        }
        return
    }

    # ── Ruta 2: bootstrap (antes de que Core.dll esté disponible) ────────────
    if (([System.Management.Automation.PSTypeName]$GuardType).Type) {
        Write-Verbose "SysOpt: $Label ya cargado en esta sesion"
        return
    }
    if (-not (Test-Path $DllPath)) {
        $msg = "SysOpt: $DllPath no encontrado. Ejecuta compile-dlls.ps1 en .\libs\"
        if ($Hard) { throw $msg } else { Write-Warning $msg; return }
    }
    try   { Add-Type -Path $DllPath -ErrorAction Stop }
    catch { Write-Verbose "SysOpt: $Label — Add-Type: $($_.Exception.Message)" }
}

$script:_libsDir = Join-Path $PSScriptRoot "libs"

# ── [DLL 1/7] MemoryHelper — Win32 P/Invoke para EmptyWorkingSet ─────────────
Set-SplashProgress 10 "Cargando MemoryHelper..."
Load-SysOptDll -DllPath (Join-Path $script:_libsDir "SysOpt.MemoryHelper.dll") `
               -GuardType "MemoryHelper" -Label "MemoryHelper" -Hard

# ── [DLL 2/7] DiskEngine — modelos y escaner paralelo del Explorador ──────────
# Contiene: DiskItem_v211, DiskItemToggle_v230, ScanCtl211, PScanner211
Set-SplashProgress 17 "Cargando DiskEngine..."
Load-SysOptDll -DllPath (Join-Path $script:_libsDir "SysOpt.DiskEngine.dll") `
               -GuardType "DiskItem_v211" -Label "DiskEngine" -Hard

# ── [DLL 3/7] Core — LangEngine + XamlLoader + CTK + DAL + AgentBus ──────────
# v3.2.0: añade ScanTokenManager, SystemDataCollector, modelos de datos y AgentBus
Set-SplashProgress 24 "Cargando Core (CTK + DAL)..."
Load-SysOptDll -DllPath (Join-Path $script:_libsDir "SysOpt.Core.dll") `
               -GuardType "LangEngine" -Label "Core" -Hard

# ── [DLL 4/7] ThemeEngine — parser de archivos .theme ────────────────────────
Set-SplashProgress 31 "Cargando ThemeEngine..."
Load-SysOptDll -DllPath (Join-Path $script:_libsDir "SysOpt.ThemeEngine.dll") `
               -GuardType "ThemeEngine" -Label "ThemeEngine" -Hard

# ── [DLL 5/7] WseTrim — SetProcessWorkingSetSize para trim de Working Set ─────
# Se carga aqui (inicio) en lugar de bajo demanda para errores tempranos visibles
Set-SplashProgress 38 "Cargando WseTrim..."
Load-SysOptDll -DllPath (Join-Path $script:_libsDir "SysOpt.WseTrim.dll") `
               -GuardType "WseTrim" -Label "WseTrim"
# WseTrim es no-Hard: si falta el DLL la app sigue funcionando sin trim de WS

# ── [DLL 6/7] Optimizer — OptimizerEngine + WUCacheManager + ProcessManager ──
# Contiene: OptimizeOptions, OptimizeProgress, OptimizerEngine, WUCacheManager, ProcessManager
Set-SplashProgress 45 "Cargando Optimizer..."
Load-SysOptDll -DllPath (Join-Path $script:_libsDir "SysOpt.Optimizer.dll") `
               -GuardType "SysOpt.Optimizer.OptimizerEngine" -Label "Optimizer" 

# ── [DLL 7/7] StartupManager — motor de gestión de programas de inicio ──────
# Contiene: StartupEntry, ApplyResult, StartupEngine
Set-SplashProgress 52 "Cargando StartupManager..."
Load-SysOptDll -DllPath (Join-Path $script:_libsDir "SysOpt.StartupManager.dll") `
               -GuardType "SysOpt.StartupManager.StartupEngine" -Label "StartupManager"

# ── [DLL 8/8] Diagnostics — DiagnosticsEngine (análisis del sistema y puntuación) ──
# Contiene: DiagInput, DiagItem, DiagResult, DiagnosticsEngine
Set-SplashProgress 59 "Cargando Diagnostics..."
Load-SysOptDll -DllPath (Join-Path $script:_libsDir "SysOpt.Diagnostics.dll") `
               -GuardType "SysOpt.Diagnostics.DiagnosticsEngine" -Label "Diagnostics"

# ── Inicializar CTK global ────────────────────────────────────────────────────
# ScanTokenManager reemplaza el flag booleano ScanCtl211.Stop para cancelacion
# limpia de runspaces. El token se crea aqui; cada operacion llama RequestNew().
if (([System.Management.Automation.PSTypeName]'ScanTokenManager').Type) {
    [ScanTokenManager]::RequestNew()
    Write-Verbose "SysOpt: ScanTokenManager inicializado"
} else {
    Write-Warning "SysOpt: ScanTokenManager no disponible — CTK desactivado (Core.dll v3.1?)"
}

# Ruta centralizada a los XAML externos estáticos
$script:XamlFolder = Join-Path $PSScriptRoot "assets\xaml"

Set-SplashProgress 70 "Ensamblados cargados."

# ─────────────────────────────────────────────────────────────────────────────
# [I18N] Variables globales de idioma y tema
# ─────────────────────────────────────────────────────────────────────────────
$script:LangDict       = @{}           # Diccionario clave→texto actual
$script:CurrentLang    = "es-es"       # Código del idioma activo
$script:CurrentTheme   = "default"     # Nombre del tema activo (sin extensión)
$script:ThemesDir      = Join-Path $PSScriptRoot "assets\themes"
$script:LangDir        = Join-Path $PSScriptRoot "assets\lang"

# Función T() — traducción centralizada
function T([string]$Key, [string]$Fallback = "") {
    if ($script:LangDict.ContainsKey($Key)) { return $script:LangDict[$Key] }
    if ($Fallback) { return $Fallback }
    return $Key
}

function Get-TC {
    param([string]$Key, [string]$Default = "#FFFFFF")
    if ($script:CurrentThemeColors -and $script:CurrentThemeColors.ContainsKey($Key)) {
        return $script:CurrentThemeColors[$Key]
    }
    return $Default
}

# ── Registro de ventanas flotantes que deben recibir el tema ─────────────────
# Cualquier ventana flotante (Tasks, DedupWindow…) se añade aquí al abrirse y
# se elimina al cerrarse. Apply-ThemeWithProgress itera la lista para
# propagar los TB_* brushes a sus ResourceDictionary igual que al MainWindow.
$script:ThemedWindows = [System.Collections.Generic.List[System.Windows.Window]]::new()

# ── New-ThemedWindowResources ─────────────────────────────────────────────────
# Genera un ResourceDictionary con todos los TB_* SolidColorBrushes del tema
# actual clonados desde $window.Resources, listo para asignarse a una ventana
# flotante y recibir actualizaciones posteriores de Apply-ThemeWithProgress.
function New-ThemedWindowResources {
    $rd = [System.Windows.ResourceDictionary]::new()
    foreach ($key in $window.Resources.Keys) {
        $keyStr = "$key"
        if ($keyStr -like 'TB_*') {
            $brush = $window.Resources[$key]
            if ($brush -is [System.Windows.Media.SolidColorBrush]) {
                $rd[$keyStr] = [System.Windows.Media.SolidColorBrush]::new($brush.Color)
            }
        }
    }
    return $rd
}

function Update-DynamicThemeValues {
    $tc = $script:CurrentThemeColors
    if (-not $tc -or $tc.Count -eq 0) { return }

    # Compute status colors via C# ThemeApplier
    # BuildStatusColors expects Dictionary<string,string> — convert Hashtable
    $tcDict = [System.Collections.Generic.Dictionary[string, string]]::new()
    foreach ($k in $tc.Keys) { $tcDict[$k] = [string]$tc[$k] }
    $statusColors = [ThemeApplier]::BuildStatusColors($tcDict)
    foreach ($kv in $statusColors.GetEnumerator()) { $tc[$kv.Key] = $kv.Value }

    # Update TaskStatusMap with themed colors
    $script:TaskStatusMap = @{
        running   = @{ Text = T 'StatusRunning' 'En curso';   Bg = $tc["StatusRunningBg"]; Fg = $tc["StatusRunningFg"] }
        paused    = @{ Text = T 'StatusPaused'  'Pausada';    Bg = $tc["StatusCancelBg"];  Fg = $tc["StatusCancelFg"] }
        done      = @{ Text = T 'StatusDone' 'Completada';    Bg = $tc["StatusDoneBg"];    Fg = $tc["StatusDoneFg"] }
        error     = @{ Text = T 'StatusError' 'Error';        Bg = $tc["StatusErrorBg"];   Fg = $tc["StatusErrorFg"] }
        cancelled = @{ Text = T 'StatusCancel' 'Cancelada';   Bg = $tc["StatusCancelBg"];  Fg = $tc["StatusCancelFg"] }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Reutiliza runspaces entre operaciones async (exportar, cargar entries, top-files)
# eliminando el overhead de arranque (~2-5 MB por runspace) y la carga de módulos.
# Pool de 1 mín / 3 máx runspaces. Se abre una sola vez al inicio.
# ─────────────────────────────────────────────────────────────────────────────
$script:RunspacePool = $null
function Initialize-RunspacePool {
    if ($null -ne $script:RunspacePool -and $script:RunspacePool.RunspacePoolStateInfo.State -eq 'Opened') { return }
    try {
        $iss  = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
        $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 3, $iss, $Host)
        $pool.ApartmentState = [System.Threading.ApartmentState]::MTA
        $pool.Open()
        $script:RunspacePool = $pool
        [SysOptFallbacks]::RunspacePoolAvailable = $true
        Write-Log "RunspacePool abierto (1-3 runspaces)" -Level DBG
    } catch {
        Write-Verbose "SysOpt: RunspacePool init failed — will fallback to individual runspaces. $_"
        $script:RunspacePool = $null
        [SysOptFallbacks]::RunspacePoolAvailable = $false
    }
}

# Helper para crear PowerShell asignado al pool (o runspace individual como fallback)
function New-PooledPS {
    Initialize-RunspacePool
    $ps = [System.Management.Automation.PowerShell]::Create()
    if ([SysOptFallbacks]::RunspacePoolAvailable -and $null -ne $script:RunspacePool) {
        $ps.RunspacePool = $script:RunspacePool
        return @{ PS = $ps; RS = $null }
    } else {
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.ApartmentState = "MTA"; $rs.Open()
        $ps.Runspace = $rs
        return @{ PS = $ps; RS = $rs }
    }
}

# Helper para dispose limpio de PS+RS (RS puede ser $null si usó pool)
function Dispose-PooledPS($ctx) {
    try { $ctx.PS.Dispose() } catch {}
    if ($null -ne $ctx.RS) { try { $ctx.RS.Close(); $ctx.RS.Dispose() } catch {} }
}

# ─────────────────────────────────────────────────────────────────────────────
function Invoke-AggressiveGC {
    try {
        [Runtime.GCSettings]::LargeObjectHeapCompactionMode = `
            [Runtime.GCLargeObjectHeapCompactionMode]::CompactOnce
        [GC]::Collect(2, [GCCollectionMode]::Forced, $true, $true)
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect(2, [GCCollectionMode]::Forced, $true, $true)
        # EmptyWorkingSet en el proceso actual
        $h = [MemoryHelper]::OpenProcess(0x1F0FFF, $false, [Diagnostics.Process]::GetCurrentProcess().Id)
        if ($h -ne [IntPtr]::Zero) {
            [MemoryHelper]::EmptyWorkingSet($h) | Out-Null
            [MemoryHelper]::CloseHandle($h) | Out-Null
        }
    } catch {}
}

# ─────────────────────────────────────────────────────────────────────────────
# Verificar permisos de administrador
# ─────────────────────────────────────────────────────────────────────────────
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    [System.Windows.MessageBox]::Show(
        "Este programa requiere permisos de administrador.`n`nPor favor, ejecuta PowerShell como administrador y vuelve a intentarlo.",
        "Permisos Insuficientes",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    )
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
[SysOptFallbacks]::InitMutex("Global\OptimizadorSistemaGUI_v5")
if (-not [SysOptFallbacks]::AcquireMutex()) {
    [System.Windows.MessageBox]::Show(
        "Ya hay una instancia del Optimizador en ejecución.`n`nCierra la ventana existente antes de abrir una nueva.",
        "Ya en ejecución",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning
    )
    exit
}

Set-SplashProgress 40 "Analizando permisos..."

# ─────────────────────────────────────────────────────────────────────────────
# XAML — Interfaz Gráfica v1.0
# ─────────────────────────────────────────────────────────────────────────────
$xaml = [XamlLoader]::Load($script:XamlFolder, "MainWindow")

# ─────────────────────────────────────────────────────────────────────────────
# Cargar XAML y obtener controles
# ─────────────────────────────────────────────────────────────────────────────
Set-SplashProgress 65 "Construyendo interfaz gráfica..."
$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
Set-SplashProgress 85 "Enlazando controles..."
Initialize-RunspacePool

# ─────────────────────────────────────────────────────────────────────────────
# [ERR] Error boundary global — captura excepciones no controladas de runspaces
# y del hilo UI. Loguea el error y muestra un diálogo amigable en lugar de
# que el proceso muera silenciosamente o con un crash report crudo de PowerShell.
# ─────────────────────────────────────────────────────────────────────────────

# Handler para excepciones no controladas en cualquier hilo/runspace
$script:UnhandledExHandler = [System.UnhandledExceptionEventHandler]{
    param($sender, $e)
    $ex  = $e.ExceptionObject
    $msg = if ($ex -is [Exception]) { $ex.Message } else { $ex.ToString() }
    $stack = if ($ex -is [Exception] -and $ex.StackTrace) { "`n$($ex.StackTrace)" } else { "" }
    try { Write-Log "[ERR-GLOBAL] $msg$stack" -Level "CRIT" -NoUI } catch {}
    # Intentar mostrar diálogo si el Dispatcher sigue vivo
    try {
        $window.Dispatcher.Invoke([action]{
            $body = "SysOpt ha detectado un error inesperado en un proceso en segundo plano.`n`n$msg`n`nLa aplicación intentará continuar. Si el problema persiste, revisa el log en .\logs\"
            Show-ThemedDialog -Title "Error inesperado" -Message $body -Type "error"
        })
    } catch {}
}
[System.AppDomain]::CurrentDomain.add_UnhandledException($script:UnhandledExHandler)

# Handler para excepciones no controladas en el hilo del Dispatcher de WPF
$script:DispatcherExHandler = [System.Windows.Threading.DispatcherUnhandledExceptionEventHandler]{
    param($sender, $e)
    $msg   = $e.Exception.Message
    $stack = if ($e.Exception.StackTrace) { "`n$($e.Exception.StackTrace)" } else { "" }
    try { Write-Log "[ERR-DISPATCHER] $msg$stack" -Level "CRIT" } catch {}
    try {
        Show-ThemedDialog -Title "Error de interfaz" `
            -Message "Error inesperado en la interfaz gráfica.`n`n$msg`n`nLa aplicación intentará continuar. Revisa el log en .\logs\" `
            -Type "error"
    } catch {}
    $e.Handled = $true   # evitar que WPF cierre la ventana
}
$window.Dispatcher.add_UnhandledException($script:DispatcherExHandler)

$StatusText    = $window.FindName("StatusText")
$ConsoleOutput = $window.FindName("ConsoleOutput")
$ProgressBar   = $window.FindName("ProgressBar")
$ProgressText  = $window.FindName("ProgressText")
$TaskText      = $window.FindName("TaskText")

# Info panel
$InfoCPU       = $window.FindName("InfoCPU")
$InfoRAM       = $window.FindName("InfoRAM")
$InfoDisk      = $window.FindName("InfoDisk")
$btnRefreshInfo= $window.FindName("btnRefreshInfo")
$CpuPctText    = $window.FindName("CpuPctText")
$RamPctText    = $window.FindName("RamPctText")
$DiskPctText   = $window.FindName("DiskPctText")
$CpuChart      = $window.FindName("CpuChart")
$RamChart      = $window.FindName("RamChart")
$DiskChart     = $window.FindName("DiskChart")

# Checkboxes
$chkDryRun          = $window.FindName("chkDryRun")
$chkOptimizeDisks   = $window.FindName("chkOptimizeDisks")
$chkRecycleBin      = $window.FindName("chkRecycleBin")
$chkTempFiles       = $window.FindName("chkTempFiles")
$chkUserTemp        = $window.FindName("chkUserTemp")
$chkWUCache         = $window.FindName("chkWUCache")
$chkChkdsk          = $window.FindName("chkChkdsk")
$chkClearMemory     = $window.FindName("chkClearMemory")
$chkCloseProcesses  = $window.FindName("chkCloseProcesses")
$chkDNSCache        = $window.FindName("chkDNSCache")
$chkBrowserCache    = $window.FindName("chkBrowserCache")
$chkBackupRegistry  = $window.FindName("chkBackupRegistry")
$chkCleanRegistry   = $window.FindName("chkCleanRegistry")
$chkSFC             = $window.FindName("chkSFC")
$chkDISM            = $window.FindName("chkDISM")
$chkEventLogs       = $window.FindName("chkEventLogs")
$chkShowStartup     = $window.FindName("chkShowStartup")
$chkAutoRestart     = $window.FindName("chkAutoRestart")

# Botones
$btnSelectAll  = $window.FindName("btnSelectAll")
$btnDryRun     = $window.FindName("btnDryRun")
$btnStart      = $window.FindName("btnStart")
$btnCancel     = $window.FindName("btnCancel")
$btnSaveLog    = $window.FindName("btnSaveLog")
$btnExit       = $window.FindName("btnExit")
$btnAbout      = $window.FindName("btnAbout")
$btnOptions    = $window.FindName("btnOptions")

# Output panel controls
$OutputPanel      = $window.FindName("OutputPanel")
$btnOutputClose   = $window.FindName("btnOutputClose")
$btnOutputMinimize= $window.FindName("btnOutputMinimize")
$btnOutputExpand  = $window.FindName("btnOutputExpand")
$btnShowOutput    = $window.FindName("btnShowOutput")

# ── Estado del panel Output ──────────────────────────────────────────────────
$script:OutputState   = "normal"   # "normal" | "minimized" | "hidden" | "expanded"
$script:OutputNormalH = 200        # altura normal en píxeles

function Set-OutputState {
    param([string]$State)
    # Obtener el RowDefinition del Grid padre por índice 3
    $mainGrid = $OutputPanel.Parent
    $outputRowDef = $mainGrid.RowDefinitions[3]

    switch ($State) {
        "hidden" {
            $OutputPanel.Visibility = [System.Windows.Visibility]::Collapsed
            $outputRowDef.Height = [System.Windows.GridLength]::new(0)
            $btnShowOutput.Visibility = [System.Windows.Visibility]::Visible
            $script:OutputState = "hidden"
        }
        "minimized" {
            $OutputPanel.Visibility = [System.Windows.Visibility]::Visible
            $outputRowDef.Height = [System.Windows.GridLength]::new(36)
            $btnShowOutput.Visibility = [System.Windows.Visibility]::Collapsed
            $script:OutputState = "minimized"
        }
        "expanded" {
            $OutputPanel.Visibility = [System.Windows.Visibility]::Visible
            $outputRowDef.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
            $btnShowOutput.Visibility = [System.Windows.Visibility]::Collapsed
            $script:OutputState = "expanded"
        }
        default {   # "normal"
            $OutputPanel.Visibility = [System.Windows.Visibility]::Visible
            $outputRowDef.Height = [System.Windows.GridLength]::new($script:OutputNormalH)
            $btnShowOutput.Visibility = [System.Windows.Visibility]::Collapsed
            $script:OutputState = "normal"
        }
    }
}

$btnOutputClose.Add_Click({ Set-OutputState "hidden" })
$btnOutputMinimize.Add_Click({
    if ($script:OutputState -eq "minimized") { Set-OutputState "normal" } else { Set-OutputState "minimized" }
})
$btnOutputExpand.Add_Click({
    if ($script:OutputState -eq "expanded") { Set-OutputState "normal" } else { Set-OutputState "expanded" }
})
$btnShowOutput.Add_Click({ Set-OutputState "normal" })

# ─────────────────────────────────────────────────────────────────────────────
# DIÁLOGOS TEMÁTICOS — reemplazan MessageBox y InputBox del sistema
# Tipos: "info" | "warning" | "error" | "success" | "question"
# ─────────────────────────────────────────────────────────────────────────────
function Show-ThemedDialog {
    param(
        [string]$Title,
        [string]$Message,
        [ValidateSet("info","warning","error","success","question")]
        [string]$Type = "info",
        [ValidateSet("OK","YesNo")]
        [string]$Buttons = "OK"
    )

    $iconChar  = switch ($Type) {
        "info"     { "ℹ" }
        "warning"  { "⚠" }
        "error"    { "✕" }
        "success"  { "✓" }
        "question" { "?" }
    }
    $accentColor = switch ($Type) {
        "info"     { "#5BA3FF" }
        "warning"  { "#FFB547" }
        "error"    { "#FF6B84" }
        "success"  { "#4AE896" }
        "question" { "#9B7EFF" }
    }
    # accentBg: usa claves de tema para que sea compatible con temas claros y oscuros
    $accentBg = switch ($Type) {
        "info"     { Get-TC 'DryRunBg'       '#0D1E35' }
        "warning"  { Get-TC 'BgStatusWarn'   '#2B1E0A' }
        "error"    { Get-TC 'BgStatusErr'    '#2B0D12' }
        "success"  { Get-TC 'BgStatusOk'     '#0D2B1A' }
        "question" { Get-TC 'BgStatusWarn' '#2A2010' }
    }

    # Escapar caracteres especiales XML para evitar romper el XAML
    $Title   = $Title   -replace '&','&amp;' -replace '"','&quot;' -replace "'","&apos;" -replace '<','&lt;' -replace '>','&gt;'
    $Message = $Message -replace '&','&amp;' -replace '"','&quot;' -replace "'","&apos;" -replace '<','&lt;' -replace '>','&gt;'

    $btnOkXaml = if ($Buttons -eq "OK") {
        "<Button Name=`"btnOK`" Content=`"Aceptar`" Width=`"100`" Height=`"34`" Margin=`"0`"
                 Background=`"$accentColor`" Foreground=`"$(Get-TC 'BgDeep' '#0D0F1A')`" BorderThickness=`"0`"
                 FontWeight=`"Bold`" FontSize=`"12`" Cursor=`"Hand`" IsDefault=`"True`"/>"
    } else {
        "<StackPanel Orientation=`"Horizontal`" HorizontalAlignment=`"Right`" Margin=`"0`">
            <Button Name=`"btnNo`"  Content=`"No`"  Width=`"90`" Height=`"34`" Margin=`"0,0,8,0`"
                    Background=`"$(Get-TC 'BtnSecondaryBg' '#1A1E2F')`" Foreground=`"$(Get-TC 'TextMuted' '#7880A0')`"
                    BorderBrush=`"$(Get-TC 'BorderSubtle' '#252B40')`" BorderThickness=`"1`"
                    FontSize=`"12`" Cursor=`"Hand`" IsCancel=`"True`"/>
            <Button Name=`"btnYes`" Content=`"Sí`"  Width=`"90`" Height=`"34`"
                    Background=`"$accentColor`" Foreground=`"$(Get-TC 'BgDeep' '#0D0F1A')`" BorderThickness=`"0`"
                    FontWeight=`"Bold`" FontSize=`"12`" Cursor=`"Hand`" IsDefault=`"True`"/>
        </StackPanel>"
    }

    $dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="" Width="420" SizeToContent="Height"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent"
        Topmost="True">
    <Border Background="$(Get-TC 'BgCardDark' '#131625')" CornerRadius="12"
            BorderBrush="$accentColor" BorderThickness="1">
        <Border.Effect>
            <DropShadowEffect BlurRadius="30" ShadowDepth="0" Opacity="0.6" Color="$(Get-TC 'ConsoleBg' '#000000')"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Header con icono y título -->
            <Border Grid.Row="0" Background="$accentBg" CornerRadius="11,11,0,0"
                    BorderBrush="$accentColor" BorderThickness="0,0,0,1" Padding="20,16">
                <StackPanel Orientation="Horizontal">
                    <Border Width="32" Height="32" CornerRadius="8"
                            Background="$accentColor" Margin="0,0,14,0" VerticalAlignment="Center">
                        <TextBlock Text="$iconChar" FontSize="16" FontWeight="Bold"
                                   Foreground="$(Get-TC 'BgDeep' '#0D0F1A')"
                                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <TextBlock Text="$Title" FontSize="14" FontWeight="Bold"
                               Foreground="$(Get-TC 'TextPrimary' '#E8ECF4')" VerticalAlignment="Center"
                               FontFamily="Syne, Segoe UI"/>
                </StackPanel>
            </Border>

            <!-- Mensaje -->
            <Border Grid.Row="1" Padding="22,18,22,14">
                <TextBlock Text="$Message" Foreground="$(Get-TC 'TextSecondary' '#B0BACC')" FontSize="12.5"
                           TextWrapping="Wrap" LineHeight="20"
                           FontFamily="Segoe UI"/>
            </Border>

            <!-- Botones -->
            <Border Grid.Row="2" Padding="22,0,22,18">
                $btnOkXaml
            </Border>
        </Grid>
    </Border>
</Window>
"@

    $dlgReader = [System.Xml.XmlNodeReader]::new([xml]$dlgXaml)
    $dlg = [Windows.Markup.XamlReader]::Load($dlgReader)
    try { $dlg.Owner = $window } catch {}

    $result = $false
    if ($Buttons -eq "OK") {
        $dlg.FindName("btnOK").Add_Click({ $dlg.DialogResult = $true; $dlg.Close() })
    } else {
        $script:_themedDlgRef = $dlg
        $dlg.FindName("btnYes").Add_Click({ $script:_dlgResult = $true;  $script:_themedDlgRef.Close() })
        $dlg.FindName("btnNo").Add_Click({  $script:_dlgResult = $false; $script:_themedDlgRef.Close() })
    }

    # Arrastrar la ventana por cualquier parte
    $script:_themedDlgRef = $dlg
    $dlg.Add_MouseLeftButtonDown({ $script:_themedDlgRef.DragMove() })

    $script:_dlgResult = $false
    $dlg.ShowDialog() | Out-Null
    return $script:_dlgResult
}

function Show-ThemedInput {
    param(
        [string]$Title,
        [string]$Prompt,
        [string]$Default = ""
    )

    # Escapar caracteres especiales XML para evitar romper el XAML
    $Title  = $Title  -replace '&','&amp;' -replace '"','&quot;' -replace "'","&apos;" -replace '<','&lt;' -replace '>','&gt;'
    $Prompt = $Prompt -replace '&','&amp;' -replace '"','&quot;' -replace "'","&apos;" -replace '<','&lt;' -replace '>','&gt;'

    $dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="" Width="440" SizeToContent="Height"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent"
        Topmost="True">
    <Border Background="$(Get-TC 'BgCardDark' '#131625')" CornerRadius="12"
            BorderBrush="$(Get-TC 'AccentBlue' '#5BA3FF')" BorderThickness="1">
        <Border.Effect>
            <DropShadowEffect BlurRadius="30" ShadowDepth="0" Opacity="0.6" Color="$(Get-TC 'ConsoleBg' '#000000')"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Header -->
            <Border Grid.Row="0" Background="$(Get-TC 'DryRunBg' '#0D1E35')" CornerRadius="11,11,0,0"
                    BorderBrush="$(Get-TC 'AccentBlue' '#5BA3FF')" BorderThickness="0,0,0,1" Padding="20,16">
                <StackPanel Orientation="Horizontal">
                    <Border Width="32" Height="32" CornerRadius="8"
                            Background="$(Get-TC 'AccentBlue' '#5BA3FF')" Margin="0,0,14,0" VerticalAlignment="Center">
                        <TextBlock Text="✎" FontSize="16" FontWeight="Bold"
                                   Foreground="$(Get-TC 'BgDeep' '#0D0F1A')"
                                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <TextBlock Text="$Title" FontSize="14" FontWeight="Bold"
                               Foreground="$(Get-TC 'TextPrimary' '#E8ECF4')" VerticalAlignment="Center"
                               FontFamily="Syne, Segoe UI"/>
                </StackPanel>
            </Border>

            <!-- Prompt -->
            <Border Grid.Row="1" Padding="22,16,22,8">
                <TextBlock Text="$Prompt" Foreground="$(Get-TC 'TextSecondary' '#B0BACC')" FontSize="12"
                           TextWrapping="Wrap" FontFamily="Segoe UI"/>
            </Border>

            <!-- TextBox -->
            <Border Grid.Row="2" Padding="22,0,22,16">
                <TextBox Name="txtInput"
                         Background="$(Get-TC 'BgDeep' '#0D0F1A')" Foreground="$(Get-TC 'TextPrimary' '#E8ECF4')"
                         BorderBrush="$(Get-TC 'BorderSubtle' '#2A3448')" BorderThickness="1"
                         CaretBrush="$(Get-TC 'AccentBlue' '#5BA3FF')" SelectionBrush="$(Get-TC 'ComboSelected' '#1A3A5C')"
                         FontSize="13" Padding="10,8"
                         FontFamily="JetBrains Mono, Consolas"/>
            </Border>

            <!-- Botones -->
            <Border Grid.Row="3" Padding="22,0,22,18">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                    <Button Name="btnCancel" Content="Cancelar" Width="100" Height="34" Margin="0,0,8,0"
                            Background="$(Get-TC 'BgInput' '#1A1E2F')" Foreground="$(Get-TC 'TextMuted' '#7880A0')" BorderBrush="$(Get-TC 'BorderSubtle' '#252B40')" BorderThickness="1"
                            FontSize="12" Cursor="Hand" IsCancel="True"/>
                    <Button Name="btnOK" Content="Aceptar" Width="100" Height="34"
                            Background="$(Get-TC 'AccentBlue' '#5BA3FF')" Foreground="$(Get-TC 'BgDeep' '#0D0F1A')" BorderThickness="0"
                            FontWeight="Bold" FontSize="12" Cursor="Hand" IsDefault="True"/>
                </StackPanel>
            </Border>
        </Grid>
    </Border>
</Window>
"@

    $dlgReader = [System.Xml.XmlNodeReader]::new([xml]$dlgXaml)
    $dlg = [Windows.Markup.XamlReader]::Load($dlgReader)
    try { $dlg.Owner = $window } catch {}

    $txtInput = $dlg.FindName("txtInput")
    $txtInput.Text = $Default
    $txtInput.SelectAll()

    # Guardar referencias en $script: para que los closures de Add_Click puedan accederlas
    $script:_themedInputDlg = $dlg
    $script:_themedInputTxt = $txtInput

    $dlg.Add_MouseLeftButtonDown({ $script:_themedInputDlg.DragMove() })
    $dlg.Add_ContentRendered({ $script:_themedInputTxt.Focus() })

    $script:_inputResult = $null
    $dlg.FindName("btnOK").Add_Click({
        $script:_inputResult = $script:_themedInputTxt.Text
        $script:_themedInputDlg.Close()
    })
    $dlg.FindName("btnCancel").Add_Click({
        $script:_inputResult = $null
        $script:_themedInputDlg.Close()
    })

    $dlg.ShowDialog() | Out-Null
    return $script:_inputResult
}

# ─────────────────────────────────────────────────────────────────────────────
# Directorio raíz de la aplicación — ruta canónica usada en todo el script
# ─────────────────────────────────────────────────────────────────────────────
$script:AppDir = if ($PSScriptRoot -and $PSScriptRoot -ne '') {
    $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    (Get-Location).Path
}

# ─────────────────────────────────────────────────────────────────────────────
# Cargar logo desde .\assets\img\sysopt.png e icono de ventana desde .\assets\img\sysops.ico
# ─────────────────────────────────────────────────────────────────────────────
$imgLogo = $window.FindName("imgLogo")
try {
    $logoPath = Join-Path $script:AppDir "assets\img\sysopt.png"
    if (Test-Path $logoPath) {
        $logoBitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $logoBitmap.BeginInit()
        $logoBitmap.UriSource   = [Uri]::new($logoPath, [UriKind]::Absolute)
        $logoBitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $logoBitmap.EndInit()
        $imgLogo.Source = $logoBitmap
    }
} catch {
    Write-Verbose "SysOpt: No se pudo cargar el logo — $($_.Exception.Message)"
}

# Icono de la ventana principal (barra de tareas y Alt+Tab)
try {
    $icoPath = Join-Path $script:AppDir "assets\img\sysops.ico"
    if (Test-Path $icoPath) {
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create(
            [Uri]::new($icoPath, [UriKind]::Absolute))
    }
} catch {
    Write-Verbose "SysOpt: No se pudo cargar el icono — $($_.Exception.Message)"
}

# Estado de cancelación
$script:CancelSource = $null
$script:WasCancelled = $false

# ─────────────────────────────────────────────────────────────────────────────
# [LOG] Logging estructurado — archivo rotante diario + consola UI
# Ruta: .\logs\SysOpt_YYYY-MM-DD.log  (relativo al script)
# Niveles: INFO (por defecto), WARN, ERROR
# Thread-safe: StreamWriter con mutex de nombre para acceso concurrente
# ─────────────────────────────────────────────────────────────────────────────
# ── [LOG] Logger delegado a LogEngine (SysOpt.Core.dll) ─────────────────────
# LogEngine es thread-safe, soporta rotación diaria y mutex con nombre.
# Write-Log e Initialize-Logger mantienen la misma firma pública para que
# el resto del script no necesite cambios.
# ─────────────────────────────────────────────────────────────────────────────

function Initialize-Logger {
    try {
        $logsDir = Join-Path $script:AppDir "logs"
        [LogEngine]::Initialize($logsDir)
        [LogEngine]::Header("SysOpt", $script:AppVersion)
    } catch {
        # LogEngine no disponible aún (carga inicial antes de DLLs) — silencioso
    }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("DBG","INFO","WARN","ERR","CRIT","UI")][string]$Level = "INFO",
        [switch]$NoUI    # si $true, solo va al archivo (llamadas desde runspaces)
    )
    $timestamp = Get-Date -Format "HH:mm:ss"

    # ── Escribir al archivo vía LogEngine ───────────────────────────────────
    try { [LogEngine]::Write($Message, $Level) } catch {}

    # ── Consola UI (solo hilo principal) ────────────────────────────────────
    if ($Level -eq "UI" -and $null -ne $ConsoleOutput) {
        try { $ConsoleOutput.AppendText("$Message`n"); $ConsoleOutput.ScrollToEnd() } catch {}
    } elseif (-not $NoUI -and $null -ne $ConsoleOutput) {
        try { $ConsoleOutput.AppendText("[$timestamp] $Message`n"); $ConsoleOutput.ScrollToEnd() } catch {}
    }
}

# Write-ConsoleMain — mensajes puramente visuales: van a la consola de pantalla pero NO
# al archivo de log. Usa nivel "UI" para separar instrucciones decorativas de eventos reales.
function Write-ConsoleMain {
    param([string]$Message)
    Write-Log -Message $Message -Level "UI"
}

# Inicializar el logger en cuanto AppDir esté disponible
Initialize-Logger

# ─────────────────────────────────────────────────────────────────────────────
# [BOOT] Auditoría de DLL — registra en el log qué ensamblados están cargados,
# desde qué ruta física y su versión. Detecta si alguna DLL esperada falta o
# fue cargada desde una ruta distinta a .\libs\ (p.ej. GAC o sesión anterior).
# ─────────────────────────────────────────────────────────────────────────────
try {
    $expectedDlls = @(
        @{ Guard = 'MemoryHelper';       Dll = 'SysOpt.MemoryHelper.dll'  },
        @{ Guard = 'DiskItem_v211';      Dll = 'SysOpt.DiskEngine.dll'    },
        @{ Guard = 'LangEngine';         Dll = 'SysOpt.Core.dll'          },
        @{ Guard = 'ScanTokenManager';   Dll = 'SysOpt.Core.dll'          },
        @{ Guard = 'SystemDataCollector';Dll = 'SysOpt.Core.dll'          },
        @{ Guard = 'ThemeEngine';        Dll = 'SysOpt.ThemeEngine.dll'   },
        @{ Guard = 'WseTrim';            Dll = 'SysOpt.WseTrim.dll'       },
        @{ Guard = 'SysOpt.Optimizer.OptimizerEngine'; Dll = 'SysOpt.Optimizer.dll' },
        @{ Guard = 'SysOpt.StartupManager.StartupEngine'; Dll = 'SysOpt.StartupManager.dll' },
        @{ Guard = 'SysOpt.Diagnostics.DiagnosticsEngine'; Dll = 'SysOpt.Diagnostics.dll' }
    )

    Write-Log "── Auditoría de ensamblados ──────────────────────────────" -Level "DBG" -NoUI
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($entry in $expectedDlls) {
        $type = ([System.Management.Automation.PSTypeName]$entry.Guard).Type
        if ($null -ne $type) {
            $asm      = $type.Assembly
            $location = $asm.Location
            $version  = $asm.GetName().Version.ToString()

            # Verificar que la ruta coincide con .\libs\ esperado
            $expectedPath = Join-Path $script:_libsDir $entry.Dll
            $fromExpected = $location -and ([System.IO.Path]::GetFullPath($location) -eq [System.IO.Path]::GetFullPath($expectedPath))
            $srcNote      = if ($fromExpected) { "OK" } elseif ($asm.GlobalAssemblyCache) { "GAC" } else { "RUTA DISTINTA" }

            # Solo loggear cada DLL física una vez (Core.dll tiene 3 tipos guard)
            if ($seen.Add($location)) {
                Write-Log ("[DLL] {0,-28} v{1}  [{2}]  {3}" -f $entry.Dll, $version, $srcNote, $location) -Level "DBG" -NoUI
            }
        } else {
            Write-Log ("[DLL] {0,-28} NO CARGADA — tipo '{1}' no encontrado" -f $entry.Dll, $entry.Guard) -Level "WARN" -NoUI
        }
    }

    # Extra: detectar DLLs SysOpt.*.dll en AppDomain que no estén en la lista esperada
    $allAsm = [System.AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -like 'SysOpt.*' }
    foreach ($asm in $allAsm) {
        $loc = $asm.Location
        if ($loc -and -not $seen.Contains($loc)) {
            Write-Log ("[DLL] {0,-28} v{1}  [EXTRA]  {2}" -f $asm.GetName().Name, $asm.GetName().Version, $loc) -Level "WARN" -NoUI
        }
    }

    # Auto-detección: escanear libs/ en busca de SysOpt.*.dll que existan en disco
    # pero NO estén cargadas en el AppDomain — captura DLLs nuevas no registradas
    $expectedFileNames = $expectedDlls | ForEach-Object { $_.Dll } | Sort-Object -Unique
    $diskDlls = Get-ChildItem -Path $script:_libsDir -Filter "SysOpt.*.dll" -File -ErrorAction SilentlyContinue
    foreach ($diskDll in $diskDlls) {
        if ($diskDll.Name -notin $expectedFileNames -and -not $seen.Contains($diskDll.FullName)) {
            Write-Log ("[DLL] {0,-28} [EN DISCO NO CARGADA] {1}" -f $diskDll.Name, $diskDll.FullName) -Level "WARN" -NoUI
            Write-Log "      ↳ Añade esta DLL a la sección de carga y a `$expectedDlls en la auditoría" -Level "WARN" -NoUI
        }
    }

    Write-Log "── Fin auditoría ─────────────────────────────────────────" -Level "DBG" -NoUI
} catch {
    Write-Log "[DLL] Error en auditoría de ensamblados: $($_.Exception.Message)" -Level "WARN" -NoUI
}

# ─────────────────────────────────────────────────────────────────────────────
# [TASKPOOL] Registro centralizado de tareas async — alimenta la pestaña ⚡ Tareas
# Cada operación async (escaneo, export, snapshot, dedup...) se registra aquí.
# La pestaña la lee cada segundo desde un DispatcherTimer.
# ─────────────────────────────────────────────────────────────────────────────
$script:TaskPool = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
$script:TaskIdSeq = 0

function Register-Task {
    param(
        [string]$Id,        # clave única (p.ej. "scan", "csv", "dedup")
        [string]$Name,      # nombre visible
        [string]$Icon = "⚙",
        [string]$IconBg = "#1A2040"
    )
    $task = [System.Collections.Hashtable]::Synchronized(@{
        Id         = $Id
        Name       = $Name
        Icon       = $Icon
        IconBg     = $IconBg
        Status     = "running"   # running | done | error | cancelled | paused
        Pct        = 0
        Detail     = ""
        StartTime  = [datetime]::Now
        EndTime    = $null
        # ── Hooks de control (poblados por quien lanza la tarea) ─────────────
        CancelFn   = $null       # ScriptBlock: cancela la tarea
        PauseFn    = $null       # ScriptBlock: pausa  (solo diskscan)
        ResumeFn   = $null       # ScriptBlock: reanuda (solo diskscan)
        Paused     = $false
    })
    $script:TaskPool[$Id] = $task
    Write-Log "[TASK] Iniciada: $Name" -Level "DBG" -NoUI
    return $task
}

function Complete-Task {
    param([string]$Id, [switch]$IsError, [string]$Detail = "")
    if ($script:TaskPool.ContainsKey($Id)) {
        $t = $script:TaskPool[$Id]
        $t.Status  = if ($IsError) { "error" } else { "done" }
        $t.Pct     = if ($IsError) { $t.Pct } else { 100 }
        $t.Detail  = if ($Detail) { $Detail } else { $t.Detail }
        $t.EndTime = [datetime]::Now
        Write-Log "[TASK] Completada ($($t.Status)): $($t.Name)" -Level $(if($IsError){"WARN"}else{"DBG"}) -NoUI
    }
}

function Update-Task {
    param([string]$Id, [int]$Pct = -1, [string]$Detail = "")
    if ($script:TaskPool.ContainsKey($Id)) {
        $t = $script:TaskPool[$Id]
        if ($Pct -ge 0)  { $t.Pct    = [math]::Min(99, $Pct) }
        if ($Detail)     { $t.Detail = $Detail }
    }
}
# Todas las llamadas Get-CimInstance del hilo UI la reutilizan.
# Si WMI está dañado o tarda más de 5 s, el timeout evita que la UI se congele.
# La sesión se crea lazy al primer uso y se recrea automáticamente si muere.
# ─────────────────────────────────────────────────────────────────────────────
$script:CimSession = $null

function Get-SharedCimSession {
    if ($null -ne $script:CimSession) {
        try {
            # Comprobar que la sesión sigue viva con una consulta trivial
            $null = Get-CimInstance -CimSession $script:CimSession `
                        -ClassName Win32_LocalTime -ErrorAction Stop |
                        Select-Object -First 1
            return $script:CimSession
        } catch {
            try { $script:CimSession | Remove-CimSession -ErrorAction SilentlyContinue } catch {}
            $script:CimSession = $null
        }
    }
    try {
        $opts = New-CimSessionOption -Protocol Dcom
        $script:CimSession = New-CimSession -ComputerName localhost `
                                -SessionOption $opts `
                                -OperationTimeoutSec 5 `
                                -ErrorAction Stop
        Write-Log "[WMI] CimSession creada (timeout=5s)" -Level "DBG" -NoUI
    } catch {
        Write-Log "[WMI] No se pudo crear CimSession: $($_.Exception.Message)" -Level "WARN" -NoUI
        $script:CimSession = $null
    }
    return $script:CimSession
}

# Helper: Get-CimInstance con sesión compartida y timeout — reemplaza las llamadas directas
function Invoke-CimQuery {
    param(
        [string]$ClassName,
        [string]$Filter       = "",
        [string[]]$Property   = @(),
        [switch]$SilentOnFail
    )
    $session = Get-SharedCimSession
    $params  = @{ ClassName = $ClassName; ErrorAction = if ($SilentOnFail) { "SilentlyContinue" } else { "Stop" } }
    if ($session)          { $params.CimSession = $session }
    if ($Filter)           { $params.Filter     = $Filter  }
    if ($Property.Count)   { $params.Property   = $Property }
    try {
        return Get-CimInstance @params
    } catch {
        Write-Log "[WMI] Error en $ClassName : $($_.Exception.Message)" -Level "WARN" -NoUI
        # Invalidar sesión para que se recree en el próximo intento
        try { $script:CimSession | Remove-CimSession -ErrorAction SilentlyContinue } catch {}
        $script:CimSession = $null
        if (-not $SilentOnFail) { throw }
        return $null
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Chart history buffers (60 samples each)
# ─────────────────────────────────────────────────────────────────────────────
$script:CpuHistory  = [System.Collections.Generic.List[double]]::new()
$script:RamHistory  = [System.Collections.Generic.List[double]]::new()
$script:DiskHistory = [System.Collections.Generic.List[double]]::new()
$script:DiskCounter = $null

# Pre-init disk counter
try {
    $script:DiskCounter = New-Object System.Diagnostics.PerformanceCounter("PhysicalDisk","% Disk Time","_Total",$false)
    $null = $script:DiskCounter.NextValue()   # first call always 0, warm up
} catch { $script:DiskCounter = $null }

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Draw sparkline chart on a WPF Canvas
# ─────────────────────────────────────────────────────────────────────────────
function Draw-SparkLine {
    param(
        [System.Windows.Controls.Canvas]$Canvas,
        [System.Collections.Generic.List[double]]$Data,
        [string]$LineColor,
        [string]$FillColor
    )

    $Canvas.Children.Clear()
    $w = $Canvas.ActualWidth
    $h = $Canvas.ActualHeight
    if ($w -le 0 -or $h -le 0) { $w = 300; $h = 52 }

    $maxPoints = 60
    $pts = $Data.ToArray()
    if ($pts.Count -eq 0) { return }

    $step = if ($pts.Count -gt 1) { $w / ($maxPoints - 1) } else { $w }
    $startIdx = [Math]::Max(0, $pts.Count - $maxPoints)
    $visible = $pts[$startIdx..($pts.Count - 1)]

    # Grid lines at 25%, 50%, 75%
    foreach ($gridPct in @(25, 50, 75)) {
        $gy = $h - ($gridPct / 100.0 * $h)
        $line = New-Object System.Windows.Shapes.Line
        $line.X1 = 0; $line.X2 = $w
        $line.Y1 = $gy; $line.Y2 = $gy
        $line.Stroke = [System.Windows.Media.Brushes]::White
        $line.Opacity = 0.06
        $line.StrokeDashArray = [System.Windows.Media.DoubleCollection]::new()
        $line.StrokeDashArray.Add(4); $line.StrokeDashArray.Add(4)
        [void]$Canvas.Children.Add($line)
    }

    # Build polyline points
    $polyPts = New-Object System.Windows.Media.PointCollection
    for ($i = 0; $i -lt $visible.Count; $i++) {
        $xOffset = $maxPoints - $visible.Count
        $x = ($i + $xOffset) * $step
        $y = $h - ($visible[$i] / 100.0 * $h)
        $polyPts.Add([System.Windows.Point]::new($x, $y))
    }

    # Fill polygon (area under line)
    if ($polyPts.Count -ge 2) {
        $fillPts = New-Object System.Windows.Media.PointCollection
        foreach ($p in $polyPts) { $fillPts.Add($p) }
        $fillPts.Add([System.Windows.Point]::new($polyPts[$polyPts.Count-1].X, $h))
        $fillPts.Add([System.Windows.Point]::new($polyPts[0].X, $h))

        $poly = New-Object System.Windows.Shapes.Polygon
        $poly.Points = $fillPts
        $gradBrush = New-Object System.Windows.Media.LinearGradientBrush
        $gradBrush.StartPoint = [System.Windows.Point]::new(0, 0)
        $gradBrush.EndPoint   = [System.Windows.Point]::new(0, 1)
        $gs1 = New-Object System.Windows.Media.GradientStop
        $gs1.Color  = [System.Windows.Media.ColorConverter]::ConvertFromString($FillColor)
        $gs1.Offset = 0
        $gs2 = New-Object System.Windows.Media.GradientStop
        $gs2.Color  = [System.Windows.Media.ColorConverter]::ConvertFromString($FillColor)
        $gs2.Offset = 1
        $gs2.Color = [System.Windows.Media.Color]::FromArgb(5, $gs2.Color.R, $gs2.Color.G, $gs2.Color.B)
        $gradBrush.GradientStops.Add($gs1)
        $gradBrush.GradientStops.Add($gs2)
        $poly.Fill    = $gradBrush
        $poly.Opacity = 0.35
        [void]$Canvas.Children.Add($poly)
    }

    # Draw the line
    if ($polyPts.Count -ge 2) {
        $pline = New-Object System.Windows.Shapes.Polyline
        $pline.Points = $polyPts
        $pline.Stroke = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString($LineColor))
        $pline.StrokeThickness = 1.8
        [void]$Canvas.Children.Add($pline)
    }

    # Current value dot
    if ($polyPts.Count -ge 1) {
        $lastPt = $polyPts[$polyPts.Count - 1]
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width  = 6; $dot.Height = 6
        $dot.Fill   = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString($LineColor))
        [System.Windows.Controls.Canvas]::SetLeft($dot, $lastPt.X - 3)
        [System.Windows.Controls.Canvas]::SetTop($dot,  $lastPt.Y - 3)
        [void]$Canvas.Children.Add($dot)
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# [N1] Actualizar panel superior (CPU, RAM, Disco C:) + gráficas sparkline
#      Síncrono en el UI thread — igual que el original. Los CimInstance rápidos
#      (<150 ms) no congelan la UI en un tick de 2 segundos.
# ─────────────────────────────────────────────────────────────────────────────
function Update-SystemInfo {
    try {
        # SystemDataCollector snapshots — consolidates CIM queries
        $ramSnap  = [SystemDataCollector]::GetRamSnapshot()
        $cpuSnap  = [SystemDataCollector]::GetCpuSnapshot()
        $diskSnap = [SystemDataCollector]::GetDiskSnapshot()

        $totalGB = [math]::Round($ramSnap.TotalBytes / 1GB, 1)
        $freeGB  = [math]::Round($ramSnap.FreeBytes  / 1GB, 1)
        $usedPct = [math]::Round($ramSnap.UsedPercent)

        $diskVol     = $diskSnap.Volumes | Where-Object { $_.DeviceId -eq 'C:' } | Select-Object -First 1
        $diskTotalGB = if ($diskVol) { [math]::Round($diskVol.TotalBytes / 1GB, 1) } else { 0 }
        $diskFreeGB  = if ($diskVol) { [math]::Round($diskVol.FreeBytes  / 1GB, 1) } else { 0 }
        $diskUsedPct = if ($diskVol) { [math]::Round($diskVol.UsedPercent) } else { 0 }

        $cpuLoad = [math]::Min(100, [math]::Max(0, $cpuSnap.LoadPercent))
        $cpuName = ($cpuSnap.Name -replace '\s+', ' ')
        if ($cpuName.Length -gt 35) { $cpuName = $cpuName.Substring(0, 35) + [char]0x2026 }

        # Actividad de disco via PerformanceCounter
        $diskActivity = 0.0
        if ($null -ne $script:DiskCounter) {
            try { $diskActivity = [math]::Min(100, [math]::Max(0, $script:DiskCounter.NextValue())) } catch {}
        }

        # Actualizar buffers de historial
        $script:CpuHistory.Add($cpuLoad)
        $script:RamHistory.Add([double]$usedPct)
        $script:DiskHistory.Add($diskActivity)
        if ($script:CpuHistory.Count  -gt 60) { $script:CpuHistory.RemoveAt(0) }
        if ($script:RamHistory.Count  -gt 60) { $script:RamHistory.RemoveAt(0) }
        if ($script:DiskHistory.Count -gt 60) { $script:DiskHistory.RemoveAt(0) }

        # Actualizar etiquetas del panel superior
        $InfoCPU.Text  = $cpuName
        $InfoRAM.Text  = "$freeGB GB libre / $totalGB GB"
        $InfoDisk.Text = "$diskFreeGB GB libre / $diskTotalGB GB"

        $CpuPctText.Text  = "  $([int]$cpuLoad)%"
        $RamPctText.Text  = "  $usedPct%"
        $DiskPctText.Text = "  $diskUsedPct% usado"

        # Dibujar gráficas sparkline
        Draw-SparkLine -Canvas $CpuChart  -Data $script:CpuHistory  -LineColor "#5BA3FF" -FillColor "#5BA3FF"
        Draw-SparkLine -Canvas $RamChart  -Data $script:RamHistory  -LineColor "#4AE896" -FillColor "#4AE896"
        Draw-SparkLine -Canvas $DiskChart -Data $script:DiskHistory -LineColor "#FFB547" -FillColor "#FFB547"

    } catch {
        $InfoCPU.Text  = "No disponible"
        $InfoRAM.Text  = "No disponible"
        $InfoDisk.Text = "No disponible"
    }
}

# Timer de actualización del panel superior — cada 2 segundos (igual que el original)
$chartTimer = New-Object System.Windows.Threading.DispatcherTimer
$chartTimer.Interval = [TimeSpan]::FromSeconds(2)
$chartTimer.Add_Tick({ Update-SystemInfo })

# Arrancar todo una vez que la ventana esté completamente cargada
# (garantiza que los Canvas tienen ActualWidth/Height reales para las gráficas)
# ─────────────────────────────────────────────────────────────────────────────
# [U1] Forzar tema oscuro en los ComboBox recorriendo su visual tree
#      WPF ignora Background en el ToggleButton interno a menos que se recorra
#      explícitamente el árbol visual después de que el control está cargado.
# ─────────────────────────────────────────────────────────────────────────────
function Get-VisualChildren { param($Parent); return [ThemeApplier]::GetVisualChildren($Parent) }

function Apply-ComboBoxDarkTheme {
    param([System.Windows.Controls.ComboBox]$ComboBox)
    [ThemeApplier]::ApplyComboBoxTheme(
        $ComboBox,
        (Get-TC 'BgInput' '#1A1E2F'),
        (Get-TC 'BorderSubtle' '#3A4468'),
        (Get-TC 'TextPrimary' '#E8ECF4'),
        (Get-TC 'ComboHover' '#1E3A5C')
    )
}

$window.Add_Loaded({
    try {
        Set-SplashProgress 100 "Listo."
        $splashWin.Hide()
        $splashWin.Close()
    } catch {}

    # [C3-PRE] Copiar TB_* del Window al Application.Current.Resources
    # Los ContextMenu en Popups heredan Application.Resources pero NO Window.Resources.
    # Esto garantiza que cualquier CM (incluyendo DataTemplate) resuelva los brushes.
    try {
        foreach ($rk in @($window.Resources.Keys)) {
            if ([string]$rk -like "TB_*") {
                [System.Windows.Application]::Current.Resources[[string]$rk] = $window.Resources[$rk]
            }
        }
    } catch {}

    # [C3] Restaurar configuracion guardada (tema, idioma, preferencias)
    Load-Settings

    try {
        Load-Language $script:CurrentLang
    } catch {}

    if ($script:CurrentTheme -ne "default") {
        try {
            Apply-ThemeWithProgress -ThemeName $script:CurrentTheme
            Update-DynamicThemeValues
        } catch {}
    }

    # Aplicar tema oscuro a todos los ComboBox de la ventana
    try {
        $allCombos = Get-VisualChildren $window | Where-Object { $_ -is [System.Windows.Controls.ComboBox] }
        foreach ($cb in $allCombos) { Apply-ComboBoxDarkTheme $cb }
    } catch {}

    # Aplicar colores de tema a los botones nombrados
    try { Apply-ButtonTheme } catch {}

    $chartTimer.Start()
    Update-SystemInfo        # primera carga inmediata
    Update-PerformanceTab    # poblar pestana Rendimiento al arrancar

    # ── [BOOT] Contexto de arranque — log detallado de configuracion y entorno ──
    # Se ejecuta DESPUES de Load-Settings/Load-Language/Apply-Theme para reflejar
    # el estado real con el que arranca la sesion. Solo va al archivo (-NoUI).
    try {
        # ── Aplicacion ────────────────────────────────────────────────────────
        Write-Log "── Configuracion de arranque ─────────────────────────────" -Level "INFO" -NoUI
        Write-Log ("[APP] Version        : v{0}" -f $script:AppVersion)                                         -Level "INFO" -NoUI
        Write-Log ("[APP] Tema activo     : {0}" -f $script:CurrentTheme)                                       -Level "INFO" -NoUI
        Write-Log ("[APP] Idioma activo   : {0}" -f $script:CurrentLang)                                        -Level "INFO" -NoUI
        Write-Log ("[APP] Settings path   : {0}" -f $script:SettingsPath)                                       -Level "INFO" -NoUI
        $settingsExist = Test-Path $script:SettingsPath
        Write-Log ("[APP] Settings existe : {0}" -f $(if ($settingsExist) {"SI"} else {"NO — usando defaults"})) -Level "INFO" -NoUI

        # Ruta de escaneo y auto-refresh desde los controles ya restaurados
        try {
            $scanPath    = if ($txtDiskScanPath -and $txtDiskScanPath.Text) { $txtDiskScanPath.Text } else { "(no definida)" }
            $autoRefresh = if ($chkAutoRefresh -and $chkAutoRefresh.IsChecked) { "ON" } else { "OFF" }
            $refreshSecs = if ($cmbRefreshInterval -and $cmbRefreshInterval.SelectedItem) { "$($cmbRefreshInterval.SelectedItem.Tag) s" } else { "(default)" }
            Write-Log ("[APP] Disco scan path : {0}" -f $scanPath)    -Level "INFO" -NoUI
            Write-Log ("[APP] Auto-refresh    : {0}  intervalo={1}" -f $autoRefresh, $refreshSecs) -Level "INFO" -NoUI
        } catch {}

        # ── Entorno de ejecucion ──────────────────────────────────────────────
        Write-Log ("[ENV] PowerShell      : v{0}  ({1}-bit)" -f $PSVersionTable.PSVersion, $(if ([Environment]::Is64BitProcess) {"64"} else {"32"})) -Level "INFO" -NoUI
        Write-Log ("[ENV] Admin           : {0}" -f $(if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {"SI"} else {"NO — funciones limitadas"})) -Level "INFO" -NoUI
        Write-Log ("[ENV] PID             : {0}" -f $PID)                                               -Level "INFO" -NoUI
        Write-Log ("[ENV] Script root     : {0}" -f $PSScriptRoot)                                      -Level "INFO" -NoUI
        Write-Log ("[ENV] Working dir     : {0}" -f (Get-Location).Path)                                -Level "INFO" -NoUI

        # ── Sistema operativo ─────────────────────────────────────────────────
        try {
            $osInfo = Invoke-CimQuery -ClassName Win32_OperatingSystem -SilentOnFail
            if ($osInfo) {
                $totalRamGB = [math]::Round($osInfo.TotalVisibleMemorySize / 1MB, 1)
                $freeRamGB  = [math]::Round($osInfo.FreePhysicalMemory     / 1MB, 1)
                $usedRamPct = [math]::Round((($totalRamGB - $freeRamGB) / [math]::Max($totalRamGB,1)) * 100)
                Write-Log ("[SYS] OS              : {0}  (Build {1})" -f $osInfo.Caption.Trim(), $osInfo.BuildNumber)  -Level "INFO" -NoUI
                Write-Log ("[SYS] RAM             : {0} GB total  |  {1} GB libre  |  {2}% usado" -f $totalRamGB, $freeRamGB, $usedRamPct) -Level "INFO" -NoUI
                Write-Log ("[SYS] Ultimo boot     : {0}" -f $osInfo.LastBootUpTime)                              -Level "INFO" -NoUI
            }
        } catch {}

        # ── CPU ───────────────────────────────────────────────────────────────
        try {
            $cpuInfo = Invoke-CimQuery -ClassName Win32_Processor -SilentOnFail | Select-Object -First 1
            if ($cpuInfo) {
                Write-Log ("[SYS] CPU             : {0}  ({1} cores / {2} hilos)" -f $cpuInfo.Name.Trim(), $cpuInfo.NumberOfCores, $cpuInfo.NumberOfLogicalProcessors) -Level "INFO" -NoUI
                Write-Log ("[SYS] CPU carga       : {0}%  @{1} MHz" -f $cpuInfo.LoadPercentage, $cpuInfo.CurrentClockSpeed) -Level "INFO" -NoUI
            }
        } catch {}

        # ── Disco C: ──────────────────────────────────────────────────────────
        try {
            $diskC = Invoke-CimQuery -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -SilentOnFail | Select-Object -First 1
            if ($diskC) {
                $dTotalGB = [math]::Round($diskC.Size      / 1GB, 1)
                $dFreeGB  = [math]::Round($diskC.FreeSpace / 1GB, 1)
                $dUsedPct = [math]::Round((($dTotalGB - $dFreeGB) / [math]::Max($dTotalGB,1)) * 100)
                Write-Log ("[SYS] Disco C:        : {0} GB total  |  {1} GB libre  |  {2}% usado" -f $dTotalGB, $dFreeGB, $dUsedPct) -Level "INFO" -NoUI
            }
        } catch {}

        # ── Advertencias de arranque ──────────────────────────────────────────
        # Detectar condiciones que pueden afectar al comportamiento de la app
        try {
            # RAM baja
            $osInfo2 = Invoke-CimQuery -ClassName Win32_OperatingSystem -SilentOnFail
            if ($osInfo2) {
                $freeMB = [math]::Round($osInfo2.FreePhysicalMemory / 1KB)
                if ($freeMB -lt 512) {
                    Write-Log ("[WARN] RAM libre muy baja al arrancar: ${freeMB} MB — rendimiento puede verse afectado") -Level "WARN" -NoUI
                }
                # Disco C: casi lleno
                $diskC2 = Invoke-CimQuery -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -SilentOnFail | Select-Object -First 1
                if ($diskC2) {
                    $freeGBw = [math]::Round($diskC2.FreeSpace / 1GB, 1)
                    if ($freeGBw -lt 5) {
                        Write-Log ("[WARN] Disco C: con menos de 5 GB libres (${freeGBw} GB) — algunas operaciones pueden fallar") -Level "WARN" -NoUI
                    }
                }
            }
            # Tema no encontrado (se cargó settings.json pero el .theme ya no existe)
            if ($script:CurrentTheme -ne "default") {
                $themePath = Join-Path $script:ThemesDir "$($script:CurrentTheme).theme"
                if (-not (Test-Path $themePath)) {
                    Write-Log ("[WARN] Tema guardado '$($script:CurrentTheme)' no encontrado en assets	hemes\ — usando default") -Level "WARN" -NoUI
                }
            }
            # Idioma no encontrado
            $langPath = Join-Path $script:LangDir "$($script:CurrentLang).lang"
            if (-not (Test-Path $langPath)) {
                Write-Log ("[WARN] Idioma guardado '$($script:CurrentLang)' no encontrado en assets\lang\ — sin traducciones") -Level "WARN" -NoUI
            }
        } catch {}

        Write-Log "── Fin contexto de arranque ──────────────────────────────" -Level "INFO" -NoUI
    } catch {
        Write-Log "[BOOT] Error al registrar contexto de arranque: $($_.Exception.Message)" -Level "WARN" -NoUI
    }
})

# ─────────────────────────────────────────────────────────────────────────────
# TAB 2: RENDIMIENTO — controles y lógica
# ─────────────────────────────────────────────────────────────────────────────
$btnRefreshPerf   = $window.FindName("btnRefreshPerf")
$txtPerfStatus    = $window.FindName("txtPerfStatus")
# [A3] Auto-refresco controles
$chkAutoRefresh      = $window.FindName("chkAutoRefresh")
$cmbRefreshInterval  = $window.FindName("cmbRefreshInterval")
$script:AutoRefreshTimer = $null
$script:AppClosing       = $false
# Aplicar tema oscuro al ComboBox también en su evento Loaded individual
if ($null -ne $cmbRefreshInterval) {
    $cmbRefreshInterval.Add_Loaded({ Apply-ComboBoxDarkTheme $cmbRefreshInterval })
}
$txtCpuName       = $window.FindName("txtCpuName")
$icCpuCores       = $window.FindName("icCpuCores")
$txtRamTotal      = $window.FindName("txtRamTotal")
$txtRamUsed       = $window.FindName("txtRamUsed")
$txtRamFree       = $window.FindName("txtRamFree")
$txtRamPct        = $window.FindName("txtRamPct")
$pbRam            = $window.FindName("pbRam")
$icRamModules     = $window.FindName("icRamModules")
$icSmartDisks     = $window.FindName("icSmartDisks")
$icNetAdapters    = $window.FindName("icNetAdapters")

function Format-Bytes { param([long]$Bytes); return [Formatter]::FormatBytes($Bytes) }

# causando fallo de resolución de nombre "OUL" al invocarse desde el dispatcher WPF)
function Format-Rate { param([double]$bps); return [Formatter]::FormatRate($bps) }

function Get-LinkBps { param($raw); return [Formatter]::ParseLinkBps("$raw") }

function Update-PerformanceTab {
    if ($script:AppClosing) { return }
    $txtPerfStatus.Text = "Recopilando datos…"

    try { Import-Module Storage    -ErrorAction SilentlyContinue } catch {}
    try { Import-Module NetAdapter -ErrorAction SilentlyContinue } catch {}
    try { Import-Module NetTCPIP   -ErrorAction SilentlyContinue } catch {}

    # ── CPU Cores ──────────────────────────────────────────────
    try {
        $cpuObj = Invoke-CimQuery -ClassName Win32_Processor | Select-Object -First 1
        $txtCpuName.Text = "$($cpuObj.Name)  |  $($cpuObj.NumberOfCores) núcleos  /  $($cpuObj.NumberOfLogicalProcessors) lógicos"

        $coreItems = [System.Collections.Generic.List[object]]::new()
        try {
            $cpuPerf = Invoke-CimQuery -ClassName Win32_PerfFormattedData_PerfOS_Processor -SilentOnFail |
                       Where-Object { $_.Name -ne '_Total' } |
                       Sort-Object { [int]($_.Name -replace '\D','0') }
            if ($cpuPerf) {
                foreach ($core in $cpuPerf) {
                    $val = [math]::Round([double]$core.PercentProcessorTime, 1)
                    $coreItems.Add([PSCustomObject]@{
                        CoreLabel = "Core $($core.Name)"
                        Usage     = "$val%"
                        UsageNum  = $val
                        Freq      = "$([math]::Round($cpuObj.CurrentClockSpeed / 1000.0, 2)) GHz"
                    })
                }
            } else {
                $val = [double]$cpuObj.LoadPercentage
                $coreItems.Add([PSCustomObject]@{
                    CoreLabel = "CPU Total"; Usage = "$val%"; UsageNum = $val
                    Freq      = "$([math]::Round($cpuObj.CurrentClockSpeed / 1000.0, 2)) GHz"
                })
            }
        } catch {
            $coreItems.Add([PSCustomObject]@{
                CoreLabel = "CPU Total"; Usage = "$($cpuObj.LoadPercentage)%"
                UsageNum  = [double]$cpuObj.LoadPercentage
                Freq      = "$([math]::Round($cpuObj.CurrentClockSpeed / 1000.0, 2)) GHz"
            })
        }
        $icCpuCores.ItemsSource = $coreItems
    } catch { $txtCpuName.Text = "No disponible" }

    # ── RAM Detallada ──────────────────────────────────────────
    try {
        $os     = Invoke-CimQuery -ClassName Win32_OperatingSystem
        $totalB = $os.TotalVisibleMemorySize * 1KB
        $freeB  = $os.FreePhysicalMemory     * 1KB
        $usedB  = $totalB - $freeB
        $pct    = [math]::Round($usedB / $totalB * 100)

        $fmt = { param($b) return [Formatter]::FormatBytes([long]$b) }

        $txtRamTotal.Text = & $fmt $totalB
        $txtRamUsed.Text  = & $fmt $usedB
        $txtRamFree.Text  = & $fmt $freeB
        $txtRamPct.Text   = "$pct%"
        $pbRam.Value      = $pct

        $modItems = [System.Collections.Generic.List[object]]::new()
        foreach ($mod in (Invoke-CimQuery -ClassName Win32_PhysicalMemory -SilentOnFail)) {
            $type = switch ($mod.SMBIOSMemoryType) {
                26 { "DDR4" } 34 { "DDR5" } 21 { "DDR2" } 24 { "DDR3" } default { "DDR" }
            }
            $modItems.Add([PSCustomObject]@{
                Slot = if ($mod.DeviceLocator) { $mod.DeviceLocator } else { "Ranura" }
                Info = "$type  •  $(if($mod.Speed){"$($mod.Speed) MHz"}else{"—"})  •  Mfg: $(if($mod.Manufacturer){$mod.Manufacturer}else{"N/A"})"
                Size = & $fmt ([long]$mod.Capacity)
            })
        }
        $icRamModules.ItemsSource = $modItems
    } catch { $txtRamTotal.Text = "N/A" }

    # ── SMART del Disco ────────────────────────────────────────
    try {
        $smartItems = [System.Collections.Generic.List[object]]::new()
        foreach ($disk in (Get-PhysicalDisk -ErrorAction Stop)) {
            $rel = $null
            try { $rel = Get-StorageReliabilityCounter -PhysicalDisk $disk -ErrorAction Stop } catch {}

            $health = $disk.HealthStatus
            $bg = switch ($health) {
                "Healthy" { Get-TC 'BgStatusOk'   '#182A1E' }
                "Warning" { Get-TC 'BgStatusWarn'  '#2A2010' }
                default   { Get-TC 'BgStatusErr'   '#2A1018' }
            }
            $fg = switch ($health) {
                "Healthy" { Get-TC 'FgStatusOk'   '#4AE896' }
                "Warning" { Get-TC 'FgStatusWarn'  '#FFB547' }
                default   { Get-TC 'FgStatusErr'   '#FF6B84' }
            }

            $attrs = [System.Collections.Generic.List[object]]::new()
            $sz = if ($disk.Size -ge 1GB) { "{0:N1} GB" -f ($disk.Size / 1GB) } else { "{0:N0} MB" -f ($disk.Size / 1MB) }
            $attrs.Add([PSCustomObject]@{ Name="Tipo";    Value=$disk.MediaType; ValueColor=(Get-TC 'TextSecondary' '#B0BACC') })
            $attrs.Add([PSCustomObject]@{ Name="Tamaño";  Value=$sz;             ValueColor=(Get-TC 'AccentBlue'    '#5BA3FF') })
            $attrs.Add([PSCustomObject]@{ Name="Bus";     Value=$disk.BusType;   ValueColor=(Get-TC 'TextSecondary' '#B0BACC') })
            if ($rel) {
                if ($null -ne $rel.PowerOnHours) {
                    $attrs.Add([PSCustomObject]@{ Name="Horas enc."; Value="$($rel.PowerOnHours) h"; ValueColor=(Get-TC 'AccentAmber' '#FFB547') })
                }
                if ($null -ne $rel.Temperature) {
                    $tc = $rel.Temperature
                    $tc2 = if ($tc -ge 55) { Get-TC 'FgStatusErr' '#FF6B84' } elseif ($tc -ge 45) { Get-TC 'FgStatusWarn' '#FFB547' } else { Get-TC 'FgStatusOk' '#4AE896' }
                    $attrs.Add([PSCustomObject]@{ Name="Temperatura"; Value="${tc}°C"; ValueColor=$tc2 })
                }
                if ($null -ne $rel.ReadErrorsTotal) {
                    $attrs.Add([PSCustomObject]@{ Name="Errores lect."; Value=$rel.ReadErrorsTotal
                        ValueColor=if($rel.ReadErrorsTotal -gt 0){ Get-TC 'FgStatusErr' '#FF6B84' }else{ Get-TC 'FgStatusOk' '#4AE896' } })
                }
                if ($null -ne $rel.Wear) {
                    $wc = if ($rel.Wear -ge 80) { Get-TC 'FgStatusErr' '#FF6B84' } elseif ($rel.Wear -ge 50) { Get-TC 'FgStatusWarn' '#FFB547' } else { Get-TC 'FgStatusOk' '#4AE896' }
                    $attrs.Add([PSCustomObject]@{ Name="Desgaste"; Value="$($rel.Wear)%"; ValueColor=$wc })
                }
            }
            $smartItems.Add([PSCustomObject]@{
                DiskName=$disk.FriendlyName; Status=$health; StatusBg=$bg; StatusFg=$fg; Attributes=$attrs
            })
        }
        $icSmartDisks.ItemsSource = $smartItems
    } catch {
        $icSmartDisks.ItemsSource = @([PSCustomObject]@{
            DiskName="Error al leer SMART"; Status="N/A"; StatusBg=(Get-TC 'BgStatusErr' '#2A1018'); StatusFg=(Get-TC 'FgStatusErr' '#FF6B84'); Attributes=@()
        })
    }

    # ── Tarjetas de Red ────────────────────────────────────────
    try {
        # Tabla de velocidades WMI para calcular rx/tx en tiempo real
        $wmiTable = @{}
        try {
            foreach ($row in (Invoke-CimQuery -ClassName Win32_PerfFormattedData_Tcpip_NetworkInterface -SilentOnFail)) {
                $norm = ($row.Name -replace '\s*#\d+$','' -replace '_',' ').ToLower().Trim()
                $wmiTable[$norm] = $row
            }
        } catch {}

        # Funciones de formato inline (sin scriptblock para evitar problemas de scope)
        function Format-NetRate  { param([double]$b); return [Formatter]::FormatRate($b) }
        function Format-NetBytes { param([double]$b); return [Formatter]::FormatBytes([long]$b) }
        function Format-LinkBps  { param([uint64]$bps); return [Formatter]::FormatLinkSpeed($bps) }

        $netItems = [System.Collections.Generic.List[object]]::new()

        # ── Intentar con Get-NetAdapter (módulo NetAdapter) ──────────────
        $gotNetAdapter = $false
        try {
            $adapters = Get-NetAdapter -ErrorAction Stop
            $gotNetAdapter = $true

            foreach ($a in $adapters) {
                # IP
                $ip = "Sin IP"
                try {
                    $ipObj = Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($ipObj -and $ipObj.IPAddress) { $ip = $ipObj.IPAddress }
                } catch {}

                # Tipo de adaptador
                $desc = "$($a.InterfaceDescription)"
                $adType = "🔌 Ethernet"
                if (($desc -match 'Wi.?Fi|Wireless|WLAN|802\.11') -or ("$($a.PhysicalMediaType)" -match '802\.11|Wireless|NativeWifi')) {
                    $adType = "📶 WiFi"
                } elseif ($desc -match 'Loopback|Pseudo|Miniport|Hyper-V|VMware|VirtualBox|TAP|TUN|VPN') {
                    $adType = "🔷 Virtual"
                }

                # Velocidad de enlace
                $linkBps = [uint64]0
                $lsStr = "$($a.LinkSpeed)"
                $lsParsed = [uint64]0
                if ([uint64]::TryParse($lsStr, [ref]$lsParsed)) {
                    $linkBps = $lsParsed
                } elseif ($lsStr -match '([\d\.]+)\s*(G|M|K)?bps') {
                    $lv = [double]$Matches[1]; $lu = "$($Matches[2])"
                    $lm = 1
                    if ($lu -eq 'G') { $lm = 1000000000 } elseif ($lu -eq 'M') { $lm = 1000000 } elseif ($lu -eq 'K') { $lm = 1000 }
                    $linkBps = [uint64]($lv * $lm)
                }
                $speedStr = Format-LinkBps $linkBps

                # Velocidad rx/tx desde WMI
                $descNorm = ($desc -replace '\s*#\d+$','').ToLower().Trim()
                $wmiRow = $wmiTable[$descNorm]
                if (-not $wmiRow) {
                    foreach ($k in $wmiTable.Keys) {
                        if ($descNorm -like "*$k*" -or $k -like "*$($a.Name.ToLower().Trim())*") { $wmiRow = $wmiTable[$k]; break }
                    }
                }
                $rxBps = 0.0; $txBps = 0.0
                if ($null -ne $wmiRow) { $rxBps = [double]$wmiRow.BytesReceivedPersec; $txBps = [double]$wmiRow.BytesSentPersec }

                # Bytes totales
                $ioStr = ""
                try {
                    $stats = Get-NetAdapterStatistics -Name $a.Name -ErrorAction SilentlyContinue
                    if ($stats) { $ioStr = "Total ↓ $(Format-NetBytes $stats.ReceivedBytes)  ↑ $(Format-NetBytes $stats.SentBytes)" }
                } catch {}

                # Color de estado
                $stColor = "#9BA4C0"
                if ($a.Status -eq "Up") { $stColor = "#4AE896" }

                $netItems.Add([PSCustomObject]@{
                    Name        = "$adType  $($a.Name)"
                    IP          = "IP: $ip  |  MAC: $($a.MacAddress)"
                    MAC         = $desc
                    Speed       = $speedStr
                    Status      = "$($a.Status)   ↓ $(Format-NetRate $rxBps)   ↑ $(Format-NetRate $txBps)"
                    StatusColor = $stColor
                    BytesIO     = $ioStr
                })
            }
        } catch {}

        # ── Fallback WMI puro si Get-NetAdapter no está disponible ───────
        if (-not $gotNetAdapter -or $netItems.Count -eq 0) {
            try {
                foreach ($nic in (Invoke-CimQuery -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -SilentOnFail)) {
                    $nicName = (Invoke-CimQuery -ClassName Win32_NetworkAdapter -Filter "DeviceID='$($nic.Index)'" -SilentOnFail).NetConnectionID
                    if (-not $nicName) { $nicName = $nic.Description }
                    $ip  = if ($nic.IPAddress)    { $nic.IPAddress[0]    } else { "Sin IP" }
                    $mac = if ($nic.MACAddress)   { $nic.MACAddress      } else { "—" }
                    $gw  = if ($nic.DefaultIPGateway) { $nic.DefaultIPGateway[0] } else { "Sin GW" }

                    $adType = "🔌 Ethernet"
                    if ($nic.Description -match 'Wi.?Fi|Wireless|WLAN|802\.11') { $adType = "📶 WiFi" }
                    elseif ($nic.Description -match 'Hyper-V|VMware|VirtualBox|TAP|TUN|VPN') { $adType = "🔷 Virtual" }

                    $netItems.Add([PSCustomObject]@{
                        Name        = "$adType  $nicName"
                        IP          = "IP: $ip  |  MAC: $mac"
                        MAC         = $nic.Description
                        Speed       = "—"
                        Status      = "Activa  ↓ —  ↑ —  |  GW: $gw"
                        StatusColor = "#4AE896"
                        BytesIO     = ""
                    })
                }
            } catch {
                $netItems.Add([PSCustomObject]@{
                    Name="⚠ Error WMI al leer red"; IP=$_.Exception.Message
                    MAC=""; Speed=""; Status="Error"; StatusColor="#FF6B84"; BytesIO=""
                })
            }
        }

        if ($netItems.Count -eq 0) {
            $netItems.Add([PSCustomObject]@{
                Name="ℹ Sin adaptadores activos"; IP="No se detectaron tarjetas de red activas"
                MAC=""; Speed=""; Status="—"; StatusColor="#7880A0"; BytesIO=""
            })
        }

        $icNetAdapters.ItemsSource = $netItems

    } catch {
        $icNetAdapters.ItemsSource = @([PSCustomObject]@{
            Name="⚠ Error al leer adaptadores"
            IP="[$($_.Exception.GetType().Name)] $($_.Exception.Message)"
            MAC=""; Speed=""; Status="Error"; StatusColor="#FF6B84"; BytesIO=""
        })
    }

    $txtPerfStatus.Text = "Actualizado: $(Get-Date -Format 'HH:mm:ss')"
}

$btnRefreshPerf.Add_Click({ Update-PerformanceTab })

# [A3] Auto-refresco de Rendimiento ───────────────────────────────────────────
# Handler único compartido — evita Add_Tick duplicado si se recrea el timer
$script:AutoRefreshTick = { Update-PerformanceTab }.GetNewClosure()

function Start-AutoRefreshTimer {
    $secs = 5
    $sel  = $cmbRefreshInterval.SelectedItem
    if ($sel -and $sel.Tag) { $secs = [int]$sel.Tag }
    $script:AutoRefreshTimer          = New-Object System.Windows.Threading.DispatcherTimer
    $script:AutoRefreshTimer.Interval = [TimeSpan]::FromSeconds($secs)
    $script:AutoRefreshTimer.Add_Tick($script:AutoRefreshTick)
    $script:AutoRefreshTimer.Start()
    $txtPerfStatus.Text = "  Auto-refresco cada $secs s activo"
}

$chkAutoRefresh.Add_Checked({ Start-AutoRefreshTimer })
$chkAutoRefresh.Add_Unchecked({
    if ($null -ne $script:AutoRefreshTimer) { $script:AutoRefreshTimer.Stop(); $script:AutoRefreshTimer = $null }
    $txtPerfStatus.Text = "  Auto-refresco desactivado"
})
$cmbRefreshInterval.Add_SelectionChanged({
    if ($chkAutoRefresh.IsChecked -eq $true) {
        if ($null -ne $script:AutoRefreshTimer) { $script:AutoRefreshTimer.Stop(); $script:AutoRefreshTimer = $null }
        Start-AutoRefreshTimer
    }
})

# ─────────────────────────────────────────────────────────────────────────────
# TAB 3: EXPLORADOR DE DISCO — controles y lógica
# ─────────────────────────────────────────────────────────────────────────────
$txtDiskScanPath    = $window.FindName("txtDiskScanPath")
$btnDiskBrowse      = $window.FindName("btnDiskBrowse")
$btnDiskScan        = $window.FindName("btnDiskScan")
$btnDiskStop        = $window.FindName("btnDiskStop")
$lbDiskTree         = $window.FindName("lbDiskTree")
$txtDiskScanStatus  = $window.FindName("txtDiskScanStatus")
$pbDiskScan         = $window.FindName("pbDiskScan")
$txtDiskDetailName  = $window.FindName("txtDiskDetailName")
$txtDiskDetailSize  = $window.FindName("txtDiskDetailSize")
$txtDiskDetailFiles = $window.FindName("txtDiskDetailFiles")
$txtDiskDetailDirs  = $window.FindName("txtDiskDetailDirs")
$txtDiskDetailPct   = $window.FindName("txtDiskDetailPct")
$icTopFiles         = $window.FindName("icTopFiles")
$txtDiskFilter      = $window.FindName("txtDiskFilter")
$btnDiskFilterClear = $window.FindName("btnDiskFilterClear")
$btnExportCsv       = $window.FindName("btnExportCsv")
$btnDiskReport      = $window.FindName("btnDiskReport")
$btnDedup           = $window.FindName("btnDedup")
$ctxMenu        = $lbDiskTree.ContextMenu
$ctxOpen        = $ctxMenu.Items | Where-Object { $_.Name -eq "ctxOpen"      }
$ctxCopy        = $ctxMenu.Items | Where-Object { $_.Name -eq "ctxCopy"      }
$ctxScanFolder  = $ctxMenu.Items | Where-Object { $_.Name -eq "ctxScanFolder" }
$ctxDelete      = $ctxMenu.Items | Where-Object { $_.Name -eq "ctxDelete"    }
$ctxShowOutput2 = $ctxMenu.Items | Where-Object { $_.Name -eq "ctxShowOutput" }

$script:DiskScanRunspace = $null
$script:DiskScanResults  = $null
# Rutas colapsadas por el usuario (toggle ▶/▼)
$script:CollapsedPaths   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
# Todos los items escaneados (sin filtrar) — base para rebuilds de vista
$script:AllScannedItems  = [System.Collections.Generic.List[object]]::new(4096)  # [NEW-03] capacity hint
# Índice posición en LiveList para actualizaciones O(1)
$script:LiveIndexMap     = [System.Collections.Generic.Dictionary[string,int]]::new([System.StringComparer]::OrdinalIgnoreCase)

# ─────────────────────────────────────────────────────────────────────────────
# Reconstruye la lista visible aplicando el filtro de colapso
# ─────────────────────────────────────────────────────────────────────────────
# [NEW-01] Debounce timer: evita rebuilds múltiples en ráfagas del scanner
$script:_diskViewDebounce = $null
function Request-DiskViewRefresh {
    param([switch]$RebuildMap)
    # Si viene con RebuildMap o no hay timer activo, disparar inmediatamente
    # (los colapsos manuales necesitan respuesta inmediata)
    if ($RebuildMap) {
        if ($null -ne $script:_diskViewDebounce) {
            try { $script:_diskViewDebounce.Stop() } catch {}
            $script:_diskViewDebounce = $null
        }
        Refresh-DiskView -RebuildMap
        return
    }
    # Para actualizaciones de datos (ráfaga del scanner), debounce 80ms
    if ($null -ne $script:_diskViewDebounce) { return }  # ya pendiente
    $dt = New-Object System.Windows.Threading.DispatcherTimer
    $dt.Interval = [TimeSpan]::FromMilliseconds(80)
    $dt.Add_Tick({
        $script:_diskViewDebounce.Stop()
        $script:_diskViewDebounce = $null
        Refresh-DiskView
    })
    $script:_diskViewDebounce = $dt
    $dt.Start()
}

function Refresh-DiskView {
    param([switch]$RebuildMap)
    if ($null -eq $script:LiveList) { return }

    # ── Fase 1: construir y ordenar el childMap (cacheado) ──────────────────────
    # Al colapsar/expandir los datos NO cambian → reutilizamos el mapa ya ordenado.
    # Solo se reconstruye cuando llegan datos nuevos del escáner (-RebuildMap).
    if ($RebuildMap -or $null -eq $script:CachedChildMap) {
        $script:CachedChildMap = [System.Collections.Generic.Dictionary[string,
                      System.Collections.Generic.List[object]]]::new(
                        [System.StringComparer]::OrdinalIgnoreCase)

        foreach ($item in $script:AllScannedItems) {
            $pk = if ($null -ne $item.ParentPath -and $item.ParentPath -ne '') { $item.ParentPath } else { '::ROOT::' }
            if (-not $script:CachedChildMap.ContainsKey($pk)) {
                $script:CachedChildMap[$pk] = [System.Collections.Generic.List[object]]::new()
            }
            $script:CachedChildMap[$pk].Add($item)
        }

        # Ordenar cada grupo con Array.Sort (sin pipeline) — mayor tamaño primero
        foreach ($pk in @($script:CachedChildMap.Keys)) {
            $lst = $script:CachedChildMap[$pk]
            if ($lst.Count -lt 2) { continue }
            # Sort-Object solo se ejecuta al construir el mapa (no en cada colapso)
            # PowerShell no acepta scriptblock como IComparer en [Array]::Sort
            $sorted = $lst | Sort-Object -Property @{Expression={ if ($_.SizeBytes -ge 0) { $_.SizeBytes } else { 0L } }} -Descending
            $lst.Clear()
            foreach ($x in $sorted) { $lst.Add($x) }
        }
    }

    # ── Fase 2: DFS con pila de índices (orden garantizado) ────────────────────
    # Mantenemos una pila de (parentKey, índiceActual) para recorrer el árbol
    # en profundidad respetando el orden ya establecido en CachedChildMap.
    # Esto evita la recursión y el problema del Stack LIFO que mezcla el orden.
    $script:LiveList.Clear()

    # Cada entrada en la pila: [string parentKey, int currentIndex]
    $dfsStack = [System.Collections.Generic.Stack[object[]]]::new()
    if ($script:CachedChildMap.ContainsKey('::ROOT::')) {
        $dfsStack.Push(@('::ROOT::', 0))
    }

    while ($dfsStack.Count -gt 0) {
        $frame   = $dfsStack.Peek()
        $pk      = [string]$frame[0]
        $idx     = [int]$frame[1]
        $children = $script:CachedChildMap[$pk]

        if ($idx -ge $children.Count) {
            # Agotamos todos los hijos de este padre → subimos
            [void]$dfsStack.Pop()
            continue
        }

        # Avanzar índice para la próxima vuelta de este frame
        $frame[1] = $idx + 1

        $item = $children[$idx]

        # Sincronizar ícono
        if ($item.IsDir -and $item.HasChildren) {
            $item.ToggleIcon = if ($script:CollapsedPaths.Contains($item.FullPath)) {
                [string][char]0x25B6
            } else {
                [string][char]0x25BC
            }
        }

        $script:LiveList.Add($item)

        # Si el directorio está expandido, bajar a sus hijos
        if ($item.IsDir -and $item.HasChildren -and
            -not $script:CollapsedPaths.Contains($item.FullPath) -and
            $script:CachedChildMap.ContainsKey($item.FullPath)) {
            $dfsStack.Push(@($item.FullPath, 0))
        }
    }
}

# Invalida el childMap cacheado; llamar cuando el escáner emita nuevos datos
function Invalidate-DiskViewCache {
    $script:CachedChildMap = $null
}

function Get-SizeColor {
    param([long]$Bytes)
    if ($Bytes -ge 10GB) { return "#FF6B84" }
    if ($Bytes -ge 1GB)  { return "#FFB547" }
    if ($Bytes -ge 100MB){ return "#5BA3FF" }
    return "#B0BACC"
}

# Get-SizeColorFromStr es alias de Get-SizeColor (eliminado duplicado)
Set-Alias -Name Get-SizeColorFromStr -Value Get-SizeColor -Scope Script

function Start-DiskScan {
    param([string]$RootPath)

    if (-not (Test-Path $RootPath -ErrorAction SilentlyContinue)) {
        Write-Log "[SCAN] Ruta no encontrada: $RootPath" -Level "WARN" -NoUI
        Show-ThemedDialog -Title "Ruta no encontrada" -Message "Ruta no encontrada: $RootPath" -Type "error"
        return
    }
    Write-Log ("[SCAN] Iniciando escaneo de disco: {0}" -f $RootPath) -Level "INFO" -NoUI

    # Señalizar parada al runspace anterior y esperar a que confirme la parada
    # WaitOne(500) bloquea máximo 500ms hasta que el handle complete — evita
    # que Reset() se ejecute con el hilo de escaneo anterior todavía activo.
    # [CTK] ScanTokenManager.Cancel() notifica el token; ScanCtl211.Stop mantiene
    # compatibilidad con PScanner211 que todavía lee el flag booleano.
    [ScanCtl211]::Stop = $true
    if (([System.Management.Automation.PSTypeName]'ScanTokenManager').Type) {
        [ScanTokenManager]::Cancel()
    }
    if ($null -ne $script:DiskScanAsync -and -not $script:DiskScanAsync.IsCompleted) {
        $script:DiskScanAsync.AsyncWaitHandle.WaitOne(500) | Out-Null
    }
    [ScanCtl211]::Reset()
    if (([System.Management.Automation.PSTypeName]'ScanTokenManager').Type) {
        [ScanTokenManager]::RequestNew()   # token limpio para el nuevo escaneo
    }

    $script:CollapsedPaths.Clear()
    $script:CachedChildMap = $null      # Invalidar caché al iniciar nuevo escaneo
    $script:AllScannedItems.Clear()
    if ($null -ne $script:LiveIndexMap) { $script:LiveIndexMap.Clear() }

    $btnDiskScan.IsEnabled  = $false
    $btnDiskStop.IsEnabled  = $true
    $txtDiskScanStatus.Text = "Iniciando escaneo de $RootPath …"
    if ($null -ne $btnSnapshotSave) {
        $btnSnapshotSave.IsEnabled = $false
        $txtSnapshotName.IsEnabled = $false
        $txtSnapshotName.Text      = ""
    }
    if ($null -ne $btnDedup) { $btnDedup.IsEnabled = $false }
    $pbDiskScan.IsIndeterminate = $true
    $pbDiskScan.Value = 0

    # Cola compartida: el hilo de fondo mete objetos, el timer de UI los consume
    $script:ScanQueue = [System.Collections.Concurrent.ConcurrentQueue[object[]]]::new()

    # [PAUSE] Estado de pausa compartido entre hilo UI y runspace de escaneo
    $script:ScanPauseState = [hashtable]::Synchronized(@{ Paused = $false })

    # [OPT] Usar List<object> en lugar de ObservableCollection para la UI.
    # ObservableCollection dispara CollectionChanged por cada Add() individual — con miles
    # de carpetas esto presiona enormemente el sistema de binding WPF y el GC.
    # Usamos una List normal y llamamos lbDiskTree.Items.Refresh() solo en batches.
    # LiveItems eliminado: AllScannedItems+LiveIndexMap es la única fuente de verdad.
    $script:LiveItems = [System.Collections.Generic.Dictionary[string,int]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)  # clave → índice en AllScannedItems
    $script:LiveList  = [System.Collections.Generic.List[object]]::new(2048)
    $lbDiskTree.ItemsSource = $script:LiveList

    # ── [A1] Hilo de fondo: escáner PARALELO en C# via ParallelScanner ──────
    # Solo emite CARPETAS (estilo TreeSize). Paralelismo en nivel shallow (depth<=1)
    # para máximo throughput en NVMe sin crear un exceso de threads en discos HDD.
    # La cola es ConcurrentQueue<object[]> — array posicional:
    #   [0]=Key [1]=ParentKey [2]=Name [3]=Size [4]=Files [5]=Dirs [6]=Done [7]=Depth
    $bgScript = {
        param([string]$Root,
              [System.Collections.Concurrent.ConcurrentQueue[object[]]]$Q,
              [hashtable]$PauseState)

        try {
            $topDirs = try { [System.IO.Directory]::GetDirectories($Root) } catch { @() }
            [ScanCtl211]::Total = $topDirs.Length + 1

            # Llamar al escáner C# paralelo para cada carpeta de primer nivel
            # Pasamos $Root como parentKey para que aparezcan bajo ::ROOT:: en la UI
            foreach ($d in $topDirs) {
                if ([ScanCtl211]::Stop) { break }
                # [PAUSE] Spinwait mientras la UI pida pausa (intervalo 100ms para no quemar CPU)
                while ($PauseState.Paused -and -not [ScanCtl211]::Stop) {
                    [System.Threading.Thread]::Sleep(100)
                }
                if ([ScanCtl211]::Stop) { break }
                [PScanner211]::ScanDir($d, 0, '::ROOT::', $Q) | Out-Null
            }
            [ScanCtl211]::Done++
        } catch {}
    }

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = "STA"; $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    # en el nuevo runspace para que los tipos C# sean resolubles desde el hilo de fondo
    $sharedAsmPath = [ScanCtl211].Assembly.Location
    if ($sharedAsmPath -and (Test-Path $sharedAsmPath)) {
        [void]$rs.SessionStateProxy.InvokeCommand.InvokeScript(
            "`$null = [System.Reflection.Assembly]::LoadFrom('$sharedAsmPath')"
        )
    }
    [void]$ps.AddScript($bgScript).AddParameter("Root", $RootPath).AddParameter("Q", $script:ScanQueue).AddParameter("PauseState", $script:ScanPauseState)
    # Set DefaultRunspace so C# code can resolve PS types if needed
    $rs.SessionStateProxy.SetVariable("ErrorActionPreference", "SilentlyContinue")
    $script:DiskScanRunspace = $rs
    $script:DiskScanPS    = $ps
    $script:DiskScanAsync = $ps.BeginInvoke()

    # ── Registrar tarea con hooks de control ─────────────────────────────────
    $scanTask = Register-Task -Id "diskscan" -Name "Escaneo: $RootPath" -Icon "💾" -IconBg (Get-TC 'BgStatusInfo' '#1A2F4A')
    $scanTask.CancelFn = {
        [ScanCtl211]::Stop = $true
        if (([System.Management.Automation.PSTypeName]'ScanTokenManager').Type) {
            [ScanTokenManager]::Cancel()
        }
        if ($null -ne $script:btnDiskStop) {
            try { $script:btnDiskStop.IsEnabled = $false } catch {}
        }
        $script:txtDiskScanStatus.Text = "⏹ Cancelado desde panel de tareas…"
    }
    $scanTask.PauseFn = {
        $script:ScanPauseState.Paused = $true
        $script:txtDiskScanStatus.Text = "⏸ Escaneo pausado"
        if ($null -ne $script:btnDiskStop) {
            try { $script:btnDiskStop.Content = "▶  Reanudar" } catch {}
        }
    }
    $scanTask.ResumeFn = {
        $script:ScanPauseState.Paused = $false
        $script:txtDiskScanStatus.Text = "Escaneando…"
        if ($null -ne $script:btnDiskStop) {
            try { $script:btnDiskStop.Content = "⏹  Detener" } catch {}
        }
    }

    # ── Timer UI: drena la cola y actualiza lista cada 300 ms ──────────────────
    # LiveIndexMap: clave→posición en LiveList para actualizaciones O(1)
    $script:LiveIndexMap = [System.Collections.Generic.Dictionary[string,int]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    $script:SortTickCounter = 0
    $script:GcTickCounter   = 0   # [OPT] para GC periódico durante scan

    # [FIX-CLOSURE] uiTimer debe estar en $script: para que Add_Tick pueda llamar a .Stop()
    if ($null -ne $script:DiskUiTimer) { try { $script:DiskUiTimer.Stop() } catch {} }
    $script:DiskUiTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:DiskUiTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:DiskUiTimer.Add_Tick({
        $total = [ScanCtl211]::Total
        $done  = [ScanCtl211]::Done
        $cur   = [ScanCtl211]::Current

        if ($total -gt 0) {
            $pbDiskScan.IsIndeterminate = $false
            $pbDiskScan.Value = [math]::Min(99, [math]::Round($done / $total * 100))
        }

        $lw = if ($lbDiskTree.ActualWidth -gt 100) { $lbDiskTree.ActualWidth - 270 } else { 400 }

        # Procesar hasta 600 mensajes por tick
        $anyUpdate   = $false
        $listChanged = $false
        $processed   = 0
        $msg = $null
        while ($processed -lt 600 -and ($null -ne $script:ScanQueue) -and $script:ScanQueue.TryDequeue([ref]$msg)) {
            $processed++
            $key       = [string]$msg[0]
            $parentKey = if ($msg[1]) { [string]$msg[1] } else { '::ROOT::' }
            $msgName   = [string]$msg[2]
            $msgSize   = [long]$msg[3]
            $msgFiles  = [int]$msg[4]
            $msgDirs   = [int]$msg[5]
            $msgDone   = [bool]$msg[6]
            $depth     = [int]$msg[7]
            $indent    = "$([math]::Max(4, $depth * 22)),0,0,0"

            if (-not $msgDone) {
                # Placeholder — solo si no existe ya en AllScannedItems
                if (-not $script:LiveItems.ContainsKey($key)) {
                    $entry = New-Object DiskItem_v211
                    $entry.DisplayName      = $msgName
                    $entry.FullPath         = $key
                    $entry.ParentPath       = $parentKey
                    $entry.SizeBytes        = -1L
                    $entry.SizeStr          = [char]0x2026
                    $entry.SizeColor        = "#8B96B8"
                    $entry.PctStr           = [char]0x2014
                    $entry.FileCount        = [char]0x2026
                    $entry.DirCount         = 0
                    $entry.IsDir            = $true
                    $entry.HasChildren      = $false
                    $entry.Icon             = [char]0xD83D + [char]0xDCC1
                    $entry.Indent           = $indent
                    $entry.BarWidth         = 0.0
                    $entry.BarColor         = "#3A4468"
                    $entry.TotalPct         = 0.0
                    $entry.Depth            = $depth
                    $entry.ToggleIcon       = [char]0x25B6
                    $entry.ToggleVisibility = "Collapsed"
                    $idx = $script:AllScannedItems.Count
                    $script:AllScannedItems.Add($entry)
                    $script:LiveItems[$key] = $idx   # índice en AllScannedItems
                    # Añadir a LiveList solo si ningún ancestro está colapsado
                    $hidden = $false
                    $pp = $parentKey
                    while ($pp -and $pp -ne '::ROOT::') {
                        if ($script:CollapsedPaths.Contains($pp)) { $hidden = $true; break }
                        $pp2 = try { [System.IO.Path]::GetDirectoryName($pp) } catch { $null }
                        $pp = if ($pp2 -and $pp2 -ne $pp) { $pp2 } else { $null }
                    }
                    if (-not $hidden) { $script:LiveList.Add($entry); $listChanged = $true }
                }
            } else {
                # Datos reales de carpeta completada
                $sz     = $msgSize
                $sc     = if ($sz -ge 10GB) {"#FF6B84"} elseif ($sz -ge 1GB) {"#FFB547"} elseif ($sz -ge 100MB) {"#5BA3FF"} else {"#B0BACC"}
                $szStr  = [Formatter]::FormatBytes([long]$sz)
                $fc     = "$msgFiles arch.  $msgDirs carp."
                $hasCh  = $msgDirs -gt 0

                if ($script:LiveItems.ContainsKey($key)) {
                    # Actualizar el objeto existente en AllScannedItems directamente
                    $ex = $script:AllScannedItems[$script:LiveItems[$key]]
                    $ex.SizeBytes        = $sz
                    $ex.SizeStr          = $szStr
                    $ex.SizeColor        = $sc
                    $ex.FileCount        = $fc
                    $ex.DirCount         = $msgDirs
                    $ex.HasChildren      = $hasCh
                    $ex.BarColor         = $sc
                    $ex.ToggleVisibility = if ($hasCh) {"Visible"} else {"Collapsed"}
                    $ex.ToggleIcon       = if ($script:CollapsedPaths.Contains($key)) { [char]0x25B6 } else { [char]0x25BC }
                } else {
                    $ne = New-Object DiskItem_v211
                    $ne.DisplayName      = $msgName
                    $ne.FullPath         = $key
                    $ne.ParentPath       = $parentKey
                    $ne.SizeBytes        = $sz
                    $ne.SizeStr          = $szStr
                    $ne.SizeColor        = $sc
                    $ne.PctStr           = [char]0x2014
                    $ne.FileCount        = $fc
                    $ne.DirCount         = $msgDirs
                    $ne.IsDir            = $true
                    $ne.HasChildren      = $hasCh
                    $ne.Icon             = [char]0xD83D + [char]0xDCC1
                    $ne.Indent           = $indent
                    $ne.BarWidth         = 0.0
                    $ne.BarColor         = $sc
                    $ne.TotalPct         = 0.0
                    $ne.Depth            = $depth
                    $ne.ToggleIcon       = if ($script:CollapsedPaths.Contains($key)) { [char]0x25B6 } else { [char]0x25BC }
                    $ne.ToggleVisibility = if ($hasCh) {"Visible"} else {"Collapsed"}
                    $idx2 = $script:AllScannedItems.Count
                    $script:AllScannedItems.Add($ne)
                    $script:LiveItems[$key] = $idx2
                    $hidden2 = $false
                    $pp3 = $parentKey
                    while ($pp3 -and $pp3 -ne '::ROOT::') {
                        if ($script:CollapsedPaths.Contains($pp3)) { $hidden2 = $true; break }
                        $pp4 = try { [System.IO.Path]::GetDirectoryName($pp3) } catch { $null }
                        $pp3 = if ($pp4 -and $pp4 -ne $pp3) { $pp4 } else { $null }
                    }
                    if (-not $hidden2) { $script:LiveList.Add($ne); $listChanged = $true }
                }
                $anyUpdate = $true
            }
            $msg = $null
        }

        # [OPT] Notificar WPF solo una vez por batch (no por cada Add)
        if ($listChanged) {
            $lbDiskTree.Items.Refresh()
        }

        # [A2] Actualizar porcentajes en tiempo real
        if ($anyUpdate) {
            $rtTotal = 0L
            foreach ($v in $script:AllScannedItems) {
                if ($v.Depth -eq 0 -and $v.SizeBytes -gt 0) { $rtTotal += $v.SizeBytes }
            }
            if ($rtTotal -gt 0) {
                $lw2 = if ($lbDiskTree.ActualWidth -gt 100) { $lbDiskTree.ActualWidth - 270 } else { 400 }
                foreach ($s in $script:AllScannedItems) {
                    if ($s.SizeBytes -gt 0) {
                        $pct2 = [math]::Round($s.SizeBytes / $rtTotal * 100, 1)
                        $s.PctStr   = "$pct2%"
                        $s.TotalPct = $pct2
                        $s.BarWidth = [double][math]::Max(0, [math]::Round($pct2 / 100 * $lw2))
                    }
                }
            }
        }

        # Re-ordenar por tamaño cada ~5 ticks (~1.5 s)
        $script:SortTickCounter++
        if ($anyUpdate -and $script:SortTickCounter % 5 -eq 0) {
            Refresh-DiskView -RebuildMap
        }

        # [OPT] GC periódico durante el scan — cada 20 ticks (~6 s)
        # Libera strings intermedios, arrays de la cola C# y objetos temporales PS
        $script:GcTickCounter++
        if ($script:GcTickCounter % 20 -eq 0) {
            [GC]::Collect(0, [GCCollectionMode]::Optimized)
        }

        if ($anyUpdate) {
            $cnt = $script:AllScannedItems.Count
            $tot = [ScanCtl211]::Total; $don = [ScanCtl211]::Done
            $pctScan = if ($tot -gt 0) { [int]([math]::Min(99, $don * 100 / $tot)) } else { 0 }
            Update-Task -Id "diskscan" -Pct $pctScan -Detail "$cnt carpetas · $don/$tot"
            $txtDiskScanStatus.Text = "Escaneando$([char]0x2026)  $cnt carpetas  $([char]0x00B7)  $don/$tot  $([char]0x00B7)  $cur"
        }

        # ¿Terminó el runspace?
        if ($null -ne $script:DiskScanAsync -and $script:DiskScanAsync.IsCompleted) {
            $drainMsg = $null
            while (($null -ne $script:ScanQueue) -and $script:ScanQueue.TryDequeue([ref]$drainMsg)) {
                $dk       = [string]$drainMsg[0]
                $dpk      = if ($drainMsg[1]) { [string]$drainMsg[1] } else { '::ROOT::' }
                $dn       = [string]$drainMsg[2]
                $dsz      = [long]$drainMsg[3]
                $dfiles   = [int]$drainMsg[4]
                $ddirs    = [int]$drainMsg[5]
                $ddone    = [bool]$drainMsg[6]
                $ddepth   = [int]$drainMsg[7]
                $dindent  = "$([math]::Max(4, $ddepth * 22)),0,0,0"

                if (-not $ddone) {
                    if (-not $script:LiveItems.ContainsKey($dk)) {
                        $de = New-Object DiskItem_v211
                        $de.DisplayName = $dn; $de.FullPath = $dk; $de.ParentPath = $dpk
                        $de.SizeBytes = -1L; $de.SizeStr = [char]0x2026; $de.SizeColor = "#8B96B8"
                        $de.PctStr = [char]0x2014; $de.FileCount = [char]0x2026; $de.DirCount = 0
                        $de.IsDir = $true; $de.HasChildren = $false
                        $de.Icon = [char]0xD83D + [char]0xDCC1
                        $de.Indent = $dindent; $de.BarWidth = 0.0; $de.BarColor = "#3A4468"
                        $de.TotalPct = 0.0; $de.Depth = $ddepth
                        $de.ToggleIcon = [char]0x25B6; $de.ToggleVisibility = "Collapsed"
                        $didx = $script:AllScannedItems.Count
                        $script:AllScannedItems.Add($de)
                        $script:LiveItems[$dk] = $didx
                    }
                } else {
                    $dsc    = if ($dsz -ge 10GB) {"#FF6B84"} elseif ($dsz -ge 1GB) {"#FFB547"} elseif ($dsz -ge 100MB) {"#5BA3FF"} else {"#B0BACC"}
                    $dszStr = [Formatter]::FormatBytes([long]$dsz)
                    $dhch   = $ddirs -gt 0
                    if ($script:LiveItems.ContainsKey($dk)) {
                        $dex = $script:AllScannedItems[$script:LiveItems[$dk]]
                        $dex.SizeBytes = $dsz; $dex.SizeStr = $dszStr; $dex.SizeColor = $dsc
                        $dex.FileCount = "$dfiles arch.  $ddirs carp."; $dex.DirCount = $ddirs
                        $dex.HasChildren = $dhch; $dex.BarColor = $dsc
                        $dex.ToggleVisibility = if ($dhch) {"Visible"} else {"Collapsed"}
                    } else {
                        $dne = New-Object DiskItem_v211
                        $dne.DisplayName = $dn; $dne.FullPath = $dk; $dne.ParentPath = $dpk
                        $dne.SizeBytes = $dsz; $dne.SizeStr = $dszStr; $dne.SizeColor = $dsc
                        $dne.PctStr = [char]0x2014; $dne.FileCount = "$dfiles arch.  $ddirs carp."
                        $dne.DirCount = $ddirs; $dne.IsDir = $true; $dne.HasChildren = $dhch
                        $dne.Icon = [char]0xD83D + [char]0xDCC1; $dne.Indent = $dindent
                        $dne.BarWidth = 0.0; $dne.BarColor = $dsc; $dne.TotalPct = 0.0; $dne.Depth = $ddepth
                        $dne.ToggleIcon = [char]0x25BC; $dne.ToggleVisibility = if ($dhch) {"Visible"} else {"Collapsed"}
                        $didx2 = $script:AllScannedItems.Count
                        $script:AllScannedItems.Add($dne)
                        $script:LiveItems[$dk] = $didx2
                    }
                }
                $drainMsg = $null
            }

            # [OPT] ScanQueue vaciada — liberar referencia para que el GC recoja los arrays
            $script:ScanQueue = $null

$script:DiskUiTimer.Stop()
            try { $script:DiskScanPS.EndInvoke($script:DiskScanAsync) | Out-Null } catch {}
            try { $script:DiskScanPS.Dispose(); $script:DiskScanRunspace.Close(); $script:DiskScanRunspace.Dispose() } catch {}
            $script:DiskScanAsync = $null
            $script:DiskScanPS    = $null

            # Calcular tamaño total: suma de todas las carpetas de primer nivel (Depth=0)
            $gt2 = 0L
            foreach ($v in $script:AllScannedItems) {
                if ($v.Depth -eq 0 -and $v.SizeBytes -gt 0) { $gt2 += $v.SizeBytes }
            }

            # Asignar porcentajes y corregir ToggleVisibility final en todos los items
            if ($gt2 -gt 0) {
                foreach ($s in $script:AllScannedItems) {
                    if ($s.SizeBytes -gt 0) {
                        $pct = [math]::Round($s.SizeBytes / $gt2 * 100, 1)
                        $bw  = [math]::Max(0, [math]::Round($pct / 100 * $lw))
                        $s.PctStr   = "$pct%"
                        $s.TotalPct = $pct
                        $s.BarWidth = [double]$bw
                    }
                    # Asegurar ToggleVisibility correcto según HasChildren real
                    if ($s.IsDir) {
                        $s.ToggleVisibility = if ($s.HasChildren) { "Visible" } else { "Collapsed" }
                        $s.ToggleIcon       = if ($script:CollapsedPaths.Contains($s.FullPath)) { "▶" } else { "▼" }
                    }
                }
            }

            # Reconstruir LiveList final respetando colapsos (o filtro activo)
            $script:LiveIndexMap.Clear()
            if (-not [string]::IsNullOrWhiteSpace($script:FilterText)) {
                Apply-DiskFilter $script:FilterText
            } else {
                Refresh-DiskView -RebuildMap
            }
            # [OPT] Notificar WPF de la reconstrucción de LiveList (sustituye ObservableCollection)
            $lbDiskTree.Items.Refresh()

            # [OPT] Compactar listas y liberar RAM al SO tras escaneo completo
            $script:AllScannedItems.TrimExcess()
            $script:LiveList.TrimExcess()
            # Liberar el LiveItems index map (ya no se necesita hasta el próximo scan)
            $script:LiveItems.Clear()
            Invoke-AggressiveGC

            $pbDiskScan.IsIndeterminate = $false
            $pbDiskScan.Value = 100
            $btnDiskScan.IsEnabled = $true
            $btnDiskStop.IsEnabled = $false
            $btnExportCsv.IsEnabled    = $true
            $btnDiskReport.IsEnabled   = $true  # Informe HTML
            $btnDedup.IsEnabled        = $true
            $btnSnapshotSave.IsEnabled    = $true
            $txtSnapshotName.IsEnabled    = $true
            $txtSnapshotName.Text         = "Escaneo $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
            $txtSnapshotName.SelectAll()

            $gtStr2 = [Formatter]::FormatBytes([long]$gt2)
            $emoji = if ([ScanCtl211]::Stop) { "⏹" } else { "✅" }
            $txtDiskScanStatus.Text = "$emoji  $($script:AllScannedItems.Count) elementos  ·  $gtStr2  ·  $(Get-Date -Format 'HH:mm:ss')"
            $wasStop = [ScanCtl211]::Stop
            Complete-Task -Id "diskscan" -IsError:$wasStop -Detail "$($script:AllScannedItems.Count) elementos · $gtStr2"
        }
    })
$script:DiskUiTimer.Start()
}

$btnDiskBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    try {
        $dlg.Description  = "Selecciona la carpeta a escanear"
        $dlg.RootFolder   = "MyComputer"
        $dlg.SelectedPath = $txtDiskScanPath.Text
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtDiskScanPath.Text = $dlg.SelectedPath
        }
    } finally { $dlg.Dispose() }
})

$btnDiskScan.Add_Click({
    Save-Settings  # [C3]
    Start-DiskScan -RootPath $txtDiskScanPath.Text.Trim()
})

$btnDiskStop.Add_Click({
    [ScanCtl211]::Stop = $true
    if (([System.Management.Automation.PSTypeName]'ScanTokenManager').Type) {
        [ScanTokenManager]::Cancel()   # [CTK] cancelación limpia via token
    }
    $btnDiskStop.IsEnabled = $false
    $txtDiskScanStatus.Text = "⏹ Cancelando — espera a que termine la carpeta actual…"
})

# ─────────────────────────────────────────────────────────────────────────────
# [C3] PERSISTENCIA DE CONFIGURACIÓN — %APPDATA%\SysOpt\settings.json
# ─────────────────────────────────────────────────────────────────────────────
$script:SettingsPath = [System.IO.Path]::Combine(
    [Environment]::GetFolderPath("ApplicationData"), "SysOpt", "settings.json")

function Save-Settings {
    try {
        $dir = [System.IO.Path]::GetDirectoryName($script:SettingsPath)
        if (-not (Test-Path $dir)) { [System.IO.Directory]::CreateDirectory($dir) | Out-Null }
        $cfg = @{
            DiskScanPath       = $txtDiskScanPath.Text
            AutoRefresh        = ($chkAutoRefresh.IsChecked -eq $true)
            RefreshIntervalSec = if ($cmbRefreshInterval.SelectedItem) { $cmbRefreshInterval.SelectedItem.Tag } else { "5" }
            DiskFilterText     = $txtDiskFilter.Text
            Theme              = $script:CurrentTheme
            Language           = $script:CurrentLang
            DebugLog           = [LogEngine]::DebugEnabled
        }
        $json = $cfg | ConvertTo-Json
        # Escritura atómica: temp → Move evita file-lock conflicts
        $tmp = $script:SettingsPath + ".tmp"
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
        [System.IO.File]::Copy($tmp, $script:SettingsPath, $true)
        try { [System.IO.File]::Delete($tmp) } catch {}
    } catch {
        Write-Log "[WARN] No se pudo guardar settings.json: $_" -Level "WARN" -NoUI
    }
}

function Load-Settings {
    try {
        if (Test-Path $script:SettingsPath) {
            $cfg = Get-Content -Path $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.DiskScanPath)   { $txtDiskScanPath.Text = $cfg.DiskScanPath }
            if ($cfg.DiskFilterText) { $txtDiskFilter.Text   = $cfg.DiskFilterText }
            # Auto-refresh interval
            if ($cfg.RefreshIntervalSec) {
                foreach ($item in $cmbRefreshInterval.Items) {
                    if ($item.Tag -eq "$($cfg.RefreshIntervalSec)") {
                        $cmbRefreshInterval.SelectedItem = $item; break
                    }
                }
            }
            # Auto-refresh on/off (set last so timer uses correct interval)
            if ($cfg.AutoRefresh -eq $true) { $chkAutoRefresh.IsChecked = $true }
            if ($cfg.Theme -and (Test-Path (Join-Path $script:ThemesDir "$($cfg.Theme).theme"))) {
                $script:CurrentTheme = $cfg.Theme
            }
            if ($cfg.Language -and (Test-Path (Join-Path $script:LangDir "$($cfg.Language).lang"))) {
                $script:CurrentLang = $cfg.Language
            }
            # Debug logging toggle
            if ($cfg.PSObject.Properties['DebugLog'] -and $cfg.DebugLog -eq $true) {
                [LogEngine]::DebugEnabled = $true
            }
        }
    } catch {}
}

# ─────────────────────────────────────────────────────────────────────────────
# [I18N] Cargar idioma y aplicar a toda la UI
# ─────────────────────────────────────────────────────────────────────────────
function Load-Language {
    param([string]$LangCode)
    $langPath = Join-Path $script:LangDir "$LangCode.lang"
    if (-not (Test-Path $langPath)) {
        Write-Log "[LANG] Archivo de idioma no encontrado: $LangCode  (path: $langPath)" -Level "WARN" -NoUI
        return
    }
    Write-Log "[LANG] Cargando idioma: $LangCode" -Level "INFO" -NoUI

    try {
        $script:LangDict    = [LangEngine]::ParseLangFile($langPath)
        $script:CurrentLang  = $LangCode
    } catch {
        Write-Verbose "SysOpt: Error al cargar idioma $LangCode : $($_.Exception.Message)"
        return
    }

    # Aplicar textos a controles conocidos
    Apply-LanguageToUI
}

function Apply-LanguageToUI {
    $d = $script:LangDict
    if ($d.Count -eq 0) { return }

    # Título de ventana
    $window.Title = "SysOpt - $(T 'AppSubtitle' 'Windows Optimizer GUI') v$($script:AppVersion)"

    # StatusText
    if ($null -ne $StatusText -and $StatusText.Text -match 'Listo|Ready|Pronto') {
        $StatusText.Text = T 'StatusReady' 'Listo para optimizar'
    }

    # Tooltips
    if ($null -ne $btnShowTasks) { $btnShowTasks.ToolTip = T 'TooltipTasks'   'Tareas en segundo plano' }
    if ($null -ne $btnOptions)   { $btnOptions.ToolTip   = T 'TooltipOptions' 'Opciones' }
    if ($null -ne $btnAbout)     { $btnAbout.ToolTip     = T 'TooltipAbout'   'Acerca de SysOpt' }
    if ($null -ne $btnRefreshInfo) { $btnRefreshInfo.ToolTip = T 'TooltipRefreshInfo' 'Actualizar información del sistema' }

    # DryRun label
    if ($null -ne $chkDryRun -and $null -ne $chkDryRun.Content) {
        try { $chkDryRun.Content.Text = T 'DryRunLabel' 'MODO ANÁLISIS  (sin cambios)' } catch {}
    }

    # Tab headers
    $tabs = $window.FindName("tabMain")
    if ($null -ne $tabs -and $tabs.Items.Count -ge 4) {
        $tabs.Items[0].Header = T 'TabOptimization' '⚙  Optimización'
        $tabs.Items[1].Header = T 'TabPerformance'  '📊  Rendimiento'
        $tabs.Items[2].Header = T 'TabDisk'         '💾  Explorador de Disco'
        $tabs.Items[3].Header = T 'TabHistory'      '🕒  Historial'
    }

    # Checkboxes de optimización
    $chkMap = @{
        chkOptimizeDisks  = 'ChkOptimizeDisks'
        chkRecycleBin     = 'ChkRecycleBin'
        chkTempFiles      = 'ChkTempFiles'
        chkUserTemp       = 'ChkUserTemp'
        chkWUCache        = 'ChkWUCache'
        chkChkdsk         = 'ChkChkdsk'
        chkClearMemory    = 'ChkClearMemory'
        chkCloseProcesses = 'ChkCloseProcesses'
        chkDNSCache       = 'ChkDNSCache'
        chkBrowserCache   = 'ChkBrowserCache'
        chkBackupRegistry = 'ChkBackupRegistry'
        chkCleanRegistry  = 'ChkCleanRegistry'
        chkSFC            = 'ChkSFC'
        chkDISM           = 'ChkDISM'
        chkEventLogs      = 'ChkEventLogs'
        chkShowStartup    = 'ChkShowStartup'
    }
    foreach ($entry in $chkMap.GetEnumerator()) {
        $ctrl = $window.FindName($entry.Key)
        if ($null -ne $ctrl -and $d.ContainsKey($entry.Value)) {
            $ctrl.Content = $d[$entry.Value]
        }
    }

    # Botones principales
    if ($null -ne $btnStart)     { $btnStart.Content     = T 'BtnStart'     '▶  Iniciar optimización' }
    if ($null -ne $btnDryRun)    { $btnDryRun.Content    = T 'BtnDryRun'    'Analizar' }
    if ($null -ne $btnSelectAll) { $btnSelectAll.Content  = T 'BtnSelectAll' 'Seleccionar todo' }
    if ($null -ne $btnCancel -and $btnCancel.IsEnabled -eq $false) {
        $btnCancel.Content = T 'BtnCancel' 'Cancelar'
    }
    if ($null -ne $btnSaveLog)   { $btnSaveLog.Content   = T 'BtnSaveLog'  'Guardar log' }
    if ($null -ne $btnExit)      { $btnExit.Content      = T 'BtnExit'     'Salir' }

    # CheckBox reiniciar
    if ($null -ne $chkAutoRestart) {
        try { $chkAutoRestart.Content.Text = T 'ChkAutoRestart' 'Reiniciar al finalizar' } catch {
            $chkAutoRestart.Content = T 'ChkAutoRestart' 'Reiniciar al finalizar'
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# [THEME] Aplicar tema con barra de progreso + subproceso para parsing
# ─────────────────────────────────────────────────────────────────────────────
# Theme color mapping: XAML hex -> (ThemeKey, OffsetR, OffsetG, OffsetB)

$script:ThemeColorMap = @{
    "00D4B4" = @("AccentCyan", -74, -20, 30)
    "080A14" = @("ConsoleBg", 0, 0, 0)
    "0D0F1A" = @("BgDeep", 0, 0, 0)
    "0E2E2A" = @("BtnCyanBg", 1, 0, 6)
    "131625" = @("BgCardDark", 0, 0, 0)
    "132040" = @("BgInput", -11, -2, 11)
    "161925" = @("BgCard", 0, 0, 0)
    "163530" = @("DryRunBg", 9, 13, 0)
    "181D2E" = @("PurpleBlobBg", -2, 9, -2)
    "182A1E" = @("BgStatusOk", 0, 0, 0)
    "1A1E2A" = @("BgCard", 4, 5, 5)
    "1A1E2F" = @("BgInput", -4, -4, -6)
    "1A2035" = @("BgInput", -4, -2, 0)
    "1A2040" = @("BgInput", -4, -2, 11)
    "1A2540" = @("CtxHover", -4, -5, -8)
    "1A2F4A" = @("BgStatusInfo", 0, 0, 0)
    "1A3A5C" = @("BgStatusInfo", 0, 11, 18)
    "1A4A35" = @("BgStatusOk", 2, 32, 23)
    "1A6B3E" = @("BgStatusInfo", 0, 60, -12)
    "1E2235" = @("BgInput", 0, 0, 0)
    "1E3058" = @("ComboSelected", 0, 0, -8)
    "1E3A5C" = @("ComboSelected", 0, 10, -4)
    "252A38" = @("BgInput", 7, 8, 3)
    "252B3B" = @("BgInput", 7, 9, 6)
    "252B40" = @("BorderSubtle", -5, -4, -8)
    "253060" = @("ComboSelected", 7, 0, 0)
    "28C874" = @("AccentCyan", -34, -32, -34)
    "2A1018" = @("BgStatusErr", 0, 0, 0)
    "2A1A4A" = @("PurpleBlobBg", 18, -3, 28)
    "2A2010" = @("BgStatusWarn", 0, 0, 0)
    "2A2F48" = @("BorderSubtle", 0, 0, 0)
    "2A3048" = @("BorderSubtle", 0, 1, 0)
    "2A3448" = @("BorderSubtle", 0, 5, 0)
    "2A3A5A" = @("ComboSelected", 12, 10, -6)
    "2E0E14" = @("BtnDangerBg", 0, -2, -4)
    "2E1E08" = @("BtnAmberBg", 0, -2, -8)
    "2E3650" = @("BorderSubtle", 4, 7, 8)
    "2EDFBF" = @("AccentCyan", -28, -9, 41)
    "2FD980" = @("AccentCyan", -27, -15, -22)
    "3A2010" = @("BgStatusWarn", 16, 0, 0)
    "3A4060" = @("BorderHover", 0, 0, 0)
    "3A4468" = @("BorderHover", 0, 4, 8)
    "3D5080" = @("BorderHover", 3, 16, 32)
    "3D8EFF" = @("BorderActive", -30, -21, 0)
    "4A3010" = @("BtnAmberBg", 28, 16, 0)
    "4AE896" = @("AccentCyan", 0, 0, 0)
    "5AE88A" = @("AccentCyan", 16, 0, -12)
    "5BA3FF" = @("BorderActive", 0, 0, 0)
    "6ABDA0" = @("AccentCyan", 32, -43, 10)
    "6B7A9E" = @("TextMuted", 0, 6, 10)
    "7880A0" = @("TextMuted", 13, 12, 12)
    "7BA8E0" = @("BorderActive", 32, 5, -31)
    "8B96B8" = @("TextSecondary", -16, -14, -8)
    "9B7EFF" = @("AccentPurple", -9, 2, 0)
    "9BA4C0" = @("TextSecondary", 0, 0, 0)
    "A47CFF" = @("AccentPurple", 0, 0, 0)
    "B0BACC" = @("TextSecondary", 21, 22, 12)
    "C07AFF" = @("AccentPurple", 28, -2, 0)
    "C0933A" = @("AccentAmber", -63, -34, -13)
    "CC2244" = @("AccentRed", -51, -73, -64)
    "D0D8F0" = @("TextPrimary", -24, -18, -6)
    "D4850A" = @("AccentAmber", -43, -48, -61)
    "D4D9E8" = @("TextPrimary", -20, -17, -14)
    "E0E8F4" = @("TextPrimary", -8, -2, -2)
    "E8ECF4" = @("TextPrimary", 0, 2, -2)
    "F0F3FA" = @("TextPrimary", 8, 9, 4)
    "F5A623" = @("AccentAmber", -10, -15, -36)
    "FF4D6A" = @("AccentRed", 0, -30, -26)
    "FF6B84" = @("AccentRed", 0, 0, 0)
    "FFB547" = @("AccentAmber", 0, 0, 0)
    "FFFFFF" = @("BtnPrimaryFg", 0, 0, 0)
    "1A4A8A" = @("BtnPrimaryBg", 0, 0, 0)
    "0D2E24" = @("BtnCyanBg", 0, 0, 0)
    "2E2010" = @("BtnAmberBg", 0, 0, 0)
    "2E1018" = @("BtnDangerBg", 0, 0, 0)
    "6B7494" = @("TextMuted", 0, 0, 0)
}

# ─────────────────────────────────────────────────────────────────────────────
# Apply-ButtonTheme — pinta programáticamente los botones nombrados de la
# ventana principal usando las claves del tema activo. Complementa el sistema
# TB_RRGGBB (DynamicResource) para botones con colores asignados directamente.
# ─────────────────────────────────────────────────────────────────────────────
function Apply-ButtonTheme {
    $bc = [System.Windows.Media.BrushConverter]::new()

    # Helper: clave de tema → SolidColorBrush
    function Local:Brush([string]$key, [string]$fallback) {
        $bc.ConvertFromString((Get-TC $key $fallback))
    }

    # ── Paleta por tipo de botón ──────────────────────────────────────────────
    $palette = @{
        "Primary"   = @{ Bg = (Brush 'BtnPrimaryBg'   '#1A4A8A'); Fg = (Brush 'BtnPrimaryFg'   '#FFFFFF'); Border = (Brush 'BtnPrimaryBorder' '#5BA3FF') }
        "Cyan"      = @{ Bg = (Brush 'BtnCyanBg'      '#0D2E24'); Fg = (Brush 'BtnCyanFg'      '#4AE896'); Border = (Brush 'AccentCyan'       '#4AE896') }
        "Amber"     = @{ Bg = (Brush 'BtnAmberBg'     '#2E2010'); Fg = (Brush 'BtnAmberFg'     '#FFB547'); Border = (Brush 'AccentAmber'      '#FFB547') }
        "Danger"    = @{ Bg = (Brush 'BtnDangerBg'    '#2E1018'); Fg = (Brush 'BtnDangerFg'    '#FF6B84'); Border = (Brush 'AccentRed'        '#FF6B84') }
        "Secondary" = @{ Bg = (Brush 'BtnSecondaryBg' '#1E2235'); Fg = (Brush 'BtnSecondaryFg' '#9BA4C0'); Border = (Brush 'BorderSubtle'     '#2A2F48') }
        "Ghost"     = @{ Bg = (Brush 'BtnGhostBg'     '#1E2235'); Fg = (Brush 'BtnGhostFg'     '#6B7494'); Border = (Brush 'BtnGhostBorder'   '#2A2F48') }
    }

    # ── Mapa: nombre exacto del control → tipo ───────────────────────────────
    $btnMap = @{
        # ── Footer (barra inferior) ───────────────────────────────────────────
        "btnStart"           = "Primary"    # ▶ Iniciar optimización
        "btnDryRun"          = "Cyan"       # 🔍 Analizar
        "btnCancel"          = "Amber"      # Cancelar
        "btnSelectAll"       = "Secondary"  # Seleccionar todo
        "btnSaveLog"         = "Secondary"  # Guardar log
        "btnExit"            = "Danger"     # Salir
        # ── Header (barra superior) ───────────────────────────────────────────
        "btnShowTasks"       = "Ghost"      # ⚡ Tareas
        "btnOptions"         = "Ghost"      # ⚙ Opciones
        "btnAbout"           = "Ghost"      # ℹ About
        "btnRefreshInfo"     = "Ghost"      # 🔄 Actualizar info del sistema
        # ── Tab Rendimiento ───────────────────────────────────────────────────
        "btnRefreshPerf"     = "Cyan"       # ↺ Actualizar
        # ── Tab Explorador de Disco ───────────────────────────────────────────
        "btnDiskScan"        = "Cyan"       # 🔍 Escanear
        "btnDiskStop"        = "Amber"      # ⏹ Detener
        "btnDiskBrowse"      = "Ghost"      # 📁 Browse (carpeta)
        "btnDiskFilterClear" = "Ghost"      # ✕ Limpiar filtro
        # ── Tab Historial / Snapshots ─────────────────────────────────────────
        "btnSnapshotSave"    = "Secondary"  # 💾 Guardar
        "btnSnapshotCompare" = "Cyan"       # 📊 Comparar
        "btnSnapshotDelete"  = "Danger"     # 🗑 Eliminar
    }

    foreach ($name in $btnMap.Keys) {
        try {
            $ctrl = $window.FindName($name)
            if ($null -eq $ctrl) { continue }
            $p = $palette[$btnMap[$name]]
            $ctrl.Background  = $p.Bg
            $ctrl.Foreground  = $p.Fg
            $ctrl.BorderBrush = $p.Border
        } catch {}
    }
}

function Apply-ThemeWithProgress {
    param([string]$ThemeName)

    $themePath = Join-Path $script:ThemesDir "$ThemeName.theme"
    if (-not (Test-Path $themePath)) {
        Show-ThemedDialog -Title (T 'DlgError' 'Error') `
            -Message "Tema no encontrado: $ThemeName" -Type "error"
        return
    }

    # -- Progress window (uses current theme colors) --
    $progWin = New-Object System.Windows.Window
    $progWin.Title                 = ""
    $progWin.Width                 = 440
    $progWin.Height                = 120
    $progWin.WindowStartupLocation = "CenterOwner"
    $progWin.ResizeMode            = "NoResize"
    $progWin.WindowStyle           = "None"
    $progWin.AllowsTransparency    = $true
    $progWin.Background            = [System.Windows.Media.Brushes]::Transparent
    $progWin.Topmost               = $true
    try { $progWin.Owner = $window } catch {}

    $bc = [System.Windows.Media.BrushConverter]::new()

    $rootBorder = New-Object System.Windows.Controls.Border
    $rootBorder.CornerRadius    = [System.Windows.CornerRadius]::new(12)
    $rootBorder.BorderBrush     = $bc.ConvertFromString((Get-TC 'AccentBlue' '#5BA3FF'))
    $rootBorder.BorderThickness = [System.Windows.Thickness]::new(1)
    $rootBorder.Background      = $bc.ConvertFromString((Get-TC 'BgCardDark' '#131625'))

    $shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
    $shadow.BlurRadius = 24; $shadow.ShadowDepth = 0; $shadow.Opacity = 0.5
    $shadow.Color = [System.Windows.Media.Colors]::Black
    $rootBorder.Effect = $shadow

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(24,16,24,16)

    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.FontFamily = [System.Windows.Media.FontFamily]::new("Segoe UI")
    $lbl.FontSize   = 12
    $lbl.FontWeight = [System.Windows.FontWeights]::SemiBold
    $lbl.Foreground = $bc.ConvertFromString((Get-TC 'TextPrimary' '#E8ECF4'))
    $lbl.Margin     = [System.Windows.Thickness]::new(0,0,0,8)
    $lbl.Text       = T 'SplashApplyingTheme' 'Aplicando tema...'

    $barBg = New-Object System.Windows.Controls.Border
    $barBg.Height          = 6
    $barBg.CornerRadius    = [System.Windows.CornerRadius]::new(3)
    $barBg.Background      = $bc.ConvertFromString((Get-TC 'BgInput' '#1A1E2F'))

    $barFill = New-Object System.Windows.Controls.Border
    $barFill.HorizontalAlignment = "Left"
    $barFill.Width        = 0
    $barFill.Height       = 6
    $barFill.CornerRadius = [System.Windows.CornerRadius]::new(3)
    $grad = New-Object System.Windows.Media.LinearGradientBrush
    $grad.StartPoint = [System.Windows.Point]::new(0,0)
    $grad.EndPoint   = [System.Windows.Point]::new(1,0)
    $grad.GradientStops.Add([System.Windows.Media.GradientStop]::new(
        [System.Windows.Media.ColorConverter]::ConvertFromString((Get-TC 'ProgressStart' '#5BA3FF')), 0))
    $grad.GradientStops.Add([System.Windows.Media.GradientStop]::new(
        [System.Windows.Media.ColorConverter]::ConvertFromString((Get-TC 'ProgressEnd' '#2EDFBF')), 1))
    $barFill.Background = $grad

    $barBg.Child = $barFill
    [void]$sp.Children.Add($lbl)
    [void]$sp.Children.Add($barBg)
    $rootBorder.Child = $sp
    $progWin.Content  = $rootBorder

    $progWin.Show()
    $progWin.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

    # ThemeEngine::ParseThemeFile lee un fichero INI pequeño — operación síncrona <50ms.
    # No se necesita runspace de fondo ni animación de espera.
    $lbl.Text = T 'SplashLoadingTheme' 'Cargando tema...'
    $barFill.Width = [math]::Round(392 * 20 / 100)
    $progWin.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

    $newColors = @{}
    try {
        $colors = [ThemeEngine]::ParseThemeFile($themePath)
        foreach ($k in $colors.Keys) { $newColors[$k] = $colors[$k] }
    } catch {
        $progWin.Close()
        Show-ThemedDialog -Title (T 'DlgError' 'Error') `
            -Message "Error al cargar tema: $($_.Exception.Message)" -Type "error"
        return
    }
    if ($newColors.Count -eq 0) { $progWin.Close(); return }

    # -- PASS 1: Update TB_ DynamicResource brushes (auto-propagates to main XAML) --
    $lbl.Text = T 'SplashApplyingTheme' 'Aplicando colores...'
    $barFill.Width = [math]::Round(392 * 35 / 100)
    $progWin.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

    $mapKeys = $script:ThemeColorMap.Keys
    $totalKeys = @($mapKeys).Count
    $idx = 0
    foreach ($hex in $mapKeys) {
        $info = $script:ThemeColorMap[$hex]
        $themeKey = $info[0]
        $dr = [int]$info[1]; $dg = [int]$info[2]; $db = [int]$info[3]

        if ($newColors.ContainsKey($themeKey)) {
            try {
                $baseColor = [System.Windows.Media.ColorConverter]::ConvertFromString($newColors[$themeKey])
                $newR = [math]::Max(0, [math]::Min(255, [int]$baseColor.R + $dr))
                $newG = [math]::Max(0, [math]::Min(255, [int]$baseColor.G + $dg))
                $newB = [math]::Max(0, [math]::Min(255, [int]$baseColor.B + $db))
                $finalColor = [System.Windows.Media.Color]::FromRgb($newR, $newG, $newB)
                $brush = [System.Windows.Media.SolidColorBrush]::new($finalColor)
                $window.Resources["TB_$hex"] = $brush
                # Propagar a Application.Current.Resources para que
                # cualquier Popup/ContextMenu del proceso lo resuelva
                try { [System.Windows.Application]::Current.Resources["TB_$hex"] = $brush } catch {}
                # Propagar a ventanas flotantes registradas (Tasks, Dedup, etc.)
                foreach ($fw in @($script:ThemedWindows)) {
                    try {
                        if ($null -ne $fw -and $fw.IsLoaded) {
                            $fw.Resources["TB_$hex"] = $brush
                        }
                    } catch {}
                }
            } catch {}
        }

        $idx++
        if ($idx % 20 -eq 0) {
            $pct = 35 + [math]::Round(($idx / $totalKeys) * 30)
            $barFill.Width = [math]::Round(392 * $pct / 100)
            $progWin.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
        }
    }

    # -- PASS 2: Update GradientStops via ThemeApplier --
    $barFill.Width = [math]::Round(392 * 70 / 100)
    $lbl.Text = T 'SplashApplyingTheme' 'Actualizando gradientes...'
    $progWin.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

    # Build old-to-new Color map for gradients
    $gradientMap = [System.Collections.Generic.Dictionary[string, [System.Windows.Media.Color]]]::new()
    foreach ($hex in $script:ThemeColorMap.Keys) {
        $info = $script:ThemeColorMap[$hex]
        $themeKey = $info[0]
        $dr = [int]$info[1]; $dg = [int]$info[2]; $db = [int]$info[3]
        if ($newColors.ContainsKey($themeKey)) {
            try {
                $baseColor = [System.Windows.Media.ColorConverter]::ConvertFromString($newColors[$themeKey])
                $newR = [math]::Max(0, [math]::Min(255, [int]$baseColor.R + $dr))
                $newG = [math]::Max(0, [math]::Min(255, [int]$baseColor.G + $dg))
                $newB = [math]::Max(0, [math]::Min(255, [int]$baseColor.B + $db))
                $gradientMap[("#{0:X2}{1:X2}{2:X2}" -f [int]("0x" + $hex.Substring(0,2)), [int]("0x" + $hex.Substring(2,2)), [int]("0x" + $hex.Substring(4,2)))] = [System.Windows.Media.Color]::FromRgb($newR, $newG, $newB)
            } catch {}
        }
    }
    [ThemeApplier]::ReplaceGradientColors($window, $gradientMap)

    $barFill.Width = [math]::Round(392 * 95 / 100)

    # -- PASS 3: Update script-level state --
    $barFill.Width = [math]::Round(392 * 95 / 100)
    $lbl.Text = T 'SplashApplyingTheme' 'Finalizando...'
    $progWin.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

    $script:CurrentTheme = $ThemeName
    $script:CurrentThemeColors = @{}
    foreach ($kv in $newColors.GetEnumerator()) {
        $script:CurrentThemeColors[$kv.Key] = $kv.Value
    }

    # Compute derived colors (status, etc.)
    Update-DynamicThemeValues

    # Update ComboBox themes
    try {
        $allCombos = Get-VisualChildren $window | Where-Object { $_ -is [System.Windows.Controls.ComboBox] }
        foreach ($cb in $allCombos) {
            try { Apply-ComboBoxDarkTheme -ComboBox $cb } catch {}
        }
    } catch {}

    # -- PASS 4: Repaint named buttons that use direct colors (not DynamicResource) --
    try { Apply-ButtonTheme } catch {}

    # -- PASS 5: Refresh tasks panel so IconBg/StatusBg recalculate with new theme --
    try { Refresh-TasksPanel } catch {}

    # -- PASS 6: Re-build system info (SMART badges) with new theme colors --
    try { Update-SystemInfo } catch {}

    # Save settings
    try { Save-Settings } catch {}

    $barFill.Width = 392
    $lbl.Text = T 'SplashThemeApplied' 'Tema aplicado!'
    # DispatcherTimer de un solo disparo — evita Sleep en UI thread
    $closeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $closeTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $capturedWin = $progWin
    $closeTimer.Add_Tick({
        $closeTimer.Stop()
        $capturedWin.Close()
    }.GetNewClosure())
    $closeTimer.Start()
}

# ─────────────────────────────────────────────────────────────────────────────
# [OPTIONS] Ventana de Opciones — Tema e Idioma
# ─────────────────────────────────────────────────────────────────────────────
function Show-OptionsWindow {
    $optXaml = [XamlLoader]::Load($script:XamlFolder, "OptionsWindow")
    $optXaml = $ExecutionContext.InvokeCommand.ExpandString($optXaml)
    try {
        $optReader = [System.Xml.XmlNodeReader]::new([xml]$optXaml)
        $optWin    = [Windows.Markup.XamlReader]::Load($optReader)
        $optWin.Owner = $window

        $cmbTheme    = $optWin.FindName("cmbTheme")
        $cmbLang     = $optWin.FindName("cmbLang")
        $tglDebugLog = $optWin.FindName("tglDebugLog")

        # Sincronizar checkbox con estado actual de LogEngine
        if ($null -ne $tglDebugLog) {
            $tglDebugLog.IsChecked = [LogEngine]::DebugEnabled
        }

        # ── Poblar ComboBox de temas ──
        $themeNames = [ThemeEngine]::ListThemes($script:ThemesDir)
        foreach ($tn in $themeNames) {
            $meta = [ThemeEngine]::GetThemeMeta((Join-Path $script:ThemesDir "$tn.theme"))
            $displayName = if ($meta.ContainsKey("Name")) { $meta["Name"] } else { $tn }
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = $displayName
            $item.Tag     = $tn
            [void]$cmbTheme.Items.Add($item)
            if ($tn -eq $script:CurrentTheme) { $cmbTheme.SelectedItem = $item }
        }
        if ($cmbTheme.SelectedItem -eq $null -and $cmbTheme.Items.Count -gt 0) {
            $cmbTheme.SelectedIndex = 0
        }

        # ── Poblar ComboBox de idiomas ──
        $langCodes = [LangEngine]::ListLanguages($script:LangDir)
        foreach ($lc in $langCodes) {
            $meta = [LangEngine]::GetLangMeta((Join-Path $script:LangDir "$lc.lang"))
            $displayName = if ($meta.ContainsKey("Name")) { $meta["Name"] } else { $lc }
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = $displayName
            $item.Tag     = $lc
            [void]$cmbLang.Items.Add($item)
            if ($lc -eq $script:CurrentLang) { $cmbLang.SelectedItem = $item }
        }
        if ($cmbLang.SelectedItem -eq $null -and $cmbLang.Items.Count -gt 0) {
            $cmbLang.SelectedIndex = 0
        }

        # ── Botón Aplicar ──
        $btnOptApply = $optWin.FindName("btnOptApply")
        $btnOptApply.Add_Click({
            $selectedTheme = $cmbTheme.SelectedItem.Tag
            $selectedLang  = $cmbLang.SelectedItem.Tag

            # Aplicar idioma si cambió
            if ($selectedLang -ne $script:CurrentLang) {
                Write-Log ("[CFG] Idioma cambiado: {0} → {1}" -f $script:CurrentLang, $selectedLang) -Level "INFO" -NoUI
                Load-Language -LangCode $selectedLang
            }

            # Aplicar tema si cambió — con barra de progreso
            if ($selectedTheme -ne $script:CurrentTheme) {
                Write-Log ("[CFG] Tema cambiado: {0} → {1}" -f $script:CurrentTheme, $selectedTheme) -Level "INFO" -NoUI
                $optWin.Hide()
                Apply-ThemeWithProgress -ThemeName $selectedTheme
                $optWin.Show()
            }

            # Aplicar debug toggle
            if ($null -ne $tglDebugLog) {
                [LogEngine]::DebugEnabled = ($tglDebugLog.IsChecked -eq $true)
                Write-Log ("[CFG] Debug logging: {0}" -f $(if ([LogEngine]::DebugEnabled) {"ON"} else {"OFF"})) -Level "INFO" -NoUI
            }

            try { Save-Settings } catch {}
        }.GetNewClosure())

        # ── Botón Cerrar ──
        $btnOptClose = $optWin.FindName("btnOptClose")
        $btnOptClose.Add_Click({ $optWin.Close() }.GetNewClosure())


        # ── Tematizar ComboBoxes del diálogo de opciones ──
        $optWin.Add_Loaded({
            try {
                $allCbs = Get-VisualChildren $optWin | Where-Object { $_ -is [System.Windows.Controls.ComboBox] }
                foreach ($cb in $allCbs) { Apply-ComboBoxDarkTheme $cb }
            } catch {}
        }.GetNewClosure())

        $optWin.ShowDialog() | Out-Null
    } catch {
        Show-ThemedDialog -Title (T 'DlgError' 'Error') `
            -Message "$(T 'ErrOpenOptions' 'Error al abrir opciones:')`n$($_.Exception.Message)" -Type "error"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
$script:SnapshotDir = Join-Path $script:AppDir "snapshots"
$script:LogsDir     = Join-Path $script:AppDir "logs"

# Referencias UI
$lbSnapshots            = $window.FindName("lbSnapshots")
$lbSnapshotDetail       = $window.FindName("lbSnapshotDetail")
$btnSnapshotSave        = $window.FindName("btnSnapshotSave")
$btnSnapshotCompare     = $window.FindName("btnSnapshotCompare")
$btnSnapshotDelete      = $window.FindName("btnSnapshotDelete")
$chkSnapshotSelectAll   = $window.FindName("chkSnapshotSelectAll")
$txtSnapshotSelCount    = $window.FindName("txtSnapshotSelCount")
$txtSnapshotName        = $window.FindName("txtSnapshotName")
$txtSnapshotDetailTitle = $window.FindName("txtSnapshotDetailTitle")
$txtSnapshotDetailMeta  = $window.FindName("txtSnapshotDetailMeta")
$txtSnapshotStatus      = $window.FindName("txtSnapshotStatus")

# ── Helpers de formato ───────────────────────────────────────────────────────
function Format-SnapshotSize([long]$bytes) { return [Formatter]::FormatBytes($bytes) }

# ── Actualizar contador y estado de botones según checks ─────────────────────
function Update-SnapshotCheckState {
    $all     = @($lbSnapshots.ItemsSource)
    $checked = @($all | Where-Object { $_.IsChecked })
    $n       = $checked.Count
    $total   = $all.Count

    $txtSnapshotSelCount.Text = if ($n -eq 0) {
        if ($total -eq 0) { "Sin snapshots guardados." } else { "$total snapshot(s) disponibles." }
    } else {
        "$n de $total seleccionados"
    }

    $btnSnapshotDelete.IsEnabled  = ($n -gt 0)
    $hasCurrentScan = ($null -ne $script:AllScannedItems -and $script:AllScannedItems.Count -gt 0)
    $btnSnapshotCompare.IsEnabled = ($n -eq 2) -or ($n -eq 1 -and $hasCurrentScan)
    $btnSnapshotCompare.Content   = if ($n -eq 2) {
        ([char]::ConvertFromUtf32(0x1F4CA) + "  Comparar 2")
    } else {
        ([char]::ConvertFromUtf32(0x1F4CA) + "  Comparar")
    }
}

# ── Ventana de progreso con botón "Segundo plano" ────────────────────────────
# Usada por: Load-SnapshotList, Get-SnapshotEntriesAsync, guardar snapshot,
#            exportar CSV, exportar HTML.
# El botón "Poner en segundo plano" oculta la ventana pero NO detiene el proceso
# ni el DispatcherTimer — al completarse se cierra sola igual.
function Show-ExportProgressDialog {
    param([string]$OperationTitle = "Procesando...")

    # ── Construir la ventana 100% programáticamente — sin FindName, sin Name= en XAML ──
    # FindName falla con WindowStyle=None + AllowsTransparency=True antes de Show().
    # Al crear los controles directamente tenemos referencias directas, sin ambigüedad.

    $dlg = New-Object System.Windows.Window
    $dlg.Title                  = ""
    $dlg.Width                  = 460
    $dlg.SizeToContent          = "Height"
    $dlg.WindowStartupLocation  = "CenterOwner"
    $dlg.ResizeMode             = "NoResize"
    $dlg.WindowStyle            = "None"
    $dlg.AllowsTransparency     = $true
    $dlg.Background             = [System.Windows.Media.Brushes]::Transparent
    $dlg.Topmost                = $true
    try { $dlg.Owner = $window } catch {}

    # Sombra exterior
    $shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
    $shadow.BlurRadius = 30; $shadow.ShadowDepth = 0; $shadow.Opacity = 0.6
    $shadow.Color = [System.Windows.Media.Colors]::Black

    # Border raíz
    $rootBorder = New-Object System.Windows.Controls.Border
    $rootBorder.Background   = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Get-TC 'BgCardDark' '#131625'))
    $rootBorder.BorderBrush  = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Get-TC 'AccentBlue' '#5BA3FF'))
    $rootBorder.BorderThickness = [System.Windows.Thickness]::new(1)
    $rootBorder.CornerRadius = [System.Windows.CornerRadius]::new(12)
    $rootBorder.Effect       = $shadow

    # StackPanel principal
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(24,20,24,20)

    # — Cabecera —
    $spHead = New-Object System.Windows.Controls.StackPanel
    $spHead.Orientation = "Horizontal"
    $spHead.Margin = [System.Windows.Thickness]::new(0,0,0,14)

    $iconBorder = New-Object System.Windows.Controls.Border
    $iconBorder.Width = 30; $iconBorder.Height = 30
    $iconBorder.CornerRadius = [System.Windows.CornerRadius]::new(7)
    $iconBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Get-TC 'AccentBlue' '#5BA3FF'))
    $iconBorder.Margin = [System.Windows.Thickness]::new(0,0,12,0)
    $iconBorder.VerticalAlignment = "Center"
    $tbIcon = New-Object System.Windows.Controls.TextBlock
    $tbIcon.Text = [char]0x21E9; $tbIcon.FontSize = 14; $tbIcon.FontWeight = "Bold"
    $tbIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Get-TC 'BgDeep' '#0D0F1A'))
    $tbIcon.HorizontalAlignment = "Center"; $tbIcon.VerticalAlignment = "Center"
    $iconBorder.Child = $tbIcon

    $tbTitle = New-Object System.Windows.Controls.TextBlock
    $tbTitle.Text = "Procesando..."; $tbTitle.FontSize = 14; $tbTitle.FontWeight = "Bold"
    $tbTitle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Get-TC 'TextPrimary' '#E8ECF4'))
    $tbTitle.VerticalAlignment = "Center"
    $tbTitle.FontFamily = [System.Windows.Media.FontFamily]::new("Segoe UI")

    $spHead.Children.Add($iconBorder) | Out-Null
    $spHead.Children.Add($tbTitle)    | Out-Null

    # — Fase —
    $tbPhase = New-Object System.Windows.Controls.TextBlock
    $tbPhase.Text = "Iniciando..."; $tbPhase.FontSize = 11.5
    $tbPhase.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Get-TC 'TextMuted' '#7880A0'))
    $tbPhase.TextTrimming = "CharacterEllipsis"
    $tbPhase.Margin = [System.Windows.Thickness]::new(0,0,0,10)
    $tbPhase.FontFamily = [System.Windows.Media.FontFamily]::new("Segoe UI")

    # — Barra de progreso —
    $barTrack = New-Object System.Windows.Controls.Border
    $barTrack.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Get-TC 'BgInput' '#1A1E2F'))
    $barTrack.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $barTrack.Height = 14; $barTrack.Margin = [System.Windows.Thickness]::new(0,0,0,8)
    $barGrid = New-Object System.Windows.Controls.Grid
    $barFill = New-Object System.Windows.Controls.Border
    $barFill.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Get-TC 'AccentBlue' '#5BA3FF'))
    $barFill.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $barFill.HorizontalAlignment = "Left"; $barFill.Width = 0
    $barGrid.Children.Add($barFill) | Out-Null
    $barTrack.Child = $barGrid

    # — % + ETA —
    $gridPct = New-Object System.Windows.Controls.Grid
    $gridPct.Margin = [System.Windows.Thickness]::new(0,0,0,4)
    $colStar = New-Object System.Windows.Controls.ColumnDefinition; $colStar.Width = [System.Windows.GridLength]::new(1, "Star")
    $colAuto = New-Object System.Windows.Controls.ColumnDefinition; $colAuto.Width = [System.Windows.GridLength]::Auto
    $gridPct.ColumnDefinitions.Add($colStar) | Out-Null
    $gridPct.ColumnDefinitions.Add($colAuto) | Out-Null

    $tbPct = New-Object System.Windows.Controls.TextBlock
    $tbPct.Text = "0%"; $tbPct.FontSize = 12; $tbPct.FontWeight = "Bold"
    $tbPct.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Get-TC 'AccentBlue' '#5BA3FF'))
    $tbPct.FontFamily = [System.Windows.Media.FontFamily]::new("Segoe UI")
    [System.Windows.Controls.Grid]::SetColumn($tbPct, 0)

    $tbEta = New-Object System.Windows.Controls.TextBlock
    $tbEta.Text = ""; $tbEta.FontSize = 11
    $tbEta.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Get-TC 'AccentGreen' '#4AE896'))
    $tbEta.HorizontalAlignment = "Right"
    $tbEta.FontFamily = [System.Windows.Media.FontFamily]::new("Segoe UI")
    [System.Windows.Controls.Grid]::SetColumn($tbEta, 1)

    $gridPct.Children.Add($tbPct) | Out-Null
    $gridPct.Children.Add($tbEta) | Out-Null

    # — Contador —
    $tbCount = New-Object System.Windows.Controls.TextBlock
    $tbCount.Text = ""; $tbCount.FontSize = 10.5
    $tbCount.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Get-TC 'TextMuted' '#4A5270'))
    $tbCount.Margin = [System.Windows.Thickness]::new(0,0,0,14)
    $tbCount.FontFamily = [System.Windows.Media.FontFamily]::new("Segoe UI")

    # — Botón segundo plano —
    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = [string]([char]0x2193) + "  Poner en segundo plano"
    $btn.Height = 32
    $btn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Get-TC 'BgInput' '#1A1E2F'))
    $btn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Get-TC 'TextMuted' '#7880A0'))
    $btn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Get-TC 'BorderSubtle' '#2A3050'))
    $btn.BorderThickness = [System.Windows.Thickness]::new(1)
    $btn.FontSize = 11.5
    $btn.FontFamily = [System.Windows.Media.FontFamily]::new("Segoe UI")
    $btn.Cursor = [System.Windows.Input.Cursors]::Hand
    $btn.HorizontalAlignment = "Right"
    $btn.Padding = [System.Windows.Thickness]::new(16,0,16,0)
    # GetNewClosure() captura $dlg por valor en el scope actual de la función,
    # evitando que el closure busque la variable en el scope del caller (que ya no existe).
    # _showTasksFn es una referencia al scope global para que el closure la encuentre.
    $script:_showTasksFn = ${function:Show-TasksWindow}
    $btn.Add_Click(({
        param()
        try { $dlg.Hide() } catch {}
        try { & $script:_showTasksFn } catch {}
    }.GetNewClosure()))

    # Ensamblar
    $sp.Children.Add($spHead)   | Out-Null
    $sp.Children.Add($tbPhase)  | Out-Null
    $sp.Children.Add($barTrack) | Out-Null
    $sp.Children.Add($gridPct)  | Out-Null
    $sp.Children.Add($tbCount)  | Out-Null
    $sp.Children.Add($btn)      | Out-Null
    $rootBorder.Child = $sp
    $dlg.Content = $rootBorder
    $dlg.Add_MouseLeftButtonDown(({ param(); try { $dlg.DragMove() } catch {} }.GetNewClosure()))

    return @{
        Window  = $dlg
        Title   = $tbTitle
        Phase   = $tbPhase
        BarFill = $barFill
        Pct     = $tbPct
        Eta     = $tbEta
        Count   = $tbCount
        BtnBg   = $btn
    }
}

# Helper interno: cierra la ventana de progreso (visible u oculta en 2do plano)
function Close-ProgressDialog($prog) {
    try { $prog.Window.Close() } catch {}
}

# Helper: actualiza el diálogo de progreso de forma null-safe
function Update-ProgressDialog($prog, [int]$pct, [string]$phase, [string]$count) {
    if ($null -eq $prog) { return }
    try {
        if ($null -ne $prog.Phase)   { $prog.Phase.Text    = $phase }
        if ($null -ne $prog.Pct)     { $prog.Pct.Text      = "$pct%" }
        if ($null -ne $prog.BarFill) { $prog.BarFill.Width = [math]::Round(408 * $pct / 100, 0) }
        if ($null -ne $prog.Count -and $count -ne '') { $prog.Count.Text = $count }
    } catch {}
}

# ── Estado compartido thread-safe (único, reutilizado por todos los runspaces) ─
$script:ExportState = [hashtable]::Synchronized(@{
    Phase = ""; Progress = 0; ItemsDone = 0; ItemsTotal = 0
    Done = $false; Error = ""; Result = $null
})

# ── Cargar lista de snapshots en background ──────────────────────────────────
function Load-SnapshotList {
    $snapDir   = $script:SnapshotDir
    $jsonFiles = @()
    if (Test-Path $snapDir) {
        $jsonFiles = @(Get-ChildItem -Path $snapDir -Filter "*.json" -ErrorAction SilentlyContinue |
                       Sort-Object LastWriteTime)
    }

    if ($jsonFiles.Count -eq 0) {
        $lbSnapshots.ItemsSource        = [System.Collections.Generic.List[object]]::new()
        $txtSnapshotDetailTitle.Text    = "Selecciona un snapshot para ver sus carpetas"
        $txtSnapshotDetailMeta.Text     = ""
        $lbSnapshotDetail.ItemsSource   = $null
        $chkSnapshotSelectAll.IsChecked = $false
        $txtSnapshotStatus.Text         = "Sin snapshots guardados."
        Update-SnapshotCheckState
        return
    }

    $txtSnapshotStatus.Text = "⏳ Cargando historial..."
    Register-Task -Id "snap-list" -Name "Cargando historial de snapshots" -Icon "🕒" -IconBg (Get-TC 'HdrBtnBg' '#1A2040') | Out-Null

    $filePaths = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $jsonFiles) { $filePaths.Add($f.FullName) }

    $script:LoadSnapState = [hashtable]::Synchronized(@{
        Phase = "Iniciando..."; Progress = 0; ItemsDone = 0; ItemsTotal = $filePaths.Count
        Done = $false; Error = ""
        Results = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
    })

    $bgLoad = {
        param($State, $FilePaths)
        function FmtB([long]$b) { return [Formatter]::FormatBytes($b) }
        # ── [RAM-04] JsonTextReader: leer solo metadatos sin cargar Entries ──
        function Read-SnapshotMeta([string]$fp) {
            $meta = @{ Label=""; RootPath=""; Date=""; EntryCount=0; TotalBytes=0L; RootCount=0 }
            $fs = $null; $jr = $null
            try {
                $fs = [System.IO.File]::OpenRead($fp)
                $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8, $true, 65536)
                $jr = [Newtonsoft.Json.JsonTextReader]::new($sr)
                $jr.SupportMultipleContent = $false
                $currentProp = ""
                $inEntries = $false; $entDepth = 0
                $inEntry = $false; $entPropDepth = 0
                $entSizeBytes = 0L; $entItemDepth = 0
                while ($jr.Read()) {
                    $tt = $jr.TokenType
                    if (-not $inEntries) {
                        if ($tt -eq [Newtonsoft.Json.JsonToken]::PropertyName) {
                            $currentProp = $jr.Value
                        } elseif ($tt -eq [Newtonsoft.Json.JsonToken]::String) {
                            switch ($currentProp) {
                                "Label"    { $meta.Label    = $jr.Value }
                                "RootPath" { $meta.RootPath = $jr.Value }
                                "Date"     { $meta.Date     = $jr.Value }
                            }
                        } elseif ($tt -eq [Newtonsoft.Json.JsonToken]::StartArray -and $currentProp -eq "Entries") {
                            $inEntries = $true; $entDepth = 1
                        }
                    } else {
                        # Dentro del array Entries: contar objetos y sumar SizeBytes de Depth==0
                        if ($tt -eq [Newtonsoft.Json.JsonToken]::StartObject) {
                            if ($entDepth -eq 1) {
                                $inEntry = $true; $entSizeBytes = 0L; $entItemDepth = -1
                            }
                            $entDepth++
                        } elseif ($tt -eq [Newtonsoft.Json.JsonToken]::EndObject) {
                            $entDepth--
                            if ($entDepth -eq 1 -and $inEntry) {
                                $meta.EntryCount++
                                if ($entItemDepth -eq 0) { $meta.TotalBytes += $entSizeBytes; $meta.RootCount++ }
                                $inEntry = $false
                            }
                        } elseif ($tt -eq [Newtonsoft.Json.JsonToken]::StartArray) { $entDepth++ }
                        elseif ($tt -eq [Newtonsoft.Json.JsonToken]::EndArray) {
                            $entDepth--
                            if ($entDepth -eq 0) { break }  # fin del array Entries
                        } elseif ($inEntry -and $tt -eq [Newtonsoft.Json.JsonToken]::PropertyName) {
                            $entPropDepth = $entDepth; $currentProp = $jr.Value
                        } elseif ($inEntry -and $entDepth -eq $entPropDepth) {
                            if ($currentProp -eq "SizeBytes") {
                                try { $entSizeBytes = [long]$jr.Value } catch {}
                            } elseif ($currentProp -eq "Depth") {
                                try { $entItemDepth = [int]$jr.Value } catch {}
                            }
                        }
                    }
                }
            } catch {
                # Fallback: leer metadatos básicos del principio del archivo
                try {
                    if ($null -ne $fs) { $fs.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null }
                    $raw  = [System.IO.File]::ReadAllText($fp, [System.Text.Encoding]::UTF8)
                    $data = $raw | ConvertFrom-Json; $raw = $null
                    $meta.Label    = [string]$data.Label
                    $meta.RootPath = [string]$data.RootPath
                    $meta.Date     = [string]$data.Date
                    foreach ($e in $data.Entries) {
                        $meta.EntryCount++
                        if ([int]$e.Depth -eq 0) { $meta.TotalBytes += [long]$e.SizeBytes; $meta.RootCount++ }
                    }
                    $data = $null
                } catch {}
            } finally {
                if ($null -ne $jr) { try { $jr.Close() } catch {} }
                if ($null -ne $fs) { try { $fs.Close(); $fs.Dispose() } catch {} }
            }
            return $meta
        }
        try {
            $total = $FilePaths.Count
            for ($i = 0; $i -lt $total; $i++) {
                $fp = $FilePaths[$i]
                $State.Phase     = "Leyendo $([System.IO.Path]::GetFileName($fp))..."
                $State.ItemsDone = $i
                $State.Progress  = [int](($i / $total) * 92)
                try {
                    $m = Read-SnapshotMeta $fp
                    $State.Results.Add(@{
                        FilePath   = $fp
                        Label      = $m.Label
                        RootPath   = $m.RootPath
                        DateStr    = $m.Date
                        EntryCount = $m.EntryCount
                        TotalBytes = $m.TotalBytes
                        RootCount  = $m.RootCount
                        SummaryStr = "$($m.RootCount) carpetas raíz · $($m.EntryCount) total · $(FmtB $m.TotalBytes)"
                    })
                } catch {}
            }
            $State.Phase = "Completado"; $State.Progress = 100; $State.ItemsDone = $total
            $State.Done = $true
        } catch { $State.Error = $_.Exception.Message; $State.Done = $true }
    }

    $ctx = New-PooledPS
    $ps = $ctx.PS
    [void]$ps.AddScript($bgLoad)
    [void]$ps.AddParameter("State",     $script:LoadSnapState)
    [void]$ps.AddParameter("FilePaths", $filePaths)
    $async = $ps.BeginInvoke()

    $prog = Show-ExportProgressDialog
    if ($null -ne $prog.Title)  { $prog.Title.Text = "Cargando historial de snapshots" }
    if ($null -ne $prog.Phase)  { $prog.Phase.Text = "Leyendo archivos..." }
    $prog.Window.Show()

    if ($null -ne $script:_loadTimer) { try { $script:_loadTimer.Stop() } catch {} }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:_loadTimer  = $t
    $script:_loadProg   = $prog
    $script:_loadPs     = $ps
    $script:_loadCtx    = $ctx
    $script:_loadAsync  = $async
    $script:_loadFiles  = $filePaths

    $t.Add_Tick({
        $st  = $script:LoadSnapState
        $pg  = $script:_loadProg
        $pct = [int]$st.Progress
        $cntStr = if ($st.ItemsTotal -gt 0) { "$($st.ItemsDone) / $($st.ItemsTotal) snapshots" } else { "" }
        Update-ProgressDialog $pg $pct $st.Phase $cntStr
        Update-Task -Id "snap-list" -Pct $pct -Detail $cntStr

        if ($st.Done) {
            $script:_loadTimer.Stop()
            Close-ProgressDialog $script:_loadProg
            try { $script:_loadPs.EndInvoke($script:_loadAsync) | Out-Null } catch {}
            Dispose-PooledPS $script:_loadCtx

            # Reconstruir lista en el orden original (por fecha desc)
            $map = @{}
            foreach ($r in $st.Results) { $map[$r.FilePath] = $r }
            $ordered = [System.Collections.Generic.List[object]]::new()
            foreach ($fp in $script:_loadFiles) {
                if ($map.ContainsKey($fp)) {
                    $r = $map[$fp]
                    $ordered.Add((New-Object PSObject -Property ([ordered]@{
                        FilePath   = $r.FilePath;   Label      = $r.Label
                        RootPath   = $r.RootPath;   DateStr    = $r.DateStr
                        EntryCount = $r.EntryCount; TotalBytes = $r.TotalBytes
                        RootCount  = $r.RootCount;  SummaryStr = $r.SummaryStr
                        IsChecked  = $false
                    })))
                }
            }
            $lbSnapshots.ItemsSource        = $ordered
            $txtSnapshotDetailTitle.Text    = "Selecciona un snapshot para ver sus carpetas"
            $txtSnapshotDetailMeta.Text     = ""
            $lbSnapshotDetail.ItemsSource   = $null
            $chkSnapshotSelectAll.IsChecked = $false
            $n = $ordered.Count
            $txtSnapshotStatus.Text = if ($n -eq 0) { "Sin snapshots guardados." } else { "$n snapshot(s) disponibles." }
            Update-SnapshotCheckState
            Invoke-AggressiveGC
            if ($st.Error -ne "") {
                $txtSnapshotStatus.Text = "Error al cargar: $($st.Error)"
                Complete-Task -Id "snap-list" -IsError -Detail $st.Error
            } else {
                Complete-Task -Id "snap-list" -Detail "$n snapshot(s) cargados"
            }
        }
    })
    $t.Start()
}

# ── Leer entries de un snapshot en background ────────────────────────────────
# $OnComplete: scriptblock { param($entries) ... }   entries = List[hashtable]
# $OnError:   scriptblock { param($msg) ... }
function Get-SnapshotEntriesAsync {
    param(
        [string]$FilePath,
        [string]$OperationTitle = "Cargando snapshot...",
        [scriptblock]$OnComplete,
        [scriptblock]$OnError
    )

    # (carga snapshot B) pise el estado de la primera (snapshot A) antes de que
    # su DispatcherTimer haya terminado. $script:ExportState era compartido y se
    # reiniciaba aquí, corrompiendo la condición de parada del timer anterior.
    $localExportState = [hashtable]::Synchronized(@{
        Phase      = "Leyendo archivo..."
        Progress   = 0
        ItemsDone  = 0
        ItemsTotal = 0
        Done       = $false
        Error      = ""
        Result     = $null
    })

    # Generar ID único para esta tarea (puede haber varias en cadena: A luego B)
    $script:TaskIdSeq++
    $entTaskId = "snap-ent-$($script:TaskIdSeq)"
    Register-Task -Id $entTaskId -Name $OperationTitle -Icon "📂" -IconBg (Get-TC 'BgInput' '#1A2A3A') | Out-Null

    # ── [FIFO-02] FIFO streaming load via JsonTextReader + ConcurrentQueue ───
    $entState = [hashtable]::Synchronized(@{
        Queue    = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        FeedDone = $false
        Error    = ""
        Total    = 0   # estimado, desconocido hasta parsear
    })

    $bgEnt = {
        param($EntState, $ExportState, $FilePath)
        # ConvertFrom-Json es un cmdlet interno (System.Management.Automation) y esta
        # disponible en todos los runspaces sin cargar assemblies externos.
        # Deserializamos el JSON completo y encolamos los entries uno a uno (FIFO),
        # liberando cada referencia inmediatamente tras encolar.
        try {
            $ExportState.Phase = "Leyendo archivo..."; $ExportState.Progress = 10
            $raw  = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
            $ExportState.Phase = "Deserializando...";  $ExportState.Progress = 30
            try   { $data = $raw | ConvertFrom-Json }
            catch { throw "JSON inválido en '$FilePath': $_" }
            $raw  = $null   # liberar el string JSON inmediatamente tras parsear

            $entries = $data.Entries
            $data    = $null   # liberar el objeto raiz — solo necesitamos $entries
            $total   = if ($null -ne $entries) { @($entries).Count } else { 0 }
            $ExportState.ItemsTotal = $total
            $ExportState.Phase = "Encolando entradas..."; $ExportState.Progress = 50

            $i = 0
            foreach ($e in $entries) {
                $EntState.Queue.Enqueue(@{
                    Name      = [string]$e.Name
                    FullPath  = [string]$e.FullPath
                    SizeBytes = [long]$e.SizeBytes
                    FileCount = [string]$e.FileCount
                    Depth     = [int]$e.Depth
                })
                $i++
                if ($i % 500 -eq 0) {
                    $ExportState.ItemsDone = $i
                    $ExportState.Progress  = [int](50 + ($i / [Math]::Max(1,$total)) * 46)
                    $ExportState.Phase     = "Encolando... ($i / $total)"
                }
            }
            $entries = $null

            $ExportState.ItemsDone = $i; $ExportState.ItemsTotal = $i
            $ExportState.Progress  = 100; $ExportState.Phase = "Completado"
        } catch {
            $EntState.Error    = $_.Exception.Message
            $ExportState.Error = $_.Exception.Message
        } finally {
            $EntState.FeedDone = $true
            $ExportState.Done  = $true
        }
    }

    $ctxEnt = New-PooledPS
    $ps = $ctxEnt.PS
    [void]$ps.AddScript($bgEnt)
    [void]$ps.AddParameter("EntState",    $entState)
    [void]$ps.AddParameter("ExportState", $localExportState)
    [void]$ps.AddParameter("FilePath",    $FilePath)
    $async = $ps.BeginInvoke()

    $prog = Show-ExportProgressDialog
    if ($null -ne $prog.Title) { $prog.Title.Text = $OperationTitle }
    $prog.Window.Show()

    if ($null -ne $script:_entTimer) { try { $script:_entTimer.Stop() } catch {} }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(150)
    # [FIX-RACE] NO guardar en $script:_ent* — capturar todo en variables locales
    # que el closure del tick vea a través del scope de la función, no del script.
    $script:_entTimer      = $t   # solo para poder detenerlo desde afuera si fuera necesario

    $localProg       = $prog
    $localPs         = $ps
    $localCtx        = $ctxEnt
    $localAsync      = $async
    $localOnComplete = $OnComplete
    $localOnError    = $OnError
    $localEntState   = $entState
    $localAccum      = [System.Collections.Generic.List[object]]::new()
    $localTaskId     = $entTaskId
    $localTimer      = $t

    # ($localExportState, $localEntState, $localAccum, etc.) en el scriptblock.
    # Sin esto, PowerShell resuelve esas variables en el scope del script al ejecutar
    # el tick, donde valen $null — causando "You cannot call a method on a null-valued
    # expression" en $entSt.Queue.TryDequeue().
    $tickBlock = {
        $st    = $localExportState
        $pg    = $localProg
        $pct   = [int]$st.Progress
        $entSt = $localEntState

        # [FIFO] Drenar queue en el tick del UI — procesa lotes sin bloquear
        $item    = $null
        $drained = 0
        if ($null -ne $entSt -and $null -ne $entSt.Queue) {
            while ($drained -lt 500 -and $entSt.Queue.TryDequeue([ref]$item)) {
                $localAccum.Add($item)
                $item = $null
                $drained++
            }
        }

        $cntStr = "$($localAccum.Count) entradas leídas"
        Update-ProgressDialog $pg $pct $st.Phase $cntStr
        Update-Task -Id $localTaskId -Pct $pct -Detail $cntStr

        if ($st.Done -and $entSt.FeedDone -and $entSt.Queue.IsEmpty) {
            $localTimer.Stop()
            Close-ProgressDialog $localProg
            try { $localPs.EndInvoke($localAsync) | Out-Null } catch {}
            Dispose-PooledPS $localCtx
            [System.GC]::Collect(2, [System.GCCollectionMode]::Forced, $true, $true)
            [System.GC]::WaitForPendingFinalizers()
            try {
                [System.Runtime.GCSettings]::LargeObjectHeapCompactionMode = `
                    [System.Runtime.GCLargeObjectHeapCompactionMode]::CompactOnce
                [System.GC]::Collect()
            } catch {}

            if ($st.Error -ne "") {
                Complete-Task -Id $localTaskId -IsError -Detail $st.Error
                if ($null -ne $localOnError) { & $localOnError $st.Error }
            } else {
                $nEnt = $localAccum.Count
                Complete-Task -Id $localTaskId -Detail "$nEnt entradas cargadas"
                if ($null -ne $localOnComplete) { & $localOnComplete $localAccum }
            }
        }
    }.GetNewClosure()
    $t.Add_Tick($tickBlock)
    $t.Start()
}

# ── Guardar snapshot del escaneo actual ─────────────────────────────────────
$btnSnapshotSave.Add_Click({
    if ($null -eq $script:AllScannedItems -or $script:AllScannedItems.Count -eq 0) { return }
    $label = $txtSnapshotName.Text.Trim()
    if ($label -eq '') { $label = "Escaneo $(Get-Date -Format 'dd/MM/yyyy HH:mm')" }

    $btnSnapshotSave.IsEnabled = $false
    $txtSnapshotStatus.Text    = "⏳ Guardando snapshot..."
    Register-Task -Id "snap-save" -Name "Guardando snapshot: $label" -Icon "💾" -IconBg (Get-TC 'BgStatusOk' '#1A2A1E') | Out-Null

    $script:ExportState.Phase     = "Preparando..."; $script:ExportState.Progress = 0
    $script:ExportState.ItemsDone = 0; $script:ExportState.ItemsTotal = $script:AllScannedItems.Count
    $script:ExportState.Done      = $false; $script:ExportState.Error = ""; $script:ExportState.Result = $null

    # ── [FIFO-01] FIFO streaming save via ConcurrentQueue ────────────────────
    $saveState = [hashtable]::Synchronized(@{
        Queue    = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        FeedDone = $false          # UI señaliza que terminó de encolar
        Total    = $script:AllScannedItems.Count
    })

    $saveLabel = $label
    $saveRoot  = $txtDiskScanPath.Text
    $saveDir   = $script:SnapshotDir

    # Script background: drena Queue con StreamWriter JSON manual — sin dependencia Newtonsoft
    $bgSave = {
        param($State, $ExportState, $Label, $RootPath, $SnapshotDir)
        $fs = $null; $sw = $null
        try {
            $ExportState.Phase = "Preparando directorio..."; $ExportState.Progress = 5
            if (-not (Test-Path $SnapshotDir)) {
                [System.IO.Directory]::CreateDirectory($SnapshotDir) | Out-Null
            }
            $fp = [System.IO.Path]::Combine($SnapshotDir, "snapshot_$(Get-Date -Format 'yyyyMMdd_HHmmss').json")

            # [FIFO] Abrir StreamWriter con buffer 64KB — escribe JSON manualmente token a token
            $fs = [System.IO.File]::Open($fp, [System.IO.FileMode]::Create,
                  [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $sw = [System.IO.StreamWriter]::new($fs, [System.Text.Encoding]::UTF8, 65536)

            # Helper inline: escapa solo los caracteres JSON obligatorios en strings de rutas
            # Rutas Windows raramente tienen \n/\r/\t pero sí pueden tener comillas y backslashes.
            # El backslash ya está duplicado en FullPath (ej. C:\\Users\\...) dentro del JSON.

            # Cabecera del objeto raíz
            $date = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $lbl  = $Label   -replace '\\',  '\\\\' -replace '"', '\"'
            $root = $RootPath -replace '\\', '\\\\' -replace '"', '\"'
            $sw.WriteLine('{')
            $sw.WriteLine("  `"Label`": `"$lbl`",")
            $sw.WriteLine("  `"Date`": `"$date`",")
            $sw.WriteLine("  `"RootPath`": `"$root`",")
            $sw.WriteLine('  "Entries": [')

            $ExportState.Phase = "Escribiendo entradas..."; $ExportState.Progress = 10
            $total   = $State.Total
            $written = 0
            $item    = $null
            $first   = $true

            # [FIFO] Drenar queue FIFO hasta que el productor señalice FeedDone y la queue quede vacía
            while (-not ($State.FeedDone -and $State.Queue.IsEmpty)) {
                while ($State.Queue.TryDequeue([ref]$item)) {
                    # Separador entre objetos JSON (coma antes de cada entry excepto el primero)
                    if (-not $first) { $sw.Write(',') } else { $first = $false }

                    # Escapar strings — comillas dobles y backslashes para JSON válido
                    $fp2 = ([string]$item.FP) -replace '\\', '\\\\' -replace '"', '\"'
                    $nm  = ([string]$item.N)  -replace '\\', '\\\\' -replace '"', '\"'
                    $fc  = ([string]$item.FC) -replace '\\', '\\\\' -replace '"', '\"'
                    $sz  = [long]$item.SZ
                    $d   = [int]$item.D

                    # Escribir objeto entry directamente al stream — una sola llamada Write por entry
                    $sw.WriteLine("{`"FullPath`":`"$fp2`",`"Name`":`"$nm`",`"SizeBytes`":$sz,`"FileCount`":`"$fc`",`"Depth`":$d}")
                    $item = $null   # liberar referencia inmediatamente — FIFO consume y descarta
                    $written++
                    if ($written % 500 -eq 0) {
                        $sw.Flush()   # flush periódico al disco — evita buffers grandes
                        $ExportState.ItemsDone = $written
                        $ExportState.Progress  = if ($total -gt 0) { [int](10 + ($written / $total) * 85) } else { 50 }
                        $ExportState.Phase     = "Escribiendo... ($written / $total)"
                    }
                }
                if (-not $State.FeedDone) { [System.Threading.Thread]::Sleep(5) }
            }

            # Cerrar array y objeto raíz
            $sw.WriteLine('  ]')
            $sw.WriteLine('}')
            $sw.Flush()

            $ExportState.Result = $Label; $ExportState.Progress = 100
            $ExportState.Phase  = "Completado"; $ExportState.ItemsDone = $written
            $ExportState.Done   = $true
        } catch {
            $ExportState.Error = $_.Exception.Message; $ExportState.Done = $true
        } finally {
            # [FIFO] Liberar recursos en orden — sin importar si hubo error
            if ($null -ne $sw) { try { $sw.Close() } catch {} }
            if ($null -ne $fs) { try { $fs.Close(); $fs.Dispose() } catch {} }
        }
    }

    # [FIFO] Lanzar background ANTES de encolar — así drena en paralelo
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = "MTA"; $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($bgSave)
    [void]$ps.AddParameter("State",       $saveState)
    [void]$ps.AddParameter("ExportState", $script:ExportState)
    [void]$ps.AddParameter("Label",       $saveLabel)
    [void]$ps.AddParameter("RootPath",    $saveRoot)
    [void]$ps.AddParameter("SnapshotDir", $saveDir)
    $async = $ps.BeginInvoke()

    # [FIFO] Producir: encolar AllScannedItems item a item sin construir lista intermedia
    # El background ya está corriendo y drenando en paralelo → RAM pico ≈ lote en tránsito
    foreach ($item in $script:AllScannedItems) {
        if ($item.SizeBytes -ge 0) {
            $saveState.Queue.Enqueue(@{
                FP = $item.FullPath; N = $item.DisplayName
                SZ = $item.SizeBytes; FC = $item.FileCount; D = $item.Depth
            })
        }
    }
    $saveState.FeedDone = $true   # señalizar al background que no hay más items

    $prog = Show-ExportProgressDialog
    if ($null -ne $prog.Title) { $prog.Title.Text = "Guardando snapshot" }
    $prog.Window.Show()

    if ($null -ne $script:_saveTimer) { try { $script:_saveTimer.Stop() } catch {} }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:_saveTimer = $t; $script:_saveProg  = $prog
    $script:_savePs    = $ps; $script:_saveRs   = $rs; $script:_saveAsync = $async

    $t.Add_Tick({
        $st  = $script:ExportState; $pg = $script:_saveProg; $pct = [int]$st.Progress
        $cntStr = if ($st.ItemsTotal -gt 0) { "$($st.ItemsDone) / $($st.ItemsTotal) entradas" } else { "" }
        Update-ProgressDialog $pg $pct $st.Phase $cntStr
        Update-Task -Id "snap-save" -Pct $pct -Detail $cntStr
        if ($st.Done) {
            $script:_saveTimer.Stop()
            Close-ProgressDialog $script:_saveProg
            try { $script:_savePs.EndInvoke($script:_saveAsync) | Out-Null } catch {}
            # [FIFO] Liberar runspace y forzar GC — el proceso termina limpio
            try { $script:_savePs.Dispose(); $script:_saveRs.Close(); $script:_saveRs.Dispose() } catch {}
            [System.GC]::Collect(2, [System.GCCollectionMode]::Forced, $true, $true)
            [System.GC]::WaitForPendingFinalizers()
            try {
                [System.Runtime.GCSettings]::LargeObjectHeapCompactionMode = `
                    [System.Runtime.GCLargeObjectHeapCompactionMode]::CompactOnce
                [System.GC]::Collect()
            } catch {}
            $btnSnapshotSave.IsEnabled = $true
            if ($st.Error -ne "") {
                $txtSnapshotStatus.Text = "Error al guardar: $($st.Error)"
                Complete-Task -Id "snap-save" -IsError -Detail $st.Error
            } else {
                $snapFile = if ($st.Result) { [string]$st.Result } else { "" }
                $snapLeaf = if ($snapFile) { Split-Path $snapFile -Leaf } else { "snapshot" }
                $txtSnapshotStatus.Text = "✅ Snapshot guardado: $snapLeaf"
                Complete-Task -Id "snap-save" -Detail $snapLeaf
                Load-SnapshotList
            }
        }
    })
    $t.Start()
})

# ── CheckBox "Seleccionar todo" ───────────────────────────────────────────────
$chkSnapshotSelectAll.Add_Checked({
    foreach ($item in @($lbSnapshots.ItemsSource)) { $item.IsChecked = $true }
    $lbSnapshots.Items.Refresh(); Update-SnapshotCheckState
})
$chkSnapshotSelectAll.Add_Unchecked({
    foreach ($item in @($lbSnapshots.ItemsSource)) { $item.IsChecked = $false }
    $lbSnapshots.Items.Refresh(); Update-SnapshotCheckState
})

# ── Evento burbuja CheckBox dentro del ListBox ───────────────────────────────
[System.Windows.RoutedEventHandler]$script:snapCheckHandler = { param($s,$e); Update-SnapshotCheckState }
$lbSnapshots.AddHandler([System.Windows.Controls.CheckBox]::CheckedEvent,   $script:snapCheckHandler)
$lbSnapshots.AddHandler([System.Windows.Controls.CheckBox]::UncheckedEvent, $script:snapCheckHandler)

# ── Selección de snapshot → cargar entries en background ─────────────────────
$lbSnapshots.Add_SelectionChanged({
    $sel = $lbSnapshots.SelectedItem
    if ($null -eq $sel) { Update-SnapshotCheckState; return }

    $txtSnapshotDetailTitle.Text = $sel.Label
    $txtSnapshotDetailMeta.Text  = "$($sel.DateStr)  ·  $($sel.RootPath)"
    $txtSnapshotStatus.Text      = "⏳ Cargando entradas del snapshot..."
    $lbSnapshotDetail.ItemsSource = $null

    $selLabel = $sel.Label

    Get-SnapshotEntriesAsync -FilePath $sel.FilePath `
        -OperationTitle "Cargando snapshot — $($sel.Label)" `
        -OnComplete {
            param($entries)
            $detailItems = [System.Collections.Generic.List[object]]::new()
            foreach ($e in ($entries | Sort-Object { [long]$_.SizeBytes } -Descending)) {
                $sz = [long]$e.SizeBytes
                $detailItems.Add([PSCustomObject]@{
                    FolderName = $e.Name;    FullPath = $e.FullPath
                    SizeStr    = Format-SnapshotSize $sz
                    SizeColor  = if ($sz -ge 10GB) { "#FF6B84" } elseif ($sz -ge 1GB) { "#FFB547" } `
                                 elseif ($sz -ge 100MB) { "#5BA3FF" } else { "#B0BACC" }
                    DeltaStr   = ""; DeltaColor = "#7880A0"
                })
            }
            $lbSnapshotDetail.ItemsSource = $detailItems
            $txtSnapshotStatus.Text       = "$($detailItems.Count) entradas en el snapshot."
            Update-SnapshotCheckState
        } `
        -OnError {
            param($msg)
            $txtSnapshotStatus.Text = "Error al cargar snapshot: $msg"
            Update-SnapshotCheckState
        }
})

# ── Comparar snapshots en background ─────────────────────────────────────────
# Patrón: cargar los JSON necesarios con Get-SnapshotEntriesAsync en cadena,
# luego realizar el cruce de datos en el callback (ya en el hilo UI, rápido).
$btnSnapshotCompare.Add_Click({
    $checked = @($lbSnapshots.ItemsSource | Where-Object { $_.IsChecked })

    if ($checked.Count -eq 2) {
        # ── Modo A vs B ───────────────────────────────────────────────────────
        $snapA = $checked[0]; $snapB = $checked[1]
        $txtSnapshotStatus.Text      = "⏳ Cargando snapshot A..."
        $txtSnapshotDetailTitle.Text = "Comparando: $($snapA.Label)  vs  $($snapB.Label)"
        $txtSnapshotDetailMeta.Text  = "$($snapA.DateStr)  vs  $($snapB.DateStr)"
        $lbSnapshotDetail.ItemsSource = $null

        $script:_cmpSnapA = $snapA; $script:_cmpSnapB = $snapB

        # Primero cargamos A; en su callback cargamos B; en el de B cruzamos datos
        Get-SnapshotEntriesAsync -FilePath $snapA.FilePath `
            -OperationTitle "Comparar — cargando $($snapA.Label)" `
            -OnComplete {
                param($entriesA)
                $script:_cmpEntriesA = $entriesA
                $txtSnapshotStatus.Text = "⏳ Cargando snapshot B..."

                Get-SnapshotEntriesAsync -FilePath $script:_cmpSnapB.FilePath `
                    -OperationTitle "Comparar — cargando $($script:_cmpSnapB.Label)" `
                    -OnComplete {
                        param($entriesB)
                        # Cruce de datos (rápido, en hilo UI)
                        $eA = $script:_cmpEntriesA
                        $mapB = [System.Collections.Generic.Dictionary[string,long]]::new(
                            [System.StringComparer]::OrdinalIgnoreCase)
                        foreach ($e in $entriesB) { $mapB[$e.FullPath] = [long]$e.SizeBytes }
                        $setA = [System.Collections.Generic.HashSet[string]]::new(
                            [System.StringComparer]::OrdinalIgnoreCase)
                        foreach ($e in $eA) { [void]$setA.Add($e.FullPath) }

                        $detailItems = [System.Collections.Generic.List[object]]::new()
                        foreach ($e in ($eA | Sort-Object { [long]$_.SizeBytes } -Descending)) {
                            $old = [long]$e.SizeBytes
                            $new = if ($mapB.ContainsKey($e.FullPath)) { $mapB[$e.FullPath] } else { -1L }
                            $d   = if ($new -ge 0) { $new - $old } else { $null }
                            $ds  = if ($null -eq $d) { "eliminada" } elseif ($d -eq 0) { "sin cambio" } `
                                   elseif ($d -gt 0) { "+$(Format-SnapshotSize $d)" } else { "-$(Format-SnapshotSize ([Math]::Abs($d)))" }
                            $dc  = if ($null -eq $d -or $d -eq 0) { "#7880A0" } elseif ($d -gt 0) { "#FF6B84" } else { "#4AE896" }
                            $sz  = if ($new -ge 0) { $new } else { $old }
                            $detailItems.Add([PSCustomObject]@{
                                FolderName = $e.Name; FullPath = $e.FullPath
                                SizeStr    = Format-SnapshotSize $sz
                                SizeColor  = if ($sz -ge 10GB) { "#FF6B84" } elseif ($sz -ge 1GB) { "#FFB547" } `
                                             elseif ($sz -ge 100MB) { "#5BA3FF" } else { "#B0BACC" }
                                DeltaStr   = $ds; DeltaColor = $dc
                            })
                        }
                        foreach ($e in $entriesB) {
                            if (-not $setA.Contains($e.FullPath)) {
                                $detailItems.Add([PSCustomObject]@{
                                    FolderName = $e.Name; FullPath = $e.FullPath
                                    SizeStr    = Format-SnapshotSize ([long]$e.SizeBytes)
                                    SizeColor  = "#4AE896"; DeltaStr = "nueva en B"; DeltaColor = "#4AE896"
                                })
                            }
                        }
                        $lbSnapshotDetail.ItemsSource = $detailItems
                        $txtSnapshotStatus.Text = "Comparación completada — $($detailItems.Count) carpetas."
                    } `
                    -OnError { param($msg); $txtSnapshotStatus.Text = "Error cargando snapshot B: $msg" }
            } `
            -OnError { param($msg); $txtSnapshotStatus.Text = "Error cargando snapshot A: $msg" }

    } elseif ($checked.Count -eq 1 -and $null -ne $script:AllScannedItems -and $script:AllScannedItems.Count -gt 0) {
        # ── Modo snapshot vs escaneo actual ───────────────────────────────────
        $sel = $checked[0]
        $txtSnapshotStatus.Text      = "⏳ Cargando snapshot para comparar..."
        $txtSnapshotDetailTitle.Text = "Comparando: $($sel.Label)  →  Escaneo actual"
        $txtSnapshotDetailMeta.Text  = "$($sel.DateStr)  vs  $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
        $lbSnapshotDetail.ItemsSource = $null

        Get-SnapshotEntriesAsync -FilePath $sel.FilePath `
            -OperationTitle "Comparar — cargando $($sel.Label)" `
            -OnComplete {
                param($snapEntries)
                $currentMap = [System.Collections.Generic.Dictionary[string,long]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)
                foreach ($item in $script:AllScannedItems) {
                    if ($item.SizeBytes -ge 0) { $currentMap[$item.FullPath] = [long]$item.SizeBytes }
                }
                $snapSet = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)
                foreach ($e in $snapEntries) { [void]$snapSet.Add($e.FullPath) }

                $detailItems = [System.Collections.Generic.List[object]]::new()
                foreach ($e in ($snapEntries | Sort-Object { [long]$_.SizeBytes } -Descending)) {
                    $old = [long]$e.SizeBytes
                    $new = if ($currentMap.ContainsKey($e.FullPath)) { $currentMap[$e.FullPath] } else { -1L }
                    $d   = if ($new -ge 0) { $new - $old } else { $null }
                    $ds  = if ($null -eq $d) { "eliminada" } elseif ($d -eq 0) { "sin cambio" } `
                           elseif ($d -gt 0) { "+$(Format-SnapshotSize $d)" } else { "-$(Format-SnapshotSize ([Math]::Abs($d)))" }
                    $dc  = if ($null -eq $d -or $d -eq 0) { "#7880A0" } elseif ($d -gt 0) { "#FF6B84" } else { "#4AE896" }
                    $sz  = if ($new -ge 0) { $new } else { $old }
                    $detailItems.Add([PSCustomObject]@{
                        FolderName = $e.Name; FullPath = $e.FullPath
                        SizeStr    = Format-SnapshotSize $sz
                        SizeColor  = if ($sz -ge 10GB) { "#FF6B84" } elseif ($sz -ge 1GB) { "#FFB547" } `
                                     elseif ($sz -ge 100MB) { "#5BA3FF" } else { "#B0BACC" }
                        DeltaStr   = $ds; DeltaColor = $dc
                    })
                }
                foreach ($item in $script:AllScannedItems) {
                    if ($item.SizeBytes -lt 0) { continue }
                    if (-not $snapSet.Contains($item.FullPath)) {
                        $detailItems.Add([PSCustomObject]@{
                            FolderName = $item.DisplayName; FullPath = $item.FullPath
                            SizeStr    = Format-SnapshotSize $item.SizeBytes
                            SizeColor  = "#4AE896"; DeltaStr = "nueva"; DeltaColor = "#4AE896"
                        })
                    }
                }
                $lbSnapshotDetail.ItemsSource = $detailItems
                $txtSnapshotStatus.Text = "Comparación completada — $($detailItems.Count) carpetas analizadas."
            } `
            -OnError { param($msg); $txtSnapshotStatus.Text = "Error al comparar: $msg" }
    }
})

# ── Eliminar snapshots marcados (en lote) ────────────────────────────────────
$btnSnapshotDelete.Add_Click({
    $checked = @($lbSnapshots.ItemsSource | Where-Object { $_.IsChecked })
    if ($checked.Count -eq 0) { return }
    $nombres = ($checked | ForEach-Object { $_.Label }) -join "`n  - "
    $msg = if ($checked.Count -eq 1) { "Eliminar el snapshot:`n  - $nombres" } `
           else { "Eliminar $($checked.Count) snapshots:`n  - $nombres" }
    $confirm = Show-ThemedDialog -Title "Confirmar eliminación" -Message $msg -Type "warning" -Buttons "YesNo"
    if ($confirm) {
        $errors = 0
        foreach ($snap in $checked) {
            try { Remove-Item -Path $snap.FilePath -Force -ErrorAction Stop } catch { $errors++ }
        }
        Load-SnapshotList
        if ($errors -gt 0) { $txtSnapshotStatus.Text = "Eliminados con $errors errores." }
    }
})

# ── Cargar lista la primera vez que se activa la pestaña Historial (run-once) ──
$tabMain      = $window.FindName("tabMain")
$tabHistorial = $window.FindName("tabHistorial")
$script:SnapshotListLoaded = $false

$tabMain.Add_SelectionChanged({
    param($s, $e)
    # Solo reaccionar al propio TabControl principal, no a controles hijos
    if ($e.Source -ne $tabMain) { return }
    if ($tabMain.SelectedItem -eq $tabHistorial -and -not $script:SnapshotListLoaded) {
        $script:SnapshotListLoaded = $true
        Load-SnapshotList
    }
    $e.Handled = $true
})

# ── Ventana flotante de Tareas (estilo emergente, como About) ────────────────
$script:TasksWin       = $null   # referencia a la ventana si está abierta
$lbTasks             = $null    # se asignan al abrir la ventana
$txtTasksSubtitle    = $null
$txtTasksStatus      = $null
$btnTasksClearDone   = $null

function Show-TasksWindow {
    # Si ya está abierta, traerla al frente
    if ($null -ne $script:TasksWin -and $script:TasksWin.IsVisible) {
        try { $script:TasksWin.Activate() } catch {}
        return
    }

    $twXaml = [XamlLoader]::Load($script:XamlFolder, "TasksWindow")
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($twXaml))
    $tw     = [System.Windows.Markup.XamlReader]::Load($reader)
    try { $tw.Owner = $window } catch {}

    # ── Inyectar TB_* brushes del tema actual ─────────────────────────────────
    $themedRd = New-ThemedWindowResources
    foreach ($k in @($themedRd.Keys)) {
        $tw.Resources[$k] = $themedRd[$k]
    }
    # Registrar para actualizaciones futuras de tema
    $script:ThemedWindows.Add($tw)

    $script:lbTasksWin           = $tw.FindName("lbTasks")
    $script:txtTasksSubtitleWin  = $tw.FindName("txtTasksSubtitle")
    $script:txtTasksStatusWin    = $tw.FindName("txtTasksStatus")
    $btnClear                    = $tw.FindName("btnTasksClearDone")

    $btnClear.Add_Click({

        $pool = $script:TaskPool
        if ($null -eq $pool) { return }

        $snapshot = @($pool.Keys)
        foreach ($k in $snapshot) {
            $t = $null
            # TryGetValue es seguro aunque la clave haya desaparecido entre Keys y aquí
            if ($pool.TryGetValue($k, [ref]$t) -and $null -ne $t -and $t.Status -ne "running") {
                $removed = $null
                $pool.TryRemove($k, [ref]$removed) | Out-Null
            }
        }
        Refresh-TasksPanel
    })

    # ── Menú contextual de tareas: pausar / reanudar / cancelar ──────────────
    # El ContextMenu vive en el DataTemplate, por lo que su evento Click
    # burbujea hasta la ListBox. Lo capturamos con AddHandler en el propio lb.
    $lbCtx = $script:lbTasksWin

    # ── ContextMenuOpening — propaga Tag del item al CM y MenuItems ────────────
    # Los TB_* se resuelven desde Application.Current.Resources (se sincronizan
    # en window.Add_Loaded y en cada Apply-ThemeWithProgress).
    # El unico trabajo aqui es poner el Id de la tarea en CM.Tag y MenuItem.Tag
    # porque el DataContext del ContextMenu popup esta desconectado del binding.
    $lbCtx.AddHandler(
        [System.Windows.FrameworkElement]::ContextMenuOpeningEvent,
        [System.Windows.Controls.ContextMenuEventHandler]{
            param($sCmo, $eCmo)
            try {
                # Subir por el arbol visual hasta el Border que tiene el ContextMenu
                $el = $eCmo.OriginalSource
                $border = $el; $steps = 0
                while ($null -ne $border -and $steps -lt 20) {
                    if ($border -is [System.Windows.Controls.Border] -and $null -ne $border.ContextMenu) { break }
                    $border = [System.Windows.Media.VisualTreeHelper]::GetParent($border)
                    $steps++
                }
                if ($null -eq $border -or $null -eq $border.ContextMenu) { return }
                $cm = $border.ContextMenu

                # Propagar Id de la tarea al Tag del CM y de cada MenuItem
                $dc     = $border.DataContext
                $taskId = if ($null -ne $dc -and $null -ne $dc.Id) { [string]$dc.Id } else { "" }
                $cm.Tag = $taskId
                foreach ($mi in $cm.Items) {
                    if ($mi -is [System.Windows.Controls.MenuItem]) { $mi.Tag = $taskId }
                }
            } catch {}
        }
    )

    $lbCtx.AddHandler(
        [System.Windows.Controls.MenuItem]::ClickEvent,
        [System.Windows.RoutedEventHandler]{
            param($s2, $e2)
            $mi = $e2.OriginalSource
            if (-not ($mi -is [System.Windows.Controls.MenuItem])) { return }
            $taskId = [string]$mi.Tag
            if ([string]::IsNullOrEmpty($taskId)) { return }

            switch ($mi.Header) {
                { $_ -like "*Pausar*" }    { Pause-Task  -Id $taskId }
                { $_ -like "*Reanudar*" }  { Resume-Task -Id $taskId }
                { $_ -like "*Cancelar*" }  {
                    $t = $null
                    $tName = if ($script:TaskPool.TryGetValue($taskId, [ref]$t) -and $null -ne $t) { $t.Name } else { $taskId }
                    $ok = Show-ThemedDialog -Title "Confirmar cancelación" `
                        -Message "¿Cancelar la tarea '$tName'?" -Type "confirm"
                    if ($ok) { Cancel-Task -Id $taskId }
                }
            }
        }
    )

    $tw.Add_Closed(({
        $script:TasksWin            = $null
        $script:lbTasksWin          = $null
        $script:txtTasksSubtitleWin = $null
        $script:txtTasksStatusWin   = $null
        # Desregistrar del registro de ventanas temáticas
        try { $script:ThemedWindows.Remove($tw) | Out-Null } catch {}
    }.GetNewClosure()))

    $script:TasksWin = $tw
    Refresh-TasksPanel
    $tw.Show()
}

# Mapas de presentación por estado
$script:TaskStatusMap = @{
    running   = @{ Text = T 'StatusRunning' 'En curso';   Bg = (Get-TC 'BgStatusInfo' '#1A2F4A'); Fg = (Get-TC 'FgStatusInfo' '#5BA3FF') }
    paused    = @{ Text = T 'StatusPaused'  'Pausada';    Bg = (Get-TC 'BgStatusWarn' '#2A2010');  Fg = (Get-TC 'FgStatusWarn' '#FFB547') }
    done      = @{ Text = T 'StatusDone' 'Completada';    Bg = (Get-TC 'BgStatusOk' '#182A1E');    Fg = (Get-TC 'FgStatusOk' '#4AE896') }
    error     = @{ Text = T 'StatusError' 'Error';        Bg = (Get-TC 'BgStatusErr' '#2A1018');   Fg = (Get-TC 'FgStatusErr' '#FF6B84') }
    cancelled = @{ Text = T 'StatusCancel' 'Cancelada';   Bg = (Get-TC 'BgStatusWarn' '#2A2010');  Fg = (Get-TC 'FgStatusWarn' '#FFB547') }
}
$script:TaskIconMap = @{
    running   = "⚙"
    paused    = "⏸"
    done      = "✓"
    error     = "✗"
    cancelled = "⊘"
}

# ── Helpers de control de tareas invocados desde el menú contextual ───────────
function Cancel-Task([string]$Id) {
    $t = $null
    if (-not $script:TaskPool.TryGetValue($Id, [ref]$t) -or $null -eq $t) { return }
    if ($t.Status -notin @("running","paused")) { return }
    # Si estaba pausada, reanudar antes de cancelar (evita runspace colgado)
    if ($t.Paused -and $null -ne $t.ResumeFn) {
        try { & $t.ResumeFn } catch {}
        $t.Paused = $false
    }
    if ($null -ne $t.CancelFn) {
        try { & $t.CancelFn } catch {}
    }
    $t.Status  = "cancelled"
    $t.EndTime = [datetime]::Now
    Write-Log "[TASK] Cancelada por el usuario: $($t.Name)" -Level "WARN" -NoUI
    Refresh-TasksPanel
}

function Pause-Task([string]$Id) {
    $t = $null
    if (-not $script:TaskPool.TryGetValue($Id, [ref]$t) -or $null -eq $t) { return }
    if ($t.Status -ne "running" -or $null -eq $t.PauseFn) { return }
    try { & $t.PauseFn } catch {}
    $t.Paused = $true
    $t.Status = "paused"
    Write-Log "[TASK] Pausada por el usuario: $($t.Name)" -Level "INFO" -NoUI
    Refresh-TasksPanel
}

function Resume-Task([string]$Id) {
    $t = $null
    if (-not $script:TaskPool.TryGetValue($Id, [ref]$t) -or $null -eq $t) { return }
    if ($t.Status -ne "paused" -or $null -eq $t.ResumeFn) { return }
    try { & $t.ResumeFn } catch {}
    $t.Paused = $false
    $t.Status = "running"
    Write-Log "[TASK] Reanudada por el usuario: $($t.Name)" -Level "INFO" -NoUI
    Refresh-TasksPanel
}

function Refresh-TasksPanel {
    $bc_ = [System.Windows.Media.BrushConverter]::new()
    $lbTasks          = $script:lbTasksWin
    $txtTasksSubtitle = $script:txtTasksSubtitleWin
    $txtTasksStatus   = $script:txtTasksStatusWin
    if ($null -eq $lbTasks) { return }

    $tasks  = @($script:TaskPool.Values | Where-Object { $null -ne $_ } | Sort-Object { $_.StartTime } -Descending)
    $active = @($tasks | Where-Object { $_.Status -eq "running" })
    $done   = @($tasks | Where-Object { $_.Status -ne "running" })

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $tasks) {
        $sm      = $script:TaskStatusMap[$t.Status]
        $elapsed = if ($t.EndTime) {
            $d = $t.EndTime - $t.StartTime
            if ($d.TotalHours -ge 1)   { $d.ToString("h\:mm\:ss") }
            elseif ($d.TotalMinutes -ge 1) { $d.ToString("m\:ss") + " min" }
            else { "$([int]$d.TotalSeconds) s" }
        } else {
            $d = [datetime]::Now - $t.StartTime
            if ($d.TotalHours -ge 1)   { $d.ToString("h\:mm\:ss") }
            elseif ($d.TotalMinutes -ge 1) { $d.ToString("m\:ss") + " min" }  # [FIX-BUG6] igual que EndTime
            else { "$([int]$d.TotalSeconds) s" }
        }

        $pct      = [math]::Min(100, [math]::Max(0, [int]$t.Pct))
        $pctColorHex = switch ($t.Status) {
            "done"      { Get-TC 'AccentGreen' '#4AE896' }
            "error"     { Get-TC 'AccentRed' '#FF6B84' }
            "cancelled" { Get-TC 'AccentAmber' '#FFB547' }
            default     { Get-TC 'AccentBlue' '#5BA3FF' }
        }
        $pctColor = try { $bc_.ConvertFromString($pctColorHex) } catch { $bc_.ConvertFromString((Get-TC 'AccentBlue' '#5BA3FF')) }
        $barColor = $pctColor
        $iconBgHex = switch ($t.Status) {
            "done"      { Get-TC 'BgStatusOk' '#182A1E' }
            "error"     { Get-TC 'BgStatusErr' '#2A1018' }
            "cancelled" { Get-TC 'BgStatusWarn' '#2A2010' }
            default     { $t.IconBg }
        }
        $iconBg = try { $bc_.ConvertFromString($iconBgHex) } catch { $bc_.ConvertFromString((Get-TC 'BgInput' '#1A2040')) }
        $icon = if ($t.Status -eq "running") { $t.Icon } else { $script:TaskIconMap[$t.Status] }

        $barFill  = [math]::Max(1, $pct)   # mínimo 1* para evitar columna cero
        $barEmpty = [math]::Max(1, 100 - $pct)
        # BarPx: ancho en px proporcional al porcentaje. La columna central (~280px disponibles)
        $barPx = [double]($pct * 2.8)   # 100% → 280px, 0% → 0px

        $statusBg = try { $bc_.ConvertFromString($sm.Bg) } catch { $bc_.ConvertFromString((Get-TC 'BgStatusInfo' '#152F4A')) }
        $statusFg = try { $bc_.ConvertFromString($sm.Fg) } catch { $bc_.ConvertFromString((Get-TC 'AccentBlue' '#5BA3FF')) }
        $items.Add([PSCustomObject]@{
            Id          = $t.Id
            Name        = $t.Name
            Icon        = $icon
            IconBg      = $iconBg
            StatusText  = $sm.Text
            StatusBg    = $statusBg
            StatusFg    = $statusFg
            Pct         = $pct
            PctStr      = if ($t.Status -eq "running") { "$pct%" } elseif ($t.Status -eq "done") { "100%" } else { "" }
            PctColor    = $pctColor
            BarStarFill  = "$barFill*"
            BarStarEmpty = "$barEmpty*"
            BarPx       = $barPx
            BarColor    = $barColor
            Detail      = [string]$t.Detail
            Elapsed     = $elapsed
            # ── Capacidades para el menú contextual ──────────────────────────
            CanCancel   = ($t.Status -in @("running","paused")) -and ($null -ne $t.CancelFn)
            CanPause    = ($t.Status -eq "running")             -and ($null -ne $t.PauseFn)
            CanResume   = ($t.Status -eq "paused")              -and ($null -ne $t.ResumeFn)
        })
    }

    $lbTasks.ItemsSource = $items
    $nActive = $active.Count
    $nDone   = $done.Count

    if ($null -ne $txtTasksSubtitle) {
        $txtTasksSubtitle.Text = if ($nActive -eq 0) {
            if ($nDone -eq 0) { "Sin tareas" } else { "$nDone tarea(s) completada(s)" }
        } else {
            "$nActive tarea(s) en curso · $nDone completada(s)"
        }
    }
    if ($null -ne $txtTasksStatus) {
        $txtTasksStatus.Text = "Pool: $nActive activa(s) · $nDone completada(s)/error"
    }
}

# Timer de refresco cada 1 s (solo actualiza si la ventana está abierta)
$script:TaskTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:TaskTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:TaskTimer.Add_Tick({
    if ($script:AppClosing) { $script:TaskTimer.Stop(); return }
    Refresh-TasksPanel
})
$script:TaskTimer.Start()

# ─────────────────────────────────────────────────────────────────────────────
$script:FilterText = ""

function Apply-DiskFilter {
    param([string]$Filter)
    $script:FilterText = $Filter.Trim()
    if ($null -eq $script:AllScannedItems -or $script:AllScannedItems.Count -eq 0) { return }
    if ($null -eq $script:LiveList) { return }

    # la gestiona exclusivamente. Guardar el texto y aplicar solo cuando termine.
    if ($null -ne $script:DiskScanAsync) { return }

    if ([string]::IsNullOrWhiteSpace($script:FilterText)) {
        # Sin filtro: vista normal jerárquica
        Refresh-DiskView
    } else {
        # Con filtro: lista plana de items cuyo nombre contiene el texto
        $script:LiveList.Clear()
        foreach ($item in $script:AllScannedItems) {
            if ($item.SizeBytes -ge 0 -and $item.DisplayName -like "*$script:FilterText*") {
                $script:LiveList.Add($item)
            }
        }
    }
}

$txtDiskFilter.Add_TextChanged({
    Apply-DiskFilter $txtDiskFilter.Text
    Save-Settings
})

$btnDiskFilterClear.Add_Click({
    $txtDiskFilter.Text = ""
    Apply-DiskFilter ""
})

# ─────────────────────────────────────────────────────────────────────────────
$ctxMenu.Add_Opened({
    $sel = $lbDiskTree.SelectedItem
    $hasItem = $null -ne $sel
    $ctxOpen.IsEnabled       = $hasItem -and $sel.IsDir -and (Test-Path $sel.FullPath)
    $ctxCopy.IsEnabled       = $hasItem
    $ctxScanFolder.IsEnabled = $hasItem -and $sel.IsDir -and (Test-Path $sel.FullPath)
    $ctxDelete.IsEnabled     = $hasItem -and $sel.IsDir -and (Test-Path $sel.FullPath)
})

$ctxOpen.Add_Click({
    $sel = $lbDiskTree.SelectedItem
    if ($null -ne $sel -and (Test-Path $sel.FullPath)) {
        Start-Process "explorer.exe" $sel.FullPath
    }
})

$ctxCopy.Add_Click({
    $sel = $lbDiskTree.SelectedItem
    if ($null -ne $sel) {
        [System.Windows.Clipboard]::SetText($sel.FullPath)
        $txtDiskScanStatus.Text = "✅ Ruta copiada: $($sel.FullPath)"
    }
})

$ctxDelete.Add_Click({
    $sel = $lbDiskTree.SelectedItem
    if ($null -eq $sel -or -not $sel.IsDir) { return }
    $confirm = Show-ThemedDialog -Title "Confirmar eliminación" `
        -Message "¿Eliminar permanentemente esta carpeta?`n`n$($sel.FullPath)`n`nTamaño: $($sel.SizeStr)`n`nEsta acción no se puede deshacer." `
        -Type "warning" -Buttons "YesNo"
    if ($confirm) {
        try {
            Remove-Item -Path $sel.FullPath -Recurse -Force -ErrorAction Stop
            # Quitar de AllScannedItems y refrescar vista
            $toRemove = $script:AllScannedItems | Where-Object {
                $_.FullPath -eq $sel.FullPath -or $_.FullPath.StartsWith($sel.FullPath + "\")
            }
            foreach ($r in @($toRemove)) { $script:AllScannedItems.Remove($r) | Out-Null }
            Refresh-DiskView -RebuildMap
            $txtDiskScanStatus.Text = "🗑 Eliminado: $($sel.FullPath)"
        } catch {
            Show-ThemedDialog -Title "Error al eliminar" `
                -Message "Error al eliminar:`n$($_.Exception.Message)" -Type "error"
        }
    }
})

# [B2+] Mostrar Output desde menú contextual del explorador
if ($null -ne $ctxShowOutput2) {
    $ctxShowOutput2.Add_Click({ Set-OutputState "normal" })
}

# ─────────────────────────────────────────────────────────────────────────────
# [N9] Escanear carpeta — ventana emergente con árbol de archivos y operaciones
# ─────────────────────────────────────────────────────────────────────────────
$ctxScanFolder.Add_Click({
    $sel = $lbDiskTree.SelectedItem
    if ($null -eq $sel -or -not $sel.IsDir -or -not (Test-Path $sel.FullPath)) { return }
    Show-FolderScanner -FolderPath $sel.FullPath
})

# ─────────────────────────────────────────────────────────────────────────────
$btnExportCsv.Add_Click({
    if ($null -eq $script:AllScannedItems -or $script:AllScannedItems.Count -eq 0) {
        Show-ThemedDialog -Title "Sin datos" `
            -Message "No hay datos de escaneo. Realiza un escaneo primero." -Type "info"
        return
    }
    $dlgFile = New-Object System.Windows.Forms.SaveFileDialog
    try {
        $dlgFile.Title      = "Exportar resultados del explorador"
        $dlgFile.Filter     = "CSV (*.csv)|*.csv|Todos los archivos|*.*"
        $dlgFile.DefaultExt = "csv"
        $dlgFile.FileName   = "SysOpt_Disco_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        $dlgFile.InitialDirectory = [Environment]::GetFolderPath("Desktop")
        if ($dlgFile.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $csvPath = $dlgFile.FileName
    } finally { $dlgFile.Dispose() }

    $btnExportCsv.IsEnabled  = $false
    $txtDiskScanStatus.Text  = "⏳ Exportando CSV en segundo plano..."
    Register-Task -Id "csv" -Name "Exportar CSV: $([System.IO.Path]::GetFileName($csvPath))" -Icon "📄" -IconBg (Get-TC 'BgStatusOk' '#1A2A1E') | Out-Null

    $script:ExportState.Phase     = "Preparando datos..."
    $script:ExportState.Progress  = 0
    $script:ExportState.ItemsDone = 0
    $script:ExportState.ItemsTotal= $script:AllScannedItems.Count
    $script:ExportState.Done      = $false
    $script:ExportState.Error     = ""
    $script:ExportState.Result    = ""

    # [RAM-03] Pasar AllScannedItems por referencia — sin clonar $csvData
    $script:ExportState.DataRef  = $script:AllScannedItems
    $script:ExportState.CsvPath2 = $csvPath

    $bgCsvScript = {
        param($State, $CsvPath)
        try {
            $Items = $State.DataRef
            $State.Phase    = "Ordenando datos..."
            $State.Progress = 5
            # Ordenar in-place sin crear lista nueva — usar Array.Sort con comparer
            $sorted = [System.Linq.Enumerable]::OrderByDescending(
                [System.Collections.Generic.IEnumerable[object]]$Items,
                [Func[object,long]]{ param($x) if ($x.SizeBytes -ge 0) { $x.SizeBytes } else { 0L } }
            )
            $State.Phase    = "Escribiendo CSV..."
            $State.Progress = 10
            $total = $Items.Count
            $State.ItemsTotal = $total
            $sw = [System.IO.StreamWriter]::new($CsvPath, $false, [System.Text.Encoding]::UTF8, 65536)
            try {
                $sw.WriteLine('"Ruta","Tamaño","Bytes","Archivos","Carpetas","% del total","Tipo"')
                $i = 0
                foreach ($r in $sorted) {
                    if ($r.SizeBytes -lt 0) { $i++; continue }
                    $ruta  = [string]$r.FullPath  -replace '"','""'
                    $tam   = [string]$r.SizeStr   -replace '"','""'
                    $arch  = [string]$r.FileCount -replace '"','""'
                    $pct   = [string]$r.PctStr    -replace '"','""'
                    $tipo  = if ($r.IsDir) { "Carpeta" } else { "Archivo" }
                    $sw.WriteLine('"' + $ruta + '","' + $tam + '",' + $r.SizeBytes + ',"' + $arch + '",' + $r.DirCount + ',"' + $pct + '","' + $tipo + '"')
                    $i++
                    if ($i % 1000 -eq 0) {
                        $sw.Flush()
                        $State.ItemsDone = $i
                        $State.Progress  = [int](10 + ($i / [math]::Max(1,$total)) * 85)
                        $State.Phase     = "Escribiendo fila $i de $total..."
                    }
                }
                $sw.Flush()
            } finally { $sw.Close(); $sw.Dispose() }
            $State.Result    = $CsvPath
            $State.Progress  = 100
            $State.Phase     = "Completado"
            $State.ItemsDone = $total
            $State.Done      = $true
        } catch {
            $State.Error = $_.Exception.Message
            $State.Done  = $true
        }
    }

    $ctxCsv = New-PooledPS
    $ps4 = $ctxCsv.PS
    [void]$ps4.AddScript($bgCsvScript)
    [void]$ps4.AddParameter("State",   $script:ExportState)
    [void]$ps4.AddParameter("CsvPath", $csvPath)
    $asyncCsv = $ps4.BeginInvoke()

    $progCsv = Show-ExportProgressDialog
    if ($null -ne $progCsv.Title) { $progCsv.Title.Text = "Exportando CSV" }
    $progCsv.Window.Show()

    $csvTimer = New-Object System.Windows.Threading.DispatcherTimer
    $csvTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:_csvProg  = $progCsv
    $script:_csvTimer = $csvTimer
    $script:_csvPs    = $ps4
    $script:_csvCtx   = $ctxCsv
    $script:_csvAsync = $asyncCsv

    # CancelFn para el menú contextual de tareas
    $csvTask = $null
    if ($script:TaskPool.TryGetValue("csv", [ref]$csvTask) -and $null -ne $csvTask) {
        $csvTask.CancelFn = {
            $script:ExportState.Done  = $true
            $script:ExportState.Error = "Cancelado por el usuario"
            if ($null -ne $script:_csvTimer) { try { $script:_csvTimer.Stop() } catch {} }
            try { $script:_csvPs.Stop() } catch {}
            Dispose-PooledPS $script:_csvCtx
            if ($null -ne $script:_csvProg) { try { $script:_csvProg.Window.Close() } catch {} }
            try { $btnExportCsv.IsEnabled = $true } catch {}
        }
    }

    $csvTimer.Add_Tick({
        $st   = $script:ExportState
        $prog = $script:_csvProg
        $pct  = [int]$st.Progress
        $cntStr = if ($st.ItemsTotal -gt 0) { "$($st.ItemsDone) / $($st.ItemsTotal) filas" } else { "" }
        Update-ProgressDialog $prog $pct $st.Phase $cntStr
        Update-Task -Id "csv" -Pct $pct -Detail "$($st.Phase) $cntStr"
        if ($st.Done) {
            $script:_csvTimer.Stop()
            $prog.Window.Close()
            try { $script:_csvPs.EndInvoke($script:_csvAsync) | Out-Null } catch {}
            Dispose-PooledPS $script:_csvCtx
            $btnExportCsv.IsEnabled = $true
            if ($st.Error -ne "") {
                Complete-Task -Id "csv" -IsError -Detail $st.Error
                Show-ThemedDialog -Title "Error al exportar" -Message "Error:`n$($st.Error)" -Type "error"
            } else {
                $f     = if ($st.Result) { [string]$st.Result } else { "" }
                $fLeaf = if ($f) { Split-Path $f -Leaf } else { "export.csv" }
                Complete-Task -Id "csv" -Detail $fLeaf
                $txtDiskScanStatus.Text = "✅ CSV exportado: $fLeaf"
                $n = $script:AllScannedItems.Count
                Show-ThemedDialog -Title "Exportación completada" `
                    -Message "CSV guardado en:`n$f`n`n$n elementos." -Type "success"
                Invoke-AggressiveGC
            }
        }
    })
    $csvTimer.Start()
})

# ── [B3] Generar informe HTML desde el explorador de disco ───────────────────
# La exportación ocurre en un Runspace separado para no bloquear la UI.
# ─────────────────────────────────────────────────────────────────────────────

$btnDiskReport.Add_Click({
    if ($null -eq $script:AllScannedItems -or $script:AllScannedItems.Count -eq 0) {
        Show-ThemedDialog -Title "Sin datos" `
            -Message "No hay datos de escaneo. Realiza un escaneo primero." -Type "info"
        return
    }
    $templatePath = Join-Path $script:AppDir "assets\templates\diskreport.html"
    if (-not (Test-Path $templatePath)) {
        Show-ThemedDialog -Title "Template no encontrado" `
            -Message "No se encontro el archivo de plantilla:`n$templatePath" -Type "error"
        return
    }

    $btnDiskReport.IsEnabled = $false
    $txtDiskScanStatus.Text  = "⏳ Generando informe HTML en segundo plano..."
    Register-Task -Id "html" -Name "Informe HTML: $($txtDiskScanPath.Text)" -Icon "🌐" -IconBg (Get-TC 'BgInput' '#1A2030') | Out-Null

    $script:ExportState.Phase     = "Preparando datos..."
    $script:ExportState.Progress  = 0
    $script:ExportState.ItemsDone = 0
    $script:ExportState.ItemsTotal= $script:AllScannedItems.Count
    $script:ExportState.Done      = $false
    $script:ExportState.Error     = ""
    $script:ExportState.Result    = ""

    # [RAM-03] Pasar AllScannedItems por referencia — sin clonar en $dataSnapshot
    # El runspace recibe la referencia directa al list; no hay copia de RAM en pico
    $script:ExportState.DataRef = $script:AllScannedItems

    $exportParams = @{
        State        = $script:ExportState
        TemplatePath = $templatePath
        ScanPath     = $txtDiskScanPath.Text
        AppDir       = $script:AppDir
    }

    $bgExportScript = {
        param($State, $TemplatePath, $ScanPath, $AppDir)

        function SafeHtml([string]$s) {
            $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' `
               -replace '"','&quot;' -replace "'","&#39;"
        }
        function FmtSize([long]$bytes) {
            if ($bytes -ge 1GB) { "{0:N2} GB" -f ($bytes/1GB) }
            elseif ($bytes -ge 1MB) { "{0:N1} MB" -f ($bytes/1MB) }
            elseif ($bytes -ge 1KB) { "{0:N0} KB" -f ($bytes/1KB) }
            else { "$bytes B" }
        }

        $DataSnapshot = $State.DataRef

        try {
            $State.Phase = "Leyendo plantilla..."; $State.Progress = 2
            $tpl = [System.IO.File]::ReadAllText($TemplatePath, [System.Text.Encoding]::UTF8)

            $State.Phase = "Cargando logo..."; $State.Progress = 5
            $logoB64 = ""
            $logoPath = Join-Path $AppDir "assets\img\sysopt.png"
            if (Test-Path $logoPath) {
                try { $logoB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($logoPath)) } catch {}
            }
            $logoTag = if ($logoB64) {
                "<img src='data:image/png;base64,$logoB64' alt='SysOpt' class='logo-img'/>"
            } else { "<div class='logo-fallback'>&#9881;</div>" }

            $State.Phase = "Calculando estadisticas..."; $State.Progress = 10
            $now        = Get-Date
            $reportDate = $now.ToString('yyyyMMddHHmm')
            $dateLong   = $now.ToString('dd/MM/yyyy HH:mm:ss')

            $validItems = @($DataSnapshot)
            $rootItems  = @($validItems | Where-Object { $_.Depth -eq 0 } | Sort-Object SizeBytes -Descending)
            $totalBytes = ($rootItems | Measure-Object -Property SizeBytes -Sum).Sum
            if ($totalBytes -le 0) { $totalBytes = 1 }
            $totalStr     = FmtSize $totalBytes
            $totalFolders = $validItems.Count
            $totalFiles   = ($validItems | ForEach-Object {
                $fc = $_.FileCount
                if ($fc -match '^(\d+)\s') { [int]$Matches[1] } else { 0 }
            } | Measure-Object -Sum).Sum

            $diskStatsExtra = ""; $diskUsageBar = ""
            try {
                $drive = [System.IO.Path]::GetPathRoot($ScanPath)
                if ($drive -match '^[A-Za-z]:\\$') {
                    $di   = [System.IO.DriveInfo]::new($drive)
                    $dTot = $di.TotalSize; $dFree = $di.AvailableFreeSpace
                    $dUsed= $dTot - $dFree
                    $dPct = [math]::Round($dUsed / $dTot * 100, 1)
                    $diskStatsExtra = "<div class=`"stat-box`"><div class=`"stat-lbl`">Total unidad $drive</div><div class=`"stat-val c-cyan`">$(FmtSize $dTot)</div></div><div class=`"stat-box`"><div class=`"stat-lbl`">Espacio libre</div><div class=`"stat-val c-green`">$(FmtSize $dFree)</div></div><div class=`"stat-box`"><div class=`"stat-lbl`">Uso de disco</div><div class=`"stat-val c-red`">$dPct%</div></div>"
                    $diskUsageBar   = "<div class=`"disk-bar-wrap`"><div class=`"disk-bar-fill`" style=`"width:$dPct%`"></div></div><div class=`"disk-bar-label`">$dPct% utilizado &mdash; $(FmtSize $dUsed) de $(FmtSize $dTot)</div>"
                }
            } catch {}

            $State.Phase = "Generando grafico de sectores..."; $State.Progress = 18
            $pal = @('#5BA3FF','#4AE896','#FFB547','#FF6B84','#9B7EFF','#2EDFBF',
                     '#FF9F43','#54A0FF','#5F27CD','#01CBC6','#FFC312','#C4E538',
                     '#12CBC4','#FDA7DF','#ED4C67','#F79F1F','#A29BFE','#74B9FF')
            $slicesSvg = ""; $legendHtml = ""
            $cx = 160; $cy = 160; $r = 148; $startAngle = -90.0
            $topN = [math]::Min($rootItems.Count, 16)
            $otherBytes = $totalBytes
            for ($i = 0; $i -lt $topN; $i++) { $otherBytes -= [long]$rootItems[$i].SizeBytes }
            $hasOther = ($rootItems.Count -gt $topN) -and ($otherBytes -gt 0)
            for ($i = 0; $i -lt $topN; $i++) {
                $item = $rootItems[$i]; $pct  = [long]$item.SizeBytes / $totalBytes
                $angle= $pct * 360.0; $endA = $startAngle + $angle
                $large= if ($angle -gt 180) { 1 } else { 0 }; $col = $pal[$i % $pal.Count]
                $pctLbl = [math]::Round($pct * 100, 1); $szStr = FmtSize ([long]$item.SizeBytes)
                $nameEsc = SafeHtml $item.DisplayName
                if ($angle -ge 359.9) {
                    $slicesSvg += "<circle cx='$cx' cy='$cy' r='$r' fill='$col' class='slice' data-name='$nameEsc' data-size='$szStr' data-pct='$pctLbl%'/>`n"
                } else {
                    $x1=[math]::Round($cx+$r*[math]::Cos($startAngle*[math]::PI/180),3)
                    $y1=[math]::Round($cy+$r*[math]::Sin($startAngle*[math]::PI/180),3)
                    $x2=[math]::Round($cx+$r*[math]::Cos($endA*[math]::PI/180),3)
                    $y2=[math]::Round($cy+$r*[math]::Sin($endA*[math]::PI/180),3)
                    $slicesSvg += "<path d='M$cx,$cy L$x1,$y1 A$r,$r 0 $large,1 $x2,$y2 Z' fill='$col' opacity='0.92' class='slice' data-name='$nameEsc' data-size='$szStr' data-pct='$pctLbl%'/>`n"
                }
                $legendHtml += "<div class='legend-item'><span class='legend-dot' style='background:$col'></span><span class='legend-name' title='$nameEsc'>$nameEsc</span><span class='legend-size'>$szStr</span><span class='legend-pct'>$pctLbl%</span></div>`n"
                $startAngle = $endA
            }
            if ($hasOther) {
                $angle=[math]::Round($otherBytes/$totalBytes*360,2); $endA=$startAngle+$angle
                $large=if($angle-gt 180){1}else{0}; $col='#3A4468'
                $szStr=FmtSize $otherBytes; $pctLbl=[math]::Round($otherBytes/$totalBytes*100,1)
                $x1=[math]::Round($cx+$r*[math]::Cos($startAngle*[math]::PI/180),3)
                $y1=[math]::Round($cy+$r*[math]::Sin($startAngle*[math]::PI/180),3)
                $x2=[math]::Round($cx+$r*[math]::Cos($endA*[math]::PI/180),3)
                $y2=[math]::Round($cy+$r*[math]::Sin($endA*[math]::PI/180),3)
                $slicesSvg += "<path d='M$cx,$cy L$x1,$y1 A$r,$r 0 $large,1 $x2,$y2 Z' fill='$col' opacity='0.7' class='slice' data-name='Otras carpetas' data-size='$szStr' data-pct='$pctLbl%'/>`n"
                $legendHtml += "<div class='legend-item'><span class='legend-dot' style='background:$col'></span><span class='legend-name'>Otras carpetas</span><span class='legend-size'>$szStr</span><span class='legend-pct'>$pctLbl%</span></div>`n"
            }

            $State.Phase = "Generando tabla de carpetas..."; $State.Progress = 25
            $State.ItemsTotal = $validItems.Count
            # El StringBuilder ya no crece ilimitado en memoria
            $tmpRowsFile = [System.IO.Path]::GetTempFileName()
            $swRows = [System.IO.StreamWriter]::new($tmpRowsFile, $false, [System.Text.Encoding]::UTF8, 65536)
            $allSorted = @($validItems | Sort-Object SizeBytes -Descending)
            $total_items = $allSorted.Count
            $idx = 0; $startTime = [DateTime]::UtcNow
            try {
                for ($r2 = 0; $r2 -lt $total_items; $r2++) {
                    $item   = $allSorted[$r2]
                    $col2   = $pal[$idx % $pal.Count]
                    $pct2   = [math]::Round([long]$item.SizeBytes / $totalBytes * 100, 2)
                    $bar    = [math]::Min(100, $pct2)
                    $szStr2 = FmtSize ([long]$item.SizeBytes)
                    $nmEsc  = SafeHtml $item.DisplayName
                    $ptEsc  = SafeHtml $item.FullPath
                    $depth  = [int]$item.Depth
                    $dClass = switch ($depth) { 0 {"depth-0"} 1 {"depth-1"} 2 {"depth-2"} 3 {"depth-3"} default {"depth-4p"} }
                    $files  = if ($item.FileCount -match '^(\d+)\s' -and [int]$Matches[1] -gt 0) { $item.FileCount } else { "" }
                    $dotCol = if ($depth -eq 0) { $pal[$idx % $pal.Count] } else { "#3A4468" }
                    $swRows.WriteLine("<tr><td class=`"td-dot`"><span class=`"dot`" style=`"background:$dotCol`"></span></td><td class=`"$dClass`" title=`"$ptEsc`">$nmEsc</td><td class=`"td-path`" title=`"$ptEsc`">$ptEsc</td><td class=`"td-size`">$szStr2</td><td class=`"td-pct`">$pct2%</td><td class=`"td-files`">$files</td><td class=`"td-bar`"><div class=`"bar-wrap`"><div class=`"bar-fill`" style=`"width:$bar%;background:$dotCol`"></div></div></td></tr>")
                    if ($depth -eq 0) { $idx++ }
                    if ($r2 % 500 -eq 0) {
                        $swRows.Flush()
                        $State.ItemsDone = $r2
                        $elapsed = ([DateTime]::UtcNow - $startTime).TotalSeconds
                        $pctTable = if ($total_items -gt 0) { $r2 / $total_items } else { 1 }
                        $State.Progress = [int](25 + $pctTable * 55)
                        if ($elapsed -gt 0.5 -and $pctTable -gt 0.01) {
                            $eta = [int](($elapsed / $pctTable) * (1 - $pctTable))
                            $State.Phase = "Generando filas HTML... (ETA: ${eta}s)"
                        }
                    }
                }
                $swRows.Flush()
            } finally { $swRows.Close(); $swRows.Dispose() }
            $State.ItemsDone = $total_items; $State.Progress = 82

            $State.Phase = "Ensamblando HTML..."; $State.Progress = 85
            $scanPathEsc = SafeHtml $ScanPath
            # Leer las filas del archivo temporal
            $tableRowsStr = [System.IO.File]::ReadAllText($tmpRowsFile, [System.Text.Encoding]::UTF8)
            try { [System.IO.File]::Delete($tmpRowsFile) } catch {}
            $html = $tpl `
                -replace '{{LOGO_TAG}}',         $logoTag `
                -replace '{{SCAN_PATH}}',         $scanPathEsc `
                -replace '{{REPORT_DATE}}',       $reportDate `
                -replace '{{REPORT_DATE_LONG}}',  $dateLong `
                -replace '{{SCAN_TIME}}',         $dateLong `
                -replace '{{APP_VERSION}}',       "v3.2.0 (Dev)" `
                -replace '{{TOTAL_SIZE}}',        $totalStr `
                -replace '{{TOTAL_FOLDERS}}',     $totalFolders `
                -replace '{{TOTAL_FILES}}',       $totalFiles `
                -replace '{{DISK_STATS_EXTRA}}',  $diskStatsExtra `
                -replace '{{DISK_USAGE_BAR}}',    $diskUsageBar `
                -replace '{{PIE_SLICES}}',        $slicesSvg `
                -replace '{{PIE_LEGEND}}',        $legendHtml `
                -replace '{{TABLE_ROWS}}',        $tableRowsStr
            $tableRowsStr = $null  # liberar ref

            $State.Phase = "Escribiendo archivo..."; $State.Progress = 95
            $outDir = Join-Path $AppDir "output"
            if (-not (Test-Path $outDir)) { [System.IO.Directory]::CreateDirectory($outDir) | Out-Null }
            $outFile = Join-Path $outDir "diskreport_$reportDate.html"
            [System.IO.File]::WriteAllText($outFile, $html, [System.Text.Encoding]::UTF8)

            $State.Result = $outFile; $State.Progress = 100
            $State.Phase  = "Completado"; $State.Done = $true
        } catch {
            $State.Error = $_.Exception.Message; $State.Done = $true
        }
    }

    $ctxHtml = New-PooledPS
    $ps2 = $ctxHtml.PS
    [void]$ps2.AddScript($bgExportScript)
    [void]$ps2.AddParameter("State",        $exportParams.State)
    [void]$ps2.AddParameter("TemplatePath", $exportParams.TemplatePath)
    [void]$ps2.AddParameter("ScanPath",     $exportParams.ScanPath)
    [void]$ps2.AddParameter("AppDir",       $exportParams.AppDir)
    $asyncHtml = $ps2.BeginInvoke()

    $progHtml = Show-ExportProgressDialog
    if ($null -ne $progHtml.Title) { $progHtml.Title.Text = "Generando informe HTML" }
    $progHtml.Window.Show()

    $htmlTimer = New-Object System.Windows.Threading.DispatcherTimer
    $htmlTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:_htmlProg  = $progHtml
    $script:_htmlTimer = $htmlTimer
    $script:_htmlPs    = $ps2
    $script:_htmlCtx   = $ctxHtml
    $script:_htmlAsync = $asyncHtml

    # CancelFn para el menú contextual de tareas
    $htmlTask = $null
    if ($script:TaskPool.TryGetValue("html", [ref]$htmlTask) -and $null -ne $htmlTask) {
        $htmlTask.CancelFn = {
            $script:ExportState.Done  = $true
            $script:ExportState.Error = "Cancelado por el usuario"
            if ($null -ne $script:_htmlTimer) { try { $script:_htmlTimer.Stop() } catch {} }
            try { $script:_htmlPs.Stop() } catch {}
            Dispose-PooledPS $script:_htmlCtx
            if ($null -ne $script:_htmlProg) { try { $script:_htmlProg.Window.Close() } catch {} }
        }
    }

    $htmlTimer.Add_Tick({
        $st   = $script:ExportState
        $prog = $script:_htmlProg
        $pct  = [int]$st.Progress
        $cntStr = if ($st.ItemsTotal -gt 0) { "$($st.ItemsDone) / $($st.ItemsTotal) elementos" } else { "" }
        Update-ProgressDialog $prog $pct $st.Phase $cntStr
        Update-Task -Id "html" -Pct $pct -Detail "$($st.Phase) $cntStr"
        if ($st.Done) {
            $script:_htmlTimer.Stop()
            $prog.Window.Close()
            try { $script:_htmlPs.EndInvoke($script:_htmlAsync) | Out-Null } catch {}
            Dispose-PooledPS $script:_htmlCtx
            $btnDiskReport.IsEnabled = $true
            if ($st.Error -ne "") {
                Complete-Task -Id "html" -IsError -Detail $st.Error
                $txtDiskScanStatus.Text = "Error al generar informe."
                Show-ThemedDialog -Title "Error al generar informe" -Message $st.Error -Type "error"
            } else {
                $outFile2 = if ($st.Result) { [string]$st.Result } else { "" }
                $outLeaf  = if ($outFile2) { Split-Path $outFile2 -Leaf } else { "informe.html" }
                Complete-Task -Id "html" -Detail $outLeaf
                $txtDiskScanStatus.Text = "✅ Informe generado: $outLeaf"
                $open = Show-ThemedDialog -Title "Informe generado" `
                    -Message "Informe HTML guardado en:`n$outFile2`n`n¿Abrir en el navegador?" `
                    -Type "success" -Buttons "YesNo"
                if ($open -and $outFile2) { Start-Process $outFile2 }
                Invoke-AggressiveGC
            }
        }
    })
    $htmlTimer.Start()
})

# ─────────────────────────────────────────────────────────────────────────────
# El hash se calcula en un runspace background para no bloquear la UI.
# Los resultados se muestran en una ventana dedicada con grupos por hash.
# ─────────────────────────────────────────────────────────────────────────────
$btnDedup.Add_Click({
    if ($null -eq $script:AllScannedItems -or $script:AllScannedItems.Count -eq 0) {
        Show-ThemedDialog -Title "Sin datos" `
            -Message "No hay datos de escaneo. Realiza un escaneo primero." -Type "info"
        return
    }

    $btnDedup.IsEnabled     = $false
    $txtDiskScanStatus.Text = "⏳ Calculando hashes SHA256 (archivos >10 MB)..."

    # [FIX-BUG1] Definir $rootPath ANTES de Register-Task (que lo usa en el nombre)
    $rootPath = $txtDiskScanPath.Text
    Register-Task -Id "dedup" -Name "Deduplicación SHA256: $rootPath" -Icon "🔍" -IconBg (Get-TC 'PurpleBlobBg' '#1A1A2F') | Out-Null

    # Estado compartido entre runspace y UI
    $script:DedupState = [hashtable]::Synchronized(@{
        Done       = $false
        Stop       = $false
        Paused     = $false
        Error      = ""
        Groups     = $null     # List de grupos de duplicados
        TotalFiles = 0
        TotalWaste = 0L        # bytes recuperables
    })
    $dedupParams = @{
        State    = $script:DedupState
        RootPath = $rootPath
    }

    $bgDedupScript = {
        param($State, $RootPath)
        try {
            $minBytes  = 10MB
            $sha256    = [System.Security.Cryptography.SHA256]::Create()
            $hashMap   = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new()

            # [FIX-DEDUP-ACCESS] Enumerar archivos con cola manual para saltar directorios
            # inaccesibles (p.ej. C:\Documents and Settings — junction point protegido de
            # Windows Vista+) en lugar de EnumerateFiles(..., AllDirectories) que lanza
            # UnauthorizedAccessException en el primer directorio denegado y aborta todo.
            $queue = [System.Collections.Generic.Queue[string]]::new()
            $queue.Enqueue($RootPath)
            $count = 0

            # [FIX-DEDUP-SYSTEM] Rutas del sistema excluidas: archivos de Windows son
            # idénticos por diseño (dlls, drivers) y marcarlos como "duplicados" es
            # peligroso y confuso. Se excluyen también junctions conocidos.
            $systemExclusions = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)
            foreach ($excl in @(
                [System.IO.Path]::Combine($RootPath, "Windows"),
                [System.IO.Path]::Combine($RootPath, "Windows.old"),
                [System.IO.Path]::Combine($RootPath, "Documents and Settings"),
                [System.IO.Path]::Combine($RootPath, "System Volume Information"),
                [System.IO.Path]::Combine($RootPath, "Recovery"),
                [System.IO.Path]::Combine($RootPath, "$Recycle.Bin"),
                [System.IO.Path]::Combine($RootPath, "ProgramData\Microsoft"),
                [System.IO.Path]::Combine([System.Environment]::GetFolderPath("Windows"), "")
            )) { [void]$systemExclusions.Add($excl.TrimEnd('\')) }

            while ($queue.Count -gt 0) {
                $dir = $queue.Dequeue()

                # [CANCEL] Comprobar flag de cancelación en cada iteración
                if ($State.Stop) { break }

                # [PAUSE] Spinwait si la UI ha solicitado pausa
                while ($State.Paused -and -not $State.Stop) {
                    [System.Threading.Thread]::Sleep(100)
                }
                if ($State.Stop) { break }

                # [FIX-DEDUP-SYSTEM] Saltar rutas del sistema
                $dirNorm = $dir.TrimEnd('\')
                $skipDir = $false
                foreach ($excl in $systemExclusions) {
                    if ($dirNorm -eq $excl -or $dirNorm.StartsWith($excl + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                        $skipDir = $true; break
                    }
                }
                if ($skipDir) { continue }

                # Saltar junction points / symlinks — evita bucles y accesos denegados
                try {
                    $dirInfo = [System.IO.DirectoryInfo]::new($dir)
                    $isJunction = ($dirInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
                    if ($isJunction) { continue }
                } catch { continue }

                # Encolar subdirectorios (silenciar error de acceso por directorio)
                try {
                    foreach ($sub in [System.IO.Directory]::GetDirectories($dir)) {
                        $queue.Enqueue($sub)
                    }
                } catch { <# sin permisos — continuar con el resto #> }

                # Procesar archivos del directorio actual
                try {
                    foreach ($f in [System.IO.Directory]::GetFiles($dir)) {
                        try {
                            $fi = [System.IO.FileInfo]::new($f)
                            if ($fi.Length -lt $minBytes) { continue }
                            $stream    = [System.IO.File]::OpenRead($f)
                            $hashBytes = $sha256.ComputeHash($stream)
                            $stream.Close(); $stream.Dispose()
                            $hex = [System.BitConverter]::ToString($hashBytes) -replace '-',''
                            if (-not $hashMap.ContainsKey($hex)) {
                                $hashMap[$hex] = [System.Collections.Generic.List[string]]::new()
                            }
                            $hashMap[$hex].Add($f)
                            $count++
                        } catch { continue }
                    }
                } catch { continue }
            }
            $sha256.Dispose()

            # Filtrar solo grupos con 2+ archivos (duplicados reales)
            $groups = [System.Collections.Generic.List[object]]::new()
            $totalWaste = 0L
            foreach ($kvp in $hashMap.GetEnumerator()) {
                if ($kvp.Value.Count -lt 2) { continue }
                $sampleSize = ([System.IO.FileInfo]::new($kvp.Value[0])).Length
                $waste = $sampleSize * ($kvp.Value.Count - 1)
                $totalWaste += $waste

                $fmtSize = if ($sampleSize -ge 1GB) { "{0:N2} GB" -f ($sampleSize/1GB) }
                           elseif ($sampleSize -ge 1MB) { "{0:N1} MB" -f ($sampleSize/1MB) }
                           else { "{0:N0} KB" -f ($sampleSize/1KB) }
                $fmtWaste = if ($waste -ge 1GB) { "{0:N2} GB" -f ($waste/1GB) }
                            elseif ($waste -ge 1MB) { "{0:N1} MB" -f ($waste/1MB) }
                            else { "{0:N0} KB" -f ($waste/1KB) }

                $groups.Add([PSCustomObject]@{
                    Hash       = $kvp.Key.Substring(0, 16) + "…"
                    FullHash   = $kvp.Key
                    Count      = $kvp.Value.Count
                    SizeStr    = $fmtSize
                    SizeBytes  = $sampleSize
                    WasteStr   = $fmtWaste
                    WasteBytes = $waste
                    Files      = $kvp.Value -join "`n"
                    FilesList  = $kvp.Value
                })
            }

            # Ordenar por espacio desperdiciado descendente
            $sorted = $groups | Sort-Object WasteBytes -Descending
            $State.Groups     = [System.Collections.Generic.List[object]]::new()
            foreach ($g in $sorted) { $State.Groups.Add($g) }
            $State.TotalFiles = $count
            $State.TotalWaste = $totalWaste
        } catch {
            $State.Error = $_.Exception.Message
        } finally {
            $State.Done = $true
        }
    }

    $ctx = New-PooledPS
    $ctx.PS.AddScript($bgDedupScript).AddParameter("State", $script:DedupState).AddParameter("RootPath", $rootPath) | Out-Null
    $dedupAsync = $ctx.PS.BeginInvoke()

    $dedupTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:_dedupTimer = $dedupTimer

    # Registrar hooks de control para el menú contextual de tareas
    $dedupTask = $null
    if ($script:TaskPool.TryGetValue("dedup", [ref]$dedupTask) -and $null -ne $dedupTask) {
        $dedupTask.CancelFn = {
            $script:DedupState.Paused = $false  # desbloquear spinwait antes de cancelar
            $script:DedupState.Stop   = $true
            $script:DedupState.Done   = $true   # desbloquea el timer tick para limpieza
        }
        $dedupTask.PauseFn = {
            $script:DedupState.Paused = $true
        }
        $dedupTask.ResumeFn = {
            $script:DedupState.Paused = $false
        }
    }
    $dedupTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $dedupTimer.Add_Tick({
        if (-not $script:DedupState.Done) { return }
        # [FIX] Usar $script:_dedupTimer en vez de $dedupTimer — en PS5.1 el closure
        # del Add_Tick no captura variables locales del scope padre; $dedupTimer sería
        # $null aquí y lanzaría "You cannot call a method on a null-valued expression".
        $script:_dedupTimer.Stop()
        $script:_dedupTimer = $null
        Dispose-PooledPS $ctx

        $btnDedup.IsEnabled = $true

        if ($script:DedupState.Error) {
            Complete-Task -Id "dedup" -IsError -Detail $script:DedupState.Error
            $txtDiskScanStatus.Text = "Error en deduplicación."
            Write-Log "[B5] Error SHA256: $($script:DedupState.Error)" -Level "ERR"
            Show-ThemedDialog -Title "Error de deduplicación" `
                -Message "Error al calcular hashes:`n$($script:DedupState.Error)" -Type "error"
            return
        }

        $groups = $script:DedupState.Groups
        $waste  = $script:DedupState.TotalWaste
        $fmtW   = if ($waste -ge 1GB) { "{0:N2} GB" -f ($waste/1GB) }
                  elseif ($waste -ge 1MB) { "{0:N1} MB" -f ($waste/1MB) }
                  else { "{0:N0} KB" -f ($waste/1KB) }

        if ($null -eq $groups -or $groups.Count -eq 0) {
            Complete-Task -Id "dedup" -Detail "Sin duplicados"
            $txtDiskScanStatus.Text = "✓ No se encontraron duplicados (>10 MB)."
            Write-Log "[B5] Deduplicación completada: sin duplicados." -Level "INFO"
            Show-ThemedDialog -Title "Sin duplicados" `
                -Message "No se encontraron archivos duplicados mayores de 10 MB en la ruta escaneada." -Type "info"
            return
        }

        Complete-Task -Id "dedup" -Detail "$($groups.Count) grupos · $fmtW recuperables"
        $txtDiskScanStatus.Text = "✓ $($groups.Count) grupos de duplicados — $fmtW recuperables."
        Write-Log "[B5] Deduplicación: $($groups.Count) grupos, $fmtW recuperables." -Level "INFO"

        # ── Ventana de resultados de deduplicación ──────────────────────────
        $dedupXaml = [XamlLoader]::Load($script:XamlFolder, "DedupWindow")
        try {
            $dr   = [System.Xml.XmlNodeReader]::new([xml]$dedupXaml)
            $dWin = [Windows.Markup.XamlReader]::Load($dr)
            $dWin.Owner = $window

            # ── Inyectar TB_* brushes del tema actual y registrar para futuros cambios
            $themedRd = New-ThemedWindowResources
            foreach ($k in @($themedRd.Keys)) { $dWin.Resources[$k] = $themedRd[$k] }
            $script:ThemedWindows.Add($dWin)
            $dWin.Add_Closed({ try { $script:ThemedWindows.Remove($dWin) | Out-Null } catch {} })

            $lbGroups       = $dWin.FindName("lbDedupGroups")
            $txtDedupSum    = $dWin.FindName("txtDedupSummary")
            $txtDedupSt     = $dWin.FindName("txtDedupStatus")
            $btnDedupClose  = $dWin.FindName("btnDedupClose")

            $txtDedupSum.Text = "$($groups.Count) grupos · $($script:DedupState.TotalFiles) archivos analizados · $fmtW recuperables eliminando copias"
            $lbGroups.ItemsSource = $groups

            # Botón eliminar copias de un grupo (conserva el primer archivo)
            $lbGroups.AddHandler(
                [System.Windows.Controls.Button]::ClickEvent,
                [System.Windows.RoutedEventHandler]{
                    param($s2, $e2)
                    $srcBtn = $e2.OriginalSource
                    if (-not ($srcBtn -is [System.Windows.Controls.Button]) -or $srcBtn.Name -ne "btnDedupDelete") { return }
                    $fullHash = [string]$srcBtn.Tag
                    $grp = $groups | Where-Object { $_.FullHash -eq $fullHash } | Select-Object -First 1
                    if ($null -eq $grp) { return }

                    $copies = $grp.FilesList | Select-Object -Skip 1
                    $confirmMsg = "Se eliminarán $($copies.Count) copia(s) del grupo:`n(se conserva: $($grp.FilesList[0]))`n`n¿Continuar?"
                    $ok = Show-ThemedDialog -Title "Confirmar eliminación" -Message $confirmMsg -Type "confirm"
                    if (-not $ok) { return }

                    $deleted = 0; $errors = 0
                    foreach ($f in $copies) {
                        try { Remove-Item -Path $f -Force -ErrorAction Stop; $deleted++ }
                        catch { $errors++; Write-Log "[B5] Error eliminando $f : $($_.Exception.Message)" -Level "WARN" }
                    }
                    Write-Log "[B5] Eliminadas $deleted copias del hash $($grp.Hash). Errores: $errors." -Level "INFO"
                    $txtDedupSt.Text = "✓ $deleted archivo(s) eliminado(s)$(if($errors -gt 0){" · $errors error(es)"})"

                    # Refrescar lista quitando el grupo procesado
                    $groups.Remove($grp) | Out-Null
                    $lbGroups.Items.Refresh()
                }
            )

            $btnDedupClose.Add_Click({ $dWin.Close() })
            $dWin.ShowDialog() | Out-Null
        } catch {
            Write-Log "[B5] Error abriendo ventana de duplicados: $($_.Exception.Message)" -Level "ERR"
            Show-ThemedDialog -Title "Error" -Message "Error al abrir la ventana de duplicados:`n$($_.Exception.Message)" -Type "error"
        }
    })
    $dedupTimer.Start()
})
$lbDiskTree.AddHandler(
    [System.Windows.Controls.Button]::ClickEvent,
    [System.Windows.RoutedEventHandler]{
        param($s, $e)
        $btn = $e.OriginalSource
        if ($btn -is [System.Windows.Controls.Button] -and $null -ne $btn.Tag -and "$($btn.Tag)" -ne "") {
            $path = [string]$btn.Tag
            if ($script:CollapsedPaths.Contains($path)) {
                # Expandir: quitar de colapsados, actualizar icono
                $script:CollapsedPaths.Remove($path) | Out-Null
                if ($null -ne $script:LiveItems -and $script:LiveItems.ContainsKey($path) -and $null -ne $script:AllScannedItems) {
                    $script:AllScannedItems[$script:LiveItems[$path]].ToggleIcon = [string][char]0x25BC   # ▼
                }
            } else {
                # Colapsar: añadir a colapsados, actualizar icono
                $script:CollapsedPaths.Add($path) | Out-Null
                if ($null -ne $script:LiveItems -and $script:LiveItems.ContainsKey($path) -and $null -ne $script:AllScannedItems) {
                    $script:AllScannedItems[$script:LiveItems[$path]].ToggleIcon = [string][char]0x25B6   # ▶
                }
            }
            # Refresh reconstruye qué items son visibles (muestra/oculta hijos).
            # Items.Refresh() es obligatorio: LiveList es List<T>, no ObservableCollection —
            # WPF no detecta Clear()/Add() sin notificación explícita al ItemsControl.
            Refresh-DiskView
            $lbDiskTree.Items.Refresh()
            $e.Handled = $true
        }
    }
)

# Selección en la lista → actualizar panel de detalle
$lbDiskTree.Add_SelectionChanged({
    $sel = $lbDiskTree.SelectedItem
    if ($null -eq $sel) { return }

    $txtDiskDetailName.Text  = $sel.DisplayName
    $txtDiskDetailSize.Text  = $sel.SizeStr
    $txtDiskDetailFiles.Text = if ($sel.IsDir) { $sel.FileCount } else { "1 archivo" }
    $txtDiskDetailDirs.Text  = if ($sel.IsDir) { "$($sel.DirCount) carpetas" } else { "—" }
    $txtDiskDetailPct.Text   = "$($sel.TotalPct)%"

    # Top 10 archivos más grandes — ejecutado en runspace para no bloquear la UI
    $icTopFiles.ItemsSource = @([PSCustomObject]@{ FileName = "Buscando archivos grandes…"; FileSize = "" })
    $selPath = $sel.FullPath
    if ($sel.IsDir -and (Test-Path $selPath)) {
        $topBg = {
            param([string]$p)
            try {
                [System.IO.Directory]::GetFiles($p, "*", [System.IO.SearchOption]::AllDirectories) |
                    ForEach-Object {
                        try { [PSCustomObject]@{ Name=[System.IO.Path]::GetFileName($_); Len=([System.IO.FileInfo]$_).Length } } catch {}
                    } |
                    Sort-Object Len -Descending |
                    Select-Object -First 10
            } catch { @() }
        }
        $ctxTop = New-PooledPS
        $psTop = $ctxTop.PS
        [void]$psTop.AddScript($topBg).AddParameter("p", $selPath)
        $asyncTop = $psTop.BeginInvoke()
        $script:_topTimer = New-Object System.Windows.Threading.DispatcherTimer
        $topTimer = $script:_topTimer
        $topTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        $script:_topCtx = $ctxTop
        $topTimer.Add_Tick({
            if (-not $asyncTop.IsCompleted) { return }
            $topTimer.Stop()
            $results = try { $psTop.EndInvoke($asyncTop) } catch { @() }
            Dispose-PooledPS $script:_topCtx
            $topFiles2 = [System.Collections.Generic.List[object]]::new()
            foreach ($r in $results) {
                if ($null -ne $r) {
                    $sz = [Formatter]::FormatBytes([long]$r.Len)
                    $topFiles2.Add([PSCustomObject]@{ FileName=$r.Name; FileSize=$sz })
                }
            }
            if ($topFiles2.Count -eq 0) { $topFiles2.Add([PSCustomObject]@{ FileName="(ningún archivo encontrado)"; FileSize="" }) }
            $icTopFiles.ItemsSource = $topFiles2
        })
        $topTimer.Start()
    }
})

# ─────────────────────────────────────────────────────────────────────────────
# [N9] Show-FolderScanner — ventana emergente de análisis de carpeta
# ─────────────────────────────────────────────────────────────────────────────
function Show-FolderScanner {
    param([string]$FolderPath)

    $fsXaml = [XamlLoader]::Load($script:XamlFolder, "FolderScannerWindow")
    $fsXaml = $ExecutionContext.InvokeCommand.ExpandString($fsXaml)

    $fsReader  = [System.Xml.XmlNodeReader]::new([xml]$fsXaml)
    $fsWindow  = [Windows.Markup.XamlReader]::Load($fsReader)
    $fsWindow.Owner = $window

    # ── Obtener controles ──
    $fsPathLabel   = $fsWindow.FindName("fsPathLabel")
    $fsTotalSize   = $fsWindow.FindName("fsTotalSize")
    $fsFileCount   = $fsWindow.FindName("fsFileCount")
    $fsFilter      = $fsWindow.FindName("fsFilter")
    $fsFilterHint  = $fsWindow.FindName("fsFilterHint")
    $fsSortSize    = $fsWindow.FindName("fsSortSize")
    $fsSortName    = $fsWindow.FindName("fsSortName")
    $fsSortExt     = $fsWindow.FindName("fsSortExt")
    $fsListBox     = $fsWindow.FindName("fsListBox")
    $fsScanStatus  = $fsWindow.FindName("fsScanStatus")
    $fsScanProgress= $fsWindow.FindName("fsScanProgress")
    $fsScanCount   = $fsWindow.FindName("fsScanCount")
    $fsSelInfo     = $fsWindow.FindName("fsSelInfo")
    $fsBtnClose    = $fsWindow.FindName("fsBtnClose")
    $fsCtxMenu     = $fsListBox.ContextMenu
    $fsCtxPreview  = $fsCtxMenu.Items | Where-Object { $_.Name -eq "fsCtxPreview"  }
    $fsCtxLocation = $fsCtxMenu.Items | Where-Object { $_.Name -eq "fsCtxLocation" }
    $fsCtxDelete   = $fsCtxMenu.Items | Where-Object { $_.Name -eq "fsCtxDelete"   }

    $fsPathLabel.Text = $FolderPath
    $script:fsAllItems  = [System.Collections.Generic.List[object]]::new()
    $script:fsSortMode  = "size"   # "size" | "name" | "ext"
    $script:fsFilterTxt = ""

    # ── Helper: formatear tamaño ──
    function Format-FsSize([long]$b) {
        if ($b -ge 1GB) { return "{0:N2} GB" -f ($b / 1GB) }
        if ($b -ge 1MB) { return "{0:N1} MB" -f ($b / 1MB) }
        if ($b -ge 1KB) { return "{0:N0} KB" -f ($b / 1KB) }
        return "$b B"
    }

    # ── Helper: color por tamaño ──
    function Get-FsSizeColor([long]$b) {
        if ($b -ge 1GB)  { return "#FF6B84" }
        if ($b -ge 100MB){ return "#FFB547" }
        if ($b -ge 10MB) { return "#5BA3FF" }
        return "#9BA4C0"
    }

    # ── Helper: icono por extensión ──
    function Get-FsIcon([string]$ext) {
        switch ($ext.ToLower()) {
            {$_ -in @(".mp4",".mkv",".avi",".mov",".wmv",".ts",".m2ts")} { return "🎬" }
            {$_ -in @(".mp3",".flac",".wav",".aac",".ogg",".m4a")}        { return "🎵" }
            {$_ -in @(".jpg",".jpeg",".png",".gif",".bmp",".webp",".raw")} { return "🖼" }
            {$_ -in @(".zip",".rar",".7z",".tar",".gz",".bz2")}           { return "📦" }
            {$_ -in @(".exe",".msi",".dll",".sys")}                        { return "⚙" }
            {$_ -in @(".pdf")}                                             { return "📄" }
            {$_ -in @(".doc",".docx",".odt")}                              { return "📝" }
            {$_ -in @(".xls",".xlsx",".csv")}                              { return "📊" }
            {$_ -in @(".ppt",".pptx")}                                     { return "📑" }
            {$_ -in @(".iso",".img",".vhd",".vmdk")}                       { return "💿" }
            {$_ -in @(".ps1",".py",".js",".ts",".cs",".cpp",".h")}        { return "💻" }
            default                                                         { return "📄" }
        }
    }

    # ── Refrescar la lista con filtro y orden actuales ──
    function Refresh-FsList {
        # Liberar referencia anterior antes de reasignar (ayuda al GC)
        $fsListBox.ItemsSource = $null

        $filtered = if ($script:fsFilterTxt -ne "") {
            $script:fsAllItems | Where-Object { $_.FullPath -like "*$($script:fsFilterTxt)*" }
        } else { $script:fsAllItems }

        $sorted = switch ($script:fsSortMode) {
            "name" { $filtered | Sort-Object DisplayName }
            "ext"  { $filtered | Sort-Object Ext, DisplayName }
            default{ $filtered | Sort-Object SizeBytes -Descending }
        }

        # Calcular máximo con un solo foreach (sin Measure-Object que crea pipeline completo)
        $maxB = [long]0
        foreach ($it in $script:fsAllItems) { if ($it.SizeBytes -gt $maxB) { $maxB = $it.SizeBytes } }
        if ($maxB -le 0) { $maxB = 1 }

        # Pre-reservar capacidad para evitar realocaciones internas de la lista
        $rows = [System.Collections.Generic.List[object]]::new([Math]::Max(1, $script:fsAllItems.Count))
        foreach ($it in $sorted) {
            $it.BarW = [Math]::Max(4, [int](($it.SizeBytes / $maxB) * 700))
            $rows.Add($it)
        }
        $fsListBox.ItemsSource = $rows

        # Usar $script:fsTotalBytes ya acumulado — evita otro Measure-Object sobre toda la colección
        $fsTotalSize.Text  = Format-FsSize $script:fsTotalBytes
        $fsFileCount.Text  = "$($script:fsAllItems.Count) archivos"
    }

    # ── Escaneo streaming con ConcurrentQueue (nunca bloquea la UI) ──
    $script:fsScanQueue  = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $script:fsScanDone   = $false
    $script:fsTotalBytes = [long]0

    $scanScript = {
        param(
            [string]$root,
            [System.Collections.Concurrent.ConcurrentQueue[object]]$queue,
            [ref]$done
        )
        try {
            $di = [System.IO.DirectoryInfo]::new($root)
            foreach ($f in $di.EnumerateFiles("*", [System.IO.SearchOption]::AllDirectories)) {
                try {
                    $queue.Enqueue([PSCustomObject]@{
                        P = $f.FullName
                        N = $f.Name
                        B = $f.Length
                        X = $f.Extension
                        M = $f.LastWriteTime.ToString("dd/MM/yyyy  HH:mm")
                    })
                } catch {}
            }
        } catch {}
        $done.Value = $true
    }

    $rsFs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rsFs.Open()
    $psFs = [System.Management.Automation.PowerShell]::Create()
    $psFs.Runspace = $rsFs
    [void]$psFs.AddScript($scanScript).AddParameter("root", $FolderPath).AddParameter("queue", $script:fsScanQueue).AddParameter("done", ([ref]$script:fsScanDone))
    $asyncFs = $psFs.BeginInvoke()

    # Lote adaptativo: en equipos con poca RAM disponible se reduce automáticamente
    $availMB = [Math]::Round((Invoke-CimQuery -ClassName Win32_OperatingSystem -SilentOnFail).FreePhysicalMemory / 1024)
    $BATCH = if ($availMB -lt 2048) { 50 } elseif ($availMB -lt 4096) { 150 } else { 300 }

    $script:_scanTimer = New-Object System.Windows.Threading.DispatcherTimer
    $scanTimer = $script:_scanTimer
    # Intervalo adaptativo: más lento si hay poca RAM libre
    $scanIntervalMs = if ($availMB -lt 2048) { 250 } elseif ($availMB -lt 4096) { 180 } else { 120 }
    $scanTimer.Interval = [TimeSpan]::FromMilliseconds($scanIntervalMs)
    $scanTimer.Add_Tick({
        # Drena hasta $BATCH items de la queue
        $processed = 0
        $item = $null
        while ($processed -lt $BATCH -and $script:fsScanQueue.TryDequeue([ref]$item)) {
            $ext  = if ($item.X) { $item.X } else { "" }
            $icon = Get-FsIcon $ext
            $sc   = Get-FsSizeColor $item.B
            $script:fsAllItems.Add([PSCustomObject]@{
                FullPath    = $item.P
                DisplayName = $item.N
                SizeBytes   = $item.B
                SizeStr     = Format-FsSize $item.B
                SizeColor   = $sc
                Ext         = $ext.TrimStart(".")
                Modified    = $item.M
                Icon        = $icon
                NameColor   = "#E8ECF4"
                BarC        = $sc
                BarW        = 0
            })
            $script:fsTotalBytes += $item.B
            $processed++
            $item = $null  # liberar referencia al objeto de cola
        }

        # Actualizar contador en vivo
        $cnt = $script:fsAllItems.Count
        if ($cnt -gt 0) {
            $fsScanStatus.Text = "Escaneando…   $cnt archivos  ·  $(Format-FsSize $script:fsTotalBytes)"
            $fsScanCount.Text  = "$cnt archivos"
        }

        # ¿Terminado? Queue vacía Y runspace señaliza done
        if ($script:fsScanDone -and $script:fsScanQueue.IsEmpty) {
            $scanTimer.Stop()

            # Limpiar runspace
            try { $psFs.Stop()  } catch {}
            try { $psFs.Dispose() } catch {}
            try { $rsFs.Close(); $rsFs.Dispose() } catch {}

            # Liberar memoria del proceso — trabajar como el gestor de RAM de SysOpt
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            [System.GC]::Collect()
            try {
                # [DLL] WseTrim — cargado al inicio en el bloque de DLLs
                if (([System.Management.Automation.PSTypeName]'WseTrim').Type) {
                    [WseTrim]::TrimCurrentProcess()
                }
            } catch {}

            $fsScanProgress.IsIndeterminate = $false
            $fsScanProgress.Value           = 100
            $cnt2 = $script:fsAllItems.Count
            $fsScanStatus.Text = "✅  Completado — $cnt2 archivos  ·  $(Format-FsSize $script:fsTotalBytes)"
            Write-Log ("[SCAN] Completado: {0} archivos  |  {1}  |  ruta: {2}" -f $cnt2, (Format-FsSize $script:fsTotalBytes), $FolderPath) -Level "INFO" -NoUI
            $fsScanCount.Text  = "$cnt2 archivos"
            $fsTotalSize.Text  = Format-FsSize $script:fsTotalBytes
            $fsFileCount.Text  = "$cnt2 archivos"
            Refresh-FsList
        }
    })
    $scanTimer.Start()

    # ── Filtro en tiempo real ──
    $fsFilter.Add_TextChanged({
        $script:fsFilterTxt = $fsFilter.Text
        $fsFilterHint.Visibility = if ($fsFilter.Text -eq "") {
            [System.Windows.Visibility]::Visible
        } else {
            [System.Windows.Visibility]::Collapsed
        }
        Refresh-FsList
    })

    $bc_ = [System.Windows.Media.BrushConverter]::new()
    # ── Botones de ordenación ──
    $fsSortSize.Add_Click({
        $script:fsSortMode = "size"
        $fsSortSize.Background = ($bc_.ConvertFromString((Get-TC 'ComboSelected' '#132040')))
        $fsSortSize.Foreground = ($bc_.ConvertFromString((Get-TC 'AccentBlue'    '#5BA3FF')))
        $fsSortName.Background = ($bc_.ConvertFromString((Get-TC 'BgInput'       '#1A1E2F')))
        $fsSortName.Foreground = ($bc_.ConvertFromString((Get-TC 'TextSecondary' '#9BA4C0')))
        $fsSortExt.Background  = ($bc_.ConvertFromString((Get-TC 'BgInput'       '#1A1E2F')))
        $fsSortExt.Foreground  = ($bc_.ConvertFromString((Get-TC 'TextSecondary' '#9BA4C0')))
        Refresh-FsList
    })
    $fsSortName.Add_Click({
        $script:fsSortMode = "name"
        $fsSortName.Background = ($bc_.ConvertFromString((Get-TC 'ComboSelected' '#132040')))
        $fsSortName.Foreground = ($bc_.ConvertFromString((Get-TC 'AccentBlue'    '#5BA3FF')))
        $fsSortSize.Background = ($bc_.ConvertFromString((Get-TC 'BgInput'       '#1A1E2F')))
        $fsSortSize.Foreground = ($bc_.ConvertFromString((Get-TC 'TextSecondary' '#9BA4C0')))
        $fsSortExt.Background  = ($bc_.ConvertFromString((Get-TC 'BgInput'       '#1A1E2F')))
        $fsSortExt.Foreground  = ($bc_.ConvertFromString((Get-TC 'TextSecondary' '#9BA4C0')))
        Refresh-FsList
    })
    $fsSortExt.Add_Click({
        $script:fsSortMode = "ext"
        $fsSortExt.Background  = ($bc_.ConvertFromString((Get-TC 'ComboSelected' '#132040')))
        $fsSortExt.Foreground  = ($bc_.ConvertFromString((Get-TC 'AccentBlue'    '#5BA3FF')))
        $fsSortSize.Background = ($bc_.ConvertFromString((Get-TC 'BgInput'       '#1A1E2F')))
        $fsSortSize.Foreground = ($bc_.ConvertFromString((Get-TC 'TextSecondary' '#9BA4C0')))
        $fsSortName.Background = ($bc_.ConvertFromString((Get-TC 'BgInput'       '#1A1E2F')))
        $fsSortName.Foreground = ($bc_.ConvertFromString((Get-TC 'TextSecondary' '#9BA4C0')))
        Refresh-FsList
    })

    # ── Info de selección ──
    $fsListBox.Add_SelectionChanged({
        $sel = $fsListBox.SelectedItem
        if ($null -ne $sel) {
            $fsSelInfo.Text = "$($sel.DisplayName)   ·   $($sel.SizeStr)   ·   $($sel.Modified)"
        } else { $fsSelInfo.Text = "" }
    })

    # ── Doble clic → abrir ──
    $fsListBox.Add_MouseDoubleClick({
        $sel = $fsListBox.SelectedItem
        if ($null -ne $sel -and (Test-Path $sel.FullPath)) {
            try { Start-Process $sel.FullPath } catch {
                Show-ThemedDialog -Title "Error al abrir archivo" `
                    -Message "No se puede abrir el archivo.`n$($_.Exception.Message)" -Type "error"
            }
        }
    })

    # ── Menú contextual de archivos ──
    $fsCtxMenu.Add_Opened({
        $sel = $fsListBox.SelectedItem
        $has = $null -ne $sel -and (Test-Path $sel.FullPath)
        $fsCtxPreview.IsEnabled  = $has
        $fsCtxLocation.IsEnabled = $has
        $fsCtxDelete.IsEnabled   = $has
    })

    $fsCtxPreview.Add_Click({
        $sel = $fsListBox.SelectedItem
        if ($null -ne $sel -and (Test-Path $sel.FullPath)) {
            try { Start-Process $sel.FullPath } catch {
                Show-ThemedDialog -Title "Error al abrir" `
                    -Message "No se puede abrir el archivo.`n$($_.Exception.Message)" -Type "error"
            }
        }
    })

    $fsCtxLocation.Add_Click({
        $sel = $fsListBox.SelectedItem
        if ($null -ne $sel -and (Test-Path $sel.FullPath)) {
            # Abrir explorador seleccionando el archivo
            Start-Process "explorer.exe" "/select,`"$($sel.FullPath)`""
        }
    })

    $fsCtxDelete.Add_Click({
        $sel = $fsListBox.SelectedItem
        if ($null -eq $sel) { return }
        $confirm = Show-ThemedDialog -Title "Confirmar eliminación" `
            -Message "¿Eliminar permanentemente este archivo?`n`n$($sel.FullPath)`n`nTamaño: $($sel.SizeStr)`n`nEsta acción no se puede deshacer." `
            -Type "warning" -Buttons "YesNo"
        if ($confirm) {
            try {
                Remove-Item -Path $sel.FullPath -Force -ErrorAction Stop
                $script:fsAllItems.Remove($sel) | Out-Null
                $fsScanStatus.Text = "🗑  Eliminado: $($sel.FullPath)"
                Refresh-FsList
            } catch {
                Show-ThemedDialog -Title "Error al eliminar" `
                    -Message "Error al eliminar:`n$($_.Exception.Message)" -Type "error"
            }
        }
    })

    # ── Cerrar ──
    $fsBtnClose.Add_Click({
        $scanTimer.Stop()
        $script:fsScanDone = $true          # señaliza al runspace que pare
        try { $psFs.Stop()    } catch {}
        try { $psFs.Dispose() } catch {}
        try { $rsFs.Close(); $rsFs.Dispose() } catch {}
        [System.GC]::Collect()
        $fsWindow.Close()
    })
    $fsWindow.Add_Closed({
        $scanTimer.Stop()
        $script:fsScanDone = $true
        try { $psFs.Stop()    } catch {}
        try { $psFs.Dispose() } catch {}
        try { $rsFs.Close(); $rsFs.Dispose() } catch {}
        [System.GC]::Collect()
    })

    $fsWindow.ShowDialog() | Out-Null
}

# ─────────────────────────────────────────────────────────────────────────────
# [N8] Ventana de gestión de programas de inicio
# ─────────────────────────────────────────────────────────────────────────────
function Show-StartupManager {
    $startupXaml = [XamlLoader]::Load($script:XamlFolder, "StartupManagerWindow")
    $startupXaml = $ExecutionContext.InvokeCommand.ExpandString($startupXaml)

    $sReader    = [System.Xml.XmlNodeReader]::new([xml]$startupXaml)
    $sWindow    = [Windows.Markup.XamlReader]::Load($sReader)
    $sGrid      = $sWindow.FindName("StartupGrid")
    $sStatus    = $sWindow.FindName("StartupStatus")
    $btnApply   = $sWindow.FindName("btnApplyStartup")
    $btnClose   = $sWindow.FindName("btnCloseStartup")
    $titleBar   = $sWindow.FindName("titleBar")

    # Drag por la barra de título (no se puede hacer en XAML puro sin code-behind)
    $script:_startupWin = $sWindow
    $titleBar.Add_MouseLeftButtonDown({ $script:_startupWin.DragMove() })

    # ── Obtener entradas de inicio vía DLL ──────────────────────────────────────
    $rawEntries = [SysOpt.StartupManager.StartupEngine]::GetEntries()
    $startupTable = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    foreach ($e in $rawEntries) {
        $startupTable.Add([PSCustomObject]@{
            Enabled      = $e.Enabled
            Name         = $e.Name
            Command      = $e.Command
            Source       = $e.Source
            Location     = $e.Location
            OriginalName = $e.Name
        })
    }
    $sGrid.ItemsSource = $startupTable
    $sStatus.Text = "$($startupTable.Count) entradas encontradas"

    $btnApply.Add_Click({
        # Construir lista de StartupEntry desde la tabla UI
        $entryList = New-Object "System.Collections.Generic.List[SysOpt.StartupManager.StartupEntry]"
        foreach ($item in $startupTable) {
            $se = New-Object SysOpt.StartupManager.StartupEntry
            $se.Name     = $item.OriginalName
            $se.Command  = $item.Command
            $se.RegPath  = $item.Location
            $se.Source   = $item.Source
            $se.Enabled  = $item.Enabled
            $entryList.Add($se)
        }
        $results  = [SysOpt.StartupManager.StartupEngine]::ApplyChanges($entryList)
        $disabled = ($results | Where-Object { $_.Success -and $_.NewState -eq "Disabled" }).Count
        $errors   = ($results | Where-Object { -not $_.Success }).Count
        $msg = "Cambios aplicados: $disabled entradas desactivadas."
        if ($errors -gt 0) { $msg += "`n$errors entradas no pudieron modificarse (requieren permisos adicionales)." }
        Show-ThemedDialog -Title "Cambios aplicados" -Message $msg -Type "success"
        Write-ConsoleMain "🚀 Startup Manager: $disabled entradas desactivadas del registro."
        $sWindow.Close()
    })

    $script:_startupWin = $sWindow
    $btnClose.Add_Click({ $script:_startupWin.Close() })
    $sWindow.Owner = $window
    $sWindow.ShowDialog() | Out-Null
}

# ─────────────────────────────────────────────────────────────────────────────
# [N9] Ventana de Informe de Diagnóstico (resultado del Análisis Dry Run)
# ─────────────────────────────────────────────────────────────────────────────

# ── Helper WPF: renderizar fila de diagnóstico ──────────────────────────────
function Add-DiagRow {
    param(
        [System.Windows.Window]$Window,
        [System.Windows.Controls.StackPanel]$Panel,
        [string]$Status, [string]$Label, [string]$Detail, [string]$Action = ""
    )
    $styleKey = switch ($Status) {
        "OK"   { "GoodRow" }
        "WARN" { "WarnRow" }
        "CRIT" { "CritRow" }
        default{ "InfoRow" }
    }
    $border = New-Object System.Windows.Controls.Border
    $border.Style = $Window.Resources[$styleKey]

    $grid = New-Object System.Windows.Controls.Grid
    $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = [System.Windows.GridLength]::new(38)
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto
    $grid.ColumnDefinitions.Add($c0)
    $grid.ColumnDefinitions.Add($c1)
    $grid.ColumnDefinitions.Add($c2)

    $ico = New-Object System.Windows.Controls.TextBlock
    $ico.Text = switch ($Status) { "OK" { "✅" } "WARN" { "⚠️" } "CRIT" { "🔴" } default { "ℹ️" } }
    $ico.FontSize = 16; $ico.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetColumn($ico, 0)
    [void]$grid.Children.Add($ico)

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetColumn($sp, 1)

    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text       = $Label
    $lbl.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
    $lbl.FontSize   = 12
    $lbl.FontWeight = [System.Windows.FontWeights]::SemiBold
    $lblColor = switch ($Status) { "OK" { "#4AE896" } "WARN" { "#FFB547" } "CRIT" { "#FF6B84" } default { "#7BA8E0" } }
    $lbl.Foreground = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString($lblColor))
    [void]$sp.Children.Add($lbl)

    if ($Detail) {
        $det = New-Object System.Windows.Controls.TextBlock
        $det.Text       = $Detail
        $det.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
        $det.FontSize   = 10
        $det.Foreground = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString((Get-TC 'TextSecondary' '#9BA4C0')))
        $det.TextWrapping = "Wrap"
        [void]$sp.Children.Add($det)
    }
    [void]$grid.Children.Add($sp)

    if ($Action) {
        $act = New-Object System.Windows.Controls.TextBlock
        $act.Text       = $Action
        $act.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
        $act.FontSize   = 9
        $act.Foreground = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString((Get-TC 'AccentBlue' '#5BA3FF')))
        $act.VerticalAlignment = "Center"; $act.TextAlignment = "Right"; $act.Width = 160
        [System.Windows.Controls.Grid]::SetColumn($act, 2)
        [void]$grid.Children.Add($act)
    }

    $border.Child = $grid
    [void]$Panel.Children.Add($border)
}

function Show-DiagnosticReport {
    param([hashtable]$Report)

    $diagXaml = [XamlLoader]::Load($script:XamlFolder, "DiagnosticWindow")
    $diagXaml = $ExecutionContext.InvokeCommand.ExpandString($diagXaml)

    $dReader  = [System.Xml.XmlNodeReader]::new([xml]$diagXaml)
    $dWindow  = [Windows.Markup.XamlReader]::Load($dReader)
    $dPanel   = $dWindow.FindName("DiagPanel")
    $dScore   = $dWindow.FindName("ScoreText")
    $dLabel   = $dWindow.FindName("ScoreLabel")
    $dSub     = $dWindow.FindName("DiagSubtitle")
    $btnExp   = $dWindow.FindName("btnExportDiag")
    $btnClose = $dWindow.FindName("btnCloseDiag")

    # ── Construir DiagInput desde hashtable ──────────────────────────────────
    $input = New-Object SysOpt.Diagnostics.DiagInput
    foreach ($key in $Report.Keys) {
        try {
            $prop = $input.GetType().GetProperty($key)
            if ($prop) { $prop.SetValue($input, [double]$Report[$key], $null) }
        } catch { }
    }

    # ── Ejecutar motor de diagnóstico vía DLL ────────────────────────────────
    $result = [SysOpt.Diagnostics.DiagnosticsEngine]::Analyze($input)

    # ── Renderizar items en el panel WPF ─────────────────────────────────────
    foreach ($item in $result.Items) {
        if ($item.IsSection) {
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.Style = $dWindow.Resources["SectionHeader"]
            $tb.Text  = "$($item.SectionIcon)  $($item.SectionTitle)"
            [void]$dPanel.Children.Add($tb)
        } else {
            Add-DiagRow -Window $dWindow -Panel $dPanel `
                -Status $item.Status -Label $item.Label `
                -Detail $item.Detail -Action $item.Action
        }
    }

    # ── Puntuación ───────────────────────────────────────────────────────────
    $dScore.Text  = "$($result.Score)"
    $dScore.Foreground = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString($result.ScoreColor))
    $dLabel.Text = $result.ScoreLabel
    $dSub.Text = "$(Get-Date -Format 'dd/MM/yyyy HH:mm')  ·  $($result.CritCount) crítico(s)  ·  $($result.WarnCount) aviso(s)"

    # ── Exportar informe ─────────────────────────────────────────────────────
    $exportLines = $result.ExportLines
    $btnExp.Add_Click({
        $sd = New-Object System.Windows.Forms.SaveFileDialog
        try {
            $sd.Title            = "Exportar Informe de Diagnóstico"
            $sd.Filter           = "Texto (*.txt)|*.txt|Todos (*.*)|*.*"
            $sd.DefaultExt       = "txt"
            $sd.FileName         = "DiagnosticoSistema_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
            $sd.InitialDirectory = [Environment]::GetFolderPath("Desktop")
            if ($sd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $exportLines | Out-File -FilePath $sd.FileName -Encoding UTF8
                Show-ThemedDialog -Title "Informe exportado" `
                    -Message "Informe guardado en:`n$($sd.FileName)" -Type "success"
            }
        } finally { $sd.Dispose() }
    })

    $btnClose.Add_Click({ $dWindow.Close() })
    $dWindow.Owner = $window
    $dWindow.ShowDialog() | Out-Null
}

# ═════════════════════════════════════════════════════════════════════════════
# SCRIPT DE OPTIMIZACIÓN — se ejecuta en runspace separado
# ═════════════════════════════════════════════════════════════════════════════
$OptimizationScript = {
    # param() DEBE ser la primera instrucción ejecutable del script block
    # $DiagReportRef se inyecta via SessionStateProxy.SetVariable (no como argumento posicional)
    param(
        $window, $ConsoleOutput, $ProgressBar, $StatusText,
        $ProgressText, $TaskText, $options, $CancelToken
    )

    # ── Cargar DLLs dentro del runspace ──────────────────────────────────
    # IMPORTANTE: Los runspace NO heredan los assemblies del hilo principal.
    # Cada DLL debe cargarse explícitamente aquí.
    $dllDir = $options['_DllDir']   # Inyectado desde Start-Optimization
    Add-Type -Path (Join-Path $dllDir "SysOpt.Core.dll")
    Add-Type -Path (Join-Path $dllDir "SysOpt.DiskEngine.dll")
    Add-Type -Path (Join-Path $dllDir "SysOpt.MemoryHelper.dll")
    Add-Type -Path (Join-Path $dllDir "SysOpt.Optimizer.dll")
    Add-Type -Path (Join-Path $dllDir "SysOpt.Diagnostics.dll")

    # ── Mapear hashtable $options → OptimizeOptions DTO ──────────────────
    $opts = New-Object SysOpt.Optimizer.OptimizeOptions
    foreach ($key in $options.Keys) {
        if ($key.StartsWith('_')) { continue }   # skip internal keys (_DllDir)
        try {
            $prop = $opts.GetType().GetProperty($key)
            if ($prop -and $prop.PropertyType -eq [bool]) {
                $prop.SetValue($opts, [bool]$options[$key], $null)
            }
        } catch { }
    }

    # ── Callback de progreso → Dispatcher.Invoke para actualizar UI ──────
    $progressCallback = [System.Action[SysOpt.Optimizer.OptimizeProgress]]{
        param($p)
        $window.Dispatcher.Invoke([action]{
            # Actualizar barra de progreso
            if ($p.Percent -ge 0) {
                $ProgressBar.Value = $p.Percent
                $ProgressText.Text = "{0}%" -f $p.Percent
            }
            # Actualizar nombre de tarea
            if ($p.TaskName) {
                $TaskText.Text = "Tarea actual: {0}" -f $p.TaskName
            }
            # Actualizar consola
            if ($p.Message) {
                $ConsoleOutput.AppendText("{0}`n" -f $p.Message)
                $ConsoleOutput.ScrollToEnd()
            }
            # Actualizar barra de estado
            if ($p.Status) {
                $StatusText.Text = $p.Status
            }
        }.GetNewClosure())
    }

    # ── Ejecutar orquestador ─────────────────────────────────────────────
    $result = [SysOpt.Optimizer.OptimizerEngine]::Run(
        $opts, $CancelToken, $progressCallback)

    # ── Publicar datos diagnósticos al hilo principal ────────────────────
    if ($null -ne $DiagReportRef) {
        try {
            $diagHash = @{}
            foreach ($p in $result.DiagData.GetType().GetProperties()) {
                $diagHash[$p.Name] = $p.GetValue($result.DiagData, $null)
            }
            $DiagReportRef.Value = $diagHash
        } catch { }
    }

    # ── Auto-reinicio ────────────────────────────────────────────────────
    if ($result.IsDryRun -eq $false -and $options['AutoRestart'] -and
        -not $result.Cancelled) {
        $window.Dispatcher.Invoke([action]{
            $ConsoleOutput.AppendText("Reiniciando el sistema en 10 segundos...`n")
        })
        for ($i = 10; $i -gt 0; $i--) {
            $window.Dispatcher.Invoke([action]{
                $StatusText.Text = "Reiniciando en {0} segundos..." -f $i
            }.GetNewClosure())
            Start-Sleep -Seconds 1
        }
        Restart-Computer -Force
    }
}


# ═════════════════════════════════════════════════════════════════════════════
# EVENTOS DE BOTONES
# ═════════════════════════════════════════════════════════════════════════════

# [N1] Botón de actualizar info del sistema
$btnRefreshInfo.Add_Click({ Update-SystemInfo })

$script:AllOptCheckboxes = @(
    $chkOptimizeDisks, $chkRecycleBin, $chkTempFiles, $chkUserTemp,
    $chkWUCache, $chkChkdsk, $chkClearMemory, $chkCloseProcesses,
    $chkDNSCache, $chkBrowserCache, $chkBackupRegistry, $chkCleanRegistry,
    $chkSFC, $chkDISM, $chkEventLogs, $chkShowStartup
    # chkAutoRestart y chkDryRun se excluyen intencionalmente (opciones de ejecución)
)

$script:AllCheckboxes = @(
    $chkOptimizeDisks, $chkRecycleBin, $chkTempFiles, $chkUserTemp,
    $chkWUCache, $chkChkdsk, $chkClearMemory, $chkCloseProcesses,
    $chkDNSCache, $chkBrowserCache, $chkBackupRegistry, $chkCleanRegistry,
    $chkSFC, $chkDISM, $chkEventLogs, $chkShowStartup, $chkAutoRestart, $chkDryRun
)

$btnSelectAll.Add_Click({
    $allChecked = $script:AllOptCheckboxes | ForEach-Object { $_.IsChecked } | Where-Object { -not $_ }
    $targetState = ($allChecked.Count -gt 0)   # hay alguno desmarcado → vamos a marcar todos

    foreach ($cb in $script:AllOptCheckboxes) { $cb.IsChecked = $targetState }

    $btnSelectAll.Content = if ($targetState) { "✗ Deseleccionar Todo" } else { "✓ Seleccionar Todo" }
})

# ── Función central de arranque (dry-run o real) ─────────────────────────────
function Start-Optimization {
    param([bool]$DryRunOverride = $false)

    if ($chkCleanRegistry.IsChecked -and -not $chkBackupRegistry.IsChecked -and -not $DryRunOverride) {
        $warn = Show-ThemedDialog -Title "Sin backup del registro" `
            -Message "Has activado 'Limpiar registro' sin 'Crear backup'.`n`nLimpiar el registro SIN backup puede ser peligroso.`n`n¿Deseas continuar igualmente SIN hacer backup?" `
            -Type "warning" -Buttons "YesNo"
        if (-not $warn) { return }
    }

    if (-not [string]::IsNullOrWhiteSpace($ConsoleOutput.Text)) {
        $clearWarn = Show-ThemedDialog -Title "Limpiar consola" `
            -Message "La consola tiene contenido de una ejecución anterior.`n`n¿Deseas limpiarla y comenzar una nueva sesión?`n(Si quieres conservar el log, pulsa No y guárdalo primero)" `
            -Type "question" -Buttons "YesNo"
        if (-not $clearWarn) { return }
    }

    # Contar tareas seleccionadas
    # Mapa checkbox → (Nombre tarea, Clave options)
    $taskMap = @(
        @($chkOptimizeDisks,  "Optimizar discos", "OptimizeDisks"),
        @($chkRecycleBin,     "Vaciar papelera",  "RecycleBin"),
        @($chkTempFiles,      "Temp Windows",     "TempFiles"),
        @($chkUserTemp,       "Temp Usuario",     "UserTemp"),
        @($chkWUCache,        "WU Cache",         "WUCache"),
        @($chkChkdsk,         "CHKDSK",           "Chkdsk"),
        @($chkClearMemory,    "Liberar RAM",      "ClearMemory"),
        @($chkCloseProcesses, "Cerrar procesos",  "CloseProcesses"),
        @($chkDNSCache,       "DNS",              "DNSCache"),
        @($chkBrowserCache,   "Navegadores",      "BrowserCache"),
        @($chkBackupRegistry, "Backup registro",  "BackupRegistry"),
        @($chkCleanRegistry,  "Limpiar registro", "CleanRegistry"),
        @($chkSFC,            "SFC",              "SFC"),
        @($chkDISM,           "DISM",             "DISM"),
        @($chkEventLogs,      "Event Logs",       "EventLogs")
    )
    $selectedTasks = @($taskMap | Where-Object { $_[0].IsChecked } | ForEach-Object { $_[1] })

    # [N8] ShowStartup se maneja en el hilo principal antes del runspace
    if ($chkShowStartup.IsChecked) {
        Show-StartupManager
    }

    if ($selectedTasks.Count -eq 0 -and -not $chkShowStartup.IsChecked) {
        Show-ThemedDialog -Title "Sin tareas seleccionadas" `
            -Message "Por favor, selecciona al menos una opción." -Type "warning"
        return
    }

    if ($selectedTasks.Count -eq 0) { return }   # Solo ShowStartup fue marcado, ya se procesó

    $isDryRun  = $DryRunOverride -or $chkDryRun.IsChecked
    $modeLabel = if ($isDryRun) { "🔍 MODO ANÁLISIS (sin cambios)" } else { "⚙ EJECUCIÓN REAL" }

    $confirm = Show-ThemedDialog -Title "Confirmar optimización" `
        -Message "Modo: $modeLabel`n`n¿Iniciar con $($selectedTasks.Count) tareas?`n• $($selectedTasks -join "`n• ")" `
        -Type "question" -Buttons "YesNo"
    if (-not $confirm) {
        Write-Log "[OPT] Optimización cancelada por el usuario antes de iniciar." -Level "INFO" -NoUI
        return
    }
    Write-Log ("── Inicio de optimización ────────────────────────────────") -Level "INFO" -NoUI
    Write-Log ("[OPT] Modo          : {0}" -f $(if ($isDryRun) {"ANÁLISIS (dry-run)"} else {"REAL"})) -Level "INFO" -NoUI
    Write-Log ("[OPT] Tareas ({0,2})  : {1}" -f $selectedTasks.Count, ($selectedTasks -join " | ")) -Level "INFO" -NoUI
    Write-Log ("[OPT] Tema activo   : {0}  |  Idioma: {1}" -f $script:CurrentTheme, $script:CurrentLang) -Level "INFO" -NoUI

    # Preparar UI
    $btnStart.IsEnabled      = $false
    $btnDryRun.IsEnabled     = $false
    $btnSelectAll.IsEnabled  = $false
    $btnCancel.IsEnabled     = $true
    foreach ($cb in $script:AllCheckboxes) { $cb.IsEnabled = $false }

    $ConsoleOutput.Clear()
    $ProgressBar.Value  = 0
    $ProgressText.Text  = "0%"
    $TaskText.Text      = "Iniciando..."

    $script:CancelSource  = New-Object System.Threading.CancellationTokenSource
    $script:WasCancelled  = $false

    $options = @{ 'DryRun' = $isDryRun; 'AutoRestart' = $chkAutoRestart.IsChecked; '_DllDir' = "$PSScriptRoot\libs" }
    foreach ($t in $taskMap) { $options[$t[2]] = $t[0].IsChecked }


    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()

    # Variable compartida para recibir el informe de diagnóstico del runspace
    # FIX: inyectar via SessionStateProxy en lugar de pasar como [ref] en AddArgument.
    # Pasar [ref] como argumento posicional rompe el binding de TODOS los params del script.
    $script:DiagReportData   = $null
    $script:LastRunWasDryRun = $isDryRun
    $diagReportRef = [ref]$script:DiagReportData
    $script:DiagReportRef    = $diagReportRef
    $runspace.SessionStateProxy.SetVariable('DiagReportRef', $diagReportRef)

    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace
    $powershell.AddScript($OptimizationScript)
    $powershell.AddArgument($window)
    $powershell.AddArgument($ConsoleOutput)
    $powershell.AddArgument($ProgressBar)
    $powershell.AddArgument($StatusText)
    $powershell.AddArgument($ProgressText)
    $powershell.AddArgument($TaskText)
    $powershell.AddArgument($options)
    $powershell.AddArgument($script:CancelSource.Token) | Out-Null

    $handle = $powershell.BeginInvoke()

    $script:ActivePowershell = $powershell
    $script:ActiveRunspace   = $runspace
    $script:ActiveHandle     = $handle
    $script:UI_BtnStart      = $btnStart
    $script:UI_BtnDryRun     = $btnDryRun
    $script:UI_BtnSelectAll  = $btnSelectAll
    $script:UI_BtnCancel     = $btnCancel
    $script:UI_Checkboxes    = $script:AllCheckboxes
    $script:UI_ProgressBar   = $ProgressBar
    $script:UI_ProgressText  = $ProgressText
    $script:UI_TaskText      = $TaskText
    $script:UI_StatusText    = $StatusText
    $script:UI_ConsoleOutput = $ConsoleOutput

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:ActiveTimer = $timer

    $timer.Add_Tick({
        $completed = $false
        try {
            if ($script:ActiveHandle -and $script:ActiveHandle.IsCompleted) {
                $completed = $true
            }
        } catch {
            $completed = $true   # error al comprobar → asumir terminado
        }

        if ($completed) {
            $script:ActiveTimer.Stop()

            try {
                $script:ActivePowershell.EndInvoke($script:ActiveHandle)
            } catch {
                $errMsg = $_.Exception.Message
                $inner  = if ($_.Exception.InnerException) { " | Inner: $($_.Exception.InnerException.Message)" } else { "" }
                Write-Log "[RUNSPACE] Error: $errMsg$inner" -Level "ERR" -NoUI
                $window.Dispatcher.Invoke([action]{
                    $script:UI_ConsoleOutput.AppendText("[ERROR RUNSPACE] $errMsg$inner`n")
                    $script:UI_ConsoleOutput.ScrollToEnd()
                })
            }
            # Capturar errores del stream (errores no-terminantes del runspace)
            if ($script:ActivePowershell.Streams.Error.Count -gt 0) {
                foreach ($streamErr in $script:ActivePowershell.Streams.Error) {
                    $se = "[RUNSPACE] Stream error: $($streamErr.ToString()) | Script: $($streamErr.InvocationInfo.ScriptName) línea $($streamErr.InvocationInfo.ScriptLineNumber)"
                    Write-Log $se -Level "ERR" -NoUI
                }
            }
            try { $script:ActivePowershell.Dispose()  } catch { }
            try { $script:ActiveRunspace.Close()      } catch { }
            try { $script:ActiveRunspace.Dispose()    } catch { }

            $cs = $script:CancelSource
            $script:CancelSource = $null
            if ($null -ne $cs) { try { $cs.Dispose() } catch { } }

            # Reset UI
            $script:UI_ProgressBar.Value  = 0
            $script:UI_ProgressText.Text  = "0%"
            $script:UI_TaskText.Text      = ""
            $script:UI_StatusText.Text    = "Listo para optimizar"

            $script:UI_BtnStart.IsEnabled     = $true
            $script:UI_BtnDryRun.IsEnabled    = $true
            $script:UI_BtnSelectAll.IsEnabled = $true
            $script:UI_BtnCancel.IsEnabled    = $false
            $script:UI_BtnCancel.Content      = "⏹ Cancelar"
            foreach ($cb in $script:UI_Checkboxes) { $cb.IsEnabled = $true }

            # Actualizar info del sistema al finalizar
            Update-SystemInfo

            # FIX: leer datos del análisis desde PSReference (el runspace actualiza .Value,
            # no $script:DiagReportData directamente — bug de [ref] cross-runspace)
            if ($null -ne $script:DiagReportRef -and $null -ne $script:DiagReportRef.Value) {
                $script:DiagReportData = $script:DiagReportRef.Value
            }

            if ($script:WasCancelled) {
                Write-Log "[OPT] Proceso cancelado por el usuario." -Level "WARN" -NoUI
                Show-ThemedDialog -Title "Proceso cancelado" `
                    -Message "La optimizacion fue cancelada por el usuario." -Type "warning"
            } elseif ($script:LastRunWasDryRun -and $null -ne $script:DiagReportData) {
                # Modo análisis completado → mostrar informe de diagnóstico
                Write-Log "[OPT] Análisis (dry-run) completado con informe de diagnóstico." -Level "INFO" -NoUI
                Show-DiagnosticReport -Report $script:DiagReportData
            } elseif ($script:LastRunWasDryRun) {
                # Dry run sin datos (tareas no recogen diagData) → mensaje simple
                Write-Log "[OPT] Análisis (dry-run) completado." -Level "INFO" -NoUI
                Show-ThemedDialog -Title "Análisis completado" `
                    -Message "Análisis completado.`n`nRevisa la consola para ver los detalles." -Type "info"
            } else {
                Write-Log "── Fin de optimización ───────────────────────────────────" -Level "INFO" -NoUI
                Write-Log "[OPT] Optimización real completada correctamente." -Level "INFO" -NoUI
                Show-ThemedDialog -Title "Optimización completada" `
                    -Message "¡Proceso completado correctamente!`n`nTodas las tareas seleccionadas han finalizado." -Type "success"
            }
            $script:WasCancelled = $false
        }
    })
    $timer.Start()
}

# Botón Iniciar
$btnStart.Add_Click({ Start-Optimization -DryRunOverride $false })

# [N2] Botón Analizar (Dry Run directo)
$btnDryRun.Add_Click({ Start-Optimization -DryRunOverride $true })

# Botón Cancelar
$btnCancel.Add_Click({
    if ($null -ne $script:CancelSource -and -not $script:CancelSource.IsCancellationRequested) {
        $res = Show-ThemedDialog -Title "Confirmar cancelación" `
            -Message "¿Cancelar la optimización en curso?`n`nLa tarea actual terminará antes de detenerse." `
            -Type "question" -Buttons "YesNo"
        if ($res) {
            $script:WasCancelled = $true
            $script:CancelSource.Cancel()
            $btnCancel.IsEnabled = $false
            $btnCancel.Content   = "⏹ Cancelando..."
            Write-Log "⚠ Cancelación solicitada — esperando fin de tarea actual..." -Level "UI"
            Write-Log "[OPT] Usuario solicitó cancelación de la optimización en curso." -Level "WARN" -NoUI
        }
    }
})

# Botón Guardar Log
$btnSaveLog.Add_Click({
    $logContent = $ConsoleOutput.Text
    if ([string]::IsNullOrWhiteSpace($logContent)) {
        Show-ThemedDialog -Title "Log vacío" `
            -Message "La consola está vacía. No hay nada que guardar." -Type "info"
        return
    }

    $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
    try {
        $saveDialog.Title            = "Guardar Log de Optimización"
        $saveDialog.Filter           = "Archivo de texto (*.txt)|*.txt|Todos los archivos (*.*)|*.*"
        $saveDialog.DefaultExt       = "txt"
        $saveDialog.FileName         = "OptimizadorLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        if (-not (Test-Path $script:LogsDir)) {
            [System.IO.Directory]::CreateDirectory($script:LogsDir) | Out-Null
        }
        $saveDialog.InitialDirectory = $script:LogsDir

        if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            try {
                $logContent | Out-File -FilePath $saveDialog.FileName -Encoding UTF8
                Show-ThemedDialog -Title "Log guardado" `
                    -Message "Log guardado en:`n`n$($saveDialog.FileName)" -Type "success"
            } catch {
                Show-ThemedDialog -Title "Error al guardar" `
                    -Message "Error al guardar:`n$($_.Exception.Message)" -Type "error"
            }
        }
    } finally { $saveDialog.Dispose() }
})

# Botón Salir
$btnExit.Add_Click({
    try { [SysOptFallbacks]::DisposeMutex() } catch { }
    $window.Close()
})

# Liberar mutex al cerrar por la X
$window.Add_Closed({
    $script:AppClosing = $true
    # [BF3] Limpiar estado cacheado para evitar errores al reiniciar
    try { [SysOptFallbacks]::DisposeMutex() } catch { }
    try { $chartTimer.Stop() } catch { }
    try { if ($null -ne $script:DiskUiTimer) { $script:DiskUiTimer.Stop() } } catch { }
    if ($null -ne $script:DiskCounter) { try { $script:DiskCounter.Dispose() } catch { } }
    # [A3] Parar auto-refresco si activo
    try { if ($null -ne $script:AutoRefreshTimer) { $script:AutoRefreshTimer.Stop(); $script:AutoRefreshTimer = $null } } catch {}
    # [TASKPOOL] Parar timer de tareas
    try { if ($null -ne $script:TaskTimer)     { $script:TaskTimer.Stop();     $script:TaskTimer     = $null } } catch {}
    # Parar timers de operaciones async que puedan estar corriendo
    try { if ($null -ne $script:_csvTimer)     { $script:_csvTimer.Stop();     $script:_csvTimer     = $null } } catch {}
    try { if ($null -ne $script:_htmlTimer)    { $script:_htmlTimer.Stop();    $script:_htmlTimer    = $null } } catch {}
    try { if ($null -ne $script:_dedupTimer)   { $script:_dedupTimer.Stop();   $script:_dedupTimer   = $null } } catch {}
    try { if ($null -ne $script:_loadTimer)    { $script:_loadTimer.Stop();    $script:_loadTimer    = $null } } catch {}
    try { if ($null -ne $script:_entTimer)     { $script:_entTimer.Stop();     $script:_entTimer     = $null } } catch {}
    try { if ($null -ne $script:_saveTimer)    { $script:_saveTimer.Stop();    $script:_saveTimer    = $null } } catch {}
    try { if ($null -ne $script:_topTimer)     { $script:_topTimer.Stop();     $script:_topTimer     = $null } } catch {}
    try { if ($null -ne $script:_scanTimer)    { $script:_scanTimer.Stop();    $script:_scanTimer    = $null } } catch {}
    try { if ($null -ne $script:ActiveTimer)   { $script:ActiveTimer.Stop();   $script:ActiveTimer   = $null } } catch {}
    # [C3] Guardar configuración al cerrar
    try { Save-Settings } catch {}
    # [LOG] Cerrar logger (delegado a LogEngine en SysOpt.Core.dll)
    try {
        Write-Log "Sesión cerrada por el usuario." -Level "INFO" -NoUI
        [LogEngine]::Close()
    } catch {}
    # [ERR] Desregistrar handlers de error boundary
    try {
        if ($null -ne $script:UnhandledExHandler)  { [System.AppDomain]::CurrentDomain.remove_UnhandledException($script:UnhandledExHandler) }
        if ($null -ne $script:DispatcherExHandler) { $window.Dispatcher.remove_UnhandledException($script:DispatcherExHandler) }
    } catch {}
    # [WMI] Cerrar CimSession compartida
    try {
        if ($null -ne $script:CimSession) { $script:CimSession | Remove-CimSession -ErrorAction SilentlyContinue; $script:CimSession = $null }
    } catch {}

    # Señalizar parada del runspace de escaneo y esperar brevemente
    [ScanCtl211]::Stop = $true
    # [CTK] Cancelar y liberar el token global
    try {
        if (([System.Management.Automation.PSTypeName]'ScanTokenManager').Type) {
            [ScanTokenManager]::Dispose()
        }
    } catch {}
    if ($null -ne $script:DiskScanRunspace) {
        try { $script:DiskScanRunspace.Close()   } catch {}
        try { $script:DiskScanRunspace.Dispose() } catch {}
        $script:DiskScanRunspace = $null
    }
    if ($null -ne $script:DiskScanPS) {
        try { $script:DiskScanPS.Dispose() } catch {}
        $script:DiskScanPS = $null
    }
    $script:DiskScanAsync = $null

    # Vaciar cola y colecciones vivas para liberar referencias y evitar errores al relanzar
    if ($null -ne $script:ScanQueue) {
        $tmp = $null
        while ($script:ScanQueue.TryDequeue([ref]$tmp)) {}
        $script:ScanQueue = $null
    }
    if ($null -ne $script:LiveList)       { try { $script:LiveList.Clear()       } catch {}; $script:LiveList       = $null }
    if ($null -ne $script:LiveItems)      { try { $script:LiveItems.Clear()      } catch {}; $script:LiveItems      = $null }
    if ($null -ne $script:AllScannedItems){ try { $script:AllScannedItems.Clear() } catch {}; $script:AllScannedItems = $null }
    if ($null -ne $script:LiveIndexMap)   { try { $script:LiveIndexMap.Clear()   } catch {}; $script:LiveIndexMap   = $null }

    if ($null -ne $script:RunspacePool) {
        try { $script:RunspacePool.Close()   } catch {}
        try { $script:RunspacePool.Dispose() } catch {}
        $script:RunspacePool = $null
    }

    # Liberar CancellationTokenSource de optimización si estaba activo
    if ($null -ne $script:CancelSource) {
        try { $script:CancelSource.Cancel()  } catch {}
        try { $script:CancelSource.Dispose() } catch {}
        $script:CancelSource = $null
    }

    # Nota: el runspace de optimización se limpia vía $script:ActiveRunspace (arriba)
    # $script:OptRunspace no se usa — eliminado para evitar confusión
})

# ─────────────────────────────────────────────────────────────────────────────
# ARRANQUE
# ─────────────────────────────────────────────────────────────────────────────
# Update-SystemInfo se llama ahora desde el evento Loaded de la ventana
# ─────────────────────────────────────────────────────────────────────────────
# Función: Ventana emergente "Acerca de la versión"
# ─────────────────────────────────────────────────────────────────────────────
function Show-AboutWindow {
    $aboutXaml = [XamlLoader]::Load($script:XamlFolder, "AboutWindow")
    $aboutXaml = $ExecutionContext.InvokeCommand.ExpandString($aboutXaml)
    try {
        $aboutReader = [System.Xml.XmlNodeReader]::new([xml]$aboutXaml)
        $aboutWin    = [Windows.Markup.XamlReader]::Load($aboutReader)
        $aboutWin.Owner = $window

        # Cargar logo en la ventana about también
        $aboutLogoCtrl = $aboutWin.FindName("aboutLogo")
        if ($null -ne $imgLogo -and $null -ne $imgLogo.Source -and $null -ne $aboutLogoCtrl) {
            $aboutLogoCtrl.Source = $imgLogo.Source
        }

        $btnAboutClose = $aboutWin.FindName("btnAboutClose")
        $btnAboutClose.Add_Click({ $aboutWin.Close() })

        # Enlace GitHub funcional
        $lnkGh = $aboutWin.FindName("lnkGithub")
        if ($null -ne $lnkGh) {
            $lnkGh.Add_RequestNavigate({
                param($s, $e)
                Start-Process $e.Uri.AbsoluteUri
                $e.Handled = $true
            })
        }

        $aboutWin.ShowDialog() | Out-Null
    } catch {
        Show-ThemedDialog -Title "Error" `
            -Message "Error al abrir la ventana de novedades:`n$($_.Exception.Message)" -Type "error"
    }
}

# Conectar botón ℹ
if ($null -ne $btnAbout) {
    $btnAbout.Add_Click({ Show-AboutWindow })
}

# Conectar botón ⚡ Tareas
$btnShowTasks = $window.FindName("btnShowTasks")
if ($null -ne $btnShowTasks) {
    $btnShowTasks.Add_Click({ Show-TasksWindow })
}
# Conectar botón ⚙ Opciones
$btnOptions = $window.FindName("btnOptions")
if ($null -ne $btnOptions) {
    $btnOptions.Add_Click({ Show-OptionsWindow })
}

# ─────────────────────────────────────────────────────────────────────────────
# Mensaje de bienvenida simplificado en consola (novedades → botón ℹ)
# ─────────────────────────────────────────────────────────────────────────────
Write-ConsoleMain "═══════════════════════════════════════════════════════════"
Write-ConsoleMain "SysOpt - Windows Optimizer GUI  v$($script:AppVersion)"
Write-ConsoleMain "═══════════════════════════════════════════════════════════"
Write-ConsoleMain "Sistema iniciado correctamente"
Write-ConsoleMain ""
Write-ConsoleMain "Selecciona las opciones y presiona '▶ Iniciar Optimización'"
Write-ConsoleMain "  o '🔍 Analizar' para ver qué se liberaría sin cambios."
Write-ConsoleMain ""
Write-ConsoleMain "💡 Ver novedades de la versión: botón  ℹ  en la barra superior."
Write-ConsoleMain ""

$window.ShowDialog() | Out-Null