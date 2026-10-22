<#
.SYNOPSIS
    Instala el operador de Itris (servidor MCP para Claude Code) en esta PC.

.DESCRIPTION
    1. Si la raíz ya tiene el anfitrión instalado, no toca nada y remite a actualizar.ps1.
    2. Chequeo previo (cada punto dice qué corregir). Si falta algo obligatorio, lista TODO lo que
       falta y no sigue. Este script nunca cambia la configuración del sistema: lo que haya que
       instalar como administrador (el OCR en español) se imprime como comando para que lo corras vos.
    3. Crea la raíz (por omisión C:\ItrisOperador) con harness\bases.txt de ejemplo, copia
       actualizar.ps1 y reportar.ps1 a la raíz y llama a actualizar.ps1, que baja la última versión
       (gh release download), deja el anfitrión en anfitrion\ y el servidor en
       artifacts\mcp\versiones\<sello>\ (con «listo» solo si pasa su autoprueba), y copia las skills de
       Claude Code, los scripts de Python y la lista del diccionario.
    4. Registra el servidor en Claude Code: claude mcp add <Nombre> --scope user -- <raíz>\anfitrion\
       Itris.UiAgent.McpHost.exe --raiz <raíz>.

    Después, editá <raíz>\harness\bases.txt con tus bases de prueba y reiniciá Claude Code.

    Compatible con Windows PowerShell 5.1.

.PARAMETER Raiz
    Carpeta de la instalación. Por omisión C:\ItrisOperador.

.PARAMETER Zip
    Usa un zip de edición que ya tenés en disco en vez de bajar la última Release. Con -Zip no hace
    falta gh.

.PARAMETER Nombre
    Nombre con que se registra el servidor en Claude Code. Por omisión itris-operador.

.PARAMETER SinRegistrar
    No registra el servidor en Claude Code (te imprime el comando para hacerlo a mano).

.PARAMETER OmitirChequeo
    Solo para pruebas del propio instalador: lista lo que falta del chequeo previo y sigue igual. Con
    una PC que no cumple los requisitos el operador se niega a conectarse (por ejemplo, por la
    resolución de la pantalla).

.PARAMETER DestinoSkills
    Solo para pruebas del propio instalador: carpeta donde se copian las skills. Por omisión
    %USERPROFILE%\.claude\skills.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\instalar.ps1
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Raiz = 'C:\ItrisOperador',
    [string]$Zip = '',
    [string]$Nombre = 'itris-operador',
    [switch]$SinRegistrar,
    [switch]$OmitirChequeo,
    [string]$DestinoSkills = ''
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

# Resoluciones del monitor principal que el operador tiene validadas. El servidor tiene su propia lista
# (TestOperatorDisplay en Itris.UiAgent.Core): si una cambia, cambia la otra.
# La línea siguiente la lee un test de la suite (edicion.installer-resolutions-match-the-server): una sola línea, con este nombre y comillas simples.
$ResolucionesValidadas = @('1366x768', '1920x1080')

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

if (-not ('ItrisPantalla' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ItrisPantalla
{
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr ventana);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr ventana, IntPtr contexto);
    [DllImport("gdi32.dll")] private static extern int GetDeviceCaps(IntPtr contexto, int indice);

    // { ancho lógico, alto lógico, ancho físico, alto físico } del monitor principal.
    public static int[] Medir()
    {
        IntPtr contexto = GetDC(IntPtr.Zero);
        if (contexto == IntPtr.Zero) { throw new InvalidOperationException("no se pudo leer la pantalla"); }
        try
        {
            return new int[] {
                GetDeviceCaps(contexto, 8), GetDeviceCaps(contexto, 10),
                GetDeviceCaps(contexto, 118), GetDeviceCaps(contexto, 117)
            };
        }
        finally { ReleaseDC(IntPtr.Zero, contexto); }
    }
}
'@
}

$raizCompleta = [IO.Path]::GetFullPath($Raiz)
$carpetaAnfitrion = Join-Path $raizCompleta 'anfitrion'
if ($raizCompleta.TrimEnd('\') -ne 'C:\ItrisOperador') {
    Write-Host ''
    Write-Host "AVISO: instalás en $raizCompleta y no en C:\ItrisOperador. Las skills que se copian nombran C:\ItrisOperador (reportar.ps1, los scripts y la lista del diccionario): el modelo va a apuntar a un lugar equivocado. Usá otra raíz solo para probar el instalador." -ForegroundColor Yellow
    Write-Host ''
}

# --- 1. Si ya está instalado, no se reinstala. «Instalado» es una instalación completa: version.txt
# lo escribe actualizar.ps1 al final y el sello del anfitrión coincide con el de version.txt. Si quedó a
# medias (por ejemplo, falló una copia después de poner el anfitrión), este instalador la completa:
# actualizar.ps1 es idempotente y después se registra el servidor.
function Leer-SelloDe([string]$archivo) {
    if (-not (Test-Path -LiteralPath $archivo -PathType Leaf)) { return '' }
    foreach ($linea in [IO.File]::ReadAllLines($archivo)) {
        if ($linea -match '^\s*(?:sello:\s*)?(\d{8}T\d{6}Z)\s*$') { return $Matches[1] }
    }
    return ''
}
if (Test-Path -LiteralPath $carpetaAnfitrion) {
    $selloVersion = Leer-SelloDe (Join-Path $raizCompleta 'version.txt')
    $selloAnfitrion = Leer-SelloDe (Join-Path $carpetaAnfitrion 'sello.txt')
    if ($selloVersion -and $selloVersion -eq $selloAnfitrion) {
        Write-Host "Ya hay una instalación en $raizCompleta (existe $carpetaAnfitrion)."
        Write-Host "No se toca nada. Para actualizarla: powershell -NoProfile -ExecutionPolicy Bypass -File `"$raizCompleta\actualizar.ps1`""
        exit 0
    }
    Write-Warning "Hay una instalación incompleta en ${raizCompleta}: se completa ahora."
}

$scriptsHermanos = @('actualizar.ps1', 'reportar.ps1')
foreach ($hermano in $scriptsHermanos) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $hermano) -PathType Leaf)) {
        throw "Falta $hermano al lado de instalar.ps1 ($PSScriptRoot): corré el instalador desde la carpeta del repositorio completa."
    }
}
if ($Zip -and -not (Test-Path -LiteralPath $Zip -PathType Leaf)) { throw "No existe el zip $Zip." }

# --- 2. Chequeo previo.
$items = New-Object System.Collections.ArrayList
function Agregar-Item([string]$que, [bool]$ok, [string]$detalle, [string]$corregir) {
    [void]$items.Add([pscustomobject]@{ Que = $que; Ok = $ok; Detalle = $detalle; Corregir = $corregir })
}

# Escala y resolución del monitor principal.
$medidas = $null
try { $medidas = [ItrisPantalla]::Medir() } catch { $medidas = $null }
if ($medidas -eq $null) {
    Agregar-Item 'Escala de pantalla al 100 %' $false 'no se pudo leer la pantalla' 'Abrí Configuración > Sistema > Pantalla y poné la escala en 100 %.'
    Agregar-Item 'Resolución del monitor principal' $false 'no se pudo leer la pantalla' ("Poné el monitor principal en una de estas resoluciones: " + ($ResolucionesValidadas -join ', ') + '.')
} else {
    $escalaOk = ($medidas[0] -eq $medidas[2]) -and ($medidas[1] -eq $medidas[3])
    $detalleEscala = if ($escalaOk) { 'sin escalado' } else { "$($medidas[0])x$($medidas[1]) lógicos, $($medidas[2])x$($medidas[3]) físicos" }
    Agregar-Item 'Escala de pantalla al 100 %' $escalaOk $detalleEscala 'Abrí Configuración > Sistema > Pantalla > Escala y poné 100 %. Cerrá la sesión de Windows y volvé a entrar.'
    $resolucion = "$($medidas[2])x$($medidas[3])"
    Agregar-Item 'Resolución del monitor principal' ($ResolucionesValidadas -contains $resolucion) "$resolucion (validadas: $($ResolucionesValidadas -join ', '))" ("Poné el monitor principal en una de estas resoluciones: " + ($ResolucionesValidadas -join ', ') + '. Con otra, el operador se niega a conectarse.')
}

# OCR de Windows en español (es-ES). Se lee por WinRT, que no necesita administrador;
# si falla, se pregunta por la capacidad de Windows.
$ocrOk = $false
$ocrDetalle = 'no está instalado'
try {
    [void][Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
    $idiomasOcr = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag })
    $ocrOk = ($idiomasOcr -contains 'es-ES')
    $ocrDetalle = if ($ocrOk) { 'instalado' } else { 'idiomas de OCR instalados: ' + $(if ($idiomasOcr.Count -gt 0) { $idiomasOcr -join ', ' } else { 'ninguno' }) }
} catch {
    try {
        $capacidad = @(Get-WindowsCapability -Online -Name 'Language.OCR*es-ES*' | Where-Object { $_.State -eq 'Installed' })
        $ocrOk = ($capacidad.Count -gt 0)
        $ocrDetalle = if ($ocrOk) { 'instalado' } else { 'no está instalado' }
    } catch {
        $ocrDetalle = 'no se pudo consultar'
    }
}
Agregar-Item 'OCR de Windows en español (es-ES)' $ocrOk $ocrDetalle 'Abrí PowerShell COMO ADMINISTRADOR (este instalador no cambia la configuración del sistema) y corré: Add-WindowsCapability -Online -Name "Language.OCR~~~es-ES~0.0.1.0"  (necesita Internet). Después cerrá esa consola y volvé a correr este instalador.'

# Teclado Español (Latinoamérica): vale la distribución 0000080A en algún idioma de la lista, o la etiqueta de
# idioma es-419 (el idioma es-419 trae 080A:0000080A por omisión). Lo que escribe SendInput depende de la
# distribución, pero la etiqueta es-419 se acepta igual como lo documenta el README.
$tecladoOk = $false
try {
    foreach ($idioma in @(Get-WinUserLanguageList)) {
        if ($idioma.LanguageTag -eq 'es-419') { $tecladoOk = $true }
        foreach ($tip in @($idioma.InputMethodTips)) {
            if ($tip -match ':0000080A$') { $tecladoOk = $true }
        }
    }
} catch { $tecladoOk = $false }
Agregar-Item 'Teclado Español (Latinoamérica)' $tecladoOk $(if ($tecladoOk) { 'presente' } else { 'no hay ni la distribución 0000080A ni el idioma es-419 en la lista de idiomas' }) 'Abrí Configuración > Hora e idioma > Idioma y región, agregá Español (Latinoamérica) (idioma es-419, distribución 0000080A) y dejá ese teclado.'

# Formato regional Español (Argentina).
$cultura = (Get-Culture).Name
Agregar-Item 'Formato regional Español (Argentina)' ($cultura -eq 'es-AR') "formato actual: $cultura" 'Abrí Configuración > Hora e idioma > Idioma y región > Formato regional y elegí Español (Argentina).'

# Excel.
$excelOk = Test-Path -LiteralPath 'Registry::HKEY_CLASSES_ROOT\Excel.Application'
Agregar-Item 'Microsoft Excel' $excelOk $(if ($excelOk) { 'instalado' } else { 'no está registrado' }) 'Instalá Microsoft Excel (las exportaciones de grillas lo usan).'

# Python 3.10 o más nuevo.
$pythonDetalle = 'no se encontró'
$pythonOk = $false
foreach ($candidato in @(@('py', '-3'), @('python'))) {
    if (-not (Get-Command $candidato[0] -ErrorAction SilentlyContinue)) { continue }
    $resultado = Invoke-Nativo { if ($candidato.Count -gt 1) { & $candidato[0] $candidato[1] --version } else { & $candidato[0] --version } }
    $texto = ($resultado.Salida -join ' ')
    if ($resultado.Codigo -eq 0 -and $texto -match 'Python (\d+)\.(\d+)') {
        $pythonDetalle = "Python $($Matches[1]).$($Matches[2])"
        if ([int]$Matches[1] -gt 3 -or ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -ge 10)) { $pythonOk = $true; break }
    }
}
Agregar-Item 'Python 3.10 o más nuevo' $pythonOk $pythonDetalle 'Instalá Python 3.10 o más nuevo desde python.org (con el lanzador «py»).'

# Claude Code.
$claudeOk = $false
$claudeDetalle = 'no se encontró «claude» en el PATH'
if (Get-Command claude -ErrorAction SilentlyContinue) {
    $resultado = Invoke-Nativo { & claude --version }
    $claudeOk = ($resultado.Codigo -eq 0)
    $claudeDetalle = if ($claudeOk) { ($resultado.Salida -join ' ').Trim() } else { 'claude --version falló' }
}
Agregar-Item 'Claude Code' $claudeOk $claudeDetalle 'Instalá Claude Code y comprobá que «claude --version» anda en una consola nueva.'

# gh con sesión: solo hace falta para bajar la Release.
if ($Zip) {
    Agregar-Item 'gh (GitHub CLI) con sesión iniciada' $true 'no hace falta con -Zip' ''
} else {
    $ghOk = $false
    $ghDetalle = 'no se encontró «gh» en el PATH'
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $resultado = Invoke-Nativo { & gh auth status }
        $ghOk = ($resultado.Codigo -eq 0)
        $ghDetalle = if ($ghOk) { 'con sesión' } else { 'sin sesión iniciada' }
    }
    Agregar-Item 'gh (GitHub CLI) con sesión iniciada' $ghOk $ghDetalle 'Instalá gh (cli.github.com) y corré «gh auth login» con la cuenta que tiene acceso al repositorio del operador.'
}

Write-Host 'Chequeo previo:'
foreach ($item in $items) {
    $marca = if ($item.Ok) { '[ok]   ' } else { '[FALTA]' }
    Write-Host ("  {0} {1} - {2}" -f $marca, $item.Que, $item.Detalle)
}
$faltan = @($items | Where-Object { -not $_.Ok })
if ($faltan.Count -gt 0) {
    Write-Host ''
    Write-Host 'Qué corregir (en este orden):'
    $numero = 0
    foreach ($item in $faltan) {
        $numero++
        Write-Host ("  {0}. {1}" -f $numero, $item.Que)
        Write-Host ("     {0}" -f $item.Corregir)
    }
    if (-not $OmitirChequeo) {
        Write-Host ''
        Write-Host 'No se instaló nada. Corregí lo de arriba y volvé a correr el instalador.'
        exit 1
    }
    Write-Warning 'Se sigue igual por -OmitirChequeo: con esta PC el operador puede negarse a conectarse.'
}

# --- 3. La raíz.
Write-Host ''
Write-Host "Instalando en $raizCompleta..."
foreach ($subcarpeta in @('', 'harness', 'scripts', 'listas', 'artifacts\mcp\versiones')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $raizCompleta $subcarpeta) | Out-Null
}

$archivoBases = Join-Path $raizCompleta 'harness\bases.txt'
if (-not (Test-Path -LiteralPath $archivoBases)) {
    $textoBases = @(
        '# Bases de prueba que el operador puede abrir.',
        '#',
        '# Una línea por base, con el nombre exacto que muestra la barra de estado de Itris:',
        '#     prueba = NOMBRE_DE_LA_BASE',
        '# Y una sola línea «objetivo» con la base con la que vas a trabajar (tiene que estar entre las «prueba»):',
        '#     objetivo = NOMBRE_DE_LA_BASE',
        '#',
        '# El nombre de la base tiene que terminar en un sufijo de prueba (después de un guion bajo; puede',
        '# seguir un dígito, por ejemplo _TEST2): ITRIS, SERACT, CONSUL, TEST, TESTING, DESA, PRUEBA,',
        '# PREPROD, PROYECTO, POS, WEB, API. Una base cuyo nombre no termina así se niega siempre, aunque',
        '# figure acá. Producción no se opera nunca.',
        '#',
        '# Ejemplo (sacá el # de las dos líneas y poné tu base):',
        '#     objetivo = CLIENTE_ITRIS',
        '#     prueba = CLIENTE_ITRIS',
        ''
    ) -join "`r`n"
    [IO.File]::WriteAllText($archivoBases, $textoBases, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  harness\bases.txt de ejemplo creado."
} else {
    Write-Host "  harness\bases.txt ya existía: no se toca."
}

# actualizar.ps1 y reportar.ps1 viven en la raíz, para correrlos sin volver a este clon.
foreach ($hermano in $scriptsHermanos) {
    $origen = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $hermano))
    $destino = [IO.Path]::GetFullPath((Join-Path $raizCompleta $hermano))
    if ($origen -ne $destino) { Copy-Item -LiteralPath $origen -Destination $destino -Force }
}

# actualizar.ps1 hace el resto: baja la versión, la deja lista, copia skills y scripts.
$parametros = @{ Raiz = $raizCompleta }
if ($Zip) { $parametros['Zip'] = $Zip }
if ($DestinoSkills) { $parametros['DestinoSkills'] = $DestinoSkills }
$global:LASTEXITCODE = 0
& (Join-Path $raizCompleta 'actualizar.ps1') @parametros
if ($LASTEXITCODE -ne 0) {
    throw "La instalación de la versión falló (código $LASTEXITCODE). Corregí lo que dice arriba y volvé a correr este instalador."
}

# --- 4. Registro del servidor en Claude Code.
$anfitrionExe = Join-Path $carpetaAnfitrion 'Itris.UiAgent.McpHost.exe'
# El '--' va entre comillas: «claude» suele ser un script de PowerShell (npm) y Windows PowerShell 5.1 se
# come un «--» sin comillas al pasarle los argumentos; claude recibiría --raiz como opción propia.
$comandoRegistro = "claude mcp add $Nombre --scope user '--' `"$anfitrionExe`" --raiz `"$raizCompleta`""
if ($SinRegistrar) {
    Write-Host ''
    Write-Host "Sin registrar (-SinRegistrar). Para registrarlo, en PowerShell: $comandoRegistro"
} else {
    $existente = Invoke-Nativo { & claude mcp get $Nombre }
    if ($existente.Codigo -eq 0) {
        Write-Warning "Claude Code ya tiene un servidor llamado $Nombre; no se registra otro. Revisá que apunte a $anfitrionExe con: claude mcp get $Nombre"
    } else {
        $registro = Invoke-Nativo { & claude mcp add $Nombre --scope user '--' $anfitrionExe --raiz $raizCompleta }
        if ($registro.Codigo -ne 0) {
            $registro.Salida | ForEach-Object { Write-Host $_ }
            throw "No se pudo registrar el servidor (código $($registro.Codigo)). El resto quedó instalado; registralo a mano, en PowerShell, con: $comandoRegistro"
        }
        # Se comprueba lo registrado: si el '--' se hubiera perdido, --raiz no figuraría entre los argumentos.
        $registrado = Invoke-Nativo { & claude mcp get $Nombre }
        if ($registrado.Codigo -ne 0 -or (($registrado.Salida -join ' ') -notmatch '--raiz')) {
            $registrado.Salida | ForEach-Object { Write-Host $_ }
            throw "El servidor quedó registrado sin el argumento --raiz. Quitalo con «claude mcp remove $Nombre --scope user» y registralo a mano, en PowerShell, con: $comandoRegistro"
        }
        Write-Host "Servidor registrado en Claude Code como $Nombre."
    }
}

Write-Host ''
Write-Host 'Listo. Falta:'
Write-Host "  1. Editar $archivoBases con tus bases de prueba."
Write-Host '  2. Reiniciar Claude Code.'
exit 0
