<#
.SYNOPSIS
    Actualiza el operador de Itris a la última versión publicada.

.DESCRIPTION
    Baja la última Release del repositorio del operador (gh release download), y si su sello ya está
    instalado, termina. Si no:

      - deja el servidor en <raíz>\artifacts\mcp\versiones\<sello>\, corre su autoprueba del OCR
        (--autoprueba-ocr) y recién si pasa escribe el marcador «listo»: Claude Code toma la versión
        en el pedido siguiente, sin cerrarlo, y nunca toma una que no pasó la autoprueba;
      - si el anfitrión del paquete difiere del instalado, te pide cerrar Claude Code y lo reemplaza
        solo con Claude Code cerrado;
      - actualiza las skills (solo las carpetas que copió este instalador, las que tienen la marca
        .copiada-desde-itris-operador-edicion; una carpeta sin esa marca, o con la marca del operador
        .copiada-desde-itris-ui-agent (D-159), no se pisa),
        los scripts de Python y la lista del diccionario;
      - deja las 3 versiones del servidor más nuevas y borra las anteriores.

    Se corre desde <raíz> (por omisión C:\ItrisOperador). Conviene correrlo en una consola de
    PowerShell aparte, no dentro de una sesión de Claude Code.

    Compatible con Windows PowerShell 5.1.

.PARAMETER Raiz
    Carpeta de la instalación. Por omisión, la carpeta de este script si es una instalación, o
    C:\ItrisOperador.

.PARAMETER Zip
    Usa un zip de edición que ya tenés en disco en vez de bajar la última Release.

.PARAMETER DestinoSkills
    Solo para pruebas de los scripts: carpeta donde se copian las skills. Por omisión
    %USERPROFILE%\.claude\skills.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File C:\ItrisOperador\actualizar.ps1
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Raiz = '',
    [string]$Zip = '',
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

$repoEdicion = 'fmbda/itris-operador'
$patronSello = '^\d{8}T\d{6}Z$'
# Marca propia de la edición. NO es la de publicar-mcp.ps1 (.copiada-desde-itris-ui-agent, D-159): una carpeta
# con la marca del operador es de sus sesiones, y este instalador no la reemplaza nunca (R25).
$marcaSkill = '.copiada-desde-itris-operador-edicion'
$marcaOperador = '.copiada-desde-itris-ui-agent'
$ejecutableServidor = 'Itris.UiAgent.Mcp.exe'
$ejecutableAnfitrion = 'Itris.UiAgent.McpHost.exe'
$actualizarNuevo = ''
$versionesQueSeConservan = 3
$minutosAutoprueba = 3

if (-not $Raiz) {
    $Raiz = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'harness\bases.txt')) { $PSScriptRoot } else { 'C:\ItrisOperador' }
}
$Raiz = [IO.Path]::GetFullPath($Raiz)
if (-not $DestinoSkills) { $DestinoSkills = Join-Path $env:USERPROFILE '.claude\skills' }
$DestinoSkills = [IO.Path]::GetFullPath($DestinoSkills)
if (-not (Test-Path -LiteralPath (Join-Path $Raiz 'harness\bases.txt'))) {
    throw "$Raiz no es una instalación del operador (falta harness\bases.txt). Para instalar, corré instalar.ps1."
}
if ($Zip -and -not (Test-Path -LiteralPath $Zip -PathType Leaf)) { throw "No existe el zip $Zip." }

$carpetaVersiones = Join-Path $Raiz 'artifacts\mcp\versiones'
$carpetaAnfitrion = Join-Path $Raiz 'anfitrion'
New-Item -ItemType Directory -Force -Path $carpetaVersiones | Out-Null

# --- Utilidades.

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

function Es-Link([string]$ruta) {
    $item = Get-Item -LiteralPath $ruta -Force
    return [bool]$item.LinkType -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

# Lista los links (junctions, symlinks) dentro de una carpeta sin entrar en ninguno:
# en Windows PowerShell 5.1, Get-ChildItem -Recurse y Remove-Item -Recurse siguen las junctions.
function Links-Dentro([string]$carpeta) {
    $links = @()
    foreach ($entrada in [IO.Directory]::GetFileSystemEntries($carpeta)) {
        $atributos = [IO.File]::GetAttributes($entrada)
        if (($atributos -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $links += $entrada
        }
        elseif (($atributos -band [IO.FileAttributes]::Directory) -ne 0) {
            $links += @(Links-Dentro $entrada)
        }
    }
    return $links
}

# Borra una carpeta que ya se comprobó sin links, de abajo hacia arriba y sin recursión de PowerShell.
function Borrar-CarpetaSinLinks([string]$carpeta) {
    foreach ($archivo in [IO.Directory]::GetFiles($carpeta)) {
        [IO.File]::SetAttributes($archivo, [IO.FileAttributes]::Normal)
        [IO.File]::Delete($archivo)
    }
    foreach ($sub in [IO.Directory]::GetDirectories($carpeta)) {
        Borrar-CarpetaSinLinks $sub
    }
    [IO.Directory]::Delete($carpeta, $false)
}

# Borra una carpeta solo si ella y todo lo que tiene adentro no es un link.
function Borrar-Seguro([string]$carpeta) {
    if (-not (Test-Path -LiteralPath $carpeta)) { return }
    if (Es-Link $carpeta) { throw "$carpeta es un link: no se borra." }
    $links = @(Links-Dentro $carpeta)
    if ($links.Count -gt 0) { throw "$carpeta contiene links ($($links -join ', ')): no se borra." }
    Borrar-CarpetaSinLinks $carpeta
}

function Leer-Sello([string]$archivo) {
    if (-not (Test-Path -LiteralPath $archivo -PathType Leaf)) { return '' }
    foreach ($linea in [IO.File]::ReadAllLines($archivo)) {
        if ($linea -match '^\s*sello:\s*(\S+)\s*$') { return $Matches[1] }
    }
    return ''
}

function Preguntar([string]$texto) {
    # Sin consola interactiva (entrada redirigida o cerrada) Read-Host devuelve vacío sin esperar: no es un Enter de la persona.
    if ([Console]::IsInputRedirected) { return 'N' }
    try { return [string](Read-Host $texto) } catch { return 'N' }
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# --- 1. El sello más nuevo.
$selloNuevo = ''
if ($Zip) {
    $zipPropio = [IO.Path]::GetFullPath($Zip)
    $abierto = [IO.Compression.ZipFile]::OpenRead($zipPropio)
    try {
        $entradaVersion = $abierto.Entries | Where-Object { $_.FullName -eq 'version.txt' } | Select-Object -First 1
        if ($null -eq $entradaVersion) { throw "$zipPropio no es una edición del operador (no trae version.txt)." }
        $lector = New-Object IO.StreamReader($entradaVersion.Open())
        try { $textoVersion = $lector.ReadToEnd() } finally { $lector.Dispose() }
    } finally { $abierto.Dispose() }
    if ($textoVersion -match '(?m)^\s*sello:\s*(\S+)\s*$') { $selloNuevo = $Matches[1] }
} else {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'No está gh (GitHub CLI) en el PATH. Instalalo y corré «gh auth login».' }
    $consulta = Invoke-Nativo { & gh release view --repo $repoEdicion --json tagName --jq .tagName }
    if ($consulta.Codigo -ne 0) {
        throw ("No se pudo consultar la última versión en $repoEdicion (¿gh sin sesión o sin acceso al repositorio?):`n  " + ($consulta.Salida -join "`n  "))
    }
    $selloNuevo = ($consulta.Salida -join '').Trim()
}
if ($selloNuevo -notmatch $patronSello) { throw "El sello de la versión ('$selloNuevo') no tiene el formato esperado." }

$selloInstalado = Leer-Sello (Join-Path $Raiz 'version.txt')
$archivoSelloAnfitrion = Join-Path $carpetaAnfitrion 'sello.txt'
$selloAnfitrion = if (Test-Path -LiteralPath $archivoSelloAnfitrion -PathType Leaf) { ([IO.File]::ReadAllText($archivoSelloAnfitrion)).Trim() } else { '' }
$destinoVersion = Join-Path $carpetaVersiones $selloNuevo
if ($selloInstalado -eq $selloNuevo -and $selloAnfitrion -eq $selloNuevo -and (Test-Path -LiteralPath (Join-Path $destinoVersion 'listo') -PathType Leaf)) {
    Write-Host "Ya tenés la versión $selloNuevo. No hay nada que actualizar."
    exit 0
}
Write-Host "Versión instalada: $(if ($selloInstalado) { $selloInstalado } else { 'ninguna' }). Versión nueva: $selloNuevo."

$trabajo = Join-Path ([IO.Path]::GetTempPath()) ("itris-operador-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $trabajo | Out-Null
try {
    # --- 2. El zip, descomprimido.
    if ($Zip) {
        $rutaZip = $zipPropio
    } else {
        Write-Host 'Bajando la Release...'
        $descarga = Invoke-Nativo { & gh release download $selloNuevo --repo $repoEdicion --pattern '*.zip' --dir $trabajo }
        if ($descarga.Codigo -ne 0) { throw ("No se pudo bajar la Release $selloNuevo (código $($descarga.Codigo)):`n  " + ($descarga.Salida -join "`n  ")) }
        $bajados = @(Get-ChildItem -LiteralPath $trabajo -Filter '*.zip' -File)
        if ($bajados.Count -ne 1) { throw "La Release $selloNuevo trae $($bajados.Count) zips; se esperaba uno." }
        $rutaZip = $bajados[0].FullName
    }

    $extraido = Join-Path $trabajo 'paquete'
    Write-Host 'Descomprimiendo...'
    $zipAbierto = [IO.Compression.ZipFile]::OpenRead($rutaZip)
    try {
        foreach ($entrada in $zipAbierto.Entries) {
            if ($entrada.FullName -match '(^|[\\/])\.\.([\\/]|$)' -or [IO.Path]::IsPathRooted($entrada.FullName)) {
                throw "El zip trae una ruta que sale de la carpeta ($($entrada.FullName)): no se usa."
            }
        }
    } finally { $zipAbierto.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($rutaZip, $extraido)
    foreach ($necesario in @("servidor\$ejecutableServidor", "anfitrion\$ejecutableAnfitrion", 'version.txt', 'skills', 'scripts', 'listas')) {
        if (-not (Test-Path -LiteralPath (Join-Path $extraido $necesario))) { throw "El zip no es una edición completa del operador (falta $necesario)." }
    }
    if ((Leer-Sello (Join-Path $extraido 'version.txt')) -ne $selloNuevo) { throw 'El sello de version.txt del zip no coincide con el de la Release.' }

    # --- 3. Las skills: antes de cambiar nada, ninguna carpeta ajena en el camino.
    $skillsNuevas = @(Get-ChildItem -LiteralPath (Join-Path $extraido 'skills') -Directory)
    $problemasSkills = @()
    if (Test-Path -LiteralPath $DestinoSkills) {
        if (Es-Link $DestinoSkills) { $problemasSkills += "$DestinoSkills es un link: no se copian las skills ahí." }
    }
    if ($problemasSkills.Count -eq 0) {
        foreach ($skill in $skillsNuevas) {
            $destino = Join-Path $DestinoSkills $skill.Name
            # Una «<skill>.nueva» que ya existe se va a borrar para armar la copia: solo si es de este instalador.
            $restoNueva = "$destino.nueva"
            if ((Test-Path -LiteralPath $restoNueva) -and ((Es-Link $restoNueva) -or -not (Test-Path -LiteralPath (Join-Path $restoNueva $marcaSkill)))) {
                $problemasSkills += "$restoNueva ya existe y no la dejó este instalador (no tiene la marca $marcaSkill, o es un link): no se borra. Renombrala o movela y volvé a correr."
            }
            if (-not (Test-Path -LiteralPath $destino)) { continue }
            if (Es-Link $destino) {
                $problemasSkills += "$destino es un link: no se toca. Retirá el link (cmd /c rmdir `"$destino`") y volvé a correr."
            } elseif (Test-Path -LiteralPath (Join-Path $destino $marcaOperador)) {
                $problemasSkills += "$destino es una skill del operador (tiene la marca $marcaOperador, la dejó scripts\publicar-mcp.ps1): este instalador no la reemplaza. Si esta PC es la del operador, no hace falta instalar la edición acá; si no, renombrala o movela y volvé a correr."
            } elseif (-not (Test-Path -LiteralPath (Join-Path $destino $marcaSkill))) {
                $problemasSkills += "$destino ya existe y no la copió este instalador (no tiene la marca $marcaSkill): no se pisa. Renombrala o movela y volvé a correr."
            } elseif (@(Links-Dentro $destino).Count -gt 0) {
                $problemasSkills += "$destino contiene links: no se reemplaza. Quitá los links y volvé a correr."
            }
        }
    }
    if ($problemasSkills.Count -gt 0) {
        throw ("No se cambió nada. Hay carpetas de skills que no son de este instalador:`n  " + ($problemasSkills -join "`n  "))
    }

    # --- 4. El servidor en versiones\<sello>, con «listo» solo si pasa la autoprueba.
    if (Test-Path -LiteralPath (Join-Path $destinoVersion 'listo') -PathType Leaf) {
        Write-Host "El servidor $selloNuevo ya estaba instalado y probado."
    } else {
        if (Test-Path -LiteralPath $destinoVersion) { Borrar-Seguro $destinoVersion }
        New-Item -ItemType Directory -Force -Path $destinoVersion | Out-Null
        Copy-Item -Path (Join-Path $extraido 'servidor\*') -Destination $destinoVersion -Recurse -Force
        Write-Host 'Autoprueba del OCR del servidor (puede tardar un minuto)...'
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = Join-Path $destinoVersion $ejecutableServidor
        $info.Arguments = '--autoprueba-ocr'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardError = $true
        $info.RedirectStandardOutput = $true
        try {
            $proceso = [System.Diagnostics.Process]::Start($info)
        } catch {
            $falloAlArrancar = $_.Exception.Message
            try { Borrar-Seguro $destinoVersion } catch { Write-Warning "No se pudo retirar $destinoVersion : $($_.Exception.Message)" }
            throw "El servidor no arrancó ($falloAlArrancar): el paquete está dañado o un antivirus lo bloqueó. No se instaló la versión $selloNuevo; sigue la anterior."
        }
        $tareaError = $proceso.StandardError.ReadToEndAsync()
        $tareaSalida = $proceso.StandardOutput.ReadToEndAsync()
        $termino = $proceso.WaitForExit($minutosAutoprueba * 60000)
        if (-not $termino) {
            try { $proceso.Kill() } catch { }
            $proceso.WaitForExit()
        }
        $textoPrueba = (($tareaError.Result + "`n" + $tareaSalida.Result).Trim() -replace "`r?`n", "`n    ")
        if ($textoPrueba) { Write-Host "    $textoPrueba" }
        $codigoPrueba = if ($termino) { $proceso.ExitCode } else { -1 }
        if (-not $termino -or $codigoPrueba -ne 0) {
            # La carpeta sin «listo» no la toma el anfitrión; igual se retira para no dejar un servidor roto.
            try { Borrar-Seguro $destinoVersion } catch { Write-Warning "No se pudo retirar $destinoVersion : $($_.Exception.Message)" }
            $motivo = if (-not $termino) { "no terminó en $minutosAutoprueba minutos" } else { "terminó con el código $codigoPrueba" }
            throw "La autoprueba del OCR del servidor falló ($motivo): en esta PC el servidor no podría leer ninguna base. No se instaló la versión $selloNuevo; sigue la anterior. Si el mensaje de arriba no alcanza, corré reportar.ps1."
        }
        [IO.File]::WriteAllText((Join-Path $destinoVersion 'listo'), $selloNuevo, [Text.Encoding]::ASCII)
        Write-Host "Servidor $selloNuevo listo."
    }

    # --- 5. El anfitrión.
    $exeNuevo = Join-Path $extraido "anfitrion\$ejecutableAnfitrion"
    $exeActual = Join-Path $carpetaAnfitrion $ejecutableAnfitrion
    $anfitrionAlDia = $false
    # La huella (anfitrion\huella.txt) es el árbol de git de las fuentes del anfitrión: el exe de un solo archivo
    # cambia de bytes en cada compilación, la huella solo si cambió su código. Una instalación sin huella cuenta
    # como distinta una vez. Un zip sin huella (anterior a este cambio) se compara por el hash del exe.
    $archivoHuella = Join-Path $carpetaAnfitrion 'huella.txt'
    $huellaNueva = ''
    if (Test-Path -LiteralPath (Join-Path $extraido 'anfitrion\huella.txt') -PathType Leaf) {
        $huellaNueva = ([IO.File]::ReadAllText((Join-Path $extraido 'anfitrion\huella.txt'))).Trim()
    }
    $huellaInstalada = if (Test-Path -LiteralPath $archivoHuella -PathType Leaf) { ([IO.File]::ReadAllText($archivoHuella)).Trim() } else { '' }
    if (-not (Test-Path -LiteralPath $exeActual)) {
        New-Item -ItemType Directory -Force -Path $carpetaAnfitrion | Out-Null
        Copy-Item -LiteralPath $exeNuevo -Destination $exeActual -Force
        Write-Host "Anfitrión instalado en $carpetaAnfitrion."
        $anfitrionAlDia = $true
    } elseif ($(if ($huellaNueva) { $huellaNueva -eq $huellaInstalada } else { (Get-FileHash -LiteralPath $exeNuevo -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $exeActual -Algorithm SHA256).Hash })) {
        $anfitrionAlDia = $true
    } else {
        Write-Host 'El anfitrión (el lanzador que ejecuta Claude Code) cambió en esta versión.'
        $sigue = $true
        $intentos = 0
        while (@(Get-Process -Name 'claude', 'Itris.UiAgent.McpHost' -ErrorAction SilentlyContinue).Count -gt 0) {
            $intentos++
            if ($intentos -gt 5) { $sigue = $false; break }
            Write-Host 'Claude Code está abierto y Windows no deja reemplazar el lanzador mientras corre.'
            $respuesta = Preguntar 'Cerrá Claude Code (todas las ventanas y sesiones) y apretá Enter; o escribí N para dejar el lanzador para otra vez'
            if ($respuesta -match '^\s*[nN]') { $sigue = $false; break }
        }
        if ($sigue) {
            $exeTemporal = "$exeActual.nuevo"
            try {
                Copy-Item -LiteralPath $exeNuevo -Destination $exeTemporal -Force
                Move-Item -LiteralPath $exeTemporal -Destination $exeActual -Force
                Write-Host 'Anfitrión reemplazado.'
                $anfitrionAlDia = $true
            } catch {
                $falloReemplazo = $_.Exception.Message
                if (Test-Path -LiteralPath $exeTemporal) { Remove-Item -LiteralPath $exeTemporal -Force -ErrorAction SilentlyContinue }
                Write-Warning "No se pudo reemplazar el anfitrión ($falloReemplazo); probablemente Claude Code lo abrió justo ahora. Queda como estaba: volvé a correr actualizar.ps1 con Claude Code cerrado."
            }
        } else {
            Write-Warning 'El anfitrión queda como estaba. Volvé a correr actualizar.ps1 con Claude Code cerrado para completar la actualización.'
        }
    }
    if ($anfitrionAlDia) {
        if ($huellaNueva) { [IO.File]::WriteAllText($archivoHuella, $huellaNueva + "`n", [Text.Encoding]::ASCII) }
        [IO.File]::WriteAllText($archivoSelloAnfitrion, $selloNuevo, [Text.Encoding]::ASCII)
    }

    # --- 6. Las skills, por copia y con la marca.
    New-Item -ItemType Directory -Force -Path $DestinoSkills | Out-Null
    $fecha = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    foreach ($skill in $skillsNuevas) {
        $destino = Join-Path $DestinoSkills $skill.Name
        $nueva = "$destino.nueva"
        if (Test-Path -LiteralPath $nueva) { Borrar-Seguro $nueva }
        Copy-Item -LiteralPath $skill.FullName -Destination $nueva -Recurse
        [IO.File]::WriteAllLines((Join-Path $nueva $marcaSkill), @(
            "Copiada por el instalador del operador de Itris (edición $selloNuevo).",
            "Fecha: $fecha",
            'No la edites acá: la próxima actualización reemplaza esta carpeta.'
        ), (New-Object System.Text.UTF8Encoding($true)))
        if (Test-Path -LiteralPath $destino) { Borrar-Seguro $destino }
        Rename-Item -LiteralPath $nueva -NewName $skill.Name
        Write-Host "Skill $($skill.Name) copiada a $DestinoSkills"
    }

    # --- 7. Scripts de Python, lista del diccionario y version.txt.
    foreach ($par in @(@('scripts', 'scripts'), @('listas', 'listas'))) {
        $carpetaDestino = Join-Path $Raiz $par[1]
        New-Item -ItemType Directory -Force -Path $carpetaDestino | Out-Null
        foreach ($archivo in (Get-ChildItem -LiteralPath (Join-Path $extraido $par[0]) -File)) {
            Copy-Item -LiteralPath $archivo.FullName -Destination (Join-Path $carpetaDestino $archivo.Name) -Force
        }
    }
    Copy-Item -LiteralPath (Join-Path $extraido 'version.txt') -Destination (Join-Path $Raiz 'version.txt') -Force
    Write-Host 'Scripts de Python, lista del diccionario y version.txt actualizados.'

    # Los scripts del propio compañero, que la Release actualiza (herramientas\ es opcional en un zip viejo).
    $carpetaHerramientas = Join-Path $extraido 'herramientas'
    if (Test-Path -LiteralPath $carpetaHerramientas -PathType Container) {
        foreach ($herramienta in @('reportar.ps1', 'actualizar.ps1')) {
            $origenHerramienta = Join-Path $carpetaHerramientas $herramienta
            if (-not (Test-Path -LiteralPath $origenHerramienta -PathType Leaf)) { continue }
            # No se instala un script que no analiza: el siguiente arranque quedaría roto.
            $erroresAnalisis = $null
            $tokens = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($origenHerramienta, [ref]$tokens, [ref]$erroresAnalisis)
            if ($erroresAnalisis -and @($erroresAnalisis).Count -gt 0) {
                Write-Warning "$herramienta de la Release no analiza ($(@($erroresAnalisis)[0].Message)); se deja el instalado."
                continue
            }
            if ($herramienta -eq 'reportar.ps1') {
                Copy-Item -LiteralPath $origenHerramienta -Destination (Join-Path $Raiz 'reportar.ps1') -Force
                Write-Host 'reportar.ps1 actualizado.'
            } elseif ($PSCommandPath -and ([IO.Path]::GetFullPath($PSCommandPath) -eq [IO.Path]::GetFullPath((Join-Path $Raiz 'actualizar.ps1')))) {
                # Se deja al lado; el reemplazo es lo último que hace el script (paso 9).
                $actualizarNuevo = Join-Path $Raiz 'actualizar.ps1.nuevo'
                Copy-Item -LiteralPath $origenHerramienta -Destination $actualizarNuevo -Force
            }
        }
    }
} finally {
    try { Borrar-Seguro $trabajo } catch { Write-Warning "No se pudo borrar la carpeta temporal $trabajo : $($_.Exception.Message)" }
}

# --- 8. Poda: quedan las versiones listas más nuevas; lo más viejo se va.
$patronCarpeta = [regex]$patronSello
# Lo que quedó de una poda anterior (<sello>.borrar, por un link o un archivo en uso) se reintenta.
foreach ($restos in @(Get-ChildItem -LiteralPath $carpetaVersiones -Directory | Where-Object { $_.Name -match '^\d{8}T\d{6}Z\.borrar$' })) {
    try {
        Borrar-Seguro $restos.FullName
        Write-Host "Versión $($restos.Name -replace '\.borrar$', '') retirada."
    } catch {
        Write-Warning "No se pudo borrar $($restos.FullName) del todo: $($_.Exception.Message)"
    }
}
$carpetas = @(Get-ChildItem -LiteralPath $carpetaVersiones -Directory | Where-Object { $patronCarpeta.IsMatch($_.Name) })
$listas = @($carpetas | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName 'listo')) -and (Test-Path -LiteralPath (Join-Path $_.FullName $ejecutableServidor))
    } | Sort-Object -Property Name -Descending)
if ($listas.Count -gt $versionesQueSeConservan) {
    $corte = $listas[$versionesQueSeConservan - 1].Name
    foreach ($carpeta in $carpetas) {
        if ([string]::CompareOrdinal($carpeta.Name, $corte) -ge 0) { continue }
        # Renombrar primero: una versión en ejecución tiene archivos abiertos y el renombre falla entero.
        $aparte = "$($carpeta.FullName).borrar"
        try {
            if (Es-Link $carpeta.FullName) { throw 'es un link' }
            Rename-Item -LiteralPath $carpeta.FullName -NewName (Split-Path -Leaf $aparte)
        } catch {
            Write-Warning "La versión $($carpeta.Name) no se pudo retirar ($($_.Exception.Message)); queda para la próxima."
            continue
        }
        try {
            Borrar-Seguro $aparte
            Write-Host "Versión $($carpeta.Name) retirada."
        } catch {
            Write-Warning "No se pudo borrar $aparte del todo: $($_.Exception.Message)"
        }
    }
}

Write-Host ''
Write-Host "Listo: versión $selloNuevo."
# --- 9. Último paso: este script se reemplaza por el de la Release (la próxima corrida usa el nuevo). Windows
# PowerShell lee y analiza todo el archivo antes de ejecutarlo y no lo deja abierto, así que reemplazarlo
# acá es seguro; esta corrida sigue con el código viejo. Solo si corre desde la raíz de la instalación.
if ($actualizarNuevo -and (Test-Path -LiteralPath $actualizarNuevo -PathType Leaf)) {
    try {
        Move-Item -LiteralPath $actualizarNuevo -Destination (Join-Path $Raiz 'actualizar.ps1') -Force
        Write-Host 'actualizar.ps1 se actualizó para la próxima vez.'
    } catch {
        Write-Warning "No se pudo reemplazar actualizar.ps1 ($($_.Exception.Message)); queda $actualizarNuevo."
    }
}
if ($anfitrionAlDia) {
    Write-Host 'Claude Code toma el servidor nuevo en el pedido siguiente, sin cerrarlo (si ya estaba registrado). Las skills nuevas se leen al abrir una sesión nueva.'
} else {
    Write-Host 'El servidor nuevo ya está listo, pero el lanzador quedó sin reemplazar: volvé a correr este script con Claude Code cerrado.'
}
exit 0
