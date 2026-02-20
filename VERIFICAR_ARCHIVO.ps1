# Ejecuta esto en la misma carpeta para verificar que tienes el archivo correcto
$path = "$PSScriptRoot\SysOpt 2.0.ps1"
if (-not (Test-Path $path)) {
    Write-Host "ERROR: No se encuentra el archivo en: $path" -ForegroundColor Red
    exit
}
$content = Get-Content $path -Raw
$lines   = $content -split "`n"
Write-Host "Total lineas: $($lines.Count)" -ForegroundColor Cyan
Write-Host "Linea 1796: $($lines[1795].Trim())" -ForegroundColor Yellow

if ($content -match 'stopPSVar') {
    Write-Host ""
    Write-Host "*** ARCHIVO INCORRECTO - Todavia tiene el codigo viejo ***" -ForegroundColor Red
    Write-Host "Descarga el archivo SysOpt 2.0.ps1 del chat y reemplaza este." -ForegroundColor Red
} else {
    Write-Host ""
    Write-Host "Archivo correcto - No contiene stopPSVar" -ForegroundColor Green
    if ($content -match 'ScanControl') {
        Write-Host "OK: Clase ScanControl presente (nuevo codigo)" -ForegroundColor Green
    }
}
