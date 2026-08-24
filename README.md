# ESP32 Driver Installer

Script de PowerShell que descarga e instala automaticamente el driver **Silicon Labs CP210x USB to UART Bridge** necesario para que Windows reconozca la mayoria de placas ESP32, ESP8266 y otros dispositivos que usan chips CP2102, CP2102N, CP2104, CP2105 o CP2108.

Seleccionas el script, lo ejecutas como Administrador, y el driver queda instalado. Sin buscar en paginas de terceros, sin descargas manuales, sin complicaciones.

---

## ¿Por que es necesario este driver?

Las placas de desarrollo ESP32 se comunican con el computador a traves de un chip USB-to-UART fabricado por Silicon Labs. Windows 10 y Windows 11 no incluyen este driver de fabrica, por lo que al conectar la placa por primera vez aparece como "Dispositivo desconocido" en el Administrador de Dispositivos y no se asigna ningun puerto COM.

Sin el puerto COM, ni Arduino IDE, ni PlatformIO, ni esptool pueden comunicarse con la placa. Este script resuelve ese problema en un solo paso.

## ¿Que hace este script?

1. Verifica que se esta ejecutando con privilegios de Administrador.
2. Comprueba si el driver CP210x ya esta instalado en el sistema.
3. Si no esta instalado (o si se usa el parametro `-Force`), descarga el paquete oficial directamente desde silabs.com.
4. Extrae el ZIP y ejecuta el instalador silencioso correspondiente a la arquitectura del sistema (x64 o x86).
5. Si el instalador EXE falla, intenta instalar el driver via `pnputil` usando el archivo INF.
6. Verifica que el driver quedo registrado correctamente.
7. Reporta el puerto COM si hay un dispositivo ESP32 conectado.
8. Limpia los archivos temporales.

## Requisitos

- Windows 10 o Windows 11
- PowerShell 5.1 o superior (incluido en Windows 10/11 por defecto)
- Privilegios de Administrador (necesario para instalar drivers)
- Conexion a internet (para descargar el paquete de Silicon Labs)

---

## Uso

### Opcion 1: Descarga y ejecucion manual

1. Descarga `Install-ESP32Driver.ps1` desde este repositorio.
2. Abre PowerShell como Administrador.
3. Navega hasta la carpeta donde descargaste el archivo.
4. Ejecuta:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-ESP32Driver.ps1
```

### Opcion 2: One-liner desde la terminal

Abre PowerShell como Administrador y ejecuta:

```powershell
&([scriptblock]::Create((irm https://raw.githubusercontent.com/ferjomendez/ESP32-Driver-Installer/main/Install-ESP32Driver.ps1)))
```

Esto descarga y ejecuta el script directamente sin necesidad de guardarlo.

Para forzar reinstalacion desde el one-liner:

```powershell
&([scriptblock]::Create((irm https://raw.githubusercontent.com/ferjomendez/ESP32-Driver-Installer/main/Install-ESP32Driver.ps1))) -Force
```

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
║  ESP32 DRIVER INSTALLER v1.0.0                                      ║
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
  Downloaded                 3.9 MB

  [4/5] Installing driver
  Installer                  CP210xVCPInstaller_x64.exe
  Architecture               x64
  Running installer (this may take a few seconds) ...
  Installer completed successfully.

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

Algunas placas usan el chip CH340 en vez del CP210x. Si despues de instalar este driver tu placa sigue sin ser reconocida, es probable que necesites el driver CH340 en su lugar. Puedes verificar el chip revisando la serigrafía de la placa cerca del conector USB.

---

## Solucion de problemas

**"This script requires Administrator privileges"**
Haz click derecho sobre PowerShell y selecciona "Ejecutar como administrador". El script no puede instalar drivers sin estos permisos.

**La descarga falla**
Verifica tu conexion a internet. Si estas detras de un proxy corporativo, descarga el ZIP manualmente desde [la pagina oficial de Silicon Labs](https://www.silabs.com/software-and-tools/usb-to-uart-bridge-vcp-drivers), extrae el contenido, y ejecuta `CP210xVCPInstaller_x64.exe` como Administrador.

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
    README.md                  # Este archivo
    LICENSE                    # Licencia MIT
```

---

## Creditos

Driver: [Silicon Labs CP210x VCP Drivers](https://www.silabs.com/software-and-tools/usb-to-uart-bridge-vcp-drivers)

Script de instalacion: [Fernando Mendez](https://github.com/ferjomendez)
