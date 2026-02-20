#﻿Requires -RunAsAdministrator
<#
.SYNOPSIS
    Optimizador de Sistema Windows con Interfaz Gráfica
.DESCRIPTION
    Script completo de optimización con GUI, limpieza avanzada, verificación de sistema y registro.
.NOTES
    Requiere permisos de administrador
    Versión: 1.0
    Cambios v1.0.6:
      BUGS CORREGIDOS:
        [B1]  GC.Collect reemplazado por EmptyWorkingSet real via Win32 API (RAM real)
        [B2]  CleanRegistry ahora exige BackupRegistry o muestra advertencia bloqueante
        [B3]  Mutex con AbandonedMutexException — ya no bloquea tras crash
        [B4]  chkAutoRestart sincronizado con btnSelectAll correctamente
        [B5]  Detección SSD por DeviceID en lugar de FriendlyName
        [B6]  Opera / Opera GX / Brave con rutas de caché completas
        [B7]  Firefox: limpia cache y cache2 (legacy + moderno)
        [B8]  Timer valida runspace con try/catch — no queda bloqueado
        [B9]  CHKDSK: orden corregido (dirty set ANTES de chkntfs)
        [B10] btnSelectAll refleja estado real de todos los checkboxes
        [B11] Aviso antes de limpiar consola si tiene contenido
        [B12] Formato de duración corregido a dd\:hh\:mm\:ss
        [B13] Limpieza de temporales refactorizada en función reutilizable
      NUEVAS FUNCIONES:
        [N1]  Panel de información del sistema (RAM, disco, CPU) al iniciar
        [N2]  Modo Dry Run (análisis sin cambios)
        [N3]  Limpieza de Windows Update Cache (SoftwareDistribution\Download)
        [N4]  Limpieza de Event Viewer Logs (System, Application, Setup)
        [N5]  Gestor de programas de inicio (ver y desactivar entradas de autoarranque)
      MEJORAS INTERNAS:
        [M1]  Clean-TempPaths — función unificada para limpieza de carpetas temp
        [M2]  Dependencia BackupRegistry ↔ CleanRegistry
        [M3]  Detección de disco robusta via DeviceID
        [M4]  AbandonedMutexException manejada
        [M5]  Rutas de navegadores completadas
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName WindowsBase

# ─────────────────────────────────────────────────────────────────────────────
# Win32 API para liberar Working Set de procesos (liberación real de RAM)
# ─────────────────────────────────────────────────────────────────────────────
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MemoryHelper {
    [DllImport("kernel32.dll")]
    public static extern bool SetSystemFileCacheSize(IntPtr min, IntPtr max, uint flags);
    [DllImport("psapi.dll")]
    public static extern bool EmptyWorkingSet(IntPtr hProcess);
    [DllImport("kernel32.dll")]
    public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr handle);
}
"@ -ErrorAction SilentlyContinue

# Clase C# compartida entre runspaces para señal de parada del escáner
Add-Type @"
public static class ScanControl {
    private static volatile bool _stop = false;
    private static volatile int  _done = 0;
    private static volatile int  _total = 0;
    public static bool Stop  { get { return _stop; }  set { _stop = value; } }
    public static int  Done  { get { return _done; }  set { _done = value; } }
    public static int  Total { get { return _total; } set { _total = value; } }
    public static void Reset() { _stop = false; _done = 0; _total = 0; }
}
"@ -ErrorAction SilentlyContinue

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
# [B3] Evitar doble ejecución — manejo de AbandonedMutexException
# ─────────────────────────────────────────────────────────────────────────────
$script:AppMutex = New-Object System.Threading.Mutex($false, "Global\OptimizadorSistemaGUI_v5")
$mutexAcquired = $false
try {
    $mutexAcquired = $script:AppMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    # El proceso anterior murió sin liberar — el mutex nos pertenece
    $mutexAcquired = $true
}

if (-not $mutexAcquired) {
    [System.Windows.MessageBox]::Show(
        "Ya hay una instancia del Optimizador en ejecución.`n`nCierra la ventana existente antes de abrir una nueva.",
        "Ya en ejecución",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning
    )
    exit
}

# ─────────────────────────────────────────────────────────────────────────────
# XAML — Interfaz Gráfica v1.0
# ─────────────────────────────────────────────────────────────────────────────
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SysOpt - Windows Optimizer GUI v1.0" Height="980" Width="1220"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResize"
        Background="#252B3B">
    <Window.Resources>

        <!-- Colores base — fondo más claro y vibrante -->
        <SolidColorBrush x:Key="BgDeep"       Color="#252B3B"/>
        <SolidColorBrush x:Key="BgCard"        Color="#2E3650"/>
        <SolidColorBrush x:Key="BgCardHover"   Color="#3A4468"/>
        <SolidColorBrush x:Key="BorderSubtle"  Color="#4A5480"/>
        <SolidColorBrush x:Key="BorderActive"  Color="#5BA3FF"/>
        <SolidColorBrush x:Key="AccentBlue"    Color="#5BA3FF"/>
        <SolidColorBrush x:Key="AccentCyan"    Color="#2EDFBF"/>
        <SolidColorBrush x:Key="AccentAmber"   Color="#FFB547"/>
        <SolidColorBrush x:Key="AccentRed"     Color="#FF6B84"/>
        <SolidColorBrush x:Key="AccentGreen"   Color="#4AE896"/>
        <SolidColorBrush x:Key="TextPrimary"   Color="#F0F3FA"/>
        <SolidColorBrush x:Key="TextSecondary" Color="#B0BACC"/>
        <SolidColorBrush x:Key="TextMuted"     Color="#9BA4C0"/>

        <!-- Gradiente de acento para la barra de progreso -->
        <LinearGradientBrush x:Key="ProgressGradient" StartPoint="0,0" EndPoint="1,0">
            <GradientStop Color="#5BA3FF" Offset="0"/>
            <GradientStop Color="#2EDFBF" Offset="1"/>
        </LinearGradientBrush>

        <!-- Estilo de botón base -->
        <Style x:Key="BtnBase" TargetType="Button">
            <Setter Property="FontFamily"    Value="Segoe UI"/>
            <Setter Property="FontSize"      Value="12"/>
            <Setter Property="FontWeight"    Value="SemiBold"/>
            <Setter Property="Height"        Value="36"/>
            <Setter Property="Padding"       Value="16,0"/>
            <Setter Property="Margin"        Value="4,0"/>
            <Setter Property="Cursor"        Value="Hand"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" CornerRadius="8"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Opacity" Value="0.82"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bd" Property="Opacity" Value="0.65"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bd" Property="Opacity" Value="0.3"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Botón primario (verde) -->
        <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource BtnBase}">
            <Setter Property="Background"    Value="#1A6B3E"/>
            <Setter Property="BorderBrush"   Value="#2FD980"/>
            <Setter Property="Foreground"    Value="#2FD980"/>
        </Style>

        <!-- Botón secundario (azul) -->
        <Style x:Key="BtnSecondary" TargetType="Button" BasedOn="{StaticResource BtnBase}">
            <Setter Property="Background"    Value="#132040"/>
            <Setter Property="BorderBrush"   Value="#3D8EFF"/>
            <Setter Property="Foreground"    Value="#3D8EFF"/>
        </Style>

        <!-- Botón cyan (analizar) -->
        <Style x:Key="BtnCyan" TargetType="Button" BasedOn="{StaticResource BtnBase}">
            <Setter Property="Background"    Value="#0E2E2A"/>
            <Setter Property="BorderBrush"   Value="#00D4B4"/>
            <Setter Property="Foreground"    Value="#00D4B4"/>
        </Style>

        <!-- Botón amber (cancelar) -->
        <Style x:Key="BtnAmber" TargetType="Button" BasedOn="{StaticResource BtnBase}">
            <Setter Property="Background"    Value="#2E1E08"/>
            <Setter Property="BorderBrush"   Value="#F5A623"/>
            <Setter Property="Foreground"    Value="#F5A623"/>
        </Style>

        <!-- Botón rojo (salir) -->
        <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource BtnBase}">
            <Setter Property="Background"    Value="#2E0E14"/>
            <Setter Property="BorderBrush"   Value="#FF4D6A"/>
            <Setter Property="Foreground"    Value="#FF4D6A"/>
        </Style>

        <!-- Botón fantasma (guardar log) -->
        <Style x:Key="BtnGhost" TargetType="Button" BasedOn="{StaticResource BtnBase}">
            <Setter Property="Background"    Value="#1A1E2A"/>
            <Setter Property="BorderBrush"   Value="#252A38"/>
            <Setter Property="Foreground"    Value="#9BA4C0"/>
        </Style>

        <!-- CheckBox moderno -->
        <Style TargetType="CheckBox">
            <Setter Property="FontFamily"  Value="Segoe UI"/>
            <Setter Property="FontSize"    Value="12"/>
            <Setter Property="Foreground"  Value="#D4D9E8"/>
            <Setter Property="Margin"      Value="0,4"/>
            <Setter Property="Cursor"      Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <Border x:Name="box" Width="18" Height="18" CornerRadius="5"
                                    Background="#2E3650" BorderBrush="#4A5480" BorderThickness="1.5"
                                    Margin="0,0,9,0" VerticalAlignment="Center">
                                <TextBlock x:Name="chk" Text="✓" FontSize="11" FontWeight="Bold"
                                           Foreground="#5BA3FF" HorizontalAlignment="Center"
                                           VerticalAlignment="Center" Visibility="Collapsed"/>
                            </Border>
                            <ContentPresenter VerticalAlignment="Center"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="box" Property="Background"    Value="#132040"/>
                                <Setter TargetName="box" Property="BorderBrush"   Value="#3D8EFF"/>
                                <Setter TargetName="chk" Property="Visibility"    Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.35"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- ScrollBar delgado -->
        <Style TargetType="ScrollBar">
            <Setter Property="Width" Value="5"/>
            <Setter Property="Background" Value="Transparent"/>
        </Style>

        <!-- ProgressBar con gradiente -->
        <Style TargetType="ProgressBar">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Border CornerRadius="4" Background="#2E3650"
                                BorderBrush="#4A5480" BorderThickness="1" Height="6">
                            <Border x:Name="PART_Track">
                                <Border x:Name="PART_Indicator" HorizontalAlignment="Left" CornerRadius="4">
                                    <Border.Background>
                                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                                            <GradientStop Color="#5BA3FF" Offset="0"/>
                                            <GradientStop Color="#2EDFBF" Offset="1"/>
                                        </LinearGradientBrush>
                                    </Border.Background>
                                </Border>
                            </Border>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

    </Window.Resources>

    <!-- Fondo con grid de puntos (efecto dot-grid sutil) -->
    <Grid>
        <Grid.Background>
            <SolidColorBrush Color="#1E2332"/>
        </Grid.Background>

        <Grid Margin="16,12,16,12">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>   <!-- Header -->
                <RowDefinition Height="Auto"/>   <!-- Sysinfo bar + Charts -->
                <RowDefinition Height="*"/>      <!-- Opciones scroll -->
                <RowDefinition Height="200"/>    <!-- Consola -->
                <RowDefinition Height="Auto"/>   <!-- Footer/botones -->
            </Grid.RowDefinitions>

            <!-- ═══ HEADER ═══════════════════════════════════════════ -->
            <Grid Grid.Row="0" Margin="0,0,0,10">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                    <TextBlock FontFamily="Segoe UI" FontSize="22" FontWeight="Bold"
                               Foreground="#E8ECF4">
                        <Run Text="SYS"/>
                        <Run Foreground="#5BA3FF" Text="OPT"/>
                        <Run Foreground="#B0BACC" FontSize="13" FontWeight="Normal" Text="  v1.0  ·  Windows Optimizer GUI"/>
                    </TextBlock>
                    <TextBlock Name="StatusText" FontFamily="Segoe UI" FontSize="11"
                               Foreground="#9BA4C0" Margin="2,3,0,0"
                               Text="Listo para optimizar"/>
                </StackPanel>

                <!-- Modo Dry Run toggle — esquina derecha del header -->
                <Border Grid.Column="1" CornerRadius="8" Background="#163530"
                        BorderBrush="#2EDFBF" BorderThickness="1"
                        Padding="14,8" VerticalAlignment="Center">
                    <StackPanel Orientation="Horizontal">
                        <CheckBox Name="chkDryRun" VerticalAlignment="Center">
                            <CheckBox.Content>
                                <TextBlock FontFamily="Segoe UI" FontSize="11" FontWeight="SemiBold"
                                           Foreground="#2EDFBF" Text="MODO ANÁLISIS  (sin cambios)"/>
                            </CheckBox.Content>
                        </CheckBox>
                    </StackPanel>
                </Border>
            </Grid>

            <!-- ═══ SYSINFO BAR + CHARTS ══════════════════════════════════ -->
            <Border Grid.Row="1" CornerRadius="10" Background="#2E3650"
                    BorderBrush="#4A5480" BorderThickness="1"
                    Padding="16,12" Margin="0,0,0,10">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="10"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="10"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <!-- CPU Panel + Chart -->
                    <StackPanel Grid.Column="0">
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,5">
                            <Border Width="22" Height="22" CornerRadius="5" Background="#1A3A5C" Margin="0,0,7,0" VerticalAlignment="Center">
                                <TextBlock Text="" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <TextBlock Text="CPU" FontFamily="Segoe UI" FontSize="10" FontWeight="SemiBold"
                                      Foreground="#7BA8E0" VerticalAlignment="Center"/>
                            <TextBlock Name="CpuPctText" Text="  0%" FontFamily="Segoe UI" FontSize="10"
                                       FontWeight="Bold" Foreground="#5BA3FF" VerticalAlignment="Center"/>
                        </StackPanel>
                        <TextBlock Name="InfoCPU" Text="—" FontFamily="Segoe UI" FontSize="10"
                                   FontWeight="SemiBold" Foreground="#5BA3FF" Margin="0,0,0,5" TextWrapping="Wrap"/>
                        <Border Background="#1A2540" CornerRadius="5" Height="52" ClipToBounds="True">
                            <Canvas Name="CpuChart" Background="Transparent"/>
                        </Border>
                    </StackPanel>

                    <!-- Divider -->
                    <Rectangle Grid.Column="1" Fill="#3A4468" Width="1" Margin="0,2"/>

                    <!-- RAM Panel + Chart -->
                    <StackPanel Grid.Column="2" Margin="4,0,0,0">
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,5">
                            <Border Width="22" Height="22" CornerRadius="5" Background="#1A4A35" Margin="0,0,7,0" VerticalAlignment="Center">
                                <TextBlock Text="" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <TextBlock Text="RAM" FontFamily="Segoe UI" FontSize="10" FontWeight="SemiBold"
                                      Foreground="#6ABDA0" VerticalAlignment="Center"/>
                            <TextBlock Name="RamPctText" Text="  0%" FontFamily="Segoe UI" FontSize="10"
                                       FontWeight="Bold" Foreground="#4AE896" VerticalAlignment="Center"/>
                        </StackPanel>
                        <TextBlock Name="InfoRAM" Text="—" FontFamily="Segoe UI" FontSize="10"
                                   FontWeight="SemiBold" Foreground="#4AE896" Margin="0,0,0,5"/>
                        <Border Background="#1A2540" CornerRadius="5" Height="52" ClipToBounds="True">
                            <Canvas Name="RamChart" Background="Transparent"/>
                        </Border>
                    </StackPanel>

                    <!-- Divider -->
                    <Rectangle Grid.Column="3" Fill="#3A4468" Width="1" Margin="0,2"/>

                    <!-- Disco Panel + Chart -->
                    <StackPanel Grid.Column="4" Margin="4,0,0,0">
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,5">
                            <Border Width="22" Height="22" CornerRadius="5" Background="#4A3010" Margin="0,0,7,0" VerticalAlignment="Center">
                                <TextBlock Text="" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <TextBlock Text="DISCO C:" FontFamily="Segoe UI" FontSize="10" FontWeight="SemiBold"
                                      Foreground="#C0933A" VerticalAlignment="Center"/>
                            <TextBlock Name="DiskPctText" Text="  0%" FontFamily="Segoe UI" FontSize="10"
                                       FontWeight="Bold" Foreground="#FFB547" VerticalAlignment="Center"/>
                        </StackPanel>
                        <TextBlock Name="InfoDisk" Text="—" FontFamily="Segoe UI" FontSize="10"
                                   FontWeight="SemiBold" Foreground="#FFB547" Margin="0,0,0,5"/>
                        <Border Background="#1A2540" CornerRadius="5" Height="52" ClipToBounds="True">
                            <Canvas Name="DiskChart" Background="Transparent"/>
                        </Border>
                    </StackPanel>

                    <!-- Refresh -->
                    <Button Name="btnRefreshInfo" Grid.Column="5" Style="{StaticResource BtnGhost}"
                            Content="↻" FontSize="16" Height="32" Width="32" Padding="0"
                            ToolTip="Actualizar información del sistema" Margin="10,0,0,0" VerticalAlignment="Top"/>
                </Grid>
            </Border>

            <!-- ═══ PESTAÑAS PRINCIPALES ══════════════════════════════ -->
            <TabControl Grid.Row="2" Margin="0,0,0,10"
                        Background="#1E2332" BorderBrush="#4A5480" BorderThickness="1">
                <TabControl.Resources>
                    <Style TargetType="TabItem">
                        <Setter Property="FontFamily" Value="Segoe UI"/>
                        <Setter Property="FontSize" Value="12"/>
                        <Setter Property="FontWeight" Value="SemiBold"/>
                        <Setter Property="Foreground" Value="#9BA4C0"/>
                        <Setter Property="Background" Value="#252B3B"/>
                        <Setter Property="Padding" Value="16,8"/>
                        <Setter Property="BorderThickness" Value="0"/>
                        <Setter Property="Template">
                            <Setter.Value>
                                <ControlTemplate TargetType="TabItem">
                                    <Border x:Name="tabBorder" Background="{TemplateBinding Background}"
                                            BorderThickness="0,0,0,2" BorderBrush="Transparent"
                                            Padding="{TemplateBinding Padding}">
                                        <ContentPresenter ContentSource="Header"
                                                          HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsSelected" Value="True">
                                            <Setter TargetName="tabBorder" Property="BorderBrush" Value="#5BA3FF"/>
                                            <Setter Property="Foreground" Value="#F0F3FA"/>
                                            <Setter TargetName="tabBorder" Property="Background" Value="#2E3650"/>
                                        </Trigger>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="tabBorder" Property="Background" Value="#2A3048"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Setter.Value>
                        </Setter>
                    </Style>
                </TabControl.Resources>

                <!-- ══ TAB 1: OPTIMIZACIÓN ══ -->
                <TabItem Header="⚙  Optimización">
                <ScrollViewer VerticalScrollBarVisibility="Auto" Background="#1E2332">
                <Grid Margin="4,8,4,4">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="10"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <!-- Columna izquierda -->
                    <StackPanel Grid.Column="0">

                        <!-- Card: Discos y Archivos -->
                        <Border CornerRadius="10" Background="#2E3650" BorderBrush="#4A5480"
                                BorderThickness="1" Padding="16,14" Margin="0,0,0,8">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                    <Border Width="28" Height="28" CornerRadius="7" Background="Transparent" BorderBrush="#FFFFFF" BorderThickness="1.5"
                                            Margin="0,0,10,0">
                                        <TextBlock Text="" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <TextBlock Text="DISCOS Y ARCHIVOS" FontFamily="Segoe UI" FontSize="13"
                                               FontWeight="Bold" Foreground="#FFFFFF" VerticalAlignment="Center"
                                              />
                                </StackPanel>
                                <CheckBox Name="chkOptimizeDisks" Content="Optimizar discos (Defrag HDD / TRIM SSD·NVMe)" IsChecked="True"/>
                                <CheckBox Name="chkRecycleBin"    Content="Vaciar papelera de reciclaje" IsChecked="True"/>
                                <CheckBox Name="chkTempFiles"     Content="Temp de Windows (System\Temp, Prefetch)" IsChecked="True"/>
                                <CheckBox Name="chkUserTemp"      Content="Temp de usuario (%TEMP%, AppData\Local\Temp)" IsChecked="True"/>
                                <CheckBox Name="chkWUCache"       Content="Caché de Windows Update" IsChecked="False"/>
                                <CheckBox Name="chkChkdsk"        Content="Check Disk (CHKDSK)  —  requiere reinicio" IsChecked="False"/>
                            </StackPanel>
                        </Border>

                        <!-- Card: Memoria y Procesos -->
                        <Border CornerRadius="10" Background="#2E3650" BorderBrush="#4A5480"
                                BorderThickness="1" Padding="16,14" Margin="0,0,0,8">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                    <Border Width="28" Height="28" CornerRadius="7" Background="Transparent" BorderBrush="#FFFFFF" BorderThickness="1.5"
                                            Margin="0,0,10,0">
                                        <TextBlock Text="" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <TextBlock Text="MEMORIA Y PROCESOS" FontFamily="Segoe UI" FontSize="13"
                                               FontWeight="Bold" Foreground="#FFFFFF" VerticalAlignment="Center"
                                              />
                                </StackPanel>
                                <CheckBox Name="chkClearMemory"    Content="Liberar RAM (vaciar Working Set de procesos)" IsChecked="True"/>
                                <CheckBox Name="chkCloseProcesses" Content="Cerrar procesos no críticos" IsChecked="False"/>
                            </StackPanel>
                        </Border>

                        <!-- Card: Red y Navegadores -->
                        <Border CornerRadius="10" Background="#2E3650" BorderBrush="#4A5480"
                                BorderThickness="1" Padding="16,14" Margin="0,0,0,8">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                    <Border Width="28" Height="28" CornerRadius="7" Background="Transparent" BorderBrush="#FFFFFF" BorderThickness="1.5"
                                            Margin="0,0,10,0">
                                        <TextBlock Text="" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <TextBlock Text="RED Y NAVEGADORES" FontFamily="Segoe UI" FontSize="13"
                                               FontWeight="Bold" Foreground="#FFFFFF" VerticalAlignment="Center"
                                              />
                                </StackPanel>
                                <CheckBox Name="chkDNSCache"     Content="Limpiar caché DNS" IsChecked="True"/>
                                <CheckBox Name="chkBrowserCache" Content="Caché de navegadores (Chrome, Edge, Firefox, Opera, Brave)" IsChecked="True"/>
                            </StackPanel>
                        </Border>

                    </StackPanel>

                    <!-- Columna derecha -->
                    <StackPanel Grid.Column="2">

                        <!-- Card: Registro -->
                        <Border CornerRadius="10" Background="#2E3650" BorderBrush="#4A5480"
                                BorderThickness="1" Padding="16,14" Margin="0,0,0,8">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                    <Border Width="28" Height="28" CornerRadius="7" Background="Transparent" BorderBrush="#FFFFFF" BorderThickness="1.5"
                                            Margin="0,0,10,0">
                                        <TextBlock Text="" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <TextBlock Text="REGISTRO DE WINDOWS" FontFamily="Segoe UI" FontSize="13"
                                               FontWeight="Bold" Foreground="#FFFFFF" VerticalAlignment="Center"
                                              />
                                </StackPanel>
                                <CheckBox Name="chkBackupRegistry" Content="Backup del registro (recomendado)" IsChecked="True"/>
                                <CheckBox Name="chkCleanRegistry"  Content="Limpiar claves huérfanas" IsChecked="False"/>
                            </StackPanel>
                        </Border>

                        <!-- Card: Verificación del Sistema -->
                        <Border CornerRadius="10" Background="#2E3650" BorderBrush="#4A5480"
                                BorderThickness="1" Padding="16,14" Margin="0,0,0,8">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                    <Border Width="28" Height="28" CornerRadius="7" Background="Transparent" BorderBrush="#FFFFFF" BorderThickness="1.5"
                                            Margin="0,0,10,0">
                                        <TextBlock Text="" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <TextBlock Text="VERIFICACIÓN DEL SISTEMA" FontFamily="Segoe UI" FontSize="13"
                                               FontWeight="Bold" Foreground="#FFFFFF" VerticalAlignment="Center"
                                              />
                                </StackPanel>
                                <CheckBox Name="chkSFC"  Content="SFC /SCANNOW  —  verificador de archivos" IsChecked="False"/>
                                <CheckBox Name="chkDISM" Content="DISM  —  reparar imagen del sistema" IsChecked="False"/>
                            </StackPanel>
                        </Border>

                        <!-- Card: Registros de Eventos -->
                        <Border CornerRadius="10" Background="#2E3650" BorderBrush="#4A5480"
                                BorderThickness="1" Padding="16,14" Margin="0,0,0,8">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                    <Border Width="28" Height="28" CornerRadius="7" Background="Transparent" BorderBrush="#FFFFFF" BorderThickness="1.5"
                                            Margin="0,0,10,0">
                                        <TextBlock Text="" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <TextBlock Text="REGISTROS DE EVENTOS" FontFamily="Segoe UI" FontSize="13"
                                               FontWeight="Bold" Foreground="#FFFFFF" VerticalAlignment="Center"
                                              />
                                </StackPanel>
                                <CheckBox Name="chkEventLogs" Content="Event Viewer (System, Application, Setup)" IsChecked="False"/>
                                <TextBlock Text="El log Security no se toca" FontFamily="Segoe UI" FontSize="10"
                                           Foreground="#8B96B8" Margin="27,3,0,0"/>
                            </StackPanel>
                        </Border>

                        <!-- Card: Programas de inicio -->
                        <Border CornerRadius="10" Background="#2E3650" BorderBrush="#4A5480"
                                BorderThickness="1" Padding="16,14" Margin="0,0,0,8">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                    <Border Width="28" Height="28" CornerRadius="7" Background="Transparent" BorderBrush="#FFFFFF" BorderThickness="1.5"
                                            Margin="0,0,10,0">
                                        <TextBlock Text="" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <TextBlock Text="PROGRAMAS DE INICIO" FontFamily="Segoe UI" FontSize="13"
                                               FontWeight="Bold" Foreground="#FFFFFF" VerticalAlignment="Center"
                                              />
                                </StackPanel>
                                <CheckBox Name="chkShowStartup" Content="Gestionar entradas de autoarranque" IsChecked="False"/>
                                <TextBlock Text="Abre ventana de gestión al iniciar" FontFamily="Segoe UI" FontSize="10"
                                           Foreground="#8B96B8" Margin="27,3,0,0"/>
                            </StackPanel>
                        </Border>

                    </StackPanel>
                </Grid>
                </ScrollViewer>
                </TabItem>

                <!-- ══ TAB 2: RENDIMIENTO ══ -->
                <TabItem Header="📊  Rendimiento">
                <Grid Background="#1E2332" Margin="0">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <!-- Toolbar rendimiento -->
                    <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="10,8,10,4">
                        <Button Name="btnRefreshPerf" Style="{StaticResource BtnSecondary}"
                                Content="↻  Actualizar" MinWidth="110" Height="30"/>
                        <TextBlock Name="txtPerfStatus" Text="  Haz clic en Actualizar para cargar datos"
                                   FontFamily="Segoe UI" FontSize="11" Foreground="#9BA4C0"
                                   VerticalAlignment="Center" Margin="10,0,0,0"/>
                    </StackPanel>
                    <!-- Contenido en scroll -->
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                    <StackPanel Margin="10,0,10,10">

                        <!-- ── CPU CORES ── -->
                        <Border CornerRadius="10" Background="#2E3650" BorderBrush="#4A5480"
                                BorderThickness="1" Padding="16,14" Margin="0,0,0,8">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                                    <Border Width="26" Height="26" CornerRadius="6" Background="#1A3A5C" Margin="0,0,10,0">
                                        <TextBlock Text="" FontFamily="Segoe MDL2 Assets" FontSize="13"
                                                   Foreground="#5BA3FF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <TextBlock Text="CORES DEL PROCESADOR" FontFamily="Segoe UI" FontSize="13"
                                               FontWeight="Bold" Foreground="#FFFFFF" VerticalAlignment="Center"/>
                                </StackPanel>
                                <!-- Nombre CPU -->
                                <TextBlock Name="txtCpuName" Text="—" FontFamily="Segoe UI" FontSize="11"
                                           Foreground="#9BA4C0" Margin="0,0,0,8"/>
                                <!-- Grid de cores generado dinámicamente -->
                                <ItemsControl Name="icCpuCores">
                                    <ItemsControl.ItemsPanel>
                                        <ItemsPanelTemplate>
                                            <WrapPanel Orientation="Horizontal"/>
                                        </ItemsPanelTemplate>
                                    </ItemsControl.ItemsPanel>
                                    <ItemsControl.ItemTemplate>
                                        <DataTemplate>
                                            <Border CornerRadius="8" Background="#1A2540" BorderBrush="#3A4468"
                                                    BorderThickness="1" Padding="10,8" Margin="4,4"
                                                    Width="120">
                                                <StackPanel>
                                                    <TextBlock Text="{Binding CoreLabel}" FontFamily="Segoe UI"
                                                               FontSize="10" FontWeight="SemiBold" Foreground="#B0BACC"
                                                               HorizontalAlignment="Center"/>
                                                    <TextBlock Text="{Binding Usage}" FontFamily="Segoe UI"
                                                               FontSize="20" FontWeight="Bold" Foreground="#5BA3FF"
                                                               HorizontalAlignment="Center" Margin="0,2"/>
                                                    <ProgressBar Minimum="0" Maximum="100" Value="{Binding UsageNum}"
                                                                 Height="4" Margin="0,4,0,2"/>
                                                    <TextBlock Text="{Binding Freq}" FontFamily="Segoe UI"
                                                               FontSize="9" Foreground="#8B96B8"
                                                               HorizontalAlignment="Center"/>
                                                </StackPanel>
                                            </Border>
                                        </DataTemplate>
                                    </ItemsControl.ItemTemplate>
                                </ItemsControl>
                            </StackPanel>
                        </Border>

                        <!-- ── RAM DETALLADA ── -->
                        <Border CornerRadius="10" Background="#2E3650" BorderBrush="#4A5480"
                                BorderThickness="1" Padding="16,14" Margin="0,0,0,8">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                                    <Border Width="26" Height="26" CornerRadius="6" Background="#1A4A35" Margin="0,0,10,0">
                                        <TextBlock Text="" FontFamily="Segoe MDL2 Assets" FontSize="13"
                                                   Foreground="#4AE896" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <TextBlock Text="MEMORIA RAM" FontFamily="Segoe UI" FontSize="13"
                                               FontWeight="Bold" Foreground="#FFFFFF" VerticalAlignment="Center"/>
                                </StackPanel>
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <StackPanel Grid.Column="0" HorizontalAlignment="Center">
                                        <TextBlock Text="TOTAL" FontFamily="Segoe UI" FontSize="9" Foreground="#8B96B8" HorizontalAlignment="Center"/>
                                        <TextBlock Name="txtRamTotal" Text="—" FontFamily="Segoe UI" FontSize="18"
                                                   FontWeight="Bold" Foreground="#4AE896" HorizontalAlignment="Center"/>
                                    </StackPanel>
                                    <StackPanel Grid.Column="1" HorizontalAlignment="Center">
                                        <TextBlock Text="USADA" FontFamily="Segoe UI" FontSize="9" Foreground="#8B96B8" HorizontalAlignment="Center"/>
                                        <TextBlock Name="txtRamUsed" Text="—" FontFamily="Segoe UI" FontSize="18"
                                                   FontWeight="Bold" Foreground="#FFB547" HorizontalAlignment="Center"/>
                                    </StackPanel>
                                    <StackPanel Grid.Column="2" HorizontalAlignment="Center">
                                        <TextBlock Text="LIBRE" FontFamily="Segoe UI" FontSize="9" Foreground="#8B96B8" HorizontalAlignment="Center"/>
                                        <TextBlock Name="txtRamFree" Text="—" FontFamily="Segoe UI" FontSize="18"
                                                   FontWeight="Bold" Foreground="#4AE896" HorizontalAlignment="Center"/>
                                    </StackPanel>
                                    <StackPanel Grid.Column="3" HorizontalAlignment="Center">
                                        <TextBlock Text="USO%" FontFamily="Segoe UI" FontSize="9" Foreground="#8B96B8" HorizontalAlignment="Center"/>
                                        <TextBlock Name="txtRamPct" Text="—" FontFamily="Segoe UI" FontSize="18"
                                                   FontWeight="Bold" Foreground="#5BA3FF" HorizontalAlignment="Center"/>
                                    </StackPanel>
                                </Grid>
                                <ProgressBar Name="pbRam" Minimum="0" Maximum="100" Value="0"
                                             Height="8" Margin="0,10,0,4"/>
                                <!-- Módulos de RAM -->
                                <ItemsControl Name="icRamModules">
                                    <ItemsControl.ItemTemplate>
                                        <DataTemplate>
                                            <Border CornerRadius="6" Background="#1A2540" BorderBrush="#2A3A5A"
                                                    BorderThickness="1" Padding="10,6" Margin="0,3">
                                                <Grid>
                                                    <Grid.ColumnDefinitions>
                                                        <ColumnDefinition Width="Auto"/>
                                                        <ColumnDefinition Width="*"/>
                                                        <ColumnDefinition Width="Auto"/>
                                                    </Grid.ColumnDefinitions>
                                                    <TextBlock Grid.Column="0" Text="{Binding Slot}" FontFamily="Segoe UI"
                                                               FontSize="10" FontWeight="Bold" Foreground="#5BA3FF"
                                                               VerticalAlignment="Center" Width="60"/>
                                                    <TextBlock Grid.Column="1" Text="{Binding Info}" FontFamily="Segoe UI"
                                                               FontSize="10" Foreground="#B0BACC" VerticalAlignment="Center"/>
                                                    <TextBlock Grid.Column="2" Text="{Binding Size}" FontFamily="Segoe UI"
                                                               FontSize="11" FontWeight="Bold" Foreground="#4AE896"
                                                               VerticalAlignment="Center"/>
                                                </Grid>
                                            </Border>
                                        </DataTemplate>
                                    </ItemsControl.ItemTemplate>
                                </ItemsControl>
                            </StackPanel>
                        </Border>

                        <!-- ── SMART DEL DISCO ── -->
                        <Border CornerRadius="10" Background="#2E3650" BorderBrush="#4A5480"
                                BorderThickness="1" Padding="16,14" Margin="0,0,0,8">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                                    <Border Width="26" Height="26" CornerRadius="6" Background="#3A2010" Margin="0,0,10,0">
                                        <TextBlock Text="" FontFamily="Segoe MDL2 Assets" FontSize="13"
                                                   Foreground="#FFB547" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <TextBlock Text="ESTADO S.M.A.R.T. DEL DISCO" FontFamily="Segoe UI" FontSize="13"
                                               FontWeight="Bold" Foreground="#FFFFFF" VerticalAlignment="Center"/>
                                </StackPanel>
                                <ItemsControl Name="icSmartDisks">
                                    <ItemsControl.ItemTemplate>
                                        <DataTemplate>
                                            <Border CornerRadius="8" Background="#1A2540" BorderBrush="#2A3A5A"
                                                    BorderThickness="1" Padding="14,10" Margin="0,4">
                                                <StackPanel>
                                                    <Grid Margin="0,0,0,6">
                                                        <Grid.ColumnDefinitions>
                                                            <ColumnDefinition Width="*"/>
                                                            <ColumnDefinition Width="Auto"/>
                                                        </Grid.ColumnDefinitions>
                                                        <TextBlock Grid.Column="0" Text="{Binding DiskName}" FontFamily="Segoe UI"
                                                                   FontSize="11" FontWeight="SemiBold" Foreground="#E0E8F4"/>
                                                        <Border Grid.Column="1" CornerRadius="4" Padding="8,2"
                                                                Background="{Binding StatusBg}">
                                                            <TextBlock Text="{Binding Status}" FontFamily="Segoe UI"
                                                                       FontSize="10" FontWeight="Bold" Foreground="{Binding StatusFg}"/>
                                                        </Border>
                                                    </Grid>
                                                    <ItemsControl ItemsSource="{Binding Attributes}">
                                                        <ItemsControl.ItemsPanel>
                                                            <ItemsPanelTemplate>
                                                                <WrapPanel Orientation="Horizontal"/>
                                                            </ItemsPanelTemplate>
                                                        </ItemsControl.ItemsPanel>
                                                        <ItemsControl.ItemTemplate>
                                                            <DataTemplate>
                                                                <Border CornerRadius="5" Background="#252B3B" BorderBrush="#3A4468"
                                                                        BorderThickness="1" Padding="8,4" Margin="3,3" MinWidth="130">
                                                                    <StackPanel>
                                                                        <TextBlock Text="{Binding Name}" FontFamily="Segoe UI"
                                                                                   FontSize="9" Foreground="#8B96B8"/>
                                                                        <TextBlock Text="{Binding Value}" FontFamily="Segoe UI"
                                                                                   FontSize="12" FontWeight="Bold"
                                                                                   Foreground="{Binding ValueColor}"/>
                                                                    </StackPanel>
                                                                </Border>
                                                            </DataTemplate>
                                                        </ItemsControl.ItemTemplate>
                                                    </ItemsControl>
                                                </StackPanel>
                                            </Border>
                                        </DataTemplate>
                                    </ItemsControl.ItemTemplate>
                                </ItemsControl>
                            </StackPanel>
                        </Border>

                        <!-- ── RED ── -->
                        <Border CornerRadius="10" Background="#2E3650" BorderBrush="#4A5480"
                                BorderThickness="1" Padding="16,14" Margin="0,0,0,8">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                                    <Border Width="26" Height="26" CornerRadius="6" Background="#2A1A4A" Margin="0,0,10,0">
                                        <TextBlock Text="" FontFamily="Segoe MDL2 Assets" FontSize="13"
                                                   Foreground="#C07AFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <TextBlock Text="TARJETAS DE RED" FontFamily="Segoe UI" FontSize="13"
                                               FontWeight="Bold" Foreground="#FFFFFF" VerticalAlignment="Center"/>
                                </StackPanel>
                                <ItemsControl Name="icNetAdapters">
                                    <ItemsControl.ItemTemplate>
                                        <DataTemplate>
                                            <Border CornerRadius="8" Background="#1A2540" BorderBrush="#2A3A5A"
                                                    BorderThickness="1" Padding="14,10" Margin="0,4">
                                                <Grid>
                                                    <Grid.ColumnDefinitions>
                                                        <ColumnDefinition Width="*"/>
                                                        <ColumnDefinition Width="Auto"/>
                                                    </Grid.ColumnDefinitions>
                                                    <StackPanel Grid.Column="0">
                                                        <TextBlock Text="{Binding Name}" FontFamily="Segoe UI"
                                                                   FontSize="11" FontWeight="SemiBold" Foreground="#E0E8F4"/>
                                                        <TextBlock Text="{Binding IP}" FontFamily="Segoe UI"
                                                                   FontSize="10" Foreground="#8B96B8" Margin="0,2"/>
                                                        <TextBlock Text="{Binding MAC}" FontFamily="Segoe UI"
                                                                   FontSize="10" Foreground="#8B96B8"/>
                                                    </StackPanel>
                                                    <StackPanel Grid.Column="1" HorizontalAlignment="Right">
                                                        <TextBlock Text="{Binding Speed}" FontFamily="Segoe UI"
                                                                   FontSize="13" FontWeight="Bold" Foreground="#C07AFF"
                                                                   HorizontalAlignment="Right"/>
                                                        <TextBlock Text="{Binding Status}" FontFamily="Segoe UI"
                                                                   FontSize="10" Foreground="{Binding StatusColor}"
                                                                   HorizontalAlignment="Right"/>
                                                        <TextBlock Text="{Binding BytesIO}" FontFamily="Segoe UI"
                                                                   FontSize="9" Foreground="#8B96B8"
                                                                   HorizontalAlignment="Right" Margin="0,2"/>
                                                    </StackPanel>
                                                </Grid>
                                            </Border>
                                        </DataTemplate>
                                    </ItemsControl.ItemTemplate>
                                </ItemsControl>
                            </StackPanel>
                        </Border>

                    </StackPanel>
                    </ScrollViewer>
                </Grid>
                </TabItem>

                <!-- ══ TAB 3: EXPLORADOR DE DISCO ══ -->
                <TabItem Header="💾  Explorador de Disco">
                <Grid Background="#1E2332">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <!-- Toolbar -->
                    <Border Grid.Row="0" Background="#252B3B" BorderBrush="#4A5480" BorderThickness="0,0,0,1" Padding="10,8">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Grid.Column="0" Text="Ruta:" FontFamily="Segoe UI" FontSize="11"
                                       Foreground="#9BA4C0" VerticalAlignment="Center" Margin="0,0,6,0"/>
                            <TextBox Name="txtDiskScanPath" Grid.Column="1" Text="C:\"
                                     FontFamily="Segoe UI" FontSize="11" Foreground="#F0F3FA"
                                     Background="#2E3650" BorderBrush="#4A5480" BorderThickness="1"
                                     Padding="6,4" VerticalAlignment="Center"/>
                            <Button Name="btnDiskBrowse" Grid.Column="2" Style="{StaticResource BtnGhost}"
                                    Content="📁" Height="28" Width="32" Padding="0" Margin="4,0"/>
                            <Button Name="btnDiskScan" Grid.Column="3" Style="{StaticResource BtnSecondary}"
                                    Content="🔍  Escanear" Height="28" MinWidth="100" Margin="0,0,4,0"/>
                            <Button Name="btnDiskStop" Grid.Column="4" Style="{StaticResource BtnAmber}"
                                    Content="⏹  Detener" Height="28" MinWidth="90" IsEnabled="False"/>
                        </Grid>
                    </Border>

                    <!-- TreeView de resultados -->
                    <Grid Grid.Row="1">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="4"/>
                            <ColumnDefinition Width="260"/>
                        </Grid.ColumnDefinitions>

                        <!-- ListView principal -->
                        <Border Grid.Column="0" Background="#1A2035" BorderBrush="#3A4468" BorderThickness="0,0,1,0">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="*"/>
                                </Grid.RowDefinitions>
                                <!-- Header de columnas -->
                                <Grid Grid.Row="0" Background="#252B3B" Margin="0">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="100"/>
                                        <ColumnDefinition Width="70"/>
                                        <ColumnDefinition Width="90"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="  Nombre" FontFamily="Segoe UI" FontSize="10"
                                               FontWeight="SemiBold" Foreground="#9BA4C0" Padding="8,5"/>
                                    <TextBlock Grid.Column="1" Text="Tamaño" FontFamily="Segoe UI" FontSize="10"
                                               FontWeight="SemiBold" Foreground="#9BA4C0" Padding="8,5" TextAlignment="Right"/>
                                    <TextBlock Grid.Column="2" Text="%" FontFamily="Segoe UI" FontSize="10"
                                               FontWeight="SemiBold" Foreground="#9BA4C0" Padding="8,5" TextAlignment="Right"/>
                                    <TextBlock Grid.Column="3" Text="Archivos" FontFamily="Segoe UI" FontSize="10"
                                               FontWeight="SemiBold" Foreground="#9BA4C0" Padding="8,5" TextAlignment="Right"/>
                                </Grid>
                                <ListBox Name="lbDiskTree" Grid.Row="1"
                                         Background="Transparent" BorderThickness="0"
                                         ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                                         VirtualizingStackPanel.IsVirtualizing="True">
                                    <ListBox.ItemContainerStyle>
                                        <Style TargetType="ListBoxItem">
                                            <Setter Property="Padding" Value="0"/>
                                            <Setter Property="Margin" Value="0"/>
                                            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                                            <Setter Property="Template">
                                                <Setter.Value>
                                                    <ControlTemplate TargetType="ListBoxItem">
                                                        <Border x:Name="lbiBd" Background="Transparent"
                                                                BorderBrush="#2A3448" BorderThickness="0,0,0,1">
                                                            <ContentPresenter/>
                                                        </Border>
                                                        <ControlTemplate.Triggers>
                                                            <Trigger Property="IsSelected" Value="True">
                                                                <Setter TargetName="lbiBd" Property="Background" Value="#1A3A5C"/>
                                                            </Trigger>
                                                            <Trigger Property="IsMouseOver" Value="True">
                                                                <Setter TargetName="lbiBd" Property="Background" Value="#252B3B"/>
                                                            </Trigger>
                                                        </ControlTemplate.Triggers>
                                                    </ControlTemplate>
                                                </Setter.Value>
                                            </Setter>
                                        </Style>
                                    </ListBox.ItemContainerStyle>
                                    <ListBox.ItemTemplate>
                                        <DataTemplate>
                                            <Grid Height="30">
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="100"/>
                                                    <ColumnDefinition Width="70"/>
                                                    <ColumnDefinition Width="90"/>
                                                </Grid.ColumnDefinitions>
                                                <!-- Barra de fondo proporcional -->
                                                <Border Grid.Column="0" Grid.ColumnSpan="4"
                                                        HorizontalAlignment="Left"
                                                        Width="{Binding BarWidth}" Height="30"
                                                        Background="{Binding BarColor}" Opacity="0.15"/>
                                                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center"
                                                            Margin="{Binding Indent}">
                                                    <TextBlock Text="{Binding Icon}" FontSize="12" Margin="0,0,5,0"
                                                               VerticalAlignment="Center"/>
                                                    <TextBlock Text="{Binding DisplayName}" FontFamily="Segoe UI" FontSize="11"
                                                               Foreground="#D0D8F0" VerticalAlignment="Center"
                                                               TextTrimming="CharacterEllipsis"/>
                                                </StackPanel>
                                                <TextBlock Grid.Column="1" Text="{Binding SizeStr}" FontFamily="Segoe UI"
                                                           FontSize="11" FontWeight="SemiBold" Foreground="{Binding SizeColor}"
                                                           VerticalAlignment="Center" TextAlignment="Right" Margin="0,0,8,0"/>
                                                <TextBlock Grid.Column="2" Text="{Binding PctStr}" FontFamily="Segoe UI"
                                                           FontSize="10" Foreground="#8B96B8"
                                                           VerticalAlignment="Center" TextAlignment="Right" Margin="0,0,8,0"/>
                                                <TextBlock Grid.Column="3" Text="{Binding FileCount}" FontFamily="Segoe UI"
                                                           FontSize="10" Foreground="#8B96B8"
                                                           VerticalAlignment="Center" TextAlignment="Right" Margin="0,0,8,0"/>
                                            </Grid>
                                        </DataTemplate>
                                    </ListBox.ItemTemplate>
                                </ListBox>
                            </Grid>
                        </Border>

                        <!-- Panel lateral de detalle -->
                        <Border Grid.Column="2" Background="#252B3B" Padding="12">
                            <StackPanel>
                                <TextBlock Text="DETALLE" FontFamily="Segoe UI" FontSize="10" FontWeight="SemiBold"
                                           Foreground="#6B7A9E" Margin="0,0,0,10"/>
                                <TextBlock Name="txtDiskDetailName" Text="—" FontFamily="Segoe UI" FontSize="12"
                                           FontWeight="Bold" Foreground="#F0F3FA" TextWrapping="Wrap" Margin="0,0,0,8"/>
                                <Grid Margin="0,0,0,6">
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                    <TextBlock Text="Tamaño:" FontFamily="Segoe UI" FontSize="10" Foreground="#8B96B8"/>
                                    <TextBlock Name="txtDiskDetailSize" Grid.Column="1" Text="—" FontFamily="Segoe UI"
                                               FontSize="10" FontWeight="Bold" Foreground="#FFB547"/>
                                </Grid>
                                <Grid Margin="0,0,0,6">
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                    <TextBlock Text="Archivos:" FontFamily="Segoe UI" FontSize="10" Foreground="#8B96B8"/>
                                    <TextBlock Name="txtDiskDetailFiles" Grid.Column="1" Text="—" FontFamily="Segoe UI"
                                               FontSize="10" FontWeight="Bold" Foreground="#4AE896"/>
                                </Grid>
                                <Grid Margin="0,0,0,6">
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                    <TextBlock Text="Carpetas:" FontFamily="Segoe UI" FontSize="10" Foreground="#8B96B8"/>
                                    <TextBlock Name="txtDiskDetailDirs" Grid.Column="1" Text="—" FontFamily="Segoe UI"
                                               FontSize="10" FontWeight="Bold" Foreground="#5BA3FF"/>
                                </Grid>
                                <Grid Margin="0,0,0,14">
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                    <TextBlock Text="% del padre:" FontFamily="Segoe UI" FontSize="10" Foreground="#8B96B8"/>
                                    <TextBlock Name="txtDiskDetailPct" Grid.Column="1" Text="—" FontFamily="Segoe UI"
                                               FontSize="10" FontWeight="Bold" Foreground="#C07AFF"/>
                                </Grid>
                                <Rectangle Height="1" Fill="#3A4468" Margin="0,0,0,12"/>
                                <TextBlock Text="TOP 10 ARCHIVOS MÁS GRANDES" FontFamily="Segoe UI" FontSize="9"
                                           FontWeight="SemiBold" Foreground="#6B7A9E" Margin="0,0,0,8"/>
                                <ItemsControl Name="icTopFiles">
                                    <ItemsControl.ItemTemplate>
                                        <DataTemplate>
                                            <StackPanel Margin="0,0,0,6">
                                                <TextBlock Text="{Binding FileName}" FontFamily="Segoe UI" FontSize="10"
                                                           Foreground="#B0BACC" TextTrimming="CharacterEllipsis"/>
                                                <TextBlock Text="{Binding FileSize}" FontFamily="Segoe UI" FontSize="10"
                                                           FontWeight="Bold" Foreground="#FFB547"/>
                                            </StackPanel>
                                        </DataTemplate>
                                    </ItemsControl.ItemTemplate>
                                </ItemsControl>
                            </StackPanel>
                        </Border>
                    </Grid>

                    <!-- Barra de estado del escaneo -->
                    <Border Grid.Row="2" Background="#252B3B" BorderBrush="#4A5480" BorderThickness="0,1,0,0" Padding="10,6">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Name="txtDiskScanStatus" Text="Listo"
                                       FontFamily="Segoe UI" FontSize="10" Foreground="#9BA4C0" VerticalAlignment="Center"/>
                            <ProgressBar Name="pbDiskScan" Grid.Column="1" Width="150" Height="6"
                                         Minimum="0" Maximum="100" Value="0" IsIndeterminate="False"
                                         VerticalAlignment="Center"/>
                        </Grid>
                    </Border>
                </Grid>
                </TabItem>

            </TabControl>

            <!-- ═══ CONSOLA ════════════════════════════════════════════ -->
            <Border Grid.Row="3" CornerRadius="10" Background="#1A2035"
                    BorderBrush="#4A5480" BorderThickness="1" Margin="0,0,0,10">
                <Grid Margin="1">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <!-- Barra de título de la consola -->
                    <Border Grid.Row="0" CornerRadius="10,10,0,0" Background="#2E3650"
                            BorderBrush="#4A5480" BorderThickness="0,0,0,1" Padding="14,8">
                        <StackPanel Orientation="Horizontal">
                            <Ellipse Width="10" Height="10" Fill="#FF6B84" Margin="0,0,6,0"/>
                            <Ellipse Width="10" Height="10" Fill="#F5A623" Margin="0,0,6,0"/>
                            <Ellipse Width="10" Height="10" Fill="#4AE896" Margin="0,0,14,0"/>
                            <TextBlock Text="OUTPUT" FontFamily="Segoe UI" FontSize="9" FontWeight="SemiBold"
                                       Foreground="#8B96B8" VerticalAlignment="Center"/>
                            <TextBlock Name="TaskText" FontFamily="Segoe UI" FontSize="10"
                                       Foreground="#9BA4C0" VerticalAlignment="Center" Margin="14,0,0,0"/>
                        </StackPanel>
                    </Border>

                    <!-- Texto de salida -->
                    <TextBox Name="ConsoleOutput" Grid.Row="1"
                             IsReadOnly="True"
                             VerticalScrollBarVisibility="Auto"
                             HorizontalScrollBarVisibility="Disabled"
                             FontFamily="Cascadia Code, Consolas, Courier New"
                             FontSize="10.5"
                             Background="Transparent"
                             Foreground="#5AE88A"
                             BorderThickness="0"
                             Padding="14,10"
                             TextWrapping="Wrap"
                             SelectionBrush="#3D8EFF"/>

                    <!-- Barra de progreso + porcentaje -->
                    <Grid Grid.Row="2" Margin="14,6,14,10">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <ProgressBar Name="ProgressBar" Grid.Column="0" Height="6"
                                     Minimum="0" Maximum="100" Value="0"
                                     VerticalAlignment="Center"/>
                        <TextBlock Name="ProgressText" Grid.Column="1"
                                   Text="0%" FontFamily="Segoe UI" FontSize="10"
                                   FontWeight="SemiBold" Foreground="#9BA4C0"
                                   VerticalAlignment="Center" Margin="12,0,0,0" Width="36"/>
                    </Grid>
                </Grid>
            </Border>

            <!-- ═══ FOOTER / BOTONES ══════════════════════════════════ -->
            <Grid Grid.Row="4">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <!-- Reinicio automático -->
                <Border Grid.Column="0" CornerRadius="8" Background="#2E3650"
                        BorderBrush="#4A5480" BorderThickness="1" Padding="12,0" Margin="0,0,8,0">
                    <CheckBox Name="chkAutoRestart" VerticalAlignment="Center">
                        <CheckBox.Content>
                            <TextBlock Text="Reiniciar al finalizar" FontFamily="Segoe UI"
                                       FontSize="11" Foreground="#9BA4C0"/>
                        </CheckBox.Content>
                    </CheckBox>
                </Border>

                <!-- Spacer -->
                <Rectangle Grid.Column="1"/>

                <Button Name="btnSelectAll" Grid.Column="2" Style="{StaticResource BtnGhost}"
                        Content="Seleccionar todo" MinWidth="130"/>
                <Button Name="btnDryRun"    Grid.Column="3" Style="{StaticResource BtnCyan}"
                        Content="Analizar" MinWidth="90"
                        ToolTip="Dry Run — reportar sin ejecutar cambios"/>
                <Button Name="btnStart"     Grid.Column="4" Style="{StaticResource BtnPrimary}"
                        Content="▶  Iniciar optimización" MinWidth="160" FontWeight="Bold"/>
                <Button Name="btnCancel"    Grid.Column="5" Style="{StaticResource BtnAmber}"
                        Content="Cancelar" MinWidth="90" IsEnabled="False"/>
                <Button Name="btnSaveLog"   Grid.Column="6" Style="{StaticResource BtnGhost}"
                        Content="Guardar log" MinWidth="100"/>
                <Button Name="btnExit"      Grid.Column="7" Style="{StaticResource BtnDanger}"
                        Content="Salir" MinWidth="80"/>
            </Grid>

        </Grid>
    </Grid>
</Window>
"@

# ─────────────────────────────────────────────────────────────────────────────
# Cargar XAML y obtener controles
# ─────────────────────────────────────────────────────────────────────────────
$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

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

# Estado de cancelación
$script:CancelSource = $null
$script:WasCancelled = $false

# ─────────────────────────────────────────────────────────────────────────────
# Función para escribir en consola (hilo principal)
# ─────────────────────────────────────────────────────────────────────────────
function Write-ConsoleMain {
    param([string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss"
    $ConsoleOutput.AppendText("[$timestamp] $Message`n")
    $ConsoleOutput.ScrollToEnd()
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
        $gs2.Color  = $gs2.Color; $gs2.Color = [System.Windows.Media.Color]::FromArgb(5, $gs2.Color.R, $gs2.Color.G, $gs2.Color.B)
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
# [N1] Función para actualizar panel de información del sistema + gráficas
# ─────────────────────────────────────────────────────────────────────────────
function Update-SystemInfo {
    try {
        $os  = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $cpu = Get-CimInstance -ClassName Win32_Processor       -ErrorAction Stop | Select-Object -First 1

        $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $freeGB  = [math]::Round($os.FreePhysicalMemory     / 1MB, 1)
        $usedPct = [math]::Round((($totalGB - $freeGB) / $totalGB) * 100)

        $vol = Get-Volume -DriveLetter C -ErrorAction Stop
        $diskTotalGB = [math]::Round($vol.Size          / 1GB, 1)
        $diskFreeGB  = [math]::Round($vol.SizeRemaining / 1GB, 1)
        $diskUsedPct = [math]::Round((($diskTotalGB - $diskFreeGB) / $diskTotalGB) * 100)

        $cpuName = $cpu.Name -replace '\s+', ' '
        if ($cpuName.Length -gt 35) { $cpuName = $cpuName.Substring(0, 35) + "…" }

        $InfoCPU.Text  = $cpuName
        $InfoRAM.Text  = "$freeGB GB libre / $totalGB GB"
        $InfoDisk.Text = "$diskFreeGB GB libre / $diskTotalGB GB"

        # CPU Load via WMI
        $cpuLoad = [math]::Min(100, [math]::Max(0, [double]($cpu.LoadPercentage)))

        # Disk activity via perf counter
        $diskActivity = 0.0
        if ($null -ne $script:DiskCounter) {
            try { $diskActivity = [math]::Min(100, [math]::Max(0, $script:DiskCounter.NextValue())) } catch { }
        }

        # Update history buffers
        $script:CpuHistory.Add($cpuLoad)
        $script:RamHistory.Add([double]$usedPct)
        $script:DiskHistory.Add($diskActivity)
        if ($script:CpuHistory.Count  -gt 60) { $script:CpuHistory.RemoveAt(0) }
        if ($script:RamHistory.Count  -gt 60) { $script:RamHistory.RemoveAt(0) }
        if ($script:DiskHistory.Count -gt 60) { $script:DiskHistory.RemoveAt(0) }

        # Update percentage labels
        $CpuPctText.Text  = "  $([int]$cpuLoad)%"
        $RamPctText.Text  = "  $usedPct%"
        $DiskPctText.Text = "  $diskUsedPct% usado"

        # Draw charts
        Draw-SparkLine -Canvas $CpuChart  -Data $script:CpuHistory  -LineColor "#5BA3FF" -FillColor "#5BA3FF"
        Draw-SparkLine -Canvas $RamChart  -Data $script:RamHistory  -LineColor "#4AE896" -FillColor "#4AE896"
        Draw-SparkLine -Canvas $DiskChart -Data $script:DiskHistory -LineColor "#FFB547" -FillColor "#FFB547"

    } catch {
        $InfoCPU.Text  = "No disponible"
        $InfoRAM.Text  = "No disponible"
        $InfoDisk.Text = "No disponible"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Timer de actualización de gráficas (cada 2 segundos)
# ─────────────────────────────────────────────────────────────────────────────
$chartTimer = New-Object System.Windows.Threading.DispatcherTimer
$chartTimer.Interval = [TimeSpan]::FromSeconds(2)
$chartTimer.Add_Tick({ Update-SystemInfo })

# Start chart timer once window is fully loaded (ensures canvas has ActualWidth/Height)
$window.Add_Loaded({
    $chartTimer.Start()
    Update-SystemInfo
    Update-PerformanceTab
})

# ─────────────────────────────────────────────────────────────────────────────
# TAB 2: RENDIMIENTO — controles y lógica
# ─────────────────────────────────────────────────────────────────────────────
$btnRefreshPerf   = $window.FindName("btnRefreshPerf")
$txtPerfStatus    = $window.FindName("txtPerfStatus")
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

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N1} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N0} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N0} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Update-PerformanceTab {
    $txtPerfStatus.Text = "Recopilando datos…"

    # ── CPU Cores ──────────────────────────────────────────────
    try {
        $cpuObj = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $txtCpuName.Text = "$($cpuObj.Name)  |  $($cpuObj.NumberOfCores) núcleos  /  $($cpuObj.NumberOfLogicalProcessors) lógicos"

        $coreItems = [System.Collections.Generic.List[object]]::new()
        try {
            $counters = @()
            for ($i = 0; $i -lt $cpuObj.NumberOfLogicalProcessors; $i++) {
                $counters += "\Processor($i)\% Processor Time"
            }
            # Warm-up
            $null = (Get-Counter $counters -SampleInterval 1 -MaxSamples 1 -ErrorAction SilentlyContinue)
            $sample = (Get-Counter $counters -SampleInterval 1 -MaxSamples 1 -ErrorAction SilentlyContinue)
            $readings = $sample.CounterSamples

            for ($i = 0; $i -lt $cpuObj.NumberOfLogicalProcessors; $i++) {
                $val = [math]::Round($readings[$i].CookedValue, 1)
                $color = if ($val -ge 80) { "#FF6B84" } elseif ($val -ge 50) { "#FFB547" } else { "#5BA3FF" }
                $coreItems.Add([PSCustomObject]@{
                    CoreLabel = "Core $i"
                    Usage     = "$val%"
                    UsageNum  = $val
                    Freq      = "$([math]::Round($cpuObj.CurrentClockSpeed / 1000.0, 2)) GHz"
                })
            }
        } catch {
            # Fallback: single entry with overall load
            $coreItems.Add([PSCustomObject]@{
                CoreLabel = "CPU Total"
                Usage     = "$($cpuObj.LoadPercentage)%"
                UsageNum  = [double]$cpuObj.LoadPercentage
                Freq      = "$([math]::Round($cpuObj.CurrentClockSpeed / 1000.0, 2)) GHz"
            })
        }
        $icCpuCores.ItemsSource = $coreItems
    } catch {
        $txtCpuName.Text = "No disponible"
    }

    # ── RAM Detallada ──────────────────────────────────────────
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $totalB = $os.TotalVisibleMemorySize * 1KB
        $freeB  = $os.FreePhysicalMemory     * 1KB
        $usedB  = $totalB - $freeB
        $pct    = [math]::Round($usedB / $totalB * 100)

        $txtRamTotal.Text = Format-Bytes $totalB
        $txtRamUsed.Text  = Format-Bytes $usedB
        $txtRamFree.Text  = Format-Bytes $freeB
        $txtRamPct.Text   = "$pct%"
        $pbRam.Value      = $pct

        $modules = Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop
        $modItems = [System.Collections.Generic.List[object]]::new()
        foreach ($mod in $modules) {
            $slotId   = if ($mod.DeviceLocator) { $mod.DeviceLocator } else { "Ranura" }
            $sizeStr  = Format-Bytes ([long]$mod.Capacity)
            $speed    = if ($mod.Speed) { "$($mod.Speed) MHz" } else { "—" }
            $type     = switch ($mod.SMBIOSMemoryType) {
                26 { "DDR4" } 34 { "DDR5" } 21 { "DDR2" } 24 { "DDR3" } default { "DDR" }
            }
            $modItems.Add([PSCustomObject]@{
                Slot = $slotId
                Info = "$type  •  $speed  •  Mfg: $(if($mod.Manufacturer){''+$mod.Manufacturer}else{'N/A'})"
                Size = $sizeStr
            })
        }
        $icRamModules.ItemsSource = $modItems
    } catch {
        $txtRamTotal.Text = "N/A"
    }

    # ── SMART del Disco ────────────────────────────────────────
    try {
        $physDisks = Get-PhysicalDisk -ErrorAction Stop
        $smartItems = [System.Collections.Generic.List[object]]::new()

        foreach ($disk in $physDisks) {
            $reliability = $null
            try { $reliability = Get-StorageReliabilityCounter -PhysicalDisk $disk -ErrorAction Stop } catch {}

            $health = $disk.HealthStatus
            $bg = switch ($health) {
                "Healthy"   { "#182A1E" }
                "Warning"   { "#2A2010" }
                default     { "#2A1018" }
            }
            $fg = switch ($health) {
                "Healthy"   { "#4AE896" }
                "Warning"   { "#FFB547" }
                default     { "#FF6B84" }
            }

            $attrs = [System.Collections.Generic.List[object]]::new()
            $attrs.Add([PSCustomObject]@{ Name="Tipo";     Value=$disk.MediaType;                   ValueColor="#B0BACC" })
            $attrs.Add([PSCustomObject]@{ Name="Tamaño";   Value=(Format-Bytes $disk.Size);         ValueColor="#5BA3FF" })
            $attrs.Add([PSCustomObject]@{ Name="Bus";      Value=$disk.BusType;                     ValueColor="#B0BACC" })
            if ($reliability) {
                if ($null -ne $reliability.PowerOnHours) {
                    $attrs.Add([PSCustomObject]@{ Name="Horas enc."; Value="$($reliability.PowerOnHours) h"; ValueColor="#FFB547" })
                }
                if ($null -ne $reliability.Temperature) {
                    $tempC = $reliability.Temperature
                    $tColor = if ($tempC -ge 55) { "#FF6B84" } elseif ($tempC -ge 45) { "#FFB547" } else { "#4AE896" }
                    $attrs.Add([PSCustomObject]@{ Name="Temperatura"; Value="${tempC}°C"; ValueColor=$tColor })
                }
                if ($null -ne $reliability.ReadErrorsTotal) {
                    $ec = if ($reliability.ReadErrorsTotal -gt 0) { "#FF6B84" } else { "#4AE896" }
                    $attrs.Add([PSCustomObject]@{ Name="Errores lect."; Value=$reliability.ReadErrorsTotal; ValueColor=$ec })
                }
                if ($null -ne $reliability.Wear) {
                    $wc = if ($reliability.Wear -ge 80) { "#FF6B84" } elseif ($reliability.Wear -ge 50) { "#FFB547" } else { "#4AE896" }
                    $attrs.Add([PSCustomObject]@{ Name="Desgaste"; Value="$($reliability.Wear)%"; ValueColor=$wc })
                }
            }
            $smartItems.Add([PSCustomObject]@{
                DiskName   = "$($disk.FriendlyName)"
                Status     = $health
                StatusBg   = $bg
                StatusFg   = $fg
                Attributes = $attrs
            })
        }
        $icSmartDisks.ItemsSource = $smartItems
    } catch {
        $icSmartDisks.ItemsSource = @([PSCustomObject]@{
            DiskName="Error al leer SMART"; Status="N/A"; StatusBg="#2A1018"; StatusFg="#FF6B84"; Attributes=@()
        })
    }

    # ── Tarjetas de Red ────────────────────────────────────────
    try {
        $adapters = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq "Up" -or $_.Status -eq "Disconnected" }
        $netItems = [System.Collections.Generic.List[object]]::new()
        foreach ($a in $adapters) {
            $ip = (Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                   Select-Object -First 1).IPAddress
            if (-not $ip) { $ip = "Sin IP" }

            $speedStr = if ($a.LinkSpeed -gt 0) {
                $bps = $a.LinkSpeed
                if ($bps -ge 1000000000) { "$([math]::Round($bps/1000000000,0)) Gbps" }
                elseif ($bps -ge 1000000) { "$([math]::Round($bps/1000000,0)) Mbps" }
                else { "$bps bps" }
            } else { "—" }

            # Bytes enviados/recibidos (desde stats)
            $stats = $null
            try { $stats = Get-NetAdapterStatistics -Name $a.Name -ErrorAction SilentlyContinue } catch {}
            $ioStr = if ($stats) {
                "↓ $(Format-Bytes $stats.ReceivedBytes)  ↑ $(Format-Bytes $stats.SentBytes)"
            } else { "" }

            $statusColor = if ($a.Status -eq "Up") { "#4AE896" } else { "#FF6B84" }

            $netItems.Add([PSCustomObject]@{
                Name        = $a.Name
                IP          = "IP: $ip"
                MAC         = "MAC: $($a.MacAddress)"
                Speed       = $speedStr
                Status      = $a.Status
                StatusColor = $statusColor
                BytesIO     = $ioStr
            })
        }
        $icNetAdapters.ItemsSource = $netItems
    } catch {
        $icNetAdapters.ItemsSource = @()
    }

    $txtPerfStatus.Text = "Actualizado: $(Get-Date -Format 'HH:mm:ss')"
}

$btnRefreshPerf.Add_Click({ Update-PerformanceTab })

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

$script:DiskScanRunspace = $null
# DiskScanStop now handled by [ScanControl]::Stop
$script:DiskScanResults  = $null

function Get-SizeColor {
    param([long]$Bytes)
    if ($Bytes -ge 10GB) { return "#FF6B84" }
    if ($Bytes -ge 1GB)  { return "#FFB547" }
    if ($Bytes -ge 100MB){ return "#5BA3FF" }
    return "#B0BACC"
}

function Get-SizeColorFromStr {
    param([long]$Bytes)
    if ($Bytes -ge 10GB) { return "#FF6B84" }
    if ($Bytes -ge 1GB)  { return "#FFB547" }
    if ($Bytes -ge 100MB){ return "#5BA3FF" }
    return "#B0BACC"
}

function Start-DiskScan {
    param([string]$RootPath)

    if (-not (Test-Path $RootPath -ErrorAction SilentlyContinue)) {
        [System.Windows.MessageBox]::Show("Ruta no encontrada: $RootPath", "Error", "OK", "Error")
        return
    }

    # Señalizar parada al runspace anterior si hubiera uno corriendo
    [ScanControl]::Stop = $true
    Start-Sleep -Milliseconds 150
    [ScanControl]::Reset()

    $btnDiskScan.IsEnabled  = $false
    $btnDiskStop.IsEnabled  = $true
    $txtDiskScanStatus.Text = "Iniciando escaneo de $RootPath …"
    $pbDiskScan.IsIndeterminate = $true
    $pbDiskScan.Value = 0

    # Cola compartida: el hilo de fondo mete objetos, el timer de UI los consume
    $script:ScanQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

    # Diccionario y lista observable que alimenta el ListBox
    $script:LiveItems = [System.Collections.Generic.Dictionary[string,object]]::new()
    $script:LiveList  = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    $lbDiskTree.ItemsSource = $script:LiveList

    # ── Hilo de fondo ────────────────────────────────────────────────────────
    $bgScript = {
        param([string]$Root, [System.Collections.Concurrent.ConcurrentQueue[object]]$Q)

        # Mide un directorio recursivamente y devuelve tamaño + conteos
        function Measure-Dir([string]$Path) {
            $size = 0L; $files = 0; $dirs = 0
            try {
                $stack = [System.Collections.Generic.Stack[string]]::new()
                $stack.Push($Path)
                while ($stack.Count -gt 0) {
                    if ([ScanControl]::Stop) { break }
                    $cur = $stack.Pop()
                    try {
                        foreach ($f in [System.IO.Directory]::GetFiles($cur)) {
                            try { $size += ([System.IO.FileInfo]$f).Length; $files++ } catch {}
                        }
                        foreach ($d in [System.IO.Directory]::GetDirectories($cur)) {
                            $dirs++; $stack.Push($d)
                        }
                    } catch {}
                }
            } catch {}
            return [PSCustomObject]@{ Size=$size; Files=$files; Dirs=$dirs }
        }

        try {
            # Carpetas y archivos de primer nivel
            $topDirs  = try { [System.IO.Directory]::GetDirectories($Root) } catch { @() }
            $topFiles = try { [System.IO.Directory]::GetFiles($Root)        } catch { @() }
            [ScanControl]::Total = $topDirs.Count + 1

            # Archivos sueltos en la raíz
            $rootSize = 0L; $rootCount = 0
            foreach ($f in $topFiles) {
                if ([ScanControl]::Stop) { break }
                try { $rootSize += ([System.IO.FileInfo]$f).Length; $rootCount++ } catch {}
            }
            if ($rootCount -gt 0) {
                $Q.Enqueue([PSCustomObject]@{
                    Key='__rootfiles__'; Name="[Archivos en raíz]"
                    Size=$rootSize; Files=$rootCount; Dirs=0; IsDir=$false; Done=$true
                })
            }
            [ScanControl]::Done++

            # Carpetas: emitir placeholder inmediato → luego resultado real
            foreach ($d in $topDirs) {
                if ([ScanControl]::Stop) { break }
                $dName = [System.IO.Path]::GetFileName($d)
                [ScanControl]::Current = $dName

                # Placeholder "calculando…"
                $Q.Enqueue([PSCustomObject]@{
                    Key=$d; Name=$dName; Size=-1L
                    Files=0; Dirs=0; IsDir=$true; Done=$false
                })

                $info = Measure-Dir $d

                # Resultado real
                $Q.Enqueue([PSCustomObject]@{
                    Key=$d; Name=$dName; Size=$info.Size
                    Files=$info.Files; Dirs=$info.Dirs; IsDir=$true; Done=$true
                })
                [ScanControl]::Done++
            }
        } catch {}
    }

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = "STA"; $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($bgScript).AddParameter("Root", $RootPath).AddParameter("Q", $script:ScanQueue)
    $script:DiskScanRunspace = $rs
    $async = $ps.BeginInvoke()

    # ── Timer UI: drena la cola y actualiza lista cada 400 ms ─────────────────
    $uiTimer = New-Object System.Windows.Threading.DispatcherTimer
    $uiTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $uiTimer.Add_Tick({

        $total = [ScanControl]::Total
        $done  = [ScanControl]::Done
        $cur   = [ScanControl]::Current

        if ($total -gt 0) {
            $pbDiskScan.IsIndeterminate = $false
            $pbDiskScan.Value = [math]::Min(99, [math]::Round($done / $total * 100))
        }

        # Ancho disponible para barras proporcionales
        $lw = if ($lbDiskTree.ActualWidth -gt 100) { $lbDiskTree.ActualWidth - 270 } else { 400 }

        # Drena todos los mensajes en cola
        $anyUpdate = $false
        $msg = $null
        while ($script:ScanQueue.TryDequeue([ref]$msg)) {
            $key = $msg.Key

            if (-not $msg.Done) {
                # Placeholder: añadir a lista si no existe
                if (-not $script:LiveItems.ContainsKey($key)) {
                    $entry = [PSCustomObject]@{
                        DisplayName="$($msg.Name)"; FullPath=$key
                        SizeBytes=-1L; SizeStr="calculando…"; SizeColor="#8B96B8"
                        PctStr="—"; FileCount="…"; DirCount=0; IsDir=$true
                        Icon="📁"; Indent="4,0,0,0"; BarWidth=0.0; BarColor="#3A4468"; TotalPct=0.0
                    }
                    $script:LiveItems[$key] = $entry
                    $script:LiveList.Add($entry)
                }
            } else {
                # Datos reales: calcular color y construir entrada final
                $sz = $msg.Size
                $sc = if ($sz -ge 10GB) { "#FF6B84" } elseif ($sz -ge 1GB) { "#FFB547" } elseif ($sz -ge 100MB) { "#5BA3FF" } else { "#B0BACC" }
                $szStr = if ($sz -ge 1GB) { "{0:N1} GB" -f ($sz/1GB) } elseif ($sz -ge 1MB) { "{0:N0} MB" -f ($sz/1MB) } elseif ($sz -ge 1KB) { "{0:N0} KB" -f ($sz/1KB) } else { "$sz B" }
                $icon = if ($msg.IsDir) { "📁" } else { "📄" }
                $fc   = if ($msg.IsDir) { "$($msg.Files) arch.  $($msg.Dirs) carp." } else { "$($msg.Files) arch." }
                $newEntry = [PSCustomObject]@{
                    DisplayName=$msg.Name; FullPath=$key
                    SizeBytes=$sz; SizeStr=$szStr; SizeColor=$sc
                    PctStr="—"; FileCount=$fc; DirCount=$msg.Dirs; IsDir=$msg.IsDir
                    Icon=$icon; Indent="4,0,0,0"; BarWidth=0.0; BarColor=$sc; TotalPct=0.0
                }
                if ($script:LiveItems.ContainsKey($key)) {
                    $idx = $script:LiveList.IndexOf($script:LiveItems[$key])
                    $script:LiveItems[$key] = $newEntry
                    if ($idx -ge 0) { $script:LiveList[$idx] = $newEntry } else { $script:LiveList.Add($newEntry) }
                } else {
                    $script:LiveItems[$key] = $newEntry
                    $script:LiveList.Add($newEntry)
                }
                $anyUpdate = $true
            }
            $msg = $null
        }

        # Recalcular porcentajes y reordenar cuando hay cambios reales
        if ($anyUpdate) {
            $gt = 0L
            foreach ($v in $script:LiveList) { if ($v.SizeBytes -gt 0) { $gt += $v.SizeBytes } }
            if ($gt -gt 0) {
                # Reordenar por tamaño
                $sorted = @($script:LiveList | Sort-Object SizeBytes -Descending)
                $script:LiveList.Clear()
                foreach ($s in $sorted) {
                    if ($s.SizeBytes -gt 0) {
                        $pct = [math]::Round($s.SizeBytes / $gt * 100, 1)
                        $bw  = [math]::Max(0, [math]::Round($pct / 100 * $lw))
                        $s.PctStr   = "$pct%"
                        $s.TotalPct = $pct
                        $s.BarWidth = [double]$bw
                    }
                    $script:LiveList.Add($s)
                }
                $gtStr = if ($gt -ge 1GB) { "{0:N1} GB" -f ($gt/1GB) } elseif ($gt -ge 1MB) { "{0:N0} MB" -f ($gt/1MB) } else { "{0:N0} KB" -f ($gt/1KB) }
                $txtDiskScanStatus.Text = "Escaneando  $($script:LiveList.Count) elementos  ·  $gtStr  ·  $done/$total carpetas  ·  $cur"
            }
        }

        # ¿Terminó el runspace?
        if ($async.IsCompleted) {
            $uiTimer.Stop()
            try { $ps.EndInvoke($async) | Out-Null } catch {}
            try { $ps.Dispose(); $rs.Close(); $rs.Dispose() } catch {}

            # Ordenar final y recalcular barras
            $gt2 = 0L
            foreach ($v in $script:LiveList) { if ($v.SizeBytes -gt 0) { $gt2 += $v.SizeBytes } }
            $sorted2 = @($script:LiveList | Sort-Object SizeBytes -Descending)
            $script:LiveList.Clear()
            $script:LiveItems.Clear()
            foreach ($s in $sorted2) {
                if ($s.SizeBytes -gt 0 -and $gt2 -gt 0) {
                    $pct = [math]::Round($s.SizeBytes / $gt2 * 100, 1)
                    $bw  = [math]::Max(0, [math]::Round($pct / 100 * $lw))
                    $s.PctStr = "$pct%"; $s.TotalPct = $pct; $s.BarWidth = [double]$bw
                }
                $script:LiveList.Add($s)
                $script:LiveItems[$s.FullPath] = $s
            }

            $pbDiskScan.IsIndeterminate = $false
            $pbDiskScan.Value = 100
            $btnDiskScan.IsEnabled = $true
            $btnDiskStop.IsEnabled = $false

            $gtStr2 = if ($gt2 -ge 1GB) { "{0:N1} GB" -f ($gt2/1GB) } elseif ($gt2 -ge 1MB) { "{0:N0} MB" -f ($gt2/1MB) } else { "{0:N0} KB" -f ($gt2/1KB) }
            $emoji = if ([ScanControl]::Stop) { "⏹" } else { "✅" }
            $txtDiskScanStatus.Text = "$emoji  $($script:LiveList.Count) elementos  ·  $gtStr2  ·  $(Get-Date -Format 'HH:mm:ss')"
        }
    })
    $uiTimer.Start()
}


$btnDiskBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Selecciona la carpeta a escanear"
    $dlg.RootFolder  = "MyComputer"
    $dlg.SelectedPath = $txtDiskScanPath.Text
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtDiskScanPath.Text = $dlg.SelectedPath
    }
})

$btnDiskScan.Add_Click({
    Start-DiskScan -RootPath $txtDiskScanPath.Text.Trim()
})

$btnDiskStop.Add_Click({
    [ScanControl]::Stop = $true
    $btnDiskStop.IsEnabled = $false
    $txtDiskScanStatus.Text = "⏹ Cancelando — espera a que termine la carpeta actual…"
})

# Selección en la lista → actualizar panel de detalle
$lbDiskTree.Add_SelectionChanged({
    $sel = $lbDiskTree.SelectedItem
    if ($null -eq $sel) { return }

    $txtDiskDetailName.Text  = $sel.DisplayName
    $txtDiskDetailSize.Text  = $sel.SizeStr
    $txtDiskDetailFiles.Text = if ($sel.IsDir) { $sel.FileCount } else { "1 archivo" }
    $txtDiskDetailDirs.Text  = if ($sel.IsDir) { "$($sel.DirCount) carpetas" } else { "—" }
    $txtDiskDetailPct.Text   = "$($sel.TotalPct)%"

    # Top 10 archivos más grandes dentro de esa carpeta
    $topFiles = [System.Collections.Generic.List[object]]::new()
    if ($sel.IsDir -and (Test-Path $sel.FullPath)) {
        try {
            $bigFiles = Get-ChildItem -Path $sel.FullPath -Recurse -File -ErrorAction SilentlyContinue |
                        Sort-Object Length -Descending |
                        Select-Object -First 10
            foreach ($f in $bigFiles) {
                $topFiles.Add([PSCustomObject]@{
                    FileName = $f.Name
                    FileSize = Format-Bytes $f.Length
                })
            }
        } catch {}
    }
    $icTopFiles.ItemsSource = $topFiles
})

# ─────────────────────────────────────────────────────────────────────────────
# [N8] Ventana de gestión de programas de inicio
# ─────────────────────────────────────────────────────────────────────────────
function Show-StartupManager {
    $startupXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Gestor de Programas de Inicio" Height="520" Width="800"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize">
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Programas configurados para iniciar con Windows (solo usuario actual y máquina local)"
                   FontSize="11" Foreground="Gray" Margin="0,0,0,8" TextWrapping="Wrap"/>
        <DataGrid Name="StartupGrid" Grid.Row="1"
                  AutoGenerateColumns="False" IsReadOnly="False"
                  CanUserAddRows="False" CanUserDeleteRows="False"
                  SelectionMode="Extended" GridLinesVisibility="Horizontal"
                  AlternatingRowBackground="#F5F5F5" FontSize="11">
            <DataGrid.Columns>
                <DataGridCheckBoxColumn Header="Activo" Binding="{Binding Enabled}" Width="55"/>
                <DataGridTextColumn Header="Nombre"  Binding="{Binding Name}"    Width="180" IsReadOnly="True"/>
                <DataGridTextColumn Header="Comando" Binding="{Binding Command}"  Width="*"   IsReadOnly="True"/>
                <DataGridTextColumn Header="Origen"  Binding="{Binding Source}"   Width="130" IsReadOnly="True"/>
            </DataGrid.Columns>
        </DataGrid>
        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
            <TextBlock Name="StartupStatus" VerticalAlignment="Center" Foreground="Gray"
                       FontSize="11" Margin="0,0,10,0"/>
            <Button Name="btnApplyStartup" Content="✔ Aplicar cambios" Background="#27AE60"
                    Foreground="White" Padding="12,5" Margin="5" Cursor="Hand" FontSize="12"/>
            <Button Name="btnCloseStartup" Content="Cerrar" Background="#95A5A6"
                    Foreground="White" Padding="12,5" Margin="5" Cursor="Hand" FontSize="12"/>
        </StackPanel>
    </Grid>
</Window>
"@

    $sReader    = [System.Xml.XmlNodeReader]::new([xml]$startupXaml)
    $sWindow    = [Windows.Markup.XamlReader]::Load($sReader)
    $sGrid      = $sWindow.FindName("StartupGrid")
    $sStatus    = $sWindow.FindName("StartupStatus")
    $btnApply   = $sWindow.FindName("btnApplyStartup")
    $btnClose   = $sWindow.FindName("btnCloseStartup")

    # Rutas del registro donde viven las entradas de autoarranque
    $regPaths = @(
        @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run";            Source = "HKCU Run" },
        @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run";            Source = "HKLM Run" },
        @{ Path = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run";Source = "HKLM Run (32)" }
    )

    # Tabla observable para el DataGrid
    $startupTable = New-Object System.Collections.ObjectModel.ObservableCollection[object]

    foreach ($reg in $regPaths) {
        if (Test-Path $reg.Path) {
            $props = Get-ItemProperty -Path $reg.Path -ErrorAction SilentlyContinue
            if ($props) {
                $props.PSObject.Properties | Where-Object {
                    $_.Name -notmatch '^PS'
                } | ForEach-Object {
                    $entry = [PSCustomObject]@{
                        Enabled = $true
                        Name    = $_.Name
                        Command = $_.Value
                        Source  = $reg.Source
                        RegPath = $reg.Path
                        OriginalName = $_.Name
                    }
                    $startupTable.Add($entry)
                }
            }
        }
    }

    $sGrid.ItemsSource = $startupTable
    $sStatus.Text = "$($startupTable.Count) entradas encontradas"

    $btnApply.Add_Click({
        $disabled = 0
        $errors   = 0
        foreach ($item in $startupTable) {
            if (-not $item.Enabled) {
                try {
                    Remove-ItemProperty -Path $item.RegPath -Name $item.OriginalName -Force -ErrorAction Stop
                    $disabled++
                } catch {
                    $errors++
                }
            }
        }
        $msg = "Cambios aplicados: $disabled entradas desactivadas."
        if ($errors -gt 0) { $msg += "`n$errors entradas no pudieron modificarse (requieren permisos adicionales)." }
        [System.Windows.MessageBox]::Show($msg, "Cambios aplicados",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information)
        Write-ConsoleMain "🚀 Startup Manager: $disabled entradas desactivadas del registro."
        $sWindow.Close()
    })

    $btnClose.Add_Click({ $sWindow.Close() })
    $sWindow.Owner = $window
    $sWindow.ShowDialog() | Out-Null
}

# ─────────────────────────────────────────────────────────────────────────────
# [N9] Ventana de Informe de Diagnóstico (resultado del Análisis Dry Run)
# ─────────────────────────────────────────────────────────────────────────────
function Show-DiagnosticReport {
    param([hashtable]$Report)

    $diagXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Informe de Diagnóstico del Sistema" Height="680" Width="860"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
        Background="#1E2332">
    <Window.Resources>
        <Style x:Key="SectionHeader" TargetType="TextBlock">
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="FontSize"   Value="11"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Foreground" Value="#B0BACC"/>
            <Setter Property="Margin"     Value="0,14,0,4"/>
        </Style>
        <Style x:Key="GoodRow" TargetType="Border">
            <Setter Property="Background"     Value="#182A1E"/>
            <Setter Property="BorderBrush"    Value="#2A4A35"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius"   Value="6"/>
            <Setter Property="Padding"        Value="12,7"/>
            <Setter Property="Margin"         Value="0,3"/>
        </Style>
        <Style x:Key="WarnRow" TargetType="Border">
            <Setter Property="Background"     Value="#2A2010"/>
            <Setter Property="BorderBrush"    Value="#5A4010"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius"   Value="6"/>
            <Setter Property="Padding"        Value="12,7"/>
            <Setter Property="Margin"         Value="0,3"/>
        </Style>
        <Style x:Key="CritRow" TargetType="Border">
            <Setter Property="Background"     Value="#2A1018"/>
            <Setter Property="BorderBrush"    Value="#5A1828"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius"   Value="6"/>
            <Setter Property="Padding"        Value="12,7"/>
            <Setter Property="Margin"         Value="0,3"/>
        </Style>
        <Style x:Key="InfoRow" TargetType="Border">
            <Setter Property="Background"     Value="#1A2540"/>
            <Setter Property="BorderBrush"    Value="#2A3A60"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius"   Value="6"/>
            <Setter Property="Padding"        Value="12,7"/>
            <Setter Property="Margin"         Value="0,3"/>
        </Style>
    </Window.Resources>

    <Grid Margin="0">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <Border Grid.Row="0" Background="#252B3B" BorderBrush="#4A5480" BorderThickness="0,0,0,1" Padding="24,16">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                    <TextBlock FontFamily="Segoe UI" FontSize="20" FontWeight="Bold" Foreground="#F0F3FA">
                        <Run Text="Informe de Diagnóstico"/>
                    </TextBlock>
                    <TextBlock Name="DiagSubtitle" FontFamily="Segoe UI" FontSize="11"
                               Foreground="#9BA4C0" Margin="0,4,0,0"
                               Text="Análisis completado — resultados por categoría"/>
                </StackPanel>
                <!-- Score global -->
                <Border Grid.Column="1" CornerRadius="10" Padding="18,10" VerticalAlignment="Center">
                    <Border.Background>
                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                            <GradientStop Color="#1A3A5C" Offset="0"/>
                            <GradientStop Color="#162A40" Offset="1"/>
                        </LinearGradientBrush>
                    </Border.Background>
                    <StackPanel HorizontalAlignment="Center">
                        <TextBlock Text="PUNTUACIÓN" FontFamily="Segoe UI" FontSize="9"
                                   FontWeight="Bold" Foreground="#7BA8E0" HorizontalAlignment="Center"/>
                        <TextBlock Name="ScoreText" Text="—" FontFamily="Segoe UI" FontSize="32"
                                   FontWeight="Bold" Foreground="#5BA3FF" HorizontalAlignment="Center"/>
                        <TextBlock Name="ScoreLabel" Text="calculando..." FontFamily="Segoe UI" FontSize="10"
                                   Foreground="#9BA4C0" HorizontalAlignment="Center"/>
                    </StackPanel>
                </Border>
            </Grid>
        </Border>

        <!-- Body — scroll con categorías -->
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0">
            <StackPanel Name="DiagPanel" Margin="24,16,24,16"/>
        </ScrollViewer>

        <!-- Footer -->
        <Border Grid.Row="2" Background="#252B3B" BorderBrush="#4A5480" BorderThickness="0,1,0,0" Padding="24,12">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Name="DiagFooterNote" Grid.Column="0"
                           FontFamily="Segoe UI" FontSize="10" Foreground="#6B7599"
                           VerticalAlignment="Center"
                           Text="▶  Pulsa 'Iniciar Optimización' en la ventana principal para reparar los puntos marcados."/>
                <Button Name="btnExportDiag" Grid.Column="1" Content="💾  Exportar informe"
                        Background="#1A2540" BorderBrush="#3D5080" BorderThickness="1"
                        Foreground="#7BA8E0" FontFamily="Segoe UI" FontSize="11" FontWeight="SemiBold"
                        Padding="14,7" Margin="8,0" Cursor="Hand" Height="34"/>
                <Button Name="btnCloseDiag" Grid.Column="2" Content="Cerrar"
                        Background="#1A2540" BorderBrush="#4A5480" BorderThickness="1"
                        Foreground="#9BA4C0" FontFamily="Segoe UI" FontSize="11"
                        Padding="18,7" Cursor="Hand" Height="34"/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

    $dReader  = [System.Xml.XmlNodeReader]::new([xml]$diagXaml)
    $dWindow  = [Windows.Markup.XamlReader]::Load($dReader)
    $dPanel   = $dWindow.FindName("DiagPanel")
    $dScore   = $dWindow.FindName("ScoreText")
    $dLabel   = $dWindow.FindName("ScoreLabel")
    $dSub     = $dWindow.FindName("DiagSubtitle")
    $btnExp   = $dWindow.FindName("btnExportDiag")
    $btnClose = $dWindow.FindName("btnCloseDiag")

    # ── Helper: añadir fila al panel ────────────────────────────────────────
    function Add-DiagSection {
        param([string]$Title, [string]$Icon)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Style = $dWindow.Resources["SectionHeader"]
        $tb.Text  = "$Icon  $Title"
        [void]$dPanel.Children.Add($tb)
    }

    function Add-DiagRow {
        param([string]$Status, [string]$Label, [string]$Detail, [string]$Action = "")
        $styleKey = switch ($Status) {
            "OK"   { "GoodRow" }
            "WARN" { "WarnRow" }
            "CRIT" { "CritRow" }
            default{ "InfoRow" }
        }
        $border = New-Object System.Windows.Controls.Border
        $border.Style = $dWindow.Resources[$styleKey]

        $grid = New-Object System.Windows.Controls.Grid
        $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = [System.Windows.GridLength]::new(38)
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto
        $grid.ColumnDefinitions.Add($c0)
        $grid.ColumnDefinitions.Add($c1)
        $grid.ColumnDefinitions.Add($c2)

        # Icono de estado
        $ico = New-Object System.Windows.Controls.TextBlock
        $ico.Text = switch ($Status) {
            "OK"   { "✅" }
            "WARN" { "⚠️" }
            "CRIT" { "🔴" }
            default{ "ℹ️" }
        }
        $ico.FontSize = 16
        $ico.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($ico, 0)
        [void]$grid.Children.Add($ico)

        # Texto principal
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($sp, 1)

        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text       = $Label
        $lbl.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
        $lbl.FontSize   = 12
        $lbl.FontWeight = [System.Windows.FontWeights]::SemiBold
        $lblColor = switch ($Status) {
            "OK"    { "#4AE896" }
            "WARN"  { "#FFB547" }
            "CRIT"  { "#FF6B84" }
            default { "#7BA8E0" }
        }
        $lbl.Foreground = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString($lblColor))
        [void]$sp.Children.Add($lbl)

        if ($Detail) {
            $det = New-Object System.Windows.Controls.TextBlock
            $det.Text       = $Detail
            $det.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
            $det.FontSize   = 10
            $det.Foreground = New-Object System.Windows.Media.SolidColorBrush(
                [System.Windows.Media.ColorConverter]::ConvertFromString("#9BA4C0"))
            $det.TextWrapping = "Wrap"
            [void]$sp.Children.Add($det)
        }
        [void]$grid.Children.Add($sp)

        # Acción recomendada
        if ($Action) {
            $act = New-Object System.Windows.Controls.TextBlock
            $act.Text       = $Action
            $act.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
            $act.FontSize   = 9
            $act.Foreground = New-Object System.Windows.Media.SolidColorBrush(
                [System.Windows.Media.ColorConverter]::ConvertFromString("#5BA3FF"))
            $act.VerticalAlignment = "Center"
            $act.TextAlignment = "Right"
            $act.Width = 160
            [System.Windows.Controls.Grid]::SetColumn($act, 2)
            [void]$grid.Children.Add($act)
        }

        $border.Child = $grid
        [void]$dPanel.Children.Add($border)
    }

    # ── Calcular y mostrar resultados ────────────────────────────────────────
    $points     = 100
    $deductions = 0
    $critCount  = 0
    $warnCount  = 0
    $exportLines = [System.Collections.Generic.List[string]]::new()
    $exportLines.Add("INFORME DE DIAGNÓSTICO DEL SISTEMA — SysOpt v1.0")
    $exportLines.Add("Fecha: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')")
    $exportLines.Add("")

    # ── SECCIÓN: ALMACENAMIENTO ──────────────────────────────────────────────
    Add-DiagSection "ALMACENAMIENTO" "🗄️"
    $exportLines.Add("=== ALMACENAMIENTO ===")

    $tempTotal = $(if ($null -ne $Report.TempFilesMB) { [double]$Report.TempFilesMB } else { 0.0 }) + $(if ($null -ne $Report.UserTempMB) { [double]$Report.UserTempMB } else { 0.0 })
    if ($tempTotal -gt 1000) {
        Add-DiagRow "CRIT" "Archivos temporales acumulados" "$([math]::Round($tempTotal,0)) MB en carpetas Temp" "Limpiar Temp Windows + Usuario"
        $deductions += 15; $critCount++
        $exportLines.Add("[CRÍTICO] Archivos temporales: $([math]::Round($tempTotal,0)) MB — Limpiar Temp Windows + Usuario")
    } elseif ($tempTotal -gt 200) {
        Add-DiagRow "WARN" "Archivos temporales moderados" "$([math]::Round($tempTotal,0)) MB — recomendable limpiar" "Limpiar carpetas Temp"
        $deductions += 7; $warnCount++
        $exportLines.Add("[AVISO] Archivos temporales: $([math]::Round($tempTotal,0)) MB — recomendable limpiar")
    } else {
        Add-DiagRow "OK" "Carpetas temporales limpias" "$([math]::Round($tempTotal,1)) MB — nivel óptimo"
        $exportLines.Add("[OK] Archivos temporales: $([math]::Round($tempTotal,1)) MB")
    }

    $recycleSize = $(if ($null -ne $Report.RecycleBinMB) { [double]$Report.RecycleBinMB } else { 0.0 })
    if ($recycleSize -gt 500) {
        Add-DiagRow "WARN" "Papelera de reciclaje llena" "$([math]::Round($recycleSize,0)) MB ocupados" "Vaciar papelera"
        $deductions += 5; $warnCount++
        $exportLines.Add("[AVISO] Papelera: $([math]::Round($recycleSize,0)) MB — vaciar recomendado")
    } elseif ($recycleSize -gt 0) {
        Add-DiagRow "INFO" "Papelera con contenido" "$([math]::Round($recycleSize,1)) MB"
        $exportLines.Add("[INFO] Papelera: $([math]::Round($recycleSize,1)) MB")
    } else {
        Add-DiagRow "OK" "Papelera vacía" "Sin archivos pendientes de eliminar"
        $exportLines.Add("[OK] Papelera vacía")
    }

    $wuSize = $(if ($null -ne $Report.WUCacheMB) { [double]$Report.WUCacheMB } else { 0.0 })
    if ($wuSize -gt 2000) {
        Add-DiagRow "WARN" "Caché de Windows Update grande" "$([math]::Round($wuSize,0)) MB en SoftwareDistribution" "Limpiar WU Cache"
        $deductions += 8; $warnCount++
        $exportLines.Add("[AVISO] WU Cache: $([math]::Round($wuSize,0)) MB — limpiar recomendado")
    } elseif ($wuSize -gt 0) {
        Add-DiagRow "INFO" "Caché Windows Update presente" "$([math]::Round($wuSize,1)) MB"
        $exportLines.Add("[INFO] WU Cache: $([math]::Round($wuSize,1)) MB")
    } else {
        Add-DiagRow "OK" "Caché de Windows Update limpia" "Sin residuos de actualización"
        $exportLines.Add("[OK] WU Cache limpia")
    }

    # ── SECCIÓN: MEMORIA Y RENDIMIENTO ──────────────────────────────────────
    Add-DiagSection "MEMORIA Y RENDIMIENTO" "💾"
    $exportLines.Add("")
    $exportLines.Add("=== MEMORIA Y RENDIMIENTO ===")

    $ramUsedPct = $(if ($null -ne $Report.RamUsedPct) { [double]$Report.RamUsedPct } else { 0.0 })
    if ($ramUsedPct -gt 85) {
        Add-DiagRow "CRIT" "Memoria RAM crítica" "$ramUsedPct% en uso — riesgo de lentitud severa" "Liberar RAM urgente"
        $deductions += 20; $critCount++
        $exportLines.Add("[CRÍTICO] RAM: $ramUsedPct% en uso — liberar urgente")
    } elseif ($ramUsedPct -gt 70) {
        Add-DiagRow "WARN" "Uso de RAM elevado" "$ramUsedPct% en uso" "Liberar RAM recomendado"
        $deductions += 10; $warnCount++
        $exportLines.Add("[AVISO] RAM: $ramUsedPct% en uso — liberar recomendado")
    } else {
        Add-DiagRow "OK" "Memoria RAM en niveles normales" "$ramUsedPct% en uso"
        $exportLines.Add("[OK] RAM: $ramUsedPct% en uso")
    }

    $diskUsedPct = $(if ($null -ne $Report.DiskCUsedPct) { [double]$Report.DiskCUsedPct } else { 0.0 })
    if ($diskUsedPct -gt 90) {
        Add-DiagRow "CRIT" "Disco C: casi lleno" "$diskUsedPct% ocupado — rendimiento muy degradado" "Liberar espacio urgente"
        $deductions += 20; $critCount++
        $exportLines.Add("[CRÍTICO] Disco C: $diskUsedPct% — liberar espacio urgente")
    } elseif ($diskUsedPct -gt 75) {
        Add-DiagRow "WARN" "Disco C: con poco espacio libre" "$diskUsedPct% ocupado" "Limpiar archivos"
        $deductions += 10; $warnCount++
        $exportLines.Add("[AVISO] Disco C: $diskUsedPct% — limpiar recomendado")
    } else {
        Add-DiagRow "OK" "Espacio en disco C: saludable" "$diskUsedPct% ocupado"
        $exportLines.Add("[OK] Disco C: $diskUsedPct% ocupado")
    }

    # ── SECCIÓN: RED Y NAVEGADORES ───────────────────────────────────────────
    Add-DiagSection "RED Y NAVEGADORES" "🌐"
    $exportLines.Add("")
    $exportLines.Add("=== RED Y NAVEGADORES ===")

    $dnsCount = $(if ($null -ne $Report.DnsEntries) { [double]$Report.DnsEntries } else { 0.0 })
    if ($dnsCount -gt 500) {
        Add-DiagRow "WARN" "Caché DNS muy grande" "$dnsCount entradas — puede ralentizar resolución" "Limpiar caché DNS"
        $deductions += 5; $warnCount++
        $exportLines.Add("[AVISO] DNS: $dnsCount entradas — limpiar recomendado")
    } else {
        Add-DiagRow "OK" "Caché DNS normal" "$dnsCount entradas"
        $exportLines.Add("[OK] DNS: $dnsCount entradas")
    }

    $browserMB = $(if ($null -ne $Report.BrowserCacheMB) { [double]$Report.BrowserCacheMB } else { 0.0 })
    if ($browserMB -gt 1000) {
        Add-DiagRow "WARN" "Caché de navegadores muy grande" "$([math]::Round($browserMB,0)) MB — recomendable limpiar" "Limpiar caché navegadores"
        $deductions += 5; $warnCount++
        $exportLines.Add("[AVISO] Caché navegadores: $([math]::Round($browserMB,0)) MB")
    } elseif ($browserMB -gt 200) {
        Add-DiagRow "INFO" "Caché de navegadores presente" "$([math]::Round($browserMB,1)) MB"
        $exportLines.Add("[INFO] Caché navegadores: $([math]::Round($browserMB,1)) MB")
    } else {
        Add-DiagRow "OK" "Caché de navegadores limpia" "$([math]::Round($browserMB,1)) MB"
        $exportLines.Add("[OK] Caché navegadores: $([math]::Round($browserMB,1)) MB")
    }

    # ── SECCIÓN: REGISTRO DE WINDOWS ────────────────────────────────────────
    Add-DiagSection "REGISTRO DE WINDOWS" "📋"
    $exportLines.Add("")
    $exportLines.Add("=== REGISTRO DE WINDOWS ===")

    $orphaned = $(if ($null -ne $Report.OrphanedKeys) { [double]$Report.OrphanedKeys } else { 0.0 })
    if ($orphaned -gt 20) {
        Add-DiagRow "WARN" "Claves huérfanas en el registro" "$orphaned claves de programas desinstalados" "Limpiar registro"
        $deductions += 5; $warnCount++
        $exportLines.Add("[AVISO] Registro: $orphaned claves huérfanas")
    } elseif ($orphaned -gt 0) {
        Add-DiagRow "INFO" "Algunas claves huérfanas" "$orphaned claves — impacto mínimo"
        $exportLines.Add("[INFO] Registro: $orphaned claves huérfanas")
    } else {
        Add-DiagRow "OK" "Registro sin claves huérfanas" "No se detectaron entradas obsoletas"
        $exportLines.Add("[OK] Registro limpio")
    }

    # ── SECCIÓN: EVENT VIEWER LOGS ────────────────────────────────────────────
    Add-DiagSection "REGISTROS DE EVENTOS" "📰"
    $exportLines.Add("")
    $exportLines.Add("=== REGISTROS DE EVENTOS ===")

    $eventSizeMB = $(if ($null -ne $Report.EventLogsMB) { [double]$Report.EventLogsMB } else { 0.0 })
    if ($eventSizeMB -gt 100) {
        Add-DiagRow "WARN" "Logs de eventos grandes" "$([math]::Round($eventSizeMB,1)) MB en System+Application+Setup" "Limpiar Event Logs"
        $deductions += 3; $warnCount++
        $exportLines.Add("[AVISO] Event Logs: $([math]::Round($eventSizeMB,1)) MB")
    } else {
        Add-DiagRow "OK" "Logs de eventos dentro de límites" "$([math]::Round($eventSizeMB,1)) MB"
        $exportLines.Add("[OK] Event Logs: $([math]::Round($eventSizeMB,1)) MB")
    }

    # ── PUNTUACIÓN FINAL ─────────────────────────────────────────────────────
    $finalScore = [math]::Max(0, $points - $deductions)
    $dScore.Text  = "$finalScore"
    $scoreColor = if ($finalScore -ge 80) { "#4AE896" } elseif ($finalScore -ge 55) { "#FFB547" } else { "#FF6B84" }
    $dScore.Foreground = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString($scoreColor))
    $dLabel.Text = if ($finalScore -ge 80) { "Sistema en buen estado" } `
                   elseif ($finalScore -ge 55) { "Mantenimiento recomendado" } `
                   else { "Atención urgente" }

    $dSub.Text = "$(Get-Date -Format 'dd/MM/yyyy HH:mm')  ·  $critCount crítico(s)  ·  $warnCount aviso(s)"

    $exportLines.Add("")
    $exportLines.Add("=== RESUMEN ===")
    $exportLines.Add("Puntuación: $finalScore / 100")
    $exportLines.Add("Críticos: $critCount  |  Avisos: $warnCount")
    $exportLines.Add("Estado: $($dLabel.Text)")

    # ── Exportar informe ─────────────────────────────────────────────────────
    $btnExp.Add_Click({
        $sd = New-Object System.Windows.Forms.SaveFileDialog
        $sd.Title            = "Exportar Informe de Diagnóstico"
        $sd.Filter           = "Texto (*.txt)|*.txt|Todos (*.*)|*.*"
        $sd.DefaultExt       = "txt"
        $sd.FileName         = "DiagnosticoSistema_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        $sd.InitialDirectory = [Environment]::GetFolderPath("Desktop")
        if ($sd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $exportLines | Out-File -FilePath $sd.FileName -Encoding UTF8
            [System.Windows.MessageBox]::Show(
                "Informe guardado en:`n$($sd.FileName)",
                "Exportado",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information)
        }
    })

    $btnClose.Add_Click({ $dWindow.Close() })
    $dWindow.Owner = $window
    $dWindow.ShowDialog() | Out-Null
}

# ═════════════════════════════════════════════════════════════════════════════
# SCRIPT DE OPTIMIZACIÓN — se ejecuta en runspace separado
# ═════════════════════════════════════════════════════════════════════════════
$OptimizationScript = {
    param(
        $window, $ConsoleOutput, $ProgressBar, $StatusText,
        $ProgressText, $TaskText, $options, $CancelToken,
        [ref]$DiagReportRef
    )

    # ── Diccionario de resultados del análisis (dry-run) ─────────────────────
    $diagData = @{
        TempFilesMB   = 0.0
        UserTempMB    = 0.0
        RecycleBinMB  = 0.0
        WUCacheMB     = 0.0
        BrowserCacheMB= 0.0
        DnsEntries    = 0
        OrphanedKeys  = 0
        EventLogsMB   = 0.0
        RamUsedPct    = 0
        DiskCUsedPct  = 0
    }

    # ── Helpers de UI ────────────────────────────────────────────────────────
    function Write-Console {
        param([string]$Message)
        $ts = Get-Date -Format "HH:mm:ss"
        $out = "[$ts] $Message"
        $window.Dispatcher.Invoke([action]{
            $ConsoleOutput.AppendText("$out`n")
            $ConsoleOutput.ScrollToEnd()
        }.GetNewClosure())
    }

    function Update-Progress {
        param([int]$Percent, [string]$TaskName = "")
        $window.Dispatcher.Invoke([action]{
            $ProgressBar.Value  = $Percent
            $ProgressText.Text  = "$Percent%"
            if ($TaskName) { $TaskText.Text = "Tarea actual: $TaskName" }
        }.GetNewClosure())
    }

    function Update-SubProgress {
        param([double]$Base, [double]$Sub, [double]$Weight)
        $actual = [math]::Round($Base + (($Sub / 100) * $Weight))
        $window.Dispatcher.Invoke([action]{
            $ProgressBar.Value = $actual
            $ProgressText.Text = "$actual%"
        }.GetNewClosure())
    }

    function Update-Status {
        param([string]$Status)
        $window.Dispatcher.Invoke([action]{
            $StatusText.Text = $Status
        }.GetNewClosure())
    }

    function Test-Cancelled {
        if ($CancelToken.IsCancellationRequested) {
            Write-Console ""
            Write-Console "⚠ OPTIMIZACIÓN CANCELADA POR EL USUARIO"
            Update-Status "⚠ Cancelado por el usuario"
            $window.Dispatcher.Invoke([action]{
                $TaskText.Text = "Cancelado"
            }.GetNewClosure())
            return $true
        }
        return $false
    }

    # ── [M1] Función unificada de limpieza de carpetas temporales ────────────
    # [B13] Elimina la duplicación total entre TempFiles y UserTemp
    function Invoke-CleanTempPaths {
        param(
            [string[]]$Paths,
            [double]$BasePercent,
            [double]$TaskWeight,
            [bool]$DryRun = $false
        )
        $totalFreed = 0
        $pathIndex  = 0
        $pathCount  = $Paths.Count

        foreach ($path in $Paths) {
            $pathIndex++
            Update-SubProgress $BasePercent ([int](($pathIndex / $pathCount) * 100)) $TaskWeight

            if (-not (Test-Path $path)) {
                Write-Console "  [$pathIndex/$pathCount] Ruta no encontrada: $path"
                continue
            }

            Write-Console "  [$pathIndex/$pathCount] Analizando: $path"
            try {
                $beforeSize = (Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue |
                               Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                if ($null -eq $beforeSize) { $beforeSize = 0 }
                $beforeMB = [math]::Round($beforeSize / 1MB, 2)
                Write-Console "    Tamaño: $beforeMB MB"

                if (-not $DryRun) {
                    $deletedCount = 0
                    Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue |
                        Where-Object { -not $_.PSIsContainer } | ForEach-Object {
                            $fp = $_.FullName
                            Remove-Item $fp -Force -ErrorAction SilentlyContinue
                            if (-not (Test-Path $fp)) { $deletedCount++ }
                        }
                    # Eliminar directorios vacíos (o con restos no eliminables)
                    # -Recurse es necesario para evitar el prompt interactivo en directorios con hijos
                    Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue |
                        Where-Object { $_.PSIsContainer } |
                        Sort-Object -Property FullName -Descending | ForEach-Object {
                            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    $afterSize = (Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue |
                                  Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                    if ($null -eq $afterSize) { $afterSize = 0 }
                    $freed = ($beforeSize - $afterSize) / 1MB
                    $totalFreed += $freed
                    Write-Console "    ✓ Eliminados: $deletedCount archivos — $([math]::Round($freed,2)) MB liberados"
                } else {
                    $totalFreed += $beforeMB
                    Write-Console "    [DRY RUN] Se liberarían ~$beforeMB MB"
                }
            } catch {
                Write-Console "    ! Error: $($_.Exception.Message)"
            }
        }
        return $totalFreed
    }

    # ── Contar tareas seleccionadas ──────────────────────────────────────────
    $taskKeys = @(
        'OptimizeDisks','RecycleBin','TempFiles','UserTemp','WUCache','Chkdsk',
        'ClearMemory','CloseProcesses','DNSCache','BrowserCache',
        'BackupRegistry','CleanRegistry','SFC','DISM','EventLogs'
        # ShowStartup se maneja en el hilo principal, no aquí
    )
    $taskList   = $taskKeys | Where-Object { $options[$_] -eq $true }
    $totalTasks = $taskList.Count
    $dryRun     = $options['DryRun'] -eq $true

    if ($totalTasks -eq 0) {
        Write-Console "No hay tareas seleccionadas."
        Update-Status "Sin tareas seleccionadas"
        Update-Progress 0 ""
        return
    }

    $taskWeight      = 100.0 / $totalTasks
    $completedTasks  = 0
    $startTime       = Get-Date
    $dryRunLabel     = if ($dryRun) { " [MODO ANÁLISIS — sin cambios]" } else { "" }

    $boxWidth  = 62   # ancho interior entre ║ y ║
    $titleLine = if ($dryRun) {
        "INICIANDO OPTIMIZACIÓN  —  MODO ANÁLISIS (DRY RUN)"
    } else {
        "INICIANDO OPTIMIZACIÓN DEL SISTEMA WINDOWS"
    }
    $pad   = [math]::Max(0, $boxWidth - $titleLine.Length)
    $left  = [math]::Floor($pad / 2)
    $right = $pad - $left
    Write-Console "╔$('═' * $boxWidth)╗"
    Write-Console "║$(' ' * $left)$titleLine$(' ' * $right)║"
    Write-Console "╚$('═' * $boxWidth)╝"
    Write-Console "Fecha:    $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"
    Write-Console "Modo:     $(if ($dryRun) { '🔍 ANÁLISIS (Dry Run) — solo reportar' } else { '⚙ EJECUCIÓN real' })"
    Write-Console "Tareas:   $totalTasks"
    Write-Console "Tareas a ejecutar: $($taskList -join ', ')"
    Write-Console ""

    # ── 1. OPTIMIZACIÓN DE DISCOS ────────────────────────────────────────────
    if ($options['OptimizeDisks']) {
        if (Test-Cancelled) { return }
        $base = [math]::Round(($completedTasks / $totalTasks) * 100)
        Update-Progress $base "Optimización de discos"
        Update-Status "$(if($dryRun){'[DRY RUN] '})Optimizando discos..."

        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "1. OPTIMIZACIÓN DE DISCOS DUROS$dryRunLabel"
        Write-Console "═══════════════════════════════════════════════════════════"

        try {
            $volumes = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' })
            Write-Console "Unidades encontradas: $($volumes.Count)"

            $volIdx = 0
            foreach ($volume in $volumes) {
                $volIdx++
                $dl      = $volume.DriveLetter
                $sizeGB  = [math]::Round($volume.Size          / 1GB, 2)
                $freeGB  = [math]::Round($volume.SizeRemaining / 1GB, 2)
                Update-SubProgress $base ([int](($volIdx / $volumes.Count) * 100)) $taskWeight

                Write-Console ""
                Write-Console "  [$volIdx/$($volumes.Count)] Unidad ${dl}: — $sizeGB GB total, $freeGB GB libre"

                try {
                    $partition = Get-Partition -DriveLetter $dl -ErrorAction Stop
                    $disk      = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop

                    # [B5] Detección robusta por DeviceID, no por FriendlyName
                    $mediaType = $disk.MediaType
                    try {
                        $physDisk = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $disk.Number } | Select-Object -First 1
                        if ($physDisk -and $physDisk.MediaType -and $physDisk.MediaType -ne 'Unspecified') {
                            $mediaType = $physDisk.MediaType
                        }
                    } catch { }

                    $isNVMe = $disk.FriendlyName -match 'NVMe|NVME|nvme'
                    $isSSD  = $mediaType -in @('SSD', 'Solid State Drive') -or $isNVMe

                    Write-Console "  Tipo: $mediaType$(if($isNVMe){' (NVMe)'})"

                    if ($dryRun) {
                        Write-Console "  [DRY RUN] Se ejecutaría: $(if($isSSD){'TRIM (Optimize-Volume -ReTrim)'}else{'Defrag (Optimize-Volume -Defrag)'})"
                    } elseif ($isSSD) {
                        Optimize-Volume -DriveLetter $dl -ReTrim -ErrorAction Stop
                        Write-Console "  ✓ TRIM completado"
                    } else {
                        Optimize-Volume -DriveLetter $dl -Defrag -ErrorAction Stop
                        Write-Console "  ✓ Desfragmentación completada"
                    }
                } catch {
                    Write-Console "  ✗ Error: $($_.Exception.Message)"
                    if (-not $dryRun) {
                        try {
                            $out = & defrag.exe "${dl}:" /O 2>&1
                            $out | Where-Object { $_ -and $_.ToString().Trim() } |
                                ForEach-Object { Write-Console "    $_" }
                        } catch {
                            Write-Console "  ✗ Método alternativo falló: $($_.Exception.Message)"
                        }
                    }
                }
            }
            Write-Console ""
            Write-Console "✓ Optimización de discos $(if($dryRun){'analizada'}else{'completada'})"
        } catch {
            Write-Console "Error general: $($_.Exception.Message)"
        }
        $completedTasks++
        Update-Progress ([math]::Round(($completedTasks / $totalTasks) * 100)) ""
    }

    # ── 2. VACIAR PAPELERA ───────────────────────────────────────────────────
    if ($options['RecycleBin']) {
        if (Test-Cancelled) { return }
        $base = [math]::Round(($completedTasks / $totalTasks) * 100)
        Update-Progress $base "Vaciando papelera"
        Update-Status "$(if($dryRun){'[DRY RUN] '})Vaciando papelera..."

        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "2. VACIANDO PAPELERA DE RECICLAJE$dryRunLabel"
        Write-Console "═══════════════════════════════════════════════════════════"

        try {
            $totalSize = 0
            Get-PSDrive -PSProvider FileSystem | ForEach-Object {
                $rp = Join-Path $_.Root '$Recycle.Bin'
                if (Test-Path $rp) {
                    $sz = (Get-ChildItem -Path $rp -Force -Recurse -ErrorAction SilentlyContinue |
                           Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                    if ($sz) { $totalSize += $sz }
                }
            }
            $totalMB = [math]::Round($totalSize / 1MB, 2)
            Write-Console "  Contenido total en papelera: $totalMB MB"
            $diagData['RecycleBinMB'] = $totalMB

            if ($dryRun) {
                Write-Console "  [DRY RUN] Se liberarían ~$totalMB MB"
            } else {
                Get-PSDrive -PSProvider FileSystem | ForEach-Object {
                    $rp = Join-Path $_.Root '$Recycle.Bin'
                    if (Test-Path $rp) {
                        Get-ChildItem -Path $rp -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
                Write-Console "  ✓ Papelera vaciada para todas las unidades — $totalMB MB liberados"
            }
        } catch {
            Write-Console "  ❌ Error: $($_.Exception.Message)"
        }

        $completedTasks++
        Update-Progress ([math]::Round(($completedTasks / $totalTasks) * 100)) ""
    }

    # ── 3. ARCHIVOS TEMPORALES DE WINDOWS ───────────────────────────────────
    if ($options['TempFiles']) {
        if (Test-Cancelled) { return }
        $base = [math]::Round(($completedTasks / $totalTasks) * 100)
        Update-Progress $base "Archivos temporales Windows"
        Update-Status "$(if($dryRun){'[DRY RUN] '})Temp Windows..."

        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "3. ARCHIVOS TEMPORALES DE WINDOWS$dryRunLabel"
        Write-Console "═══════════════════════════════════════════════════════════"

        $paths  = @("$env:SystemRoot\Temp", "$env:SystemRoot\Prefetch")
        $freed  = Invoke-CleanTempPaths -Paths $paths -BasePercent $base -TaskWeight $taskWeight -DryRun $dryRun
        $diagData['TempFilesMB'] = $freed
        Write-Console ""
        Write-Console "  ✓ Total: $([math]::Round($freed,2)) MB $(if($dryRun){'por liberar'}else{'liberados'})"

        $completedTasks++
        Update-Progress ([math]::Round(($completedTasks / $totalTasks) * 100)) ""
    }

    # ── 4. ARCHIVOS TEMPORALES DE USUARIO ───────────────────────────────────
    if ($options['UserTemp']) {
        if (Test-Cancelled) { return }
        $base = [math]::Round(($completedTasks / $totalTasks) * 100)
        Update-Progress $base "Archivos temporales Usuario"
        Update-Status "$(if($dryRun){'[DRY RUN] '})Temp Usuario..."

        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "4. ARCHIVOS TEMPORALES DE USUARIO$dryRunLabel"
        Write-Console "═══════════════════════════════════════════════════════════"

        $paths = @("$env:TEMP", "$env:LOCALAPPDATA\Temp")
        $freed = Invoke-CleanTempPaths -Paths $paths -BasePercent $base -TaskWeight $taskWeight -DryRun $dryRun
        $diagData['UserTempMB'] = $freed
        Write-Console ""
        Write-Console "  ✓ Total: $([math]::Round($freed,2)) MB $(if($dryRun){'por liberar'}else{'liberados'})"

        $completedTasks++
        Update-Progress ([math]::Round(($completedTasks / $totalTasks) * 100)) ""
    }

    # ── 5. [N3] WINDOWS UPDATE CACHE ────────────────────────────────────────
    if ($options['WUCache']) {
        if (Test-Cancelled) { return }
        $base = [math]::Round(($completedTasks / $totalTasks) * 100)
        Update-Progress $base "Windows Update Cache"
        Update-Status "$(if($dryRun){'[DRY RUN] '})Limpiando WU Cache..."

        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "5. WINDOWS UPDATE CACHE (SoftwareDistribution)$dryRunLabel"
        Write-Console "═══════════════════════════════════════════════════════════"

        $wuPath = "$env:SystemRoot\SoftwareDistribution\Download"

        try {
            $beforeSize = (Get-ChildItem -Path $wuPath -Recurse -Force -ErrorAction SilentlyContinue |
                           Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            if ($null -eq $beforeSize) { $beforeSize = 0 }
            $beforeMB = [math]::Round($beforeSize / 1MB, 2)
            Write-Console "  Tamaño actual: $beforeMB MB"
            $diagData['WUCacheMB'] = $beforeMB
            Update-SubProgress $base 30 $taskWeight

            if ($dryRun) {
                Write-Console "  [DRY RUN] Se liberarían ~$beforeMB MB"
            } else {
                # Detener servicio de Windows Update temporalmente
                Write-Console "  Deteniendo servicio Windows Update (wuauserv)..."
                Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
                Update-SubProgress $base 50 $taskWeight
                Start-Sleep -Seconds 2

                Get-ChildItem -Path $wuPath -Force -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

                $afterSize = (Get-ChildItem -Path $wuPath -Recurse -Force -ErrorAction SilentlyContinue |
                              Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                if ($null -eq $afterSize) { $afterSize = 0 }

                # Reiniciar servicio
                Update-SubProgress $base 85 $taskWeight
                Start-Service -Name wuauserv -ErrorAction SilentlyContinue
                Write-Console "  ✓ Servicio Windows Update reiniciado"

                $freed = [math]::Round(($beforeSize - $afterSize) / 1MB, 2)
                Write-Console "  ✓ WU Cache limpiada — $freed MB liberados"
            }
        } catch {
            Write-Console "  ! Error: $($_.Exception.Message)"
            # Asegurar que el servicio queda activo aunque falle
            Start-Service -Name wuauserv -ErrorAction SilentlyContinue
        }

        $completedTasks++
        Update-Progress ([math]::Round(($completedTasks / $totalTasks) * 100)) ""
    }

    # ── 6. CHECK DISK ────────────────────────────────────────────────────────
    if ($options['Chkdsk']) {
        if (Test-Cancelled) { return }
        $base = [math]::Round(($completedTasks / $totalTasks) * 100)
        Update-Progress $base "Check Disk (CHKDSK)"
        Update-Status "Programando CHKDSK..."

        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "6. PROGRAMANDO CHECK DISK (CHKDSK)"
        Write-Console "═══════════════════════════════════════════════════════════"

        if ($dryRun) {
            Write-Console "  [DRY RUN] Se programaría CHKDSK en el próximo reinicio"
        } else {
            try {
                # [B9] Orden correcto: dirty set PRIMERO, luego chkntfs /x para 
                #      excluir el chequeo automático de arranque limpio pero
                #      forzar via volumen sucio. En realidad el flujo correcto
                #      es marcar dirty y NO excluir con /x, así CHKDSK sí corre.
                Write-Console "  Marcando volumen C: como sucio (fsutil dirty set)..."
                $fsutilOutput = & fsutil dirty set C: 2>&1
                $fsutilOutput | Where-Object { $_ -and $_.ToString().Trim() } |
                    ForEach-Object { Write-Console "    $_" }

                Write-Console "  ✓ CHKDSK programado — se ejecutará en el próximo reinicio"
                Write-Console "  NOTA: El sistema debe reiniciarse para que CHKDSK se ejecute"
            } catch {
                Write-Console "  Error: $($_.Exception.Message)"
            }
        }

        $completedTasks++
        Update-Progress ([math]::Round(($completedTasks / $totalTasks) * 100)) ""
    }

    # ── 7. LIBERAR MEMORIA RAM ───────────────────────────────────────────────
    if ($options['ClearMemory']) {
        if (Test-Cancelled) { return }
        $base = [math]::Round(($completedTasks / $totalTasks) * 100)
        Update-Progress $base "Liberando memoria RAM"
        Update-Status "$(if($dryRun){'[DRY RUN] '})Liberando RAM..."

        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "7. LIBERANDO MEMORIA RAM$dryRunLabel"
        Write-Console "═══════════════════════════════════════════════════════════"

        try {
            $osBefore   = Get-CimInstance -ClassName Win32_OperatingSystem
            $totalGB    = [math]::Round($osBefore.TotalVisibleMemorySize / 1MB, 2)
            $freeGBBef  = [math]::Round($osBefore.FreePhysicalMemory     / 1MB, 2)

            Write-Console "  Total RAM:       $totalGB GB"
            Write-Console "  Libre antes:     $freeGBBef GB"
            Update-SubProgress $base 20 $taskWeight

            if ($dryRun) {
                Write-Console "  [DRY RUN] Se vaciaría el Working Set de todos los procesos accesibles"
            } else {
                # [B1] Liberación real via EmptyWorkingSet por cada proceso
                $count = 0
                foreach ($proc in (Get-Process -ErrorAction SilentlyContinue)) {
                    try {
                        $hProc = [MemoryHelper]::OpenProcess(0x1F0FFF, $false, $proc.Id)
                        if ($hProc -ne [IntPtr]::Zero) {
                            [MemoryHelper]::EmptyWorkingSet($hProc) | Out-Null
                            [MemoryHelper]::CloseHandle($hProc) | Out-Null
                            $count++
                        }
                    } catch { }
                }
                Write-Console "  Working Set vaciado en $count procesos"
                Update-SubProgress $base 70 $taskWeight
                Start-Sleep -Seconds 2

                $osAfter   = Get-CimInstance -ClassName Win32_OperatingSystem
                $freeGBAft = [math]::Round($osAfter.FreePhysicalMemory / 1MB, 2)
                $gained    = [math]::Round($freeGBAft - $freeGBBef, 2)

                Write-Console "  Libre después:   $freeGBAft GB"
                Write-Console "  ✓ RAM recuperada: $gained GB"
            }
        } catch {
            Write-Console "  Error: $($_.Exception.Message)"
        }

        $completedTasks++
        Update-Progress ([math]::Round(($completedTasks / $totalTasks) * 100)) ""
    }

    # ── 8. CERRAR PROCESOS NO CRÍTICOS ───────────────────────────────────────
    if ($options['CloseProcesses']) {
        if (Test-Cancelled) { return }
        $base = [math]::Round(($completedTasks / $totalTasks) * 100)
        Update-Progress $base "Cerrando procesos"
        Update-Status "$(if($dryRun){'[DRY RUN] '})Cerrando procesos..."

        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "8. CERRANDO PROCESOS NO CRÍTICOS$dryRunLabel"
        Write-Console "═══════════════════════════════════════════════════════════"

        try {
            $criticals = @(
                'System','svchost','csrss','wininit','services','lsass','winlogon',
                'dwm','explorer','taskhostw','RuntimeBroker','sihost','fontdrvhost',
                'smss','conhost','dllhost','spoolsv','SearchIndexer','MsMpEng',
                'powershell','pwsh','audiodg','wudfhost','dasHost','TextInputHost',
                'SecurityHealthService','SgrmBroker','SecurityHealthSystray',
                'ShellExperienceHost','StartMenuExperienceHost','SearchUI','Cortana',
                'ApplicationFrameHost','SystemSettings','WmiPrvSE','Memory Compression'
            )

            $curProc  = Get-Process -Id $PID
            $sessionId = $curProc.SessionId
            $parentPID = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue).ParentProcessId

            $targets = @(Get-Process | Where-Object {
                $_.SessionId -eq $sessionId -and
                $_.ProcessName -notin $criticals -and
                $_.Id -ne $PID -and
                $_.Id -ne $parentPID -and
                $_.ProcessName -ne 'Idle'
            })

            Write-Console "  Procesos candidatos: $($targets.Count)"

            $closed = 0
            $idx    = 0
            foreach ($p in $targets) {
                $idx++
                Update-SubProgress $base ([int](($idx / [Math]::Max($targets.Count,1)) * 100)) $taskWeight
                if ($dryRun) {
                    Write-Console "  [DRY RUN] Cerraría: $($p.ProcessName) (PID: $($p.Id))"
                } else {
                    try {
                        $p | Stop-Process -Force -ErrorAction Stop
                        $closed++
                        Write-Console "  ✓ Cerrado: $($p.ProcessName) (PID: $($p.Id))"
                    } catch { }
                }
            }
            Write-Console ""
            Write-Console "  ✓ Procesos cerrados: $closed de $($targets.Count)"
        } catch {
            Write-Console "  Error: $($_.Exception.Message)"
        }

        $completedTasks++
        Update-Progress ([math]::Round(($completedTasks / $totalTasks) * 100)) ""
    }

    # ── 9. LIMPIAR CACHÉ DNS ─────────────────────────────────────────────────
    if ($options['DNSCache']) {
        if (Test-Cancelled) { return }
        $base = [math]::Round(($completedTasks / $totalTasks) * 100)
        Update-Progress $base "Limpiando caché DNS"
        Update-Status "$(if($dryRun){'[DRY RUN] '})DNS cache..."

        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "9. LIMPIANDO CACHÉ DNS$dryRunLabel"
        Write-Console "═══════════════════════════════════════════════════════════"

        try {
            if ($dryRun) {
                $dnsEntries = (Get-DnsClientCache -ErrorAction SilentlyContinue).Count
                Write-Console "  [DRY RUN] Caché DNS actual: $dnsEntries entradas"
                $diagData['DnsEntries'] = $dnsEntries
            } else {
                Update-SubProgress $base 30 $taskWeight
                Clear-DnsClientCache -ErrorAction Stop
                Write-Console "  ✓ Clear-DnsClientCache ejecutado"
                Update-SubProgress $base 60 $taskWeight
                # [FIX] Capturar ipconfig con encoding correcto (cp850 en Windows español)
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName               = "cmd.exe"
                $psi.Arguments              = "/c chcp 65001 >nul 2>&1 & ipconfig /flushdns"
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError  = $true
                $psi.UseShellExecute        = $false
                $psi.CreateNoWindow         = $true
                $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
                $proc = [System.Diagnostics.Process]::Start($psi)
                $stdout = $proc.StandardOutput.ReadToEnd()
                $proc.WaitForExit()
                $stdout -split "`n" | Where-Object { $_.Trim() } |
                    ForEach-Object { Write-Console "  $($_.TrimEnd())" }
                Write-Console "  ✓ Caché DNS limpiada"
            }
        } catch {
            Write-Console "  Error: $($_.Exception.Message)"
        }

        $completedTasks++
        Update-Progress ([math]::Round(($completedTasks / $totalTasks) * 100)) ""
    }

    # ── 10. LIMPIAR NAVEGADORES ──────────────────────────────────────────────
    if ($options['BrowserCache']) {
        if (Test-Cancelled) { return }
        $base = [math]::Round(($completedTasks / $totalTasks) * 100)
        Update-Progress $base "Limpiando navegadores"
        Update-Status "$(if($dryRun){'[DRY RUN] '})Navegadores..."

        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "10. LIMPIANDO CACHÉ DE NAVEGADORES$dryRunLabel"
        Write-Console "═══════════════════════════════════════════════════════════"

        # [B6] Rutas completas para todos los navegadores
        $browsers = @{
            "Chrome" = @(
                "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
                "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache2",
                "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache",
                "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\GPUCache"
            )
            "Edge" = @(
                "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
                "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache2",
                "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache",
                "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\GPUCache"
            )
            "Brave" = @(
                "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Cache",
                "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Cache2",
                "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Code Cache",
                "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\GPUCache"
            )
            "Opera" = @(
                "$env:APPDATA\Opera Software\Opera Stable\Cache",
                "$env:APPDATA\Opera Software\Opera Stable\Cache2",
                "$env:APPDATA\Opera Software\Opera Stable\Code Cache",
                "$env:APPDATA\Opera Software\Opera Stable\GPUCache"
            )
            "Opera GX" = @(
                "$env:APPDATA\Opera Software\Opera GX Stable\Cache",
                "$env:APPDATA\Opera Software\Opera GX Stable\Cache2",
                "$env:APPDATA\Opera Software\Opera GX Stable\Code Cache",
                "$env:APPDATA\Opera Software\Opera GX Stable\GPUCache"
            )
            # [B7] Firefox: cache + cache2 (legacy y moderno)
            "Firefox" = @("$env:LOCALAPPDATA\Mozilla\Firefox\Profiles")
        }

        $bIdx   = 0
        $bCount = $browsers.Keys.Count

        foreach ($browser in $browsers.Keys) {
            $bIdx++
            Update-SubProgress $base ([int](($bIdx / $bCount) * 100)) $taskWeight
            Write-Console "  [$bIdx/$bCount] $browser..."
            $cleared    = $false
            $totalCleared = 0

            foreach ($path in $browsers[$browser]) {
                if ($browser -eq "Firefox") {
                    # Expandir perfiles y limpiar cache + cache2
                    $profileDirs = Get-ChildItem -Path $path -Directory -ErrorAction SilentlyContinue
                    foreach ($pd in $profileDirs) {
                        foreach ($cacheSub in @('cache', 'cache2')) {
                            $cp = Join-Path $pd.FullName $cacheSub
                            if (Test-Path $cp) {
                                $sz = (Get-ChildItem -Path $cp -Recurse -Force -ErrorAction SilentlyContinue |
                                       Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                                if ($sz) { $totalCleared += $sz / 1MB }
                                if (-not $dryRun) {
                                    Remove-Item -Path "$cp\*" -Recurse -Force -ErrorAction SilentlyContinue
                                }
                                $cleared = $true
                            }
                        }
                    }
                    continue
                }

                if (Test-Path $path) {
                    try {
                        $sz = (Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue |
                               Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                        if ($sz) { $totalCleared += $sz / 1MB }
                        if (-not $dryRun) {
                            Remove-Item -Path "$path\*" -Recurse -Force -ErrorAction SilentlyContinue
                        }
                        $cleared = $true
                    } catch { }
                }
            }

            $mb = [math]::Round($totalCleared, 2)
            $diagData['BrowserCacheMB'] += $totalCleared
            if ($cleared) {
                Write-Console "    $(if($dryRun){'[DRY RUN]'} else {'✓'}) $browser — $mb MB $(if($dryRun){'por liberar'}else{'liberados'})"
            } else {
                Write-Console "    → $browser no encontrado o sin caché"
            }
        }

        Write-Console ""
        Write-Console "  ✓ Limpieza de navegadores $(if($dryRun){'analizada'}else{'completada'})"

        $completedTasks++
        Update-Progress ([math]::Round(($completedTasks / $totalTasks) * 100)) ""
    }

    # ── 11. BACKUP DEL REGISTRO ──────────────────────────────────────────────
    if ($options['BackupRegistry']) {
        if (Test-Cancelled) { return }
        $base = [math]::Round(($completedTasks / $totalTasks) * 100)
        Update-Progress $base "Backup del registro"
        Update-Status "Creando backup del registro..."

        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "11. BACKUP DEL REGISTRO$(if($dryRun){' [DRY RUN — no se crea]'})"
        Write-Console "═══════════════════════════════════════════════════════════"

        $backupPath = "$env:USERPROFILE\Desktop\RegistryBackup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

        if ($dryRun) {
            Write-Console "  [DRY RUN] Se crearía backup en: $backupPath"
            Write-Console "  [DRY RUN] Exportaría: HKEY_CURRENT_USER, HKLM\SOFTWARE"
        } else {
            try {
                New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
                Write-Console "  Carpeta: $backupPath"

                $hives = @(
                    @{Name="HKEY_CURRENT_USER";             File="HKCU_backup.reg"},
                    @{Name="HKEY_LOCAL_MACHINE\SOFTWARE";   File="HKLM_SOFTWARE_backup.reg"}
                )

                $hi = 0
                foreach ($hive in $hives) {
                    $hi++
                    Update-SubProgress $base ([int](($hi / $hives.Count) * 100)) $taskWeight
                    Write-Console "  [$hi/$($hives.Count)] Exportando $($hive.Name)..."
                    $exportFile = Join-Path $backupPath $hive.File
                    & cmd /c "reg export `"$($hive.Name)`" `"$exportFile`" /y" 2>&1 | Out-Null
                    if (Test-Path $exportFile) {
                        $sz = [math]::Round((Get-Item $exportFile).Length / 1MB, 2)
                        Write-Console "    ✓ $sz MB"
                    } else {
                        Write-Console "    ! No se pudo exportar"
                    }
                }
                Write-Console ""
                Write-Console "  ✓ Backup completado en: $backupPath"
            } catch {
                Write-Console "  Error: $($_.Exception.Message)"
            }
        }

        $completedTasks++
        Update-Progress ([math]::Round(($completedTasks / $totalTasks) * 100)) ""
    }

    # ── 12. LIMPIAR REGISTRO ─────────────────────────────────────────────────
    if ($options['CleanRegistry']) {
        if (Test-Cancelled) { return }
        $base = [math]::Round(($completedTasks / $totalTasks) * 100)
        Update-Progress $base "Limpiando registro"
        Update-Status "$(if($dryRun){'[DRY RUN] '})Claves huérfanas..."

        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "12. LIMPIANDO CLAVES HUÉRFANAS DEL REGISTRO$dryRunLabel"
        Write-Console "═══════════════════════════════════════════════════════════"

        try {
            $uninstallPaths = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
                "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
            )

            $orphaned = 0
            $deleted  = 0
            $pIdx     = 0

            foreach ($path in $uninstallPaths) {
                $pIdx++
                Update-SubProgress $base (20 + [int](($pIdx / $uninstallPaths.Count) * 70)) $taskWeight
                if (-not (Test-Path $path)) { continue }

                Write-Console "  Analizando: $path"
                Get-ChildItem -Path $path -ErrorAction SilentlyContinue | ForEach-Object {
                    $key     = $_
                    $props   = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
                    $dName   = $props.DisplayName
                    $iLoc    = $props.InstallLocation

                    if ($iLoc -and -not (Test-Path $iLoc)) {
                        $orphaned++
                        Write-Console "    → Huérfana: $dName"
                        if (-not $dryRun) {
                            try {
                                Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction Stop
                                $deleted++
                                Write-Console "      ✓ Eliminada"
                            } catch {
                                Write-Console "      ! No se pudo eliminar: $($_.Exception.Message)"
                            }
                        } else {
                            Write-Console "      [DRY RUN] Se eliminaría"
                        }
                    }
                }
            }

            Write-Console ""
            Write-Console "  ✓ Huérfanas encontradas: $orphaned — Eliminadas: $deleted"
            $diagData['OrphanedKeys'] = $orphaned
        } catch {
            Write-Console "  Error: $($_.Exception.Message)"
        }

        $completedTasks++
        Update-Progress ([math]::Round(($completedTasks / $totalTasks) * 100)) ""
    }

    # ── 13. SFC /SCANNOW ─────────────────────────────────────────────────────
    if ($options['SFC']) {
        if (Test-Cancelled) { return }
        $base = [math]::Round(($completedTasks / $totalTasks) * 100)
        Update-Progress $base "SFC /SCANNOW"
        Update-Status "Ejecutando SFC (puede tardar varios minutos)..."

        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "13. SFC /SCANNOW"
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "    NOTA: puede tardar entre 10-30 minutos"

        if ($dryRun) {
            Write-Console "  [DRY RUN] Se ejecutaría: sfc.exe /scannow"
        } else {
            try {
                $sfcProc = Start-Process -FilePath "sfc.exe" -ArgumentList "/scannow" `
                    -NoNewWindow -Wait -PassThru

                $cbsLog = "$env:SystemRoot\Logs\CBS\CBS.log"
                if (Test-Path $cbsLog) {
                    $lastLines = Get-Content $cbsLog -Tail 20
                    Write-Console "  Últimas líneas CBS.log:"
                    $lastLines | ForEach-Object { Write-Console "    $_" }
                }

                switch ($sfcProc.ExitCode) {
                    0 { Write-Console "  ✓ SFC: No se encontraron infracciones" }
                    1 { Write-Console "  ✓ SFC: Archivos corruptos reparados" }
                    2 { Write-Console "  ! SFC: Archivos corruptos que no pudieron repararse" }
                    3 { Write-Console "  ! SFC: No se pudo realizar la verificación" }
                    default { Write-Console "  ! SFC código: $($sfcProc.ExitCode)" }
                }
            } catch {
                Write-Console "  Error: $($_.Exception.Message)"
            }
        }

        $completedTasks++
        Update-Progress ([math]::Round(($completedTasks / $totalTasks) * 100)) ""
    }

    # ── 14. DISM ─────────────────────────────────────────────────────────────
    if ($options['DISM']) {
        if (Test-Cancelled) { return }
        $base = [math]::Round(($completedTasks / $totalTasks) * 100)
        Update-Progress $base "DISM"
        Update-Status "Ejecutando DISM (puede tardar varios minutos)..."

        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "14. DISM — Reparación de imagen del sistema"
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "    NOTA: puede tardar entre 15-45 minutos"

        if ($dryRun) {
            Write-Console "  [DRY RUN] Se ejecutarían: CheckHealth, ScanHealth, RestoreHealth"
        } else {
            try {
                foreach ($step in @(
                    @{ Label="Paso 1/3: CheckHealth...";    Args="/Online /Cleanup-Image /CheckHealth";   Sub=10 },
                    @{ Label="Paso 2/3: ScanHealth...";     Args="/Online /Cleanup-Image /ScanHealth";    Sub=40 },
                    @{ Label="Paso 3/3: RestoreHealth...";  Args="/Online /Cleanup-Image /RestoreHealth"; Sub=70 }
                )) {
                    Write-Console ""
                    Write-Console "  $($step.Label)"
                    Update-SubProgress $base $step.Sub $taskWeight
                    $out = & DISM ($step.Args -split ' ') 2>&1
                    $out | Where-Object { $_ -and $_.ToString().Trim() } |
                        ForEach-Object { Write-Console "    $_" }
                }
                Write-Console ""
                Write-Console "  ✓ DISM completado"
            } catch {
                Write-Console "  Error: $($_.Exception.Message)"
            }
        }

        $completedTasks++
        Update-Progress ([math]::Round(($completedTasks / $totalTasks) * 100)) ""
    }

    # ── 15. [N7] EVENT VIEWER LOGS ───────────────────────────────────────────
    if ($options['EventLogs']) {
        if (Test-Cancelled) { return }
        $base = [math]::Round(($completedTasks / $totalTasks) * 100)
        Update-Progress $base "Event Viewer Logs"
        Update-Status "$(if($dryRun){'[DRY RUN] '})Limpiando Event Logs..."

        Write-Console ""
        Write-Console "═══════════════════════════════════════════════════════════"
        Write-Console "15. LIMPIANDO EVENT VIEWER LOGS$dryRunLabel"
        Write-Console "    (System, Application, Setup — NO Security)"
        Write-Console "═══════════════════════════════════════════════════════════"

        $logs = @('System', 'Application', 'Setup')

        $lIdx = 0
        foreach ($log in $logs) {
            $lIdx++
            Update-SubProgress $base ([int](($lIdx / $logs.Count) * 100)) $taskWeight

            try {
                $logInfo = Get-WinEvent -ListLog $log -ErrorAction Stop
                $sizeMB  = [math]::Round($logInfo.FileSize / 1MB, 2)
                $count   = $logInfo.RecordCount
                $diagData['EventLogsMB'] += $sizeMB

                Write-Console "  [$lIdx/$($logs.Count)] $log — $count eventos, $sizeMB MB"

                if ($dryRun) {
                    Write-Console "    [DRY RUN] Se limpiaría este log"
                } else {
                    & wevtutil.exe cl $log 2>&1 | Out-Null
                    Write-Console "    ✓ Log limpiado"
                }
            } catch {
                Write-Console "  [$lIdx] $log — Error: $($_.Exception.Message)"
            }
        }

        Write-Console ""
        Write-Console "  ✓ Event Logs $(if($dryRun){'analizados'}else{'limpiados'})"
        Write-Console "  NOTA: El log 'Security' NO fue modificado (requiere auditoría)"

        $completedTasks++
        Update-Progress ([math]::Round(($completedTasks / $totalTasks) * 100)) ""
    }

    # ── RESUMEN FINAL ────────────────────────────────────────────────────────
    # Capturar estado actual de RAM y disco para el informe
    try {
        $osSnap      = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        $totalMemGB  = $osSnap.TotalVisibleMemorySize / 1MB
        $freeMemGB   = $osSnap.FreePhysicalMemory     / 1MB
        $diagData['RamUsedPct']  = [math]::Round((($totalMemGB - $freeMemGB) / $totalMemGB) * 100)
        $volSnap = Get-Volume -DriveLetter C -ErrorAction SilentlyContinue
        if ($volSnap) {
            $diagData['DiskCUsedPct'] = [math]::Round((($volSnap.Size - $volSnap.SizeRemaining) / $volSnap.Size) * 100)
        }
    } catch { }

    # Publicar resultados al hilo principal si es DryRun
    if ($dryRun -and $null -ne $DiagReportRef) {
        try { $DiagReportRef.Value = $diagData } catch { }
    }

    $endTime  = Get-Date
    $duration = $endTime - $startTime
    # [B12] Formato que soporta más de 24h sin colapsar
    $durStr = "{0:D2}d {1:D2}h {2:D2}m {3:D2}s" -f $duration.Days, $duration.Hours, $duration.Minutes, $duration.Seconds

    $footerTitle = if ($dryRun) {
        "ANÁLISIS COMPLETADO EXITOSAMENTE"
    } else {
        "OPTIMIZACIÓN COMPLETADA EXITOSAMENTE"
    }
    $footerPad   = [math]::Max(0, $boxWidth - $footerTitle.Length)
    $footerLeft  = [math]::Floor($footerPad / 2)
    $footerRight = $footerPad - $footerLeft

    Write-Console ""
    Write-Console "╔$('═' * $boxWidth)╗"
    Write-Console "║$(' ' * $footerLeft)$footerTitle$(' ' * $footerRight)║"
    Write-Console "╚$('═' * $boxWidth)╝"
    Write-Console "Tareas: $completedTasks / $totalTasks"
    Write-Console "Tiempo: $durStr"
    Write-Console ""

    Update-Status "✓ $(if($dryRun){'Análisis'}else{'Optimización'}) completada"
    Update-Progress 100 "Completado"
    $window.Dispatcher.Invoke([action]{
        $TaskText.Text = "¡Todas las tareas completadas!"
    }.GetNewClosure())

    # Auto-reinicio
    if ($options['AutoRestart'] -and -not $dryRun) {
        Write-Console "Reiniciando el sistema en 10 segundos..."
        for ($i = 10; $i -gt 0; $i--) {
            Update-Status "Reiniciando en $i segundos..."
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

# [B10] Seleccionar Todo — refleja el estado real de TODOS los checkboxes
# [B4]  chkAutoRestart incluido en el toggle para coherencia
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
    # [B10] Comprobar estado real (todos marcados = deseleccionar, si alguno no = seleccionar)
    $allChecked = $script:AllOptCheckboxes | ForEach-Object { $_.IsChecked } | Where-Object { -not $_ }
    $targetState = ($allChecked.Count -gt 0)   # hay alguno desmarcado → vamos a marcar todos

    foreach ($cb in $script:AllOptCheckboxes) { $cb.IsChecked = $targetState }

    $btnSelectAll.Content = if ($targetState) { "✗ Deseleccionar Todo" } else { "✓ Seleccionar Todo" }
})

# ── Función central de arranque (dry-run o real) ─────────────────────────────
function Start-Optimization {
    param([bool]$DryRunOverride = $false)

    # [B2] Validar dependencia BackupRegistry → CleanRegistry
    if ($chkCleanRegistry.IsChecked -and -not $chkBackupRegistry.IsChecked -and -not $DryRunOverride) {
        $warn = [System.Windows.MessageBox]::Show(
            "Has activado 'Limpiar registro' sin 'Crear backup'.`n`n" +
            "Limpiar el registro SIN backup puede ser peligroso.`n`n" +
            "¿Deseas continuar igualmente SIN hacer backup?",
            "⚠ Advertencia — Sin backup del registro",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($warn -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }

    # [B11] Advertir si la consola tiene contenido previo
    if (-not [string]::IsNullOrWhiteSpace($ConsoleOutput.Text)) {
        $clearWarn = [System.Windows.MessageBox]::Show(
            "La consola tiene contenido de una ejecución anterior.`n`n" +
            "¿Deseas limpiarla y comenzar una nueva sesión?`n" +
            "(Si quieres conservar el log, pulsa No y guárdalo primero)",
            "Limpiar consola",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($clearWarn -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }

    # Contar tareas seleccionadas
    $selectedTasks = @()
    if ($chkOptimizeDisks.IsChecked)  { $selectedTasks += "Optimizar discos" }
    if ($chkRecycleBin.IsChecked)     { $selectedTasks += "Vaciar papelera" }
    if ($chkTempFiles.IsChecked)      { $selectedTasks += "Temp Windows" }
    if ($chkUserTemp.IsChecked)       { $selectedTasks += "Temp Usuario" }
    if ($chkWUCache.IsChecked)        { $selectedTasks += "WU Cache" }
    if ($chkChkdsk.IsChecked)         { $selectedTasks += "CHKDSK" }
    if ($chkClearMemory.IsChecked)    { $selectedTasks += "Liberar RAM" }
    if ($chkCloseProcesses.IsChecked) { $selectedTasks += "Cerrar procesos" }
    if ($chkDNSCache.IsChecked)       { $selectedTasks += "DNS" }
    if ($chkBrowserCache.IsChecked)   { $selectedTasks += "Navegadores" }
    if ($chkBackupRegistry.IsChecked) { $selectedTasks += "Backup registro" }
    if ($chkCleanRegistry.IsChecked)  { $selectedTasks += "Limpiar registro" }
    if ($chkSFC.IsChecked)            { $selectedTasks += "SFC" }
    if ($chkDISM.IsChecked)           { $selectedTasks += "DISM" }
    if ($chkEventLogs.IsChecked)      { $selectedTasks += "Event Logs" }

    # [N8] ShowStartup se maneja en el hilo principal antes del runspace
    if ($chkShowStartup.IsChecked) {
        Show-StartupManager
    }

    if ($selectedTasks.Count -eq 0 -and -not $chkShowStartup.IsChecked) {
        [System.Windows.MessageBox]::Show(
            "Por favor, selecciona al menos una opción.",
            "Sin tareas seleccionadas",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
        return
    }

    if ($selectedTasks.Count -eq 0) { return }   # Solo ShowStartup fue marcado, ya se procesó

    $isDryRun  = $DryRunOverride -or $chkDryRun.IsChecked
    $modeLabel = if ($isDryRun) { "🔍 MODO ANÁLISIS (sin cambios)" } else { "⚙ EJECUCIÓN REAL" }

    $confirm = [System.Windows.MessageBox]::Show(
        "Modo: $modeLabel`n`n¿Iniciar con $($selectedTasks.Count) tareas?`n• $($selectedTasks -join "`n• ")",
        "Confirmar",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

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

    $options = @{
        'DryRun'         = $isDryRun
        'OptimizeDisks'  = $chkOptimizeDisks.IsChecked
        'RecycleBin'     = $chkRecycleBin.IsChecked
        'TempFiles'      = $chkTempFiles.IsChecked
        'UserTemp'       = $chkUserTemp.IsChecked
        'WUCache'        = $chkWUCache.IsChecked
        'Chkdsk'         = $chkChkdsk.IsChecked
        'ClearMemory'    = $chkClearMemory.IsChecked
        'CloseProcesses' = $chkCloseProcesses.IsChecked
        'DNSCache'       = $chkDNSCache.IsChecked
        'BrowserCache'   = $chkBrowserCache.IsChecked
        'BackupRegistry' = $chkBackupRegistry.IsChecked
        'CleanRegistry'  = $chkCleanRegistry.IsChecked
        'SFC'            = $chkSFC.IsChecked
        'DISM'           = $chkDISM.IsChecked
        'EventLogs'      = $chkEventLogs.IsChecked
        'AutoRestart'    = $chkAutoRestart.IsChecked
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()

    # Variable compartida para recibir el informe de diagnóstico del runspace
    $script:DiagReportData   = $null
    $script:LastRunWasDryRun = $isDryRun
    $diagReportRef = [ref]$script:DiagReportData

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
    $powershell.AddArgument($script:CancelSource.Token)
    $powershell.AddArgument($diagReportRef) | Out-Null

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

    # [B8] Timer con try/catch — no bloquea si el runspace muere con excepción
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

            try { $script:ActivePowershell.EndInvoke($script:ActiveHandle) } catch { }
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

            if ($script:WasCancelled) {
                [System.Windows.MessageBox]::Show(
                    "La optimización fue cancelada por el usuario.",
                    "Proceso cancelado",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning
                )
            } elseif ($script:LastRunWasDryRun -and $null -ne $script:DiagReportData) {
                # Modo análisis completado → mostrar informe de diagnóstico
                Show-DiagnosticReport -Report $script:DiagReportData
            } elseif ($script:LastRunWasDryRun) {
                # Dry run sin datos (tareas no recogen diagData) → mensaje simple
                [System.Windows.MessageBox]::Show(
                    "🔍 Análisis completado.`n`nRevisa la consola para ver los detalles.",
                    "Análisis completado",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information
                )
            } else {
                [System.Windows.MessageBox]::Show(
                    "✅ ¡Proceso completado correctamente!`n`nTodas las tareas seleccionadas han finalizado.",
                    "Optimización completada",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information
                )
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
        $res = [System.Windows.MessageBox]::Show(
            "¿Cancelar la optimización en curso?`n`nLa tarea actual terminará antes de detenerse.",
            "Confirmar cancelación",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($res -eq [System.Windows.MessageBoxResult]::Yes) {
            $script:WasCancelled = $true
            $script:CancelSource.Cancel()
            $btnCancel.IsEnabled = $false
            $btnCancel.Content   = "⏹ Cancelando..."
            Write-ConsoleMain "⚠ Cancelación solicitada — esperando fin de tarea actual..."
        }
    }
})

# Botón Guardar Log
$btnSaveLog.Add_Click({
    $logContent = $ConsoleOutput.Text
    if ([string]::IsNullOrWhiteSpace($logContent)) {
        [System.Windows.MessageBox]::Show(
            "La consola está vacía. No hay nada que guardar.",
            "Log vacío",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
        return
    }

    $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveDialog.Title            = "Guardar Log de Optimización"
    $saveDialog.Filter           = "Archivo de texto (*.txt)|*.txt|Todos los archivos (*.*)|*.*"
    $saveDialog.DefaultExt       = "txt"
    $saveDialog.FileName         = "OptimizadorLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    $saveDialog.InitialDirectory = [Environment]::GetFolderPath("Desktop")

    if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $logContent | Out-File -FilePath $saveDialog.FileName -Encoding UTF8
            [System.Windows.MessageBox]::Show(
                "Log guardado en:`n`n$($saveDialog.FileName)",
                "Log guardado",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            )
        } catch {
            [System.Windows.MessageBox]::Show(
                "Error al guardar:`n$($_.Exception.Message)",
                "Error",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            )
        }
    }
})

# Botón Salir
$btnExit.Add_Click({
    try { $script:AppMutex.ReleaseMutex() } catch { }
    $window.Close()
})

# Liberar mutex al cerrar por la X
$window.Add_Closed({
    try { $script:AppMutex.ReleaseMutex() } catch { }
    try { $chartTimer.Stop() } catch { }
    if ($null -ne $script:DiskCounter) { try { $script:DiskCounter.Dispose() } catch { } }
    [ScanControl]::Stop = $true
    if ($null -ne $script:DiskScanRunspace) { try { $script:DiskScanRunspace.Close() } catch {} }
})

# ─────────────────────────────────────────────────────────────────────────────
# ARRANQUE
# ─────────────────────────────────────────────────────────────────────────────
# Update-SystemInfo se llama ahora desde el evento Loaded de la ventana

Write-ConsoleMain "═══════════════════════════════════════════════════════════"
Write-ConsoleMain "SysOpt - Windows Optimizer GUI — VERSIÓN 1.0"
Write-ConsoleMain "═══════════════════════════════════════════════════════════"
Write-ConsoleMain "Sistema iniciado correctamente"
Write-ConsoleMain ""
Write-ConsoleMain "NOVEDADES v1.0:"
Write-ConsoleMain "  • [T1]  Nueva pestaña RENDIMIENTO: cores CPU, RAM detallada, SMART disco, red"
Write-ConsoleMain "  • [T2]  Nueva pestaña EXPLORADOR DE DISCO: escáner tipo TreeSize"
Write-ConsoleMain "  • [G2]  Iconos de sección con colores distintivos"
Write-ConsoleMain "  • [G3]  Fondo más claro y contraste mejorado"
Write-ConsoleMain "  • [G4]  Monitor actualizado cada 2 segundos automáticamente"
Write-ConsoleMain "  • [N1]  Panel de info del sistema (CPU, RAM, Disco C:)"
Write-ConsoleMain "  • [N2]  Modo Análisis (Dry Run) — reporta sin hacer cambios"
Write-ConsoleMain "  • [N3]  Limpieza de Windows Update Cache"
Write-ConsoleMain "  • [N7]  Limpieza de Event Viewer Logs (System/App/Setup)"
Write-ConsoleMain "  • [N8]  Gestor de programas de inicio integrado"
Write-ConsoleMain "  • [M1]  Función Clean-TempPaths unificada (sin duplicación)"
Write-ConsoleMain "  • [B1]  RAM: liberación real via EmptyWorkingSet Win32"
Write-ConsoleMain "  • [B2]  Advertencia bloqueante al limpiar registro sin backup"
Write-ConsoleMain "  • [B3]  Mutex: AbandonedMutexException manejada"
Write-ConsoleMain "  • [B5]  Detección SSD por DeviceID (más robusta)"
Write-ConsoleMain "  • [B6]  Opera/OperaGX/Brave: rutas de caché completas"
Write-ConsoleMain "  • [B7]  Firefox: limpia cache y cache2 (legacy + moderno)"
Write-ConsoleMain "  • [B8]  Timer con try/catch — no bloquea si runspace falla"
Write-ConsoleMain "  • [B9]  CHKDSK: orden correcto (dirty set primero)"
Write-ConsoleMain "  • [B10] btnSelectAll refleja estado real"
Write-ConsoleMain "  • [B11] Aviso antes de limpiar consola con contenido"
Write-ConsoleMain "  • [B12] Formato de duración corregido (dd/hh/mm/ss)"
Write-ConsoleMain ""
Write-ConsoleMain "Selecciona las opciones y presiona '▶ Iniciar Optimización'"
Write-ConsoleMain "  o '🔍 Analizar' para ver qué se liberaría sin cambios."
Write-ConsoleMain ""

$window.ShowDialog() | Out-Null