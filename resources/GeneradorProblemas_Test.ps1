#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Script de Prueba para el Optimizador de Sistema
.DESCRIPTION
    Crea problemas simulados para probar todas las funcionalidades del optimizador.
    ⚠️ SOLO PARA ENTORNOS DE PRUEBA ⚠️
.NOTES
    Versión: 1.0
    ADVERTENCIA: Este script modificará el sistema intencionalmente
#>

Add-Type -AssemblyName PresentationFramework

# Verificar permisos de administrador
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    [System.Windows.MessageBox]::Show(
        "Este script requiere permisos de administrador.",
        "Permisos Insuficientes",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    )
    exit 1
}

# ADVERTENCIA INICIAL
$warning = [System.Windows.MessageBox]::Show(
    "⚠️ ADVERTENCIA ⚠️`n`n" +
    "Este script creará INTENCIONALMENTE problemas en tu sistema para probar el optimizador:`n`n" +
    "• Llenará la RAM con procesos de prueba`n" +
    "• Creará archivos temporales (varios GB)`n" +
    "• Agregará entradas huérfanas al registro`n" +
    "• Creará archivos de fragmentación en disco`n" +
    "• Llenará la papelera de reciclaje`n" +
    "• Agregará caché a navegadores simulados`n`n" +
    "¿Estás seguro de continuar?",
    "⚠️ Script de Prueba - ADVERTENCIA",
    [System.Windows.MessageBoxButton]::YesNo,
    [System.Windows.MessageBoxImage]::Warning
)

if ($warning -ne [System.Windows.MessageBoxResult]::Yes) {
    Write-Host "Script cancelado por el usuario." -ForegroundColor Yellow
    exit 0
}

Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║         SCRIPT DE PRUEBA - GENERADOR DE PROBLEMAS         ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$startTime = Get-Date

# ============================================================================
# 1. CREAR ARCHIVOS TEMPORALES
# ============================================================================
function Create-TempFiles {
    Write-Host "`n[1/7] Creando archivos temporales..." -ForegroundColor Yellow
    
    $tempPaths = @(
        $env:TEMP,
        "$env:SystemRoot\Temp",
        "$env:LOCALAPPDATA\Temp"
    )
    
    $totalSize = 0
    $fileCount = 0
    
    foreach ($tempPath in $tempPaths) {
        if (Test-Path $tempPath) {
            Write-Host "  → Creando archivos en: $tempPath" -ForegroundColor Cyan
            
            # Crear 100 archivos de 10MB cada uno = 1GB por carpeta
            for ($i = 1; $i -le 100; $i++) {
                try {
                    $fileName = "temp_test_file_$i`_$(Get-Random).tmp"
                    $filePath = Join-Path $tempPath $fileName
                    
                    # Crear archivo de ~10MB con datos aleatorios
                    $randomData = New-Object byte[] (10 * 1024 * 1024)
                    (New-Object Random).NextBytes($randomData)
                    [System.IO.File]::WriteAllBytes($filePath, $randomData)
                    
                    $totalSize += 10
                    $fileCount++
                    
                    if ($i % 20 -eq 0) {
                        Write-Host "    Creados $i/100 archivos..." -ForegroundColor Gray
                    }
                } catch {
                    Write-Host "    Error creando archivo: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
    }
    
    Write-Host "  ✓ Archivos temporales creados: $fileCount archivos (~$totalSize MB)" -ForegroundColor Green
}

# ============================================================================
# 2. LLENAR LA PAPELERA DE RECICLAJE
# ============================================================================
function Fill-RecycleBin {
    Write-Host "`n[2/7] Llenando papelera de reciclaje..." -ForegroundColor Yellow
    
    $testFolder = "$env:USERPROFILE\Desktop\TestRecycleBin_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    
    try {
        New-Item -Path $testFolder -ItemType Directory -Force | Out-Null
        
        Write-Host "  → Creando archivos para la papelera..." -ForegroundColor Cyan
        
        # Crear 50 archivos
        for ($i = 1; $i -le 50; $i++) {
            $fileName = "recycle_test_$i.txt"
            $filePath = Join-Path $testFolder $fileName
            
            # Crear archivo con contenido aleatorio
            $content = "Este es un archivo de prueba para la papelera. " * 1000
            Set-Content -Path $filePath -Value $content
            
            if ($i % 10 -eq 0) {
                Write-Host "    Creados $i/50 archivos..." -ForegroundColor Gray
            }
        }
        
        # Mover archivos a la papelera
        Write-Host "  → Moviendo archivos a la papelera..." -ForegroundColor Cyan
        
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.NameSpace($testFolder)
        
        foreach ($file in Get-ChildItem $testFolder) {
            try {
                $folder.ParseName($file.Name).InvokeVerb("delete")
                Start-Sleep -Milliseconds 50
            } catch { }
        }
        
        # Eliminar carpeta temporal
        Remove-Item -Path $testFolder -Recurse -Force -ErrorAction SilentlyContinue
        
        Write-Host "  ✓ Papelera llenada con ~50 archivos" -ForegroundColor Green
        
    } catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================================
# 3. CREAR ENTRADAS HUÉRFANAS EN EL REGISTRO
# ============================================================================
function Create-OrphanRegistryKeys {
    Write-Host "`n[3/7] Creando entradas huérfanas en el registro..." -ForegroundColor Yellow
    
    # Crear backup primero
    $backupPath = "$env:USERPROFILE\Desktop\RegistryBackup_BeforeTest_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
    
    Write-Host "  → Creando backup de seguridad en: $backupPath" -ForegroundColor Cyan
    reg export "HKCU\Software" "$backupPath\HKCU_Software_backup.reg" /y 2>$null | Out-Null
    
    $baseKey = "HKCU:\Software\TestOrphanKeys_$(Get-Date -Format 'yyyyMMddHHmmss')"
    
    try {
        # Crear clave base
        New-Item -Path $baseKey -Force | Out-Null
        
        Write-Host "  → Creando claves huérfanas..." -ForegroundColor Cyan
        
        # 1. Claves vacías
        for ($i = 1; $i -le 20; $i++) {
            $emptyKey = "$baseKey\EmptyKey_$i"
            New-Item -Path $emptyKey -Force | Out-Null
        }
        Write-Host "    Creadas 20 claves vacías" -ForegroundColor Gray
        
        # 2. Claves con referencias a archivos inexistentes
        for ($i = 1; $i -le 15; $i++) {
            $invalidKey = "$baseKey\InvalidFileReference_$i"
            New-Item -Path $invalidKey -Force | Out-Null
            Set-ItemProperty -Path $invalidKey -Name "DisplayIcon" -Value "C:\NonExistent\Path\file$i.exe,0"
            Set-ItemProperty -Path $invalidKey -Name "UninstallString" -Value "C:\Fake\Path\uninstall$i.exe"
        }
        Write-Host "    Creadas 15 claves con referencias inválidas" -ForegroundColor Gray
        
        # 3. Claves de extensiones de archivo sin asociaciones
        $fileExtsBase = "HKCU:\Software\TestOrphanFileExts_$(Get-Date -Format 'yyyyMMddHHmmss')"
        New-Item -Path $fileExtsBase -Force | Out-Null
        
        for ($i = 1; $i -le 10; $i++) {
            $extKey = "$fileExtsBase\.fakeext$i"
            New-Item -Path $extKey -Force | Out-Null
        }
        Write-Host "    Creadas 10 extensiones huérfanas" -ForegroundColor Gray
        
        # 4. Claves de desinstalación falsas
        $uninstallBase = "HKCU:\Software\TestUninstall_$(Get-Date -Format 'yyyyMMddHHmmss')"
        New-Item -Path $uninstallBase -Force | Out-Null
        
        for ($i = 1; $i -le 10; $i++) {
            $uninstallKey = "$uninstallBase\FakeProgram_$i"
            New-Item -Path $uninstallKey -Force | Out-Null
            Set-ItemProperty -Path $uninstallKey -Name "DisplayName" -Value "Fake Program $i"
            Set-ItemProperty -Path $uninstallKey -Name "DisplayIcon" -Value "C:\FakePath\icon$i.ico"
        }
        Write-Host "    Creadas 10 claves de desinstalación huérfanas" -ForegroundColor Gray
        
        Write-Host "  ✓ Creadas ~55 entradas huérfanas en el registro" -ForegroundColor Green
        Write-Host "  ℹ Backup guardado en: $backupPath" -ForegroundColor Cyan
        
    } catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================================
# 4. LLENAR LA MEMORIA RAM
# ============================================================================
function Fill-RAM {
    Write-Host "`n[4/7] Llenando memoria RAM..." -ForegroundColor Yellow
    
    # Obtener memoria disponible
    $mem = Get-CimInstance -ClassName Win32_OperatingSystem
    $freeMemGB = [math]::Round($mem.FreePhysicalMemory / 1MB, 2)
    
    Write-Host "  → Memoria libre actual: $freeMemGB GB" -ForegroundColor Cyan
    
    # Calcular cuánta memoria llenar (70% de la libre)
    $targetMemMB = [int]($mem.FreePhysicalMemory / 1024 * 0.7)
    
    Write-Host "  → Llenando ~$([math]::Round($targetMemMB/1024, 2)) GB de RAM..." -ForegroundColor Cyan
    Write-Host "    (Esto puede tardar unos minutos)" -ForegroundColor Gray
    
    try {
        # Crear script que consume memoria
        $memoryScript = @"
`$arrays = @()
`$totalMB = $targetMemMB
`$chunkMB = 100

for (`$i = 0; `$i -lt (`$totalMB / `$chunkMB); `$i++) {
    `$arrays += New-Object byte[] (100 * 1024 * 1024)
    (New-Object Random).NextBytes(`$arrays[`$i])
    
    if (`$i % 5 -eq 0) {
        Write-Host "  Consumidos: `$([math]::Round((`$i * `$chunkMB) / 1024, 2)) GB" -ForegroundColor Gray
    }
}

Write-Host "  Presiona cualquier tecla para liberar la memoria..." -ForegroundColor Yellow
`$null = `$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
"@
        
        $scriptPath = "$env:TEMP\FillRAM_Test.ps1"
        Set-Content -Path $scriptPath -Value $memoryScript
        
        # Iniciar proceso que consume memoria
        $process = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -PassThru
        
        Write-Host "  ✓ Proceso de llenado de RAM iniciado (PID: $($process.Id))" -ForegroundColor Green
        Write-Host "  ℹ El proceso permanecerá activo. Ciérralo manualmente o déjalo para que el optimizador lo elimine." -ForegroundColor Cyan
        
    } catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================================
# 5. CREAR CACHÉ DE NAVEGADORES FALSOS
# ============================================================================
function Create-BrowserCache {
    Write-Host "`n[5/7] Creando caché de navegadores simulados..." -ForegroundColor Yellow
    
    # Rutas de caché simuladas
    $cachePaths = @{
        "Chrome" = "$env:LOCALAPPDATA\TestChrome\User Data\Default\Cache"
        "Firefox" = "$env:APPDATA\TestFirefox\Profiles\TestProfile\cache2"
        "Edge" = "$env:LOCALAPPDATA\TestEdge\User Data\Default\Cache"
    }
    
    foreach ($browser in $cachePaths.Keys) {
        $path = $cachePaths[$browser]
        
        Write-Host "  → Creando caché para $browser..." -ForegroundColor Cyan
        
        try {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
            
            # Crear 50 archivos de caché
            for ($i = 1; $i -le 50; $i++) {
                $fileName = "cache_entry_$i`_$(Get-Random).dat"
                $filePath = Join-Path $path $fileName
                
                # Crear archivo de ~1MB
                $randomData = New-Object byte[] (1024 * 1024)
                (New-Object Random).NextBytes($randomData)
                [System.IO.File]::WriteAllBytes($filePath, $randomData)
            }
            
            Write-Host "    Creados 50 archivos de caché (~50 MB)" -ForegroundColor Gray
            
        } catch {
            Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    Write-Host "  ✓ Caché de navegadores creada" -ForegroundColor Green
}

# ============================================================================
# 6. FRAGMENTAR EL DISCO (SIMULACIÓN)
# ============================================================================
function Fragment-Disk {
    Write-Host "`n[6/7] Creando archivos para fragmentación del disco..." -ForegroundColor Yellow
    
    $fragmentFolder = "$env:USERPROFILE\Desktop\TestFragmentation_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    
    try {
        New-Item -Path $fragmentFolder -ItemType Directory -Force | Out-Null
        
        Write-Host "  → Creando archivos fragmentados en: $fragmentFolder" -ForegroundColor Cyan
        Write-Host "    (Esto simulará fragmentación al crear/eliminar archivos)" -ForegroundColor Gray
        
        # Crear muchos archivos pequeños dispersos
        for ($i = 1; $i -le 200; $i++) {
            $fileName = "fragment_test_$i`_$(Get-Random).dat"
            $filePath = Join-Path $fragmentFolder $fileName
            
            # Crear archivo de tamaño variable
            $size = Get-Random -Minimum 100KB -Maximum 5MB
            $randomData = New-Object byte[] $size
            (New-Object Random).NextBytes($randomData)
            [System.IO.File]::WriteAllBytes($filePath, $randomData)
            
            # Eliminar algunos aleatoriamente para crear huecos
            if ($i % 3 -eq 0) {
                Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
            }
            
            if ($i % 50 -eq 0) {
                Write-Host "    Procesados $i/200 archivos..." -ForegroundColor Gray
            }
        }
        
        $remainingFiles = (Get-ChildItem $fragmentFolder).Count
        
        Write-Host "  ✓ Creados archivos de fragmentación ($remainingFiles archivos restantes)" -ForegroundColor Green
        Write-Host "  ℹ Los archivos están en: $fragmentFolder" -ForegroundColor Cyan
        
    } catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================================
# 7. SIMULAR ERRORES DEL SISTEMA (ADVERTENCIA: LIMITADO)
# ============================================================================
function Simulate-SystemErrors {
    Write-Host "`n[7/7] Información sobre simulación de errores del sistema..." -ForegroundColor Yellow
    
    Write-Host "  ⚠️ NOTA IMPORTANTE:" -ForegroundColor Red
    Write-Host "    No es seguro ni recomendable corromper archivos del sistema intencionalmente." -ForegroundColor Yellow
    Write-Host "    SFC y DISM se pueden probar sin corromper archivos:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Opciones para probar SFC/DISM:" -ForegroundColor Cyan
    Write-Host "    1. Ejecutar SFC en un sistema que ya tenga errores naturales" -ForegroundColor Gray
    Write-Host "    2. Probar en una máquina virtual con snapshot" -ForegroundColor Gray
    Write-Host "    3. Verificar que el optimizador detecta 'sin errores' correctamente" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  ✓ Salteando corrupción intencional por seguridad" -ForegroundColor Green
}

# ============================================================================
# RESUMEN Y LIMPIEZA
# ============================================================================
function Show-Summary {
    $endTime = Get-Date
    $duration = $endTime - $startTime
    
    Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║              PRUEBAS CREADAS EXITOSAMENTE                  ║" -ForegroundColor Green
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "Tiempo total: $($duration.Minutes) minutos, $($duration.Seconds) segundos" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "RESUMEN DE PROBLEMAS CREADOS:" -ForegroundColor Yellow
    Write-Host "✓ Archivos temporales: ~3 GB en múltiples ubicaciones" -ForegroundColor White
    Write-Host "✓ Papelera de reciclaje: ~50 archivos" -ForegroundColor White
    Write-Host "✓ Registro: ~55 claves huérfanas" -ForegroundColor White
    Write-Host "✓ Memoria RAM: Proceso consumiendo memoria activo" -ForegroundColor White
    Write-Host "✓ Caché de navegadores: ~150 MB en navegadores simulados" -ForegroundColor White
    Write-Host "✓ Fragmentación: Archivos dispersos creados" -ForegroundColor White
    Write-Host ""
    Write-Host "ARCHIVOS DE BACKUP CREADOS:" -ForegroundColor Yellow
    Write-Host "• Backup del registro en el Escritorio" -ForegroundColor White
    Write-Host ""
    Write-Host "AHORA PUEDES:" -ForegroundColor Green
    Write-Host "1. Ejecutar el Optimizador de Sistema" -ForegroundColor Cyan
    Write-Host "2. Seleccionar todas las opciones" -ForegroundColor Cyan
    Write-Host "3. Verificar que todo se limpia correctamente" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "PARA LIMPIAR MANUALMENTE (si es necesario):" -ForegroundColor Yellow
    Write-Host "• Cerrar proceso de llenado de RAM (consola PowerShell abierta)" -ForegroundColor White
    Write-Host "• Eliminar carpetas TestFragmentation del escritorio" -ForegroundColor White
    Write-Host "• Eliminar claves de registro creadas (ver backup)" -ForegroundColor White
    Write-Host ""
}

# ============================================================================
# EJECUCIÓN PRINCIPAL
# ============================================================================

Write-Host "Iniciando creación de problemas de prueba..." -ForegroundColor Cyan
Write-Host "Fecha: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
Write-Host ""

# Preguntar qué pruebas ejecutar
$runAll = [System.Windows.MessageBox]::Show(
    "¿Deseas ejecutar TODAS las pruebas?`n`n" +
    "Si seleccionas 'No', podrás elegir individualmente.",
    "Selección de Pruebas",
    [System.Windows.MessageBoxButton]::YesNo,
    [System.Windows.MessageBoxImage]::Question
)

if ($runAll -eq [System.Windows.MessageBoxResult]::Yes) {
    Create-TempFiles
    Fill-RecycleBin
    Create-OrphanRegistryKeys
    Fill-RAM
    Create-BrowserCache
    Fragment-Disk
    Simulate-SystemErrors
} else {
    # Menú individual
    Write-Host "Selecciona qué pruebas ejecutar:" -ForegroundColor Yellow
    Write-Host ""
    
    $tests = @(
        @{Name="Archivos temporales"; Function="Create-TempFiles"},
        @{Name="Papelera de reciclaje"; Function="Fill-RecycleBin"},
        @{Name="Registro huérfano"; Function="Create-OrphanRegistryKeys"},
        @{Name="Llenar RAM"; Function="Fill-RAM"},
        @{Name="Caché navegadores"; Function="Create-BrowserCache"},
        @{Name="Fragmentar disco"; Function="Fragment-Disk"}
    )
    
    foreach ($test in $tests) {
        $response = Read-Host "¿Ejecutar: $($test.Name)? (S/N)"
        if ($response -eq 'S' -or $response -eq 's') {
            & $test.Function
        }
    }
    
    Simulate-SystemErrors
}

Show-Summary

Write-Host "Presiona cualquier tecla para salir..." -ForegroundColor Yellow
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")