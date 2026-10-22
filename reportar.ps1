<#
.SYNOPSIS
    Arma un reporte de un problema del operador de Itris a partir de la carpeta de evidencia de una sesión
    y, solo si vos lo confirmás, lo envía.

.DESCRIPTION
    Con la carpeta de evidencia de la sesión (la que nombra el operador en sus respuestas):

      1. Lista todos los archivos que se enviarían y el tamaño total. Las capturas son de la base con la
         que trabajaste: mirá la lista antes de contestar.
      2. Arma el zip en %TEMP% y el resumen (versión del operador, los últimos 20 eventos de
         events.jsonl y el motivo), y te los muestra.
      3. Pregunta S/N (por omisión N). Con N no se envía nada y no sale nada de tu máquina.
      4. Con S: sube el zip como adjunto de una Release «reportes» del repositorio del operador y abre un
         issue con el resumen y el nombre del adjunto (gh).

    Compatible con Windows PowerShell 5.1.

.PARAMETER Sesion
    La carpeta de evidencia de la sesión.

.PARAMETER Motivo
    Una línea con lo que pasó. Si no se pasa, el script la pide.

.PARAMETER Base
    La base de la sesión, para el título del issue. Si no se pasa, se busca en events.jsonl.

.PARAMETER Raiz
    Carpeta de la instalación (de ahí se lee version.txt). Por omisión, la carpeta de este script.

.PARAMETER Respuesta
    Solo para pruebas del script: admite únicamente N (no enviar). Enviar siempre lo confirma una persona,
    escribiendo S en una consola interactiva.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File C:\ItrisOperador\reportar.ps1 "C:\ItrisOperador\artifacts\operador\<sesión>"
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Sesion = '',
    [string]$Motivo = '',
    [string]$Base = '',
    [string]$Raiz = '',
    [ValidateSet('N', 'n')]
    [string]$Respuesta = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0

# Un error corta con un mensaje claro y código 1, sin el volcado de PowerShell.
trap {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$repoEdicion = 'fmbda/itris-operador'
$releaseReportes = 'reportes'

if (-not $Sesion) { throw 'Falta la carpeta de la sesión. Uso: reportar.ps1 <carpeta de la sesión>' }
if (-not (Test-Path -LiteralPath $Sesion -PathType Container)) { throw "No existe la carpeta $Sesion." }
$Sesion = [IO.Path]::GetFullPath($Sesion).TrimEnd('\')
if (([IO.File]::GetAttributes($Sesion) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Sesion es un link: indicá la carpeta real." }
if (-not $Raiz) { $Raiz = $PSScriptRoot }

# Corre una herramienta nativa sin que su stderr corte el script (en 5.1 redirigirlo con
# ErrorActionPreference=Stop lanza) y devuelve el código de salida y las líneas.
function Invoke-Nativo([scriptblock]$bloque) {
    $previa = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try {
        $salida = @(& $bloque 2>&1 | ForEach-Object { $_.ToString() })
        $codigo = $global:LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previa
    }
    return [pscustomobject]@{ Codigo = $codigo; Salida = $salida }
}

# Los archivos de una carpeta, sin entrar en links (junctions, symlinks): en 5.1 seguirlos lleva a
# archivos de otro lugar. Los links se devuelven aparte.
function Archivos-De([string]$carpeta, [ref]$links) {
    $lista = New-Object System.Collections.ArrayList
    foreach ($entrada in [IO.Directory]::GetFileSystemEntries($carpeta)) {
        $atributos = [IO.File]::GetAttributes($entrada)
        if (($atributos -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            [void]$links.Value.Add($entrada)
        } elseif (($atributos -band [IO.FileAttributes]::Directory) -ne 0) {
            foreach ($archivo in (Archivos-De $entrada $links)) { [void]$lista.Add($archivo) }
        } else {
            [void]$lista.Add($entrada)
        }
    }
    return $lista.ToArray()
}

function Formato-Tamano([long]$bytes) {
    if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ('{0:N0} KB' -f ($bytes / 1KB)) }
    return "$bytes B"
}

# --- 1. Qué se enviaría.
$listaCompleta = ''
$links = New-Object System.Collections.ArrayList
$archivos = @(Archivos-De $Sesion ([ref]$links))
if ($archivos.Count -eq 0) { throw "La carpeta $Sesion no tiene archivos." }
$total = [long]0
$detalle = @()
foreach ($archivo in $archivos) {
    $tamano = ([IO.FileInfo]$archivo).Length
    $total += $tamano
    $detalle += [pscustomobject]@{ Ruta = $archivo.Substring($Sesion.Length + 1); Tamano = $tamano }
}
Write-Host "Carpeta de la sesión: $Sesion"
Write-Host "Se enviarían $($archivos.Count) archivos, $(Formato-Tamano $total) en total (antes de comprimir):"
if ($detalle.Count -le 80) {
    foreach ($fila in $detalle) { Write-Host ("  {0}  ({1})" -f $fila.Ruta, (Formato-Tamano $fila.Tamano)) }
} else {
    $listaCompleta = Join-Path ([IO.Path]::GetTempPath()) ("itris-reporte-archivos-" + [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '.txt')
    [IO.File]::WriteAllLines($listaCompleta, @($detalle | ForEach-Object { "{0}  ({1})" -f $_.Ruta, (Formato-Tamano $_.Tamano) }), (New-Object System.Text.UTF8Encoding($false)))
    $porCarpeta = $detalle | Group-Object -Property { $partes = $_.Ruta -split '\\'; if ($partes.Count -gt 1) { $partes[0] } else { '(raíz)' } }
    foreach ($grupo in $porCarpeta) {
        $suma = [long]0
        foreach ($fila in $grupo.Group) { $suma += $fila.Tamano }
        Write-Host ("  {0}: {1} archivos, {2}" -f $grupo.Name, $grupo.Count, (Formato-Tamano $suma))
    }
    Write-Host "  La lista completa, archivo por archivo, está en $listaCompleta"
}
if ($links.Count -gt 0) {
    Write-Warning ("Estos links de la carpeta NO se incluyen: " + ($links.ToArray() -join ', '))
}

# --- 2. Motivo, zip y resumen (todo local, en %TEMP%).
if (-not $Motivo) {
    if (-not [Console]::IsInputRedirected) {
        try { $Motivo = [string](Read-Host 'Motivo del reporte, en una línea') } catch { $Motivo = '' }
    }
}
$Motivo = (($Motivo -replace '\s+', ' ').Trim())
if (-not $Motivo) { throw 'Hace falta un motivo (una línea con lo que pasó).' }

$archivoEventos = Join-Path $Sesion 'events.jsonl'
$ultimosEventos = @()
if (Test-Path -LiteralPath $archivoEventos -PathType Leaf) {
    $lineas = @([IO.File]::ReadAllLines($archivoEventos) | Where-Object { $_.Trim() })
    $ultimosEventos = @($lineas | Select-Object -Last 20 | ForEach-Object { if ($_.Length -gt 600) { $_.Substring(0, 600) + '...' } else { $_ } })
    if (-not $Base) {
        foreach ($linea in $lineas) {
            if ($linea -match '"base"\s*:\s*"([^"]+)"') { $Base = $Matches[1]; break }
        }
    }
}
if (-not $Base) { $Base = 'sin-base' }

$archivoVersion = Join-Path $Raiz 'version.txt'
$textoVersion = if (Test-Path -LiteralPath $archivoVersion -PathType Leaf) { ([IO.File]::ReadAllText($archivoVersion)).Trim() } else { '(sin version.txt en la instalación)' }

$ahora = [DateTime]::Now
$fecha = $ahora.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
$nombreBaseArchivo = ($Base -replace '[^A-Za-z0-9_.-]', '_')
$nombreZip = "reporte-$nombreBaseArchivo-" + $ahora.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) + '.zip'
$rutaZip = Join-Path ([IO.Path]::GetTempPath()) $nombreZip
$rutaResumen = Join-Path ([IO.Path]::GetTempPath()) ($nombreZip -replace '\.zip$', '.md')

Add-Type -AssemblyName System.IO.Compression
$flujoZip = [IO.File]::Open($rutaZip, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
try {
    $archivoZip = New-Object System.IO.Compression.ZipArchive($flujoZip, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($archivo in $archivos) {
            $nombreEntrada = $archivo.Substring($Sesion.Length + 1).Replace('\', '/')
            $entrada = $archivoZip.CreateEntry($nombreEntrada, [System.IO.Compression.CompressionLevel]::Optimal)
            $destino = $entrada.Open()
            try {
                $origen = [IO.File]::Open($archivo, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try { $origen.CopyTo($destino) } finally { $origen.Dispose() }
            } finally { $destino.Dispose() }
        }
    } finally { $archivoZip.Dispose() }
} finally { $flujoZip.Dispose() }

$cuerpo = @()
$cuerpo += "Motivo: $Motivo"
$cuerpo += "Base: $Base"
$cuerpo += "Fecha: $fecha"
$cuerpo += ''
$cuerpo += 'Versión del operador (version.txt):'
$cuerpo += '```'
$cuerpo += $textoVersion
$cuerpo += '```'
$cuerpo += ''
$cuerpo += "Últimos $($ultimosEventos.Count) eventos de events.jsonl:"
$cuerpo += '```'
$cuerpo += $(if ($ultimosEventos.Count -gt 0) { $ultimosEventos } else { '(la sesión no tiene events.jsonl)' })
$cuerpo += '```'
$cuerpo += ''
$cuerpo += "Adjunto: $nombreZip (Release $releaseReportes, $($archivos.Count) archivos, $(Formato-Tamano ((Get-Item -LiteralPath $rutaZip).Length)))."
[IO.File]::WriteAllLines($rutaResumen, $cuerpo, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host "Se armó el zip en $rutaZip ($(Formato-Tamano ((Get-Item -LiteralPath $rutaZip).Length)))."
Write-Host 'Este sería el texto del issue:'
Write-Host '----------------------------------------'
Write-Host "Título: $Base ${fecha}: $Motivo"
$cuerpo | ForEach-Object { Write-Host $_ }
Write-Host '----------------------------------------'

# --- 3. La confirmación. Sin una S escrita por una persona, no sale nada: -Respuesta solo admite N, y con la
# entrada redirigida (un script, un modelo) Read-Host no espera a nadie, así que también es N.
Write-Host ''
Write-Host 'Atención: las capturas (.png) muestran la pantalla de Itris tal como estaba: pueden verse nombres de clientes y proveedores, CUIT, importes y otros datos del negocio de la base con la que trabajaste. Los eventos de arriba también pueden traer textos escritos o leídos de la pantalla. El issue y el zip los ven todas las personas con acceso al repositorio del operador. Si no querés que salgan, contestá N; podés revisar el zip en la ruta de arriba y mandarlo por otro medio.' -ForegroundColor Yellow
if ($Respuesta -or [Console]::IsInputRedirected) {
    $contesto = 'N'
} else {
    try { $contesto = [string](Read-Host '¿Enviar el zip y el issue, con esos datos? [S/N, por omisión N]') } catch { $contesto = 'N' }
}
if ($contesto.Trim() -notmatch '^[sS]([iíIÍ])?$') {
    Write-Host 'No se envió nada. El zip y el resumen quedan en tu carpeta temporal; podés borrarlos o mandarlos por otro medio.'
    exit 0
}

# --- 4. Envío.
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'No está gh (GitHub CLI) en el PATH: no se pudo enviar. El zip y el resumen quedan en tu carpeta temporal.' }
$auth = Invoke-Nativo { & gh auth status }
if ($auth.Codigo -ne 0) { throw 'gh no tiene sesión iniciada (corré «gh auth login»): no se envió nada.' }

$adjuntado = $false
$existe = Invoke-Nativo { & gh release view $releaseReportes --repo $repoEdicion }
$listaParaSubir = $true
if ($existe.Codigo -ne 0) {
    # Una prerelease no es la «última» Release: la instalación sigue bajando la edición, no los reportes.
    $crear = Invoke-Nativo { & gh release create $releaseReportes --repo $repoEdicion --prerelease --title 'Reportes' --notes 'Adjuntos de los reportes (issues).' }
    if ($crear.Codigo -ne 0) {
        $listaParaSubir = $false
        Write-Warning ("No se pudo crear la Release de reportes (¿tu cuenta puede escribir en el repositorio?):`n  " + ($crear.Salida -join "`n  "))
    }
}
if ($listaParaSubir) {
    $subida = Invoke-Nativo { & gh release upload $releaseReportes $rutaZip --repo $repoEdicion }
    if ($subida.Codigo -eq 0) {
        $adjuntado = $true
        Write-Host "Zip subido como adjunto de la Release $releaseReportes."
    } else {
        Write-Warning ("No se pudo subir el zip:`n  " + ($subida.Salida -join "`n  "))
    }
}
if (-not $adjuntado) {
    $cuerpo += ''
    $cuerpo += "NO SE PUDO ADJUNTAR el zip (queda en la PC de quien reporta: $nombreZip)."
    [IO.File]::WriteAllLines($rutaResumen, $cuerpo, (New-Object System.Text.UTF8Encoding($false)))
}

$issue = Invoke-Nativo { & gh issue create --repo $repoEdicion --title "$Base ${fecha}: $Motivo" --body-file $rutaResumen }
if ($issue.Codigo -ne 0) {
    throw ("No se pudo abrir el issue (código $($issue.Codigo)):`n  " + ($issue.Salida -join "`n  ") + "`nEl resumen quedó en $rutaResumen.")
}
Write-Host ($issue.Salida -join "`n")
if (-not $adjuntado) { Write-Warning "El zip no se pudo adjuntar: quedó en $rutaZip; mandalo por otro medio." }
# Ya salió: el resumen y, si se adjuntó, el zip (capturas de la base) no tienen por qué quedar en el disco.
foreach ($sobrante in @($rutaResumen, $(if ($adjuntado) { $rutaZip } else { '' }), $listaCompleta)) {
    if ($sobrante -and (Test-Path -LiteralPath $sobrante -PathType Leaf)) { Remove-Item -LiteralPath $sobrante -Force }
}
Write-Host 'Listo. Reporte enviado.'
exit 0
