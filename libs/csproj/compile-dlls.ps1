# =============================================================================
# compile-dlls.ps1  —  Compila TODAS las DLL de SysOpt desde codigo fuente C#
# Ejecutar desde la carpeta .\libs\ :
#   powershell -ExecutionPolicy Bypass -File compile-dlls.ps1
#
# Auto-descubre todos los .cs de la carpeta y determina referencias adicionales
# segun el contenido del archivo (System.Management, System.Net, etc.)
# =============================================================================

#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path   # .\libs\csproj\
$outDir = Split-Path $here -Parent                            # .\libs\  (destino de los .dll)
if (-not (Test-Path $outDir)) { $outDir = $here }             # fallback: si no hay padre, mismo dir

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "    SysOpt — Compilacion automatica de DLL externos           " -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Leer version desde SysOpt.ps1 ────────────────────────────────────────────
# Busca $script:AppVersion = "X.Y.Z" en el .ps1 que está un nivel arriba
$appVersion  = "0.0.0"
$buildDate   = Get-Date -Format "yyyy-MM-dd"
# SysOpt.ps1 esta en la raiz del proyecto (padre de .\libs\)
$ps1Path = Join-Path $outDir "SysOpt.ps1"
if (-not (Test-Path $ps1Path)) {
    $ps1Path = Join-Path (Split-Path $outDir -Parent) "SysOpt.ps1"
}
if (Test-Path $ps1Path) {
    $versionLine = Select-String -Path $ps1Path -Pattern '\$script:AppVersion\s*=\s*"([\d\.]+)"' |
                   Select-Object -First 1
    if ($versionLine -and $versionLine.Matches.Count -gt 0) {
        $appVersion = $versionLine.Matches[0].Groups[1].Value
    }
}
# Convertir "3.2.0" → "3.2.0.0" (AssemblyVersion requiere 4 componentes)
$asmVersion = ($appVersion -split "\.")
while ($asmVersion.Count -lt 4) { $asmVersion += "0" }
$asmVersionStr = $asmVersion[0..3] -join "."

Write-Host "  Version detectada : $appVersion  →  AssemblyVersion $asmVersionStr" -ForegroundColor White
Write-Host ""

# ── Generar AssemblyInfo.cs temporal con la version leida ────────────────────
# Se compila junto con cada .cs y se elimina al finalizar.
# Los .cs fuente NO se modifican nunca.
$asmInfoPath = Join-Path $here "_AssemblyInfo_tmp.cs"
$asmInfoContent = @"
// AUTO-GENERADO por compile-dlls.ps1 — NO editar manualmente
// Generado: $buildDate
using System.Reflection;
[assembly: AssemblyVersion("$asmVersionStr")]
[assembly: AssemblyFileVersion("$asmVersionStr")]
[assembly: AssemblyInformationalVersion("$appVersion")]
[assembly: AssemblyProduct("SysOpt Windows Optimizer GUI")]
[assembly: AssemblyCopyright("SysOpt $((Get-Date).Year)")]
"@
[System.IO.File]::WriteAllText($asmInfoPath, $asmInfoContent, [System.Text.Encoding]::UTF8)
Write-Host "[OK] AssemblyInfo temporal generado: $asmVersionStr" -ForegroundColor Green
Write-Host ""

# ── Localizar csc.exe (NET Framework, compatible PS 5.1) ─────────────────────
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
if (-not (Test-Path $csc)) {
    # Fallback: buscar en rutas habituales de .NET Framework
    $candidates = @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $csc = $c; break }
    }
}

if (-not (Test-Path $csc)) {
    Write-Host "[ERROR] No se encontro csc.exe." -ForegroundColor Red
    Write-Host "        Instala .NET Framework 4.x o ejecuta desde Developer Command Prompt." -ForegroundColor Yellow
    exit 1
}
Write-Host "[OK] csc.exe : $csc" -ForegroundColor Green

# ── Referencias adicionales por DLL ──────────────────────────────────────────
# Mapa: nombre del .cs -> /r: extra que necesita ese archivo
# (las referencias basicas System.dll y System.Core.dll van siempre)
$extraRefs = @{
    "SysOpt.Core.cs"        = @(
        "System.Management.dll",          # WMI: ManagementObjectSearcher
        "System.dll",
        "System.Core.dll",
        "System.Net.dll",                 # NetworkInterface base
        "System.Net.NetworkInformation.dll"
        # System.IO y System.Threading son parte de mscorlib — no necesitan /r: explícito
    )
    "SysOpt.ThemeEngine.cs" = @(
        "PresentationFramework.dll",
        "PresentationCore.dll",
        "WindowsBase.dll",
        "System.Xaml.dll"
    )
    "DiskEngine.cs"         = @(
        "System.dll",
        "System.Core.dll"
    )
    "MemoryHelper.cs"       = @()
    "WseTrim.cs"            = @()
    "SysOpt.Optimizer.cs"   = @(
        "System.dll",
        "System.Core.dll",
        "System.Management.dll",          # WMI: ManagementObjectSearcher (parent PID, disk C:)
        "System.ServiceProcess.dll"       # ServiceController (wuauserv start/stop)
    )
    "SysOpt.StartupManager.cs" = @(
        "System.dll",
        "System.Core.dll"
    )
    "SysOpt.Diagnostics.cs" = @(
        "System.dll",
        "System.Core.dll"
    )
}

# Mapa: nombre del .cs -> DLLs locales del proyecto que necesita como /r:
# Estas DLLs DEBEN compilarse antes que la que las referencia.
# El orden alfabetico de los .cs lo garantiza actualmente:
#   DiskEngine -> MemoryHelper -> SysOpt.Core -> SysOpt.Diagnostics -> SysOpt.Optimizer -> SysOpt.StartupManager -> SysOpt.ThemeEngine -> WseTrim
$localRefs = @{
    "SysOpt.Optimizer.cs" = @(
        "SysOpt.Core.dll",                # CleanupEngine, CleanupResult, SystemDataCollector, RamSnapshot
        "SysOpt.DiskEngine.dll",          # DiskOptimizer, VolumeInfo, DiskResult
        "SysOpt.MemoryHelper.dll"         # MemoryHelper (P/Invoke: OpenProcess, EmptyWorkingSet)
    )
}

# Mapa: nombre del .cs -> nombre del .dll de salida
# Si el .cs no esta en este mapa se usa el mismo nombre con extension .dll
$outputNames = @{
    "DiskEngine.cs"         = "SysOpt.DiskEngine.dll"
    "MemoryHelper.cs"       = "SysOpt.MemoryHelper.dll"
    "WseTrim.cs"            = "SysOpt.WseTrim.dll"
    "SysOpt.Core.cs"        = "SysOpt.Core.dll"
    "SysOpt.ThemeEngine.cs" = "SysOpt.ThemeEngine.dll"
    "SysOpt.Optimizer.cs"   = "SysOpt.Optimizer.dll"
    "SysOpt.StartupManager.cs" = "SysOpt.StartupManager.dll"
    "SysOpt.Diagnostics.cs"    = "SysOpt.Diagnostics.dll"
}

# ── Auto-descubrir todos los .cs (excluir archivos _old / _bak / Copy) ────────
$sources = Get-ChildItem -Path $here -Filter "*.cs" |
    Where-Object { $_.Name -notmatch "_old|_bak|_copy|-Copy|\.Test\." } |
    Sort-Object Name

if ($sources.Count -eq 0) {
    Write-Host "[WARN] No se encontraron archivos .cs en $here" -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "  Archivos .cs encontrados: $($sources.Count)" -ForegroundColor White
foreach ($s in $sources) {
    Write-Host "    · $($s.Name)" -ForegroundColor Gray
}
Write-Host ""

# ── Compilar ──────────────────────────────────────────────────────────────────
$ok   = 0
$fail = 0
$skip = 0

foreach ($src in $sources) {

    # Nombre de salida
    $outName = if ($outputNames.ContainsKey($src.Name)) {
        $outputNames[$src.Name]
    } else {
        [System.IO.Path]::GetFileNameWithoutExtension($src.Name) + ".dll"
    }
    $outPath = Join-Path $outDir $outName   # DLL va a .\libs\, no a .\libs\csproj\

    Write-Host "──────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "[BUILD] $($src.Name)  →  $outName" -ForegroundColor Cyan

    # Construir lista de /r: adicionales
    $refs = @()
    if ($extraRefs.ContainsKey($src.Name)) {
        foreach ($ref in $extraRefs[$src.Name]) {
            # Primero buscar en el runtime dir, luego en GAC
            $refFull = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) $ref
            if (Test-Path $refFull) {
                $refs += "/r:$refFull"
            } else {
                # Intentar resolver desde GAC via [System.Reflection.Assembly]
                try {
                    $asmName = [System.IO.Path]::GetFileNameWithoutExtension($ref)
                    $asm = [System.Reflection.Assembly]::LoadWithPartialName($asmName)
                    if ($asm) { $refs += "/r:$($asm.Location)" }
                } catch {}
            }
        }
    }

    # Resolver referencias LOCALES (DLLs del propio proyecto)
    if ($localRefs.ContainsKey($src.Name)) {
        foreach ($localRef in $localRefs[$src.Name]) {
            $localPath = Join-Path $outDir $localRef
            if (Test-Path $localPath) {
                $refs += "/r:$localPath"
                Write-Host "    [REF] $localRef" -ForegroundColor DarkCyan
            } else {
                Write-Host "    [WARN] Referencia local no encontrada: $localRef" -ForegroundColor Yellow
                Write-Host "           Asegurar que se compila antes que $($src.Name)" -ForegroundColor Yellow
            }
        }
    }

    # Argumentos del compilador — incluye AssemblyInfo temporal para versionar el DLL
    $cscArgs = @(
        "/target:library",
        "/optimize+",
        "/nologo",
        "/nowarn:1701,1702",          # suprimir warnings de versión de assembly
        "/out:$outPath"
    ) + $refs + @($src.FullName, $asmInfoPath)

    # Ejecutar compilador
    $output = & $csc @cscArgs 2>&1

    # Mostrar output del compilador
    $hasError = $false
    foreach ($line in $output) {
        $lineStr = "$line"
        if ($lineStr -match ": error ") {
            Write-Host "  $lineStr" -ForegroundColor Red
            $hasError = $true
        } elseif ($lineStr -match ": warning ") {
            Write-Host "  $lineStr" -ForegroundColor Yellow
        } elseif ($lineStr.Trim() -ne "") {
            Write-Host "  $lineStr" -ForegroundColor DarkGray
        }
    }

    # Resultado
    if ((Test-Path $outPath) -and -not $hasError) {
        $sz      = (Get-Item $outPath).Length
        $szKb    = [math]::Round($sz / 1KB, 1)
        $ts      = (Get-Item $outPath).LastWriteTime.ToString("HH:mm:ss")
        Write-Host "[OK] $outName — ${szKb} KB  ($ts)" -ForegroundColor Green
        $ok++
    } else {
        Write-Host "[FAIL] $outName — revisa los errores anteriores" -ForegroundColor Red
        $fail++
    }
}

# ── Limpiar AssemblyInfo temporal ─────────────────────────────────────────────
try {
    if (Test-Path $asmInfoPath) {
        Remove-Item $asmInfoPath -Force
        Write-Host ""
        Write-Host "[OK] AssemblyInfo temporal eliminado." -ForegroundColor DarkGray
    }
} catch {}

# ── Resumen final ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "    Resultado:  v$appVersion  —  " -ForegroundColor Cyan -NoNewline
Write-Host "$ok OK  " -ForegroundColor Green -NoNewline
if ($fail -gt 0) {
    Write-Host "$fail ERRORES  " -ForegroundColor Red -NoNewline
}
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""

if ($fail -gt 0) { exit 1 } else { exit 0 }