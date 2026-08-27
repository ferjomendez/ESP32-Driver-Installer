# ESP32 Driver Installer

Script de PowerShell que descarga e instala automaticamente el driver **Silicon Labs CP210x USB to UART Bridge** necesario para que Windows reconozca la mayoria de placas ESP32, ESP8266 y otros dispositivos que usan chips CP2102, CP2102N, CP2104, CP2105 o CP2108.

Seleccionas el script, lo ejecutas como Administrador, y el driver queda instalado. Sin buscar en paginas de terceros, sin descargas manuales, sin complicaciones.

---

## ¿Por que es necesario este driver?

Las placas de desarrollo ESP32 se comunican con el computador a traves de un chip USB-to-UART fabricado por Silicon Labs. Windows 10 y Windows 11 no incluyen este driver de fabrica, por lo que al conectar la placa por primera vez aparece como "Dispositivo desconocido" en el Administrador de Dispositivos y no se asigna ningun puerto COM.

Sin el puerto COM, ni Arduino IDE, ni PlatformIO, ni esptool pueden comunicarse con la placa. Este script resuelve ese problema en un solo paso.

## ¿Que hace este script?

1. Verifica que se esta ejecutando con privilegios de Administrador. Si no los tiene, se relanza solo pidiendo elevacion por UAC.
2. Comprueba si el driver CP210x ya esta instalado, consultando el driver store de Windows con `pnputil`.
3. Si no esta instalado (o si se usa el parametro `-Force`), descarga el paquete oficial directamente desde silabs.com.
4. Extrae el ZIP y ejecuta el instalador silencioso correspondiente a la arquitectura del sistema (x64 o x86).
5. Si el instalador EXE falla, intenta instalar el driver via `pnputil` usando el archivo INF del paquete.
6. Verifica que el driver quedo registrado correctamente.
7. Reporta el puerto COM si hay un dispositivo ESP32 conectado.
8. Limpia los archivos temporales.

## Requisitos

- Windows 10 o Windows 11
- PowerShell 5.1 o superior (incluido en Windows 10/11 por defecto)
- Privilegios de Administrador (el script los solicita solo por UAC si hace falta)
- Conexion a internet (para descargar el paquete de Silicon Labs)

---

## Uso

### Opcion 1: Descarga y ejecucion manual

1. Descarga `Install-ESP32Driver.ps1` desde este repositorio.
2. Abre PowerShell.
3. Navega hasta la carpeta donde descargaste el archivo.
4. Ejecuta:

```powershell
Unblock-File .\Install-ESP32Driver.ps1
powershell -ExecutionPolicy Bypass -File .\Install-ESP32Driver.ps1
```

`Unblock-File` es necesario la primera vez si descargaste el archivo con el navegador: Windows marca los archivos bajados de internet y bloquea su ejecucion. Ver [Solucion de problemas](#solucion-de-problemas).

Si no abriste PowerShell como Administrador, el script mostrara el dialogo de UAC y continuara en una ventana elevada.

### Opcion 2: One-liner desde la terminal

```powershell
$s = "$env:TEMP\Install-ESP32Driver.ps1"; irm https://raw.githubusercontent.com/ferjomendez/ESP32-Driver-Installer/main/Install-ESP32Driver.ps1 -OutFile $s; powershell -ExecutionPolicy Bypass -File $s
```

Para forzar reinstalacion, agrega `-Force` al final:

```powershell
$s = "$env:TEMP\Install-ESP32Driver.ps1"; irm https://raw.githubusercontent.com/ferjomendez/ESP32-Driver-Installer/main/Install-ESP32Driver.ps1 -OutFile $s; powershell -ExecutionPolicy Bypass -File $s -Force
```

> **Nota:** el one-liner guarda el script en la carpeta temporal en vez de ejecutarlo desde memoria con
> `&([scriptblock]::Create(...))`. Ese patron parece mas limpio pero tiene dos problemas reales: el `exit`
> del script termina **el proceso de PowerShell completo**, cerrandole la ventana al usuario, y ademas deja
> `$PSCommandPath` vacio, lo que impide que el script pueda relanzarse a si mismo con permisos de Administrador.

---

## Parametros

| Parametro | Descripcion |
|-----------|-------------|
| `-Force` | Reinstala el driver aunque ya este presente en el sistema |
| `-NoColor` | Desactiva la salida coloreada en la consola |
| `-Ascii` | Usa caracteres ASCII simples en vez de Unicode para los bordes |
| `-KeepFiles` | No elimina el ZIP y la carpeta temporal despues de la instalacion |

Todos los parametros aceptan formato GNU con doble guion: `--force`, `--nocolor`, `--ascii`, `--keep`.

La variable de entorno `NO_COLOR` tambien se respeta para desactivar colores.

Existe ademas un parametro interno `-Elevated`, que el script se pasa a si mismo al relanzarse por UAC para evitar un bucle de elevacion. No es necesario usarlo a mano.

### Ejemplos

Instalacion normal:

```powershell
.\Install-ESP32Driver.ps1
```

Forzar reinstalacion:

```powershell
.\Install-ESP32Driver.ps1 -Force
```

Instalacion conservando archivos temporales:

```powershell
.\Install-ESP32Driver.ps1 --keep
```

---

## ¿Que salida produce?

El script muestra una salida estructurada con colores indicando el estado de cada paso:

- **Verde**: operacion exitosa
- **Amarillo**: advertencia o accion alternativa
- **Rojo**: error que impide continuar
- **Gris**: informacion secundaria

Ejemplo de salida exitosa:

```
╔══════════════════════════════════════════════════════════════════════╗
║  ESP32 DRIVER INSTALLER v1.1.0                                      ║
║  Silicon Labs CP210x USB to UART Bridge VCP Driver                   ║
║  2026-08-24 15:30:00  |  MI-PC  |  PS 5.1                           ║
║  github.com/ferjomendez                                              ║
╚══════════════════════════════════════════════════════════════════════╝

  [1/5] Checking privileges
  Running as Administrator.

  [2/5] Checking for existing CP210x driver
  No CP210x driver detected. Proceeding with installation.

  [3/5] Downloading driver package
  Downloading from silabs.com ...
  URL                        https://www.silabs.com/documents/public/software/CP210x_Windows_Drivers.zip
  Downloaded                 6.8 MB

  [4/5] Installing driver
  Installer                  CP210xVCPInstaller_x64.exe
  Architecture               x64
  Running installer (this may take a few seconds) ...
  Installer result           Success (0x00010100)
  Installer completed successfully.
  Installed on devices       1
  Copied to driver store     1

  [5/5] Verifying installation
  CP210x driver installed and verified.
  Driver version             11.5.0.417
  No ESP32 device currently connected. Plug in your board to verify.
  Temporary files removed.

╔══════════════════════════════════════════════════════════════════════╗
║  INSTALLATION COMPLETE                                               ║
║  Time: 8.3s                                                          ║
╚══════════════════════════════════════════════════════════════════════╝

  Press any key to close ...
```

---

## Placas compatibles

Este driver cubre cualquier dispositivo que use un chip USB-to-UART de la familia CP210x de Silicon Labs. Esto incluye, entre otros:

- ESP32 DevKit v1
- ESP32-S2, ESP32-S3, ESP32-C3 (variantes con CP210x)
- ESP8266 NodeMCU
- Adafruit Feather (modelos con CP2104)
- SparkFun Thing Plus
- Wemos Lolin32

### Si tu placa NO usa un CP210x

Muchas placas ESP32 (sobre todo clones y las variantes S2/S3/C3) no llevan chip Silicon Labs. El script lo detecta y te lo dice en vez de limitarse a reportar que no hay nada conectado:

```
  No CP210x device connected.
  Found another USB-to-UART bridge instead:
  Device                     USB-Enhanced-SERIAL CH9102 (COM4)
  Port                       COM4
  Vendor                     WCH (VID_1A86) - not Silicon Labs

  This board does not use a CP210x chip, so the Silicon Labs
  driver will not bind to it. It already has a COM port, so you
  can point your IDE at the port listed above.
  If it stops working, install the WCH CH340/CH9102 driver from wch.cn.
```

Reconoce estos fabricantes por su USB Vendor ID:

| VID | Fabricante | Chips tipicos | Que hacer |
|-----|-----------|---------------|-----------|
| `10C4` | Silicon Labs | CP2102, CP2102N, CP2104, CP2105, CP2108 | Este script |
| `1A86` | WCH | CH340, CH341, CH343, CH9102 | Driver de [wch.cn](https://www.wch-ic.com/downloads/CH341SER_EXE.html) |
| `0403` | FTDI | FT232R, FT231X | Driver VCP de [ftdichip.com](https://ftdichip.com/drivers/vcp-drivers/) |
| `303A` | Espressif | USB nativo (S2 / S3 / C3) | Ninguno, Windows lo reconoce solo |

Los puertos COM de Bluetooth se ignoran, porque no corresponden a placas.

Tambien puedes verificar el chip a simple vista revisando la serigrafia de la placa cerca del conector USB.

---

## Solucion de problemas

**"No se puede cargar el archivo ... porque la ejecucion de scripts esta deshabilitada" / no pasa nada al hacer doble clic**
Son las dos caras del mismo problema. Windows marca los archivos descargados de internet (Mark of the Web) y ademas bloquea la ejecucion de scripts por defecto. Solucion:

```powershell
Unblock-File .\Install-ESP32Driver.ps1
powershell -ExecutionPolicy Bypass -File .\Install-ESP32Driver.ps1
```

Usar `-ExecutionPolicy Bypass` en la invocacion afecta solo a ese proceso: no cambia la politica global del sistema.

**"This script requires Administrator privileges"**
Solo aparece si el script no pudo relanzarse elevado (por ejemplo, si cancelaste el dialogo de UAC). Haz click derecho sobre PowerShell, selecciona "Ejecutar como administrador" y vuelve a ejecutarlo.

**La descarga falla**
Verifica tu conexion a internet. Si estas detras de un proxy corporativo, descarga el ZIP manualmente desde [la pagina oficial de Silicon Labs](https://www.silabs.com/software-and-tools/usb-to-uart-bridge-vcp-drivers), extrae el contenido, y ejecuta `CP210xVCPInstaller_x64.exe` como Administrador.

**La instalacion falla y quieres hacerla a mano**
Ejecuta el script con `-KeepFiles` para que no borre la carpeta temporal, abre esa carpeta, haz click derecho sobre `slabvcp.inf` y selecciona "Instalar". Ojo: el INF del paquete se llama `slabvcp.inf`; `silabser` es el nombre del archivo `.sys`, no del `.inf`.

**El instalador termina pero no aparece el puerto COM**
Desconecta y vuelve a conectar la placa ESP32. Si aun no aparece, prueba con otro cable USB. Muchos cables son solo de carga y no tienen los pines de datos necesarios.

**El puerto COM aparece y desaparece**
Esto suele indicar un problema de alimentacion. Prueba con otro puerto USB del computador (preferiblemente uno trasero conectado directamente a la placa base) o con un hub USB con alimentacion externa.

**Aparece "Code 10" en el Administrador de Dispositivos**
Ejecuta el script con `-Force` para reinstalar el driver. Si persiste, desinstala el dispositivo desde el Administrador de Dispositivos (marcando "Eliminar software de controlador"), reinicia, y ejecuta el script de nuevo.

---

## Fuente del driver

El paquete se descarga directamente desde el dominio oficial de Silicon Labs:

```
https://www.silabs.com/documents/public/software/CP210x_Windows_Drivers.zip
```

No se utilizan mirrors, sitios de terceros ni repositorios de drivers externos. El instalador esta firmado digitalmente por Silicon Laboratories Inc.

Pagina oficial del driver: [CP210x USB to UART Bridge VCP Drivers](https://www.silabs.com/software-and-tools/usb-to-uart-bridge-vcp-drivers)

---

## Estructura del proyecto

```
ESP32-Driver-Installer/
    Install-ESP32Driver.ps1    # Script principal
    Tests/
        Run-Tests.ps1          # Suite de tests (sin dependencias)
        fixtures/              # Salidas capturadas de pnputil
    README.md                  # Este archivo
    LICENSE                    # Licencia MIT
```

### Tests

La suite corre sin instalar nada, sin conexion a internet y sin tocar el sistema: cada test ejercita una funcion pura o alimenta una salida de `pnputil` capturada en `Tests/fixtures`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-Tests.ps1
```

Devuelve codigo de salida 0 si todo pasa, 1 si algo falla.

---

## Creditos

Driver: [Silicon Labs CP210x VCP Drivers](https://www.silabs.com/software-and-tools/usb-to-uart-bridge-vcp-drivers)

Script de instalacion: [Fernando Mendez](https://github.com/ferjomendez)
