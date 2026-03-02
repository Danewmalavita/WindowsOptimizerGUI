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
# Buscar SysOpt.ps1 subiendo hasta 4 niveles desde el script
$ps1Path = $null
$searchDir = $here
for ($i = 0; $i -lt 4; $i++) {
    $candidate = Join-Path $searchDir "SysOpt.ps1"
    if (Test-Path $candidate) { $ps1Path = $candidate; break }
    $parent = Split-Path $searchDir -Parent
    if (-not $parent -or $parent -eq $searchDir) { break }
    $searchDir = $parent
}
if ($ps1Path -and (Test-Path $ps1Path)) {
    $versionLine = Select-String -Path $ps1Path -Pattern '\$script:AppVersion\s*=\s*"([\d\.]+)"' |
                   Select-Object -First 1
    if ($versionLine) {
        $m = [regex]::Match($versionLine.Line, '\$script:AppVersion\s*=\s*"([\d\.]+)"')
        if ($m.Success) { $appVersion = $m.Groups[1].Value }
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
    "SysOpt.ThemeEngine.cs" = @()
    "DiskEngine.cs"         = @(
        "System.dll",
        "System.Core.dll"
    )
    "MemoryHelper.cs"       = @()
    "WseTrim.cs"            = @()
    "SysOpt.UIEngine.cs"    = @(
        "System.dll",
        "System.Core.dll",
        "PresentationCore.dll",
        "PresentationFramework.dll",
        "WindowsBase.dll",
        "System.Xaml.dll",
        "System.Windows.Forms.dll"
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
    "SysOpt.UIEngine.cs"    = "SysOpt.UIEngine.dll"
}

# ── Auto-descubrir todos los .cs (excluir archivos _old / _bak / Copy) ────────
$sources = Get-ChildItem -Path $here -Filter "*.cs" |
    Where-Object { $_.Name -notmatch "_old|_bak|_copy|-Copy|\.Test\.|_AssemblyInfo_tmp" } |
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
            $resolved = $null

            # 1) Runtime dir (.NET Framework: mscorlib, System, etc.)
            $runtimePath = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) $ref
            if (Test-Path $runtimePath) { $resolved = $runtimePath }

            # 2) WPF assemblies — viven en el GAC WPF, no en el runtime dir
            if (-not $resolved) {
                $wpfCandidates = @(
                    "C:\Program Files (x86)\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8\$ref",
                    "C:\Program Files (x86)\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.7.2\$ref",
                    "C:\Program Files (x86)\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.6.1\$ref",
                    "C:\Program Files\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8\$ref",
                    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\WPF\$ref"
                )
                foreach ($c in $wpfCandidates) {
                    if (Test-Path $c) { $resolved = $c; break }
                }
            }

            # 3) Cargar via GAC y usar la ubicacion del ensamblado en memoria
            if (-not $resolved) {
                try {
                    $asmName = [System.IO.Path]::GetFileNameWithoutExtension($ref)
                    $asm = [System.Reflection.Assembly]::LoadWithPartialName($asmName)
                    if ($asm -and (Test-Path $asm.Location)) { $resolved = $asm.Location }
                } catch {}
            }

            if ($resolved) {
                $refs += "/r:$resolved"
            } else {
                Write-Host "  [WARN] No se resolvio la referencia: $ref" -ForegroundColor Yellow
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