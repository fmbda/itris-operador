# Operador de Itris

Un servidor MCP para Claude Code que opera la interfaz de Itris (el ERP de escritorio) como lo haría
un usuario de Windows: lee la pantalla, escribe, usa las teclas y los clics, y exporta grillas. Sirve
para probar y documentar Itris sobre **bases de prueba**.

## Qué bases opera

Solo bases de prueba: el nombre de la base tiene que terminar en uno de estos sufijos (después de un
guion bajo; puede seguir un dígito, por ejemplo _TEST2): `ITRIS`, `SERACT`, `CONSUL`, `TEST`, `TESTING`,
`DESA`, `PRUEBA`, `PREPROD`, `PROYECTO`, `POS`, `WEB`, `API`. Una base cuyo nombre no termina así se
niega siempre, aunque figure en la lista de bases. **Producción no se opera nunca.**

Además, cada base tiene que estar declarada en `C:\ItrisOperador\harness\bases.txt` (el instalador deja
ese archivo con un ejemplo comentado).

## Requisitos

- Windows 11.
- Escala de pantalla al 100 %. El instalador y el operador la controlan en el monitor principal; si Itris
  está en otro monitor, ese también tiene que estar al 100 % (eso no lo controla nadie).
- Resolución del monitor donde está Itris validada: **1366x768** o **1920x1080**. Con otra resolución el operador
  se niega a conectarse.
- Microsoft Excel instalado (las exportaciones de grillas lo usan).
- Python 3.10 o más nuevo (para los scripts del diccionario).
- Claude Code.
- `gh` (GitHub CLI), con sesión iniciada (`gh auth login`) en una cuenta con acceso a este repositorio
  privado. Para adjuntar el zip de un reporte la cuenta tiene que poder escribir en el repositorio; con
  acceso de solo lectura el issue se abre igual, sin el adjunto.
- Reconocimiento de texto (OCR) en español de Windows, teclado Español (Latinoamérica) y formato
  regional Español (Argentina). El instalador verifica cada uno y dice qué corregir; si falta el OCR, imprime el
  comando para instalarlo desde una consola de PowerShell de administrador (el instalador no cambia la
  configuración del sistema).

## Instalar

1. Cloná este repositorio (o descargalo como zip) y abrí una consola de PowerShell en esa carpeta:

   ```
   gh repo clone fmbda/itris-operador
   cd itris-operador
   ```

2. Corré el instalador desde ahí:

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File .\instalar.ps1
   ```

El instalador revisa los requisitos (si falta alguno, lo lista y no sigue), arma `C:\ItrisOperador`,
baja la última versión, copia las skills de Claude Code y los scripts, copia `actualizar.ps1` y
`reportar.ps1` a `C:\ItrisOperador\` y registra el servidor en Claude Code con el nombre
`itris-operador`. Después, editá `C:\ItrisOperador\harness\bases.txt` con las bases de prueba que vas a
operar y reiniciá Claude Code. Desde ahí, actualizar y reportar se corren desde `C:\ItrisOperador\`, sin
volver a este clon.

## Actualizar

```
powershell -NoProfile -ExecutionPolicy Bypass -File C:\ItrisOperador\actualizar.ps1
```

Baja la versión nueva si hay una. Si lo único que cambió es el servidor, Claude Code lo toma en el
pedido siguiente, sin cerrarlo. Si cambió el lanzador, el script te pide cerrar Claude Code antes de
reemplazarlo. También deja al día `actualizar.ps1` y `reportar.ps1` de `C:\ItrisOperador\` con los de la
versión nueva (la corrida en curso termina con el script viejo; la siguiente usa el nuevo).

## Reportar un problema

Si el operador falla o se niega sin una razón que se entienda, el script `reportar.ps1` arma un reporte
con la carpeta de evidencia de esa sesión:

```
powershell -NoProfile -ExecutionPolicy Bypass -File C:\ItrisOperador\reportar.ps1 <carpeta de la sesión>
```

Corrélo vos, en tu propia ventana de PowerShell. Antes de subir nada **muestra la lista de archivos y el
tamaño** (las capturas son de la base con la que trabajaste y pueden mostrar datos del negocio), avisa
quién va a ver el reporte y te pregunta si seguir. Solo se envía si escribís S en esa ventana; si
contestás que no, no sale nada de tu máquina.

**Quién lo ve:** el issue y el zip los ve toda persona con acceso a este repositorio. Por eso cada
colega trabaja con su propio repositorio: antes de invitar a una segunda persona, se crea un repositorio
aparte para ella.

## Mientras exporta

No uses la PC mientras el operador exporta una grilla o una lista de clases. Algunas exportaciones
(por ejemplo, *Atributos*) tardan unos minutos en abrir el cuadro «Guardar como», y tocar el teclado o
el mouse en ese momento las rompe.

## Lo que no está medido

- Dos monitores: el operador se midió con Itris en una sola pantalla. Si Itris está en un segundo
  monitor, el comportamiento no está verificado.
- La versión de Itris: el operador se midió con una versión puntual de Itris. Con otra, las pantallas
  pueden cambiar y alguna acción puede no andar; si pasa, reportalo.
