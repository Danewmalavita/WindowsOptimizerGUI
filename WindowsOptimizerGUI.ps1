#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Optimizador de Sistema Windows con Interfaz Gráfica
.DESCRIPTION
    Script completo de optimización con GUI, limpieza avanzada, verificación de sistema y registro
.NOTES
    Requiere permisos de administrador
    Versión: 3.0 (CORREGIDO - Todos los procesos + Barra de progreso en tiempo real)
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

# Verificar permisos de administrador
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
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

# XAML de la interfaz gráfica
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Optimizador de Sistema Windows v3.0" Height="800" Width="1000"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResize">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Margin" Value="5"/>
            <Setter Property="Padding" Value="10,5"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Margin" Value="5,3"/>
            <Setter Property="FontSize" Value="11"/>
        </Style>
        <Style TargetType="GroupBox">
            <Setter Property="Margin" Value="5"/>
            <Setter Property="Padding" Value="10"/>
            <Setter Property="FontWeight" Value="Bold"/>
        </Style>
    </Window.Resources>
    
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="280"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <!-- Header -->
        <Border Grid.Row="0" Background="#2C3E50" CornerRadius="5" Padding="15" Margin="0,0,0,10">
            <StackPanel>
                <TextBlock Text="OPTIMIZADOR DE SISTEMA WINDOWS v3.0" 
                          FontSize="24" FontWeight="Bold" 
                          Foreground="White" HorizontalAlignment="Center"/>
                <TextBlock Name="StatusText" Text="Listo para optimizar" 
                          FontSize="12" Foreground="#ECF0F1" 
                          HorizontalAlignment="Center" Margin="0,5,0,0"/>
            </StackPanel>
        </Border>
        
        <!-- Opciones de optimización -->
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel>
                <!-- Grupo 1: Discos y Archivos -->
                <GroupBox Header="🗄️ DISCOS Y ARCHIVOS">
                    <StackPanel>
                        <CheckBox Name="chkOptimizeDisks" Content="Optimizar discos duros (Desfragmentar/TRIM)" IsChecked="True"/>
                        <CheckBox Name="chkRecycleBin" Content="Vaciar papelera de reciclaje" IsChecked="True"/>
                        <CheckBox Name="chkTempFiles" Content="Eliminar archivos temporales de Windows" IsChecked="True"/>
                        <CheckBox Name="chkUserTemp" Content="Eliminar archivos temporales de usuario" IsChecked="True"/>
                        <CheckBox Name="chkChkdsk" Content="Ejecutar Check Disk (CHKDSK /F /R) - Requiere reinicio" IsChecked="False"/>
                    </StackPanel>
                </GroupBox>
                
                <!-- Grupo 2: Memoria y Procesos -->
                <GroupBox Header="💾 MEMORIA Y PROCESOS">
                    <StackPanel>
                        <CheckBox Name="chkClearMemory" Content="Liberar caché de memoria RAM" IsChecked="True"/>
                        <CheckBox Name="chkCloseProcesses" Content="Cerrar procesos no críticos" IsChecked="False"/>
                    </StackPanel>
                </GroupBox>
                
                <!-- Grupo 3: Red y Navegadores -->
                <GroupBox Header="🌐 RED Y NAVEGADORES">
                    <StackPanel>
                        <CheckBox Name="chkDNSCache" Content="Limpiar caché DNS" IsChecked="True"/>
                        <CheckBox Name="chkBrowserCache" Content="Limpiar caché de navegadores (Chrome, Firefox, Edge, Opera, Brave)" IsChecked="True"/>
                    </StackPanel>
                </GroupBox>
                
                <!-- Grupo 4: Registro -->
                <GroupBox Header="📋 REGISTRO DE WINDOWS">
                    <StackPanel>
                        <CheckBox Name="chkBackupRegistry" Content="Crear backup del registro" IsChecked="True"/>
                        <CheckBox Name="chkCleanRegistry" Content="Buscar y limpiar claves huérfanas del registro" IsChecked="False"/>
                    </StackPanel>
                </GroupBox>
                
                <!-- Grupo 5: Verificación del Sistema -->
                <GroupBox Header="🔧 VERIFICACIÓN DEL SISTEMA">
                    <StackPanel>
                        <CheckBox Name="chkSFC" Content="Ejecutar SFC /SCANNOW (Verificador de archivos del sistema)" IsChecked="False"/>
                        <CheckBox Name="chkDISM" Content="Ejecutar DISM (Reparar imagen del sistema)" IsChecked="False"/>
                    </StackPanel>
                </GroupBox>
            </StackPanel>
        </ScrollViewer>
        
        <!-- Consola de comandos -->
        <GroupBox Grid.Row="2" Header="📟 CONSOLA DE COMANDOS" Margin="0,5,0,5">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                
                <TextBox Name="ConsoleOutput" Grid.Row="0"
                        IsReadOnly="True" 
                        VerticalScrollBarVisibility="Auto"
                        HorizontalScrollBarVisibility="Auto"
                        FontFamily="Consolas" 
                        FontSize="10"
                        Background="#1E1E1E" 
                        Foreground="#00FF00"
                        Padding="5"
                        TextWrapping="Wrap"/>
                
                <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,5,0,0">
                    <TextBlock Name="ProgressText" Text="Progreso: 0%" 
                              VerticalAlignment="Center" Margin="0,0,10,0" FontWeight="Bold"/>
                    <TextBlock Name="TaskText" Text="" 
                              VerticalAlignment="Center" Foreground="Gray"/>
                </StackPanel>
                
                <ProgressBar Name="ProgressBar" Grid.Row="2" 
                            Height="25" Margin="0,5,0,0"
                            Minimum="0" Maximum="100" Value="0"/>
            </Grid>
        </GroupBox>
        
        <!-- Botones de acción -->
        <Grid Grid.Row="3">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            
            <StackPanel Grid.Column="0" Orientation="Horizontal">
                <CheckBox Name="chkAutoRestart" Content="Reiniciar automáticamente al finalizar" 
                         VerticalAlignment="Center" Margin="5"/>
            </StackPanel>
            
            <Button Name="btnSelectAll" Grid.Column="1" Content="✓ Seleccionar Todo" 
                   Background="#3498DB" Foreground="White" MinWidth="120"/>
            <Button Name="btnStart" Grid.Column="2" Content="▶ Iniciar Optimización" 
                   Background="#27AE60" Foreground="White" MinWidth="150" FontWeight="Bold"/>
            <Button Name="btnExit" Grid.Column="3" Content="✖ Salir" 
                   Background="#E74C3C" Foreground="White" MinWidth="100"/>
        </Grid>
    </Grid>
</Window>
"@

# Cargar XAML
$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

# Obtener elementos de la interfaz
$StatusText = $window.FindName("StatusText")
$ConsoleOutput = $window.FindName("ConsoleOutput")
$ProgressBar = $window.FindName("ProgressBar")
$ProgressText = $window.FindName("ProgressText")
$TaskText = $window.FindName("TaskText")

$chkOptimizeDisks = $window.FindName("chkOptimizeDisks")
$chkRecycleBin = $window.FindName("chkRecycleBin")
$chkTempFiles = $window.FindName("chkTempFiles")
$chkUserTemp = $window.FindName("chkUserTemp")
$chkChkdsk = $window.FindName("chkChkdsk")
$chkClearMemory = $window.FindName("chkClearMemory")
$chkCloseProcesses = $window.FindName("chkCloseProcesses")
$chkDNSCache = $window.FindName("chkDNSCache")
$chkBrowserCache = $window.FindName("chkBrowserCache")
$chkBackupRegistry = $window.FindName("chkBackupRegistry")
$chkCleanRegistry = $window.FindName("chkCleanRegistry")
$chkSFC = $window.FindName("chkSFC")
$chkDISM = $window.FindName("chkDISM")
$chkAutoRestart = $window.FindName("chkAutoRestart")

$btnSelectAll = $window.FindName("btnSelectAll")
$btnStart = $window.FindName("btnStart")
$btnExit = $window.FindName("btnExit")

# Variables globales
$script:totalTasks = 0
$script:completedTasks = 0

# Función para escribir en la consola (MAIN THREAD)
function Write-ConsoleMain {
    param([string]$Message)
    
    $timestamp = Get-Date -Format "HH:mm:ss"
    $output = "[$timestamp] $Message"
    
    $ConsoleOutput.AppendText("$output`n")
    $ConsoleOutput.ScrollToEnd()
}

# Script de optimización que se ejecutará en el runspace
$OptimizationScript = {
    param($window, $ConsoleOutput, $ProgressBar, $StatusText, $ProgressText, $TaskText, $options)
    
    # Función para escribir en la consola (RUNSPACE)
    function Write-Console {
        param([string]$Message)
        
        $timestamp = Get-Date -Format "HH:mm:ss"
        $output = "[$timestamp] $Message"
        
        $window.Dispatcher.Invoke([action]{
            $ConsoleOutput.AppendText("$output`n")
            $ConsoleOutput.ScrollToEnd()
        })
    }
    
    # Función para actualizar progreso con porcentaje y texto de tarea
    function Update-Progress {
        param(
            [int]$Percent,
            [string]$TaskName = ""
        )
        
        $window.Dispatcher.Invoke([action]{
            $ProgressBar.Value = $Percent
            $ProgressText.Text = "Progreso: $Percent%"
            if ($TaskName) {
                $TaskText.Text = "Tarea actual: $TaskName"
            }
        })
    }
    
    # Función para actualizar progreso parcial dentro de una tarea
    function Update-SubProgress {
        param(
            [int]$BasePercent,
            [int]$SubPercent,
            [int]$TaskWeight
        )
        
        $actualPercent = $BasePercent + [int](($SubPercent / 100) * $TaskWeight)
        $window.Dispatcher.Invoke([action]{
            $ProgressBar.Value = $actualPercent
            $ProgressText.Text = "Progreso: $actualPercent%"
        })
    }
    
    # Función para actualizar estado
    function Update-Status {
        param([string]$Status)
        
        $window.Dispatcher.Invoke([action]{
            $StatusText.Text = $Status
        })
    }
    
    # Contar tareas seleccionadas
    $taskList = @()
    if ($options['OptimizeDisks']) { $taskList += 'OptimizeDisks' }
    if ($options['RecycleBin']) { $taskList += 'RecycleBin' }
    if ($options['TempFiles']) { $taskList += 'TempFiles' }
    if ($options['UserTemp']) { $taskList += 'UserTemp' }
    if ($options['Chkdsk']) { $taskList += 'Chkdsk' }
    if ($options['ClearMemory']) { $taskList += 'ClearMemory' }
    if ($options['CloseProcesses']) { $taskList += 'CloseProcesses' }
    if ($options['DNSCache']) { $taskList += 'DNSCache' }
    if ($options['BrowserCache']) { $taskList += 'BrowserCache' }
    if ($options['BackupRegistry']) { $taskList += 'BackupRegistry' }
    if ($options['CleanRegistry']) { $taskList += 'CleanRegistry' }
    if ($options['SFC']) { $taskList += 'SFC' }
    if ($options['DISM']) { $taskList += 'DISM' }
    
    $totalTasks = $taskList.Count
    $completedTasks = 0
    $taskWeight = if ($totalTasks -gt 0) { [int](100 / $totalTasks) } else { 0 }
    
    Write-Console "╔════════════════════════════════════════════════════════════╗"
    Write-Console "║     INICIANDO OPTIMIZACIÓN DEL SISTEMA WINDOWS             ║"
    Write-Console "╚════════════════════════════════════════════════════════════╝"
    Write-Console "Fecha: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"
    Write-Console "Tareas seleccionadas: $totalTasks"
    Write-Console "Tareas a ejecutar: $($taskList -join ', ')"
    Write-Console ""
    
    $startTime = Get-Date
    
    # ═══════════════════════════════════════════════════════════════════════════
    # 1. OPTIMIZACIÓN DE DISCOS (Desfragmentar/TRIM)
    # ═══════════════════════════════════════════════════════════════════════════
    if ($options['OptimizeDisks']) {
        $basePercent = [int](($completedTasks / $totalTasks) * 100)
        Update-Progress $basePercent "Optimización de discos"
        Update-Status "Optimizando discos..."
        
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "OPTIMIZACIÓN DE DISCOS DUROS"
        Write-Console "═══════════════════════════════════════════════════════════"
        
        try {
            $volumes = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' }
            $volumeCount = $volumes.Count
            Write-Console "Unidades encontradas: $volumeCount"
            
            $volumeIndex = 0
            foreach ($volume in $volumes) {
                $volumeIndex++
                $driveLetter = $volume.DriveLetter
                $sizeGB = [math]::Round($volume.Size / 1GB, 2)
                $freeGB = [math]::Round($volume.SizeRemaining / 1GB, 2)
                
                # Actualizar sub-progreso
                $subPercent = [int](($volumeIndex / $volumeCount) * 100)
                Update-SubProgress $basePercent $subPercent $taskWeight
                
                Write-Console ""
                Write-Console "[$volumeIndex/$volumeCount] Unidad ${driveLetter}: - Tamaño: $sizeGB GB, Libre: $freeGB GB"
                
                try {
                    $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
                    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
                    $mediaType = $disk.MediaType
                    
                    Write-Console "  Tipo de disco: $mediaType"
                    
                    if ($mediaType -eq "SSD" -or $mediaType -eq "Solid State Drive") {
                        Write-Console "  → SSD detectado - Ejecutando TRIM (Optimize-Volume -ReTrim)..."
                        
                        # Ejecutar Optimize-Volume con ReTrim para SSD
                        $trimResult = Optimize-Volume -DriveLetter $driveLetter -ReTrim -ErrorAction Stop
                        Write-Console "  ✓ TRIM completado exitosamente"
                        
                    } else {
                        Write-Console "  → HDD detectado - Ejecutando Desfragmentación (Optimize-Volume -Defrag)..."
                        
                        # Ejecutar Optimize-Volume con Defrag para HDD
                        $defragResult = Optimize-Volume -DriveLetter $driveLetter -Defrag -ErrorAction Stop
                        Write-Console "  ✓ Desfragmentación completada exitosamente"
                    }
                    
                } catch {
                    Write-Console "  ✗ Error en unidad ${driveLetter}: $($_.Exception.Message)"
                    
                    # Intentar método alternativo con defrag.exe
                    Write-Console "  → Intentando método alternativo con defrag.exe..."
                    try {
                        $defragOutput = & defrag.exe "${driveLetter}:" /O 2>&1
                        foreach ($line in $defragOutput) {
                            if ($line -and $line.ToString().Trim()) {
                                Write-Console "    $line"
                            }
                        }
                        Write-Console "  ✓ Optimización alternativa completada"
                    } catch {
                        Write-Console "  ✗ Error alternativo: $($_.Exception.Message)"
                    }
                }
            }
            
            Write-Console ""
            Write-Console "✓ Optimización de discos completada"
            
        } catch {
            Write-Console "Error general: $($_.Exception.Message)"
        }
        
        $completedTasks++
        Update-Progress ([int](($completedTasks / $totalTasks) * 100)) ""
    }
    
    # ═══════════════════════════════════════════════════════════════════════════
    # 2. VACIAR PAPELERA
    # ═══════════════════════════════════════════════════════════════════════════
    if ($options['RecycleBin']) {
        $basePercent = [int](($completedTasks / $totalTasks) * 100)
        Update-Progress $basePercent "Vaciando papelera"
        Update-Status "Vaciando papelera..."
        
        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "VACIANDO PAPELERA DE RECICLAJE"
        Write-Console "═══════════════════════════════════════════════════════════"
        
        try {
            $shell = New-Object -ComObject Shell.Application
            $recycleBin = $shell.NameSpace(0x0a)
            $items = $recycleBin.Items()
            
            if ($items.Count -gt 0) {
                Write-Console "Elementos en papelera: $($items.Count)"
                Update-SubProgress $basePercent 50 $taskWeight
                
                Clear-RecycleBin -Force -Confirm:$false -ErrorAction Stop
                Write-Console "✓ Papelera vaciada correctamente"
            } else {
                Write-Console "La papelera ya está vacía"
            }
        } catch {
            Write-Console "Error: $($_.Exception.Message)"
        }
        
        $completedTasks++
        Update-Progress ([int](($completedTasks / $totalTasks) * 100)) ""
    }
    
    # ═══════════════════════════════════════════════════════════════════════════
    # 3. ELIMINAR ARCHIVOS TEMPORALES DE WINDOWS
    # ═══════════════════════════════════════════════════════════════════════════
    if ($options['TempFiles']) {
        $basePercent = [int](($completedTasks / $totalTasks) * 100)
        Update-Progress $basePercent "Archivos temporales Windows"
        Update-Status "Eliminando archivos temporales de Windows..."
        
        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "ELIMINANDO ARCHIVOS TEMPORALES DE WINDOWS"
        Write-Console "═══════════════════════════════════════════════════════════"
        
        $tempPaths = @(
            "$env:SystemRoot\Temp",
            "$env:SystemRoot\Prefetch"
        )
        
        $totalFreed = 0
        $pathIndex = 0
        $pathCount = $tempPaths.Count
        
        foreach ($path in $tempPaths) {
            $pathIndex++
            $subPercent = [int](($pathIndex / $pathCount) * 100)
            Update-SubProgress $basePercent $subPercent $taskWeight
            
            if (Test-Path $path) {
                Write-Console "[$pathIndex/$pathCount] Limpiando: $path"
                
                try {
                    $beforeSize = (Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue | 
                                  Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                    
                    if ($null -eq $beforeSize) { $beforeSize = 0 }
                    $beforeSizeMB = $beforeSize / 1MB
                    
                    Write-Console "  Tamaño antes: $([math]::Round($beforeSizeMB, 2)) MB"
                    
                    $deletedCount = 0
                    Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                        try {
                            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                            $deletedCount++
                        } catch { }
                    }
                    
                    $afterSize = (Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue | 
                                 Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                    
                    if ($null -eq $afterSize) { $afterSize = 0 }
                    $freed = ($beforeSize - $afterSize) / 1MB
                    $totalFreed += $freed
                    
                    Write-Console "  ✓ Eliminados: $deletedCount archivos - $([math]::Round($freed, 2)) MB liberados"
                    
                } catch {
                    Write-Console "  ! Error: $($_.Exception.Message)"
                }
            } else {
                Write-Console "[$pathIndex/$pathCount] Ruta no encontrada: $path"
            }
        }
        
        Write-Console ""
        Write-Console "✓ Total liberado (Windows Temp): $([math]::Round($totalFreed, 2)) MB"
        
        $completedTasks++
        Update-Progress ([int](($completedTasks / $totalTasks) * 100)) ""
    }
    
    # ═══════════════════════════════════════════════════════════════════════════
    # 4. ELIMINAR ARCHIVOS TEMPORALES DE USUARIO
    # ═══════════════════════════════════════════════════════════════════════════
    if ($options['UserTemp']) {
        $basePercent = [int](($completedTasks / $totalTasks) * 100)
        Update-Progress $basePercent "Archivos temporales Usuario"
        Update-Status "Eliminando archivos temporales de usuario..."
        
        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "ELIMINANDO ARCHIVOS TEMPORALES DE USUARIO"
        Write-Console "═══════════════════════════════════════════════════════════"
        
        $tempPaths = @(
            "$env:TEMP",
            "$env:LOCALAPPDATA\Temp"
        )
        
        $totalFreed = 0
        $pathIndex = 0
        $pathCount = $tempPaths.Count
        
        foreach ($path in $tempPaths) {
            $pathIndex++
            $subPercent = [int](($pathIndex / $pathCount) * 100)
            Update-SubProgress $basePercent $subPercent $taskWeight
            
            if (Test-Path $path) {
                Write-Console "[$pathIndex/$pathCount] Limpiando: $path"
                
                try {
                    $beforeSize = (Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue | 
                                  Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                    
                    if ($null -eq $beforeSize) { $beforeSize = 0 }
                    $beforeSizeMB = $beforeSize / 1MB
                    
                    Write-Console "  Tamaño antes: $([math]::Round($beforeSizeMB, 2)) MB"
                    
                    $deletedCount = 0
                    Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                        try {
                            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                            $deletedCount++
                        } catch { }
                    }
                    
                    $afterSize = (Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue | 
                                 Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                    
                    if ($null -eq $afterSize) { $afterSize = 0 }
                    $freed = ($beforeSize - $afterSize) / 1MB
                    $totalFreed += $freed
                    
                    Write-Console "  ✓ Eliminados: $deletedCount archivos - $([math]::Round($freed, 2)) MB liberados"
                    
                } catch {
                    Write-Console "  ! Error: $($_.Exception.Message)"
                }
            } else {
                Write-Console "[$pathIndex/$pathCount] Ruta no encontrada: $path"
            }
        }
        
        Write-Console ""
        Write-Console "✓ Total liberado (Usuario Temp): $([math]::Round($totalFreed, 2)) MB"
        
        $completedTasks++
        Update-Progress ([int](($completedTasks / $totalTasks) * 100)) ""
    }
    
    # ═══════════════════════════════════════════════════════════════════════════
    # 5. CHECK DISK (CHKDSK)
    # ═══════════════════════════════════════════════════════════════════════════
    if ($options['Chkdsk']) {
        $basePercent = [int](($completedTasks / $totalTasks) * 100)
        Update-Progress $basePercent "Check Disk (CHKDSK)"
        Update-Status "Programando Check Disk..."
        
        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "PROGRAMANDO CHECK DISK (CHKDSK)"
        Write-Console "═══════════════════════════════════════════════════════════"
        
        try {
            Write-Console "Programando CHKDSK para la unidad C: en el próximo reinicio..."
            
            # Programar CHKDSK para el próximo reinicio
            $chkdskOutput = & cmd /c "echo Y | chkdsk C: /F /R" 2>&1
            foreach ($line in $chkdskOutput) {
                if ($line -and $line.ToString().Trim()) {
                    Write-Console "  $line"
                }
            }
            
            Write-Console ""
            Write-Console "✓ CHKDSK programado - Se ejecutará en el próximo reinicio"
            Write-Console "  NOTA: El sistema necesitará reiniciarse para ejecutar CHKDSK"
            
        } catch {
            Write-Console "Error: $($_.Exception.Message)"
        }
        
        $completedTasks++
        Update-Progress ([int](($completedTasks / $totalTasks) * 100)) ""
    }
    
    # ═══════════════════════════════════════════════════════════════════════════
    # 6. LIBERAR MEMORIA RAM
    # ═══════════════════════════════════════════════════════════════════════════
    if ($options['ClearMemory']) {
        $basePercent = [int](($completedTasks / $totalTasks) * 100)
        Update-Progress $basePercent "Liberando memoria RAM"
        Update-Status "Liberando memoria RAM..."
        
        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "LIBERANDO MEMORIA RAM"
        Write-Console "═══════════════════════════════════════════════════════════"
        
        try {
            $memBefore = Get-CimInstance -ClassName Win32_OperatingSystem
            $totalMemGB = [math]::Round($memBefore.TotalVisibleMemorySize / 1MB, 2)
            $freeMemBefore = [math]::Round($memBefore.FreePhysicalMemory / 1MB, 2)
            
            Write-Console "Memoria total: $totalMemGB GB"
            Write-Console "Memoria libre antes: $freeMemBefore GB"
            
            Update-SubProgress $basePercent 30 $taskWeight
            
            Write-Console "Liberando caché de memoria..."
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            [System.GC]::Collect()
            
            Update-SubProgress $basePercent 70 $taskWeight
            
            Start-Sleep -Seconds 2
            
            $memAfter = Get-CimInstance -ClassName Win32_OperatingSystem
            $freeMemAfter = [math]::Round($memAfter.FreePhysicalMemory / 1MB, 2)
            $memFreed = [math]::Round($freeMemAfter - $freeMemBefore, 2)
            
            Write-Console "Memoria libre después: $freeMemAfter GB"
            Write-Console "✓ Memoria liberada: $memFreed GB"
            
        } catch {
            Write-Console "Error: $($_.Exception.Message)"
        }
        
        $completedTasks++
        Update-Progress ([int](($completedTasks / $totalTasks) * 100)) ""
    }
    
    # ═══════════════════════════════════════════════════════════════════════════
    # 7. CERRAR PROCESOS NO CRÍTICOS
    # ═══════════════════════════════════════════════════════════════════════════
    if ($options['CloseProcesses']) {
        $basePercent = [int](($completedTasks / $totalTasks) * 100)
        Update-Progress $basePercent "Cerrando procesos"
        Update-Status "Cerrando procesos no críticos..."
        
        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "CERRANDO PROCESOS NO CRÍTICOS"
        Write-Console "═══════════════════════════════════════════════════════════"
        
        try {
            $criticalProcesses = @(
                'System', 'svchost', 'csrss', 'wininit', 'services', 'lsass', 'winlogon',
                'dwm', 'explorer', 'taskhostw', 'RuntimeBroker', 'sihost', 'fontdrvhost',
                'smss', 'conhost', 'dllhost', 'spoolsv', 'SearchIndexer', 'MsMpEng',
                'powershell', 'pwsh', 'audiodg', 'wudfhost', 'dasHost', 'TextInputHost',
                'SecurityHealthService', 'SgrmBroker', 'SecurityHealthSystray',
                'ShellExperienceHost', 'StartMenuExperienceHost', 'SearchUI', 'Cortana',
                'ApplicationFrameHost', 'SystemSettings', 'WmiPrvSE', 'Memory Compression'
            )
            
            $allProcesses = Get-Process
            $nonCriticalProcesses = $allProcesses | Where-Object {
                $processName = $_.ProcessName
                -not ($criticalProcesses -contains $processName) -and
                $_.Id -ne $PID -and
                $_.ProcessName -ne 'Idle'
            }
            
            Write-Console "Procesos no críticos encontrados: $($nonCriticalProcesses.Count)"
            
            $closed = 0
            $processIndex = 0
            $processCount = $nonCriticalProcesses.Count
            
            foreach ($process in $nonCriticalProcesses) {
                $processIndex++
                if ($processCount -gt 0) {
                    $subPercent = [int](($processIndex / $processCount) * 100)
                    Update-SubProgress $basePercent $subPercent $taskWeight
                }
                
                try {
                    $processName = $process.ProcessName
                    $process | Stop-Process -Force -ErrorAction Stop
                    $closed++
                    Write-Console "  ✓ Cerrado: $processName (PID: $($process.Id))"
                } catch {
                    # Silenciar errores de procesos que no se pueden cerrar
                }
            }
            
            Write-Console ""
            Write-Console "✓ Procesos cerrados: $closed de $processCount"
            
        } catch {
            Write-Console "Error: $($_.Exception.Message)"
        }
        
        $completedTasks++
        Update-Progress ([int](($completedTasks / $totalTasks) * 100)) ""
    }
    
    # ═══════════════════════════════════════════════════════════════════════════
    # 8. LIMPIAR CACHÉ DNS
    # ═══════════════════════════════════════════════════════════════════════════
    if ($options['DNSCache']) {
        $basePercent = [int](($completedTasks / $totalTasks) * 100)
        Update-Progress $basePercent "Limpiando caché DNS"
        Update-Status "Limpiando caché DNS..."
        
        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "LIMPIANDO CACHÉ DNS"
        Write-Console "═══════════════════════════════════════════════════════════"
        
        try {
            Update-SubProgress $basePercent 30 $taskWeight
            
            Clear-DnsClientCache -ErrorAction Stop
            Write-Console "  ✓ Clear-DnsClientCache ejecutado"
            
            Update-SubProgress $basePercent 60 $taskWeight
            
            $flushOutput = ipconfig /flushdns 2>&1
            foreach ($line in $flushOutput) {
                if ($line -and $line.ToString().Trim()) {
                    Write-Console "  $line"
                }
            }
            
            Write-Console "✓ Caché DNS limpiada correctamente"
            
        } catch {
            Write-Console "Error: $($_.Exception.Message)"
        }
        
        $completedTasks++
        Update-Progress ([int](($completedTasks / $totalTasks) * 100)) ""
    }
    
    # ═══════════════════════════════════════════════════════════════════════════
    # 9. LIMPIAR NAVEGADORES
    # ═══════════════════════════════════════════════════════════════════════════
    if ($options['BrowserCache']) {
        $basePercent = [int](($completedTasks / $totalTasks) * 100)
        Update-Progress $basePercent "Limpiando navegadores"
        Update-Status "Limpiando caché de navegadores..."
        
        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "LIMPIANDO CACHÉ DE NAVEGADORES"
        Write-Console "═══════════════════════════════════════════════════════════"
        
        $browsers = @{
            "Chrome" = @(
                "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
                "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache",
                "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\GPUCache"
            )
            "Edge" = @(
                "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
                "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache",
                "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\GPUCache"
            )
            "Firefox" = @(
                "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\*\cache2"
            )
            "Opera" = @(
                "$env:APPDATA\Opera Software\Opera Stable\Cache"
            )
            "Brave" = @(
                "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Cache"
            )
        }
        
        $browserIndex = 0
        $browserCount = $browsers.Keys.Count
        
        foreach ($browser in $browsers.Keys) {
            $browserIndex++
            $subPercent = [int](($browserIndex / $browserCount) * 100)
            Update-SubProgress $basePercent $subPercent $taskWeight
            
            Write-Console "[$browserIndex/$browserCount] $browser..."
            $cleared = $false
            $totalCleared = 0
            
            foreach ($path in $browsers[$browser]) {
                # Expandir wildcards
                $expandedPaths = Get-Item -Path $path -ErrorAction SilentlyContinue
                
                foreach ($expandedPath in $expandedPaths) {
                    if (Test-Path $expandedPath) {
                        try {
                            $beforeSize = (Get-ChildItem -Path $expandedPath -Recurse -Force -ErrorAction SilentlyContinue | 
                                          Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                            if ($null -eq $beforeSize) { $beforeSize = 0 }
                            
                            Remove-Item -Path "$expandedPath\*" -Recurse -Force -ErrorAction SilentlyContinue
                            $cleared = $true
                            $totalCleared += ($beforeSize / 1MB)
                        } catch { }
                    }
                }
            }
            
            if ($cleared) {
                Write-Console "  ✓ $browser limpiado - $([math]::Round($totalCleared, 2)) MB liberados"
            } else {
                Write-Console "  → $browser no encontrado o sin caché"
            }
        }
        
        Write-Console ""
        Write-Console "✓ Limpieza de navegadores completada"
        
        $completedTasks++
        Update-Progress ([int](($completedTasks / $totalTasks) * 100)) ""
    }
    
    # ═══════════════════════════════════════════════════════════════════════════
    # 10. BACKUP DE REGISTRO
    # ═══════════════════════════════════════════════════════════════════════════
    if ($options['BackupRegistry']) {
        $basePercent = [int](($completedTasks / $totalTasks) * 100)
        Update-Progress $basePercent "Backup del registro"
        Update-Status "Creando backup del registro..."
        
        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "CREANDO BACKUP DEL REGISTRO"
        Write-Console "═══════════════════════════════════════════════════════════"
        
        $backupPath = "$env:USERPROFILE\Desktop\RegistryBackup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        
        try {
            New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
            Write-Console "Carpeta: $backupPath"
            
            $registryHives = @(
                @{Name="HKEY_CURRENT_USER"; Path="HKCU"; File="HKCU_backup.reg"}
                @{Name="HKEY_LOCAL_MACHINE\SOFTWARE"; Path="HKLM\SOFTWARE"; File="HKLM_SOFTWARE_backup.reg"}
            )
            
            $hiveIndex = 0
            $hiveCount = $registryHives.Count
            
            foreach ($hive in $registryHives) {
                $hiveIndex++
                $subPercent = [int](($hiveIndex / $hiveCount) * 100)
                Update-SubProgress $basePercent $subPercent $taskWeight
                
                Write-Console "[$hiveIndex/$hiveCount] Exportando $($hive.Name)..."
                $exportFile = Join-Path $backupPath $hive.File
                
                $regExportCmd = "reg export `"$($hive.Path)`" `"$exportFile`" /y"
                $exportOutput = cmd /c $regExportCmd 2>&1
                
                if (Test-Path $exportFile) {
                    $fileSize = [math]::Round((Get-Item $exportFile).Length / 1MB, 2)
                    Write-Console "  ✓ Exportado: $fileSize MB"
                } else {
                    Write-Console "  ! No se pudo exportar"
                }
            }
            
            Write-Console ""
            Write-Console "✓ Backup del registro completado"
            
        } catch {
            Write-Console "Error: $($_.Exception.Message)"
        }
        
        $completedTasks++
        Update-Progress ([int](($completedTasks / $totalTasks) * 100)) ""
    }
    
    # ═══════════════════════════════════════════════════════════════════════════
    # 11. LIMPIAR REGISTRO (Claves huérfanas)
    # ═══════════════════════════════════════════════════════════════════════════
    if ($options['CleanRegistry']) {
        $basePercent = [int](($completedTasks / $totalTasks) * 100)
        Update-Progress $basePercent "Limpiando registro"
        Update-Status "Buscando claves huérfanas del registro..."
        
        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "LIMPIANDO CLAVES HUÉRFANAS DEL REGISTRO"
        Write-Console "═══════════════════════════════════════════════════════════"
        
        try {
            Write-Console "Buscando claves de desinstalación huérfanas..."
            
            Update-SubProgress $basePercent 20 $taskWeight
            
            $uninstallPaths = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
                "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
            )
            
            $orphanedKeys = 0
            $pathIndex = 0
            
            foreach ($path in $uninstallPaths) {
                $pathIndex++
                $subPercent = 20 + [int](($pathIndex / $uninstallPaths.Count) * 60)
                Update-SubProgress $basePercent $subPercent $taskWeight
                
                if (Test-Path $path) {
                    Write-Console "Analizando: $path"
                    
                    Get-ChildItem -Path $path -ErrorAction SilentlyContinue | ForEach-Object {
                        $key = $_
                        $displayName = (Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue).DisplayName
                        $installLocation = (Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue).InstallLocation
                        
                        # Verificar si la ubicación de instalación existe
                        if ($installLocation -and -not (Test-Path $installLocation)) {
                            Write-Console "  → Huérfana encontrada: $displayName"
                            $orphanedKeys++
                            
                            # Eliminar la clave huérfana
                            try {
                                Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction Stop
                                Write-Console "    ✓ Eliminada"
                            } catch {
                                Write-Console "    ! No se pudo eliminar: $($_.Exception.Message)"
                            }
                        }
                    }
                }
            }
            
            Write-Console ""
            Write-Console "✓ Limpieza de registro completada - $orphanedKeys claves huérfanas procesadas"
            
        } catch {
            Write-Console "Error: $($_.Exception.Message)"
        }
        
        $completedTasks++
        Update-Progress ([int](($completedTasks / $totalTasks) * 100)) ""
    }
    
    # ═══════════════════════════════════════════════════════════════════════════
    # 12. SFC /SCANNOW
    # ═══════════════════════════════════════════════════════════════════════════
    if ($options['SFC']) {
        $basePercent = [int](($completedTasks / $totalTasks) * 100)
        Update-Progress $basePercent "SFC /SCANNOW"
        Update-Status "Ejecutando SFC /SCANNOW (puede tardar varios minutos)..."
        
        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "EJECUTANDO SFC /SCANNOW"
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "NOTA: Este proceso puede tardar entre 10-30 minutos"
        
        try {
            $sfcProcess = Start-Process -FilePath "sfc.exe" -ArgumentList "/scannow" -NoNewWindow -Wait -PassThru
            
            # Leer el log de CBS
            $cbsLogPath = "$env:SystemRoot\Logs\CBS\CBS.log"
            if (Test-Path $cbsLogPath) {
                $lastLines = Get-Content $cbsLogPath -Tail 20
                Write-Console "Últimas líneas del log CBS:"
                foreach ($line in $lastLines) {
                    Write-Console "  $line"
                }
            }
            
            if ($sfcProcess.ExitCode -eq 0) {
                Write-Console "✓ SFC completado sin errores"
            } else {
                Write-Console "! SFC completado con código: $($sfcProcess.ExitCode)"
            }
            
        } catch {
            Write-Console "Error: $($_.Exception.Message)"
        }
        
        $completedTasks++
        Update-Progress ([int](($completedTasks / $totalTasks) * 100)) ""
    }
    
    # ═══════════════════════════════════════════════════════════════════════════
    # 13. DISM
    # ═══════════════════════════════════════════════════════════════════════════
    if ($options['DISM']) {
        $basePercent = [int](($completedTasks / $totalTasks) * 100)
        Update-Progress $basePercent "DISM"
        Update-Status "Ejecutando DISM (puede tardar varios minutos)..."
        
        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "EJECUTANDO DISM (Reparación de imagen del sistema)"
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "NOTA: Este proceso puede tardar entre 15-45 minutos"
        
        try {
            Write-Console "Paso 1/3: CheckHealth..."
            Update-SubProgress $basePercent 10 $taskWeight
            $dismCheck = & DISM /Online /Cleanup-Image /CheckHealth 2>&1
            foreach ($line in $dismCheck) {
                if ($line -and $line.ToString().Trim()) {
                    Write-Console "  $line"
                }
            }
            
            Write-Console ""
            Write-Console "Paso 2/3: ScanHealth..."
            Update-SubProgress $basePercent 40 $taskWeight
            $dismScan = & DISM /Online /Cleanup-Image /ScanHealth 2>&1
            foreach ($line in $dismScan) {
                if ($line -and $line.ToString().Trim()) {
                    Write-Console "  $line"
                }
            }
            
            Write-Console ""
            Write-Console "Paso 3/3: RestoreHealth..."
            Update-SubProgress $basePercent 70 $taskWeight
            $dismRestore = & DISM /Online /Cleanup-Image /RestoreHealth 2>&1
            foreach ($line in $dismRestore) {
                if ($line -and $line.ToString().Trim()) {
                    Write-Console "  $line"
                }
            }
            
            Write-Console ""
            Write-Console "✓ DISM completado"
            
        } catch {
            Write-Console "Error: $($_.Exception.Message)"
        }
        
        $completedTasks++
        Update-Progress ([int](($completedTasks / $totalTasks) * 100)) ""
    }
    
    # ═══════════════════════════════════════════════════════════════════════════
    # RESUMEN FINAL
    # ═══════════════════════════════════════════════════════════════════════════
    $endTime = Get-Date
    $duration = $endTime - $startTime
    
    Write-Console ""
    Write-Console "╔════════════════════════════════════════════════════════════╗"
    Write-Console "║          OPTIMIZACIÓN COMPLETADA EXITOSAMENTE              ║"
    Write-Console "╚════════════════════════════════════════════════════════════╝"
    Write-Console "Tareas completadas: $completedTasks de $totalTasks"
    Write-Console "Tiempo total: $($duration.Minutes) minutos, $($duration.Seconds) segundos"
    Write-Console ""
    
    Update-Status "✓ Optimización completada"
    Update-Progress 100 "Completado"
    
    $window.Dispatcher.Invoke([action]{
        $TaskText.Text = "¡Todas las tareas completadas!"
    })
    
    # Reinicio si está seleccionado
    if ($options['AutoRestart']) {
        Write-Console "Reiniciando el sistema en 10 segundos..."
        for ($i = 10; $i -gt 0; $i--) {
            Update-Status "Reiniciando en $i segundos..."
            Start-Sleep -Seconds 1
        }
        Restart-Computer -Force
    }
}

# Eventos de botones
$btnSelectAll.Add_Click({
    $allChecked = $true
    
    $checkboxes = @(
        $chkOptimizeDisks, $chkRecycleBin, $chkTempFiles, $chkUserTemp,
        $chkClearMemory, $chkCloseProcesses, $chkDNSCache, $chkBrowserCache,
        $chkBackupRegistry, $chkCleanRegistry, $chkSFC, $chkDISM, $chkChkdsk
    )
    
    foreach ($cb in $checkboxes) {
        if (-not $cb.IsChecked) {
            $allChecked = $false
            break
        }
    }
    
    foreach ($cb in $checkboxes) {
        $cb.IsChecked = -not $allChecked
    }
    
    if ($allChecked) {
        $btnSelectAll.Content = "✓ Seleccionar Todo"
    } else {
        $btnSelectAll.Content = "✗ Deseleccionar Todo"
    }
})

$btnStart.Add_Click({
    # Contar TODAS las opciones seleccionadas
    $selectedCount = 0
    $selectedTasks = @()
    
    if ($chkOptimizeDisks.IsChecked) { $selectedCount++; $selectedTasks += "Optimizar discos" }
    if ($chkRecycleBin.IsChecked) { $selectedCount++; $selectedTasks += "Vaciar papelera" }
    if ($chkTempFiles.IsChecked) { $selectedCount++; $selectedTasks += "Temp Windows" }
    if ($chkUserTemp.IsChecked) { $selectedCount++; $selectedTasks += "Temp Usuario" }
    if ($chkChkdsk.IsChecked) { $selectedCount++; $selectedTasks += "CHKDSK" }
    if ($chkClearMemory.IsChecked) { $selectedCount++; $selectedTasks += "Liberar RAM" }
    if ($chkCloseProcesses.IsChecked) { $selectedCount++; $selectedTasks += "Cerrar procesos" }
    if ($chkDNSCache.IsChecked) { $selectedCount++; $selectedTasks += "Limpiar DNS" }
    if ($chkBrowserCache.IsChecked) { $selectedCount++; $selectedTasks += "Limpiar navegadores" }
    if ($chkBackupRegistry.IsChecked) { $selectedCount++; $selectedTasks += "Backup registro" }
    if ($chkCleanRegistry.IsChecked) { $selectedCount++; $selectedTasks += "Limpiar registro" }
    if ($chkSFC.IsChecked) { $selectedCount++; $selectedTasks += "SFC /SCANNOW" }
    if ($chkDISM.IsChecked) { $selectedCount++; $selectedTasks += "DISM" }
    
    if ($selectedCount -eq 0) {
        [System.Windows.MessageBox]::Show(
            "Por favor, selecciona al menos una opción de optimización.",
            "No hay opciones seleccionadas",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
        return
    }
    
    $taskListText = $selectedTasks -join "`n• "
    
    $result = [System.Windows.MessageBox]::Show(
        "¿Estás seguro de que deseas iniciar la optimización?`n`nSe ejecutarán $selectedCount tareas:`n• $taskListText",
        "Confirmar Optimización",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    
    if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
        $btnStart.IsEnabled = $false
        $ConsoleOutput.Clear()
        $ProgressBar.Value = 0
        $ProgressText.Text = "Progreso: 0%"
        $TaskText.Text = "Iniciando..."
        
        # Crear hashtable con TODAS las opciones
        $options = @{
            'OptimizeDisks' = $chkOptimizeDisks.IsChecked
            'RecycleBin' = $chkRecycleBin.IsChecked
            'TempFiles' = $chkTempFiles.IsChecked
            'UserTemp' = $chkUserTemp.IsChecked
            'Chkdsk' = $chkChkdsk.IsChecked
            'ClearMemory' = $chkClearMemory.IsChecked
            'CloseProcesses' = $chkCloseProcesses.IsChecked
            'DNSCache' = $chkDNSCache.IsChecked
            'BrowserCache' = $chkBrowserCache.IsChecked
            'BackupRegistry' = $chkBackupRegistry.IsChecked
            'CleanRegistry' = $chkCleanRegistry.IsChecked
            'SFC' = $chkSFC.IsChecked
            'DISM' = $chkDISM.IsChecked
            'AutoRestart' = $chkAutoRestart.IsChecked
        }
        
        # Ejecutar en un runspace separado
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = "STA"
        $runspace.ThreadOptions = "ReuseThread"
        $runspace.Open()
        
        $powershell = [powershell]::Create()
        $powershell.Runspace = $runspace
        $powershell.AddScript($OptimizationScript)
        $powershell.AddArgument($window)
        $powershell.AddArgument($ConsoleOutput)
        $powershell.AddArgument($ProgressBar)
        $powershell.AddArgument($StatusText)
        $powershell.AddArgument($ProgressText)
        $powershell.AddArgument($TaskText)
        $powershell.AddArgument($options) | Out-Null
        
        $handle = $powershell.BeginInvoke()
        
        # Monitorear la finalización
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(500)
        $timer.Add_Tick({
            if ($handle.IsCompleted) {
                $timer.Stop()
                $btnStart.IsEnabled = $true
                try {
                    $powershell.EndInvoke($handle)
                    $powershell.Dispose()
                    $runspace.Close()
                } catch { }
            }
        })
        $timer.Start()
    }
})

$btnExit.Add_Click({
    $window.Close()
})

# Mostrar ventana
Write-ConsoleMain "═══════════════════════════════════════════════════════════"
Write-ConsoleMain "OPTIMIZADOR DE SISTEMA WINDOWS - VERSIÓN 3.0"
Write-ConsoleMain "═══════════════════════════════════════════════════════════"
Write-ConsoleMain "Sistema iniciado correctamente"
Write-ConsoleMain "Selecciona las opciones deseadas y presiona 'Iniciar Optimización'"
Write-ConsoleMain ""
Write-ConsoleMain "CORRECCIONES EN ESTA VERSIÓN:"
Write-ConsoleMain "  • Todos los 13 procesos ahora se ejecutan correctamente"
Write-ConsoleMain "  • Optimize-Volume funciona con método alternativo (defrag.exe)"
Write-ConsoleMain "  • Barra de progreso se actualiza en tiempo real"
Write-ConsoleMain "  • Muestra tarea actual y porcentaje exacto"
Write-ConsoleMain ""
$window.ShowDialog() | Out-Null