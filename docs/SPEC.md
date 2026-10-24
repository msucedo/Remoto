# Remoto — Especificación de comportamiento

Versión de la especificación: 1.0 (protocolo `v = 1`).
Alcance: el comportamiento completo de Remoto, que convierte un teléfono en trackpad, teclado, botonera de acciones, control multimedia y micrófono de dictado de una Mac, a través de la red local. Describe **qué** hace el sistema; los comentarios del código citan sus secciones (`SPEC §n`).

Convenciones:
- `Remoto` es el nombre del producto y `remoto` su forma en minúsculas para identificadores, archivos y claves.
- Los identificadores de protocolo (tags JSON, nombres de campo, valores de enum) son **normativos** y se escriben tal cual.
- Los mensajes de texto para personas son **orientativos**: la redacción es libre; solo los códigos cortos (`wrongPin`, `tooLong`, …) son normativos.
- "Bytes" son bytes UTF-8; "caracteres" son escalares Unicode.
- Todos los tiempos son monotónicos salvo que se diga "UNIX" (segundos desde la época, `i64`).
- Las palabras DEBE / NO DEBE / PUEDE tienen el sentido habitual de una especificación.

---

## 1. Visión general

| Pieza | Qué es | Responsabilidades |
|---|---|---|
| **Core** (servicio) | Biblioteca embebida en la app de escritorio. Sin UI. | Servidor HTTP/HTTPS + WebSocket en la LAN, TLS con CA local, emparejamiento y tokens, protocolo, motor de inyección de entrada, ejecución de acciones, persistencia (dispositivos, deck, ajustes por dispositivo, identidad TLS). |
| **Host app** (macOS) | App de barra de menú (sin Dock). | UI (menú, tarjeta de emparejamiento con QR y PIN, ajustes, bienvenida, aprobación), permisos, y todo lo que necesita APIs de Apple y el core le delega: apps e iconos, portapapeles, volumen, reconocimiento de voz, distribución de teclado, tiempos de teclado/ratón, comandos nativos (Mission Control, bloqueo, reposo…), abrir URLs, Shortcuts. |
| **Cliente web** (teléfono) | SPA/PWA que el propio core sirve. | Superficie de trackpad con gestos y aceleración, teclados (Mac virtual, personalizados, escritura de texto), deck de botones, lista de apps, controles multimedia, dictado (captura de micrófono → PCM), ajustes locales sincronizados con la Mac. |

Flujo típico: la Mac muestra un QR con `http://<host>:<port>/#pair=<code>` → el teléfono abre la página → WebSocket `/ws` → `hello{auth:pair}` → `welcome{token}` → el teléfono guarda el token y en adelante se reconecta con `auth:token`.

---

## 2. Arquitectura

### 2.1 Componentes y concurrencia del core

| Elemento | Detalle |
|---|---|
| Runtime de red | Asíncrono, con hilo(s) nombrados `remoto-net`. |
| Hilo de entrada | Un único hilo `remoto-input` con QoS *user interactive*. Recibe comandos por un canal FIFO y es el único que publica eventos de entrada al sistema. |
| Worker de acciones | Uno por sesión; ejecuta acciones del deck en serie (cada una en un hilo bloqueante). |
| Tareas bloqueantes | Llamadas al host delegate que pueden tardar (apps, portapapeles, pegar, volumen, voz, ajustes): máximo **8 simultáneas por conexión** (§8.6). |
| Housekeeping | Tarea periódica cada **5 s** (§6.1, §5.4). |

### 2.2 Configuración que el host pasa al core (`HostConfig`)

| Campo | Tipo | Uso |
|---|---|---|
| `port` | u16 | Puerto preferido (0 = efímero). Por defecto en la host app: **8740** (rango de UI 1024–65535). |
| `dataDir` | ruta | Carpeta de persistencia (en macOS: `~/Library/Application Support/Remoto`). |
| `webRoot` | ruta | Carpeta del cliente web; vacía si no se empaquetó. |
| `hostName` | string | Nombre mDNS de la Mac (`<LocalHostName>.local`). |
| `computerName` | string | Nombre visible de la Mac (`welcome.host.name`, `/api/info.name`). |
| `appVersion` | string | Versión (`welcome.host.version`, `/api/info.version`). |
| `linkHost` | enum `HostName` \| `IpAddress` \| `Custom(address)` | Qué host aparece en el link del QR (§3.2). |
| `allowLocalProxy` | bool | Confiar en `X-Forwarded-*` desde loopback (§4.4). Por defecto false. |
| `allowPin` | bool | Permitir emparejar con PIN. Por defecto true. |
| `allowApproval` | bool | Permitir emparejar pidiendo aprobación. Por defecto true. |
| `allowShell` | bool | Permitir acciones `shell` y URLs `file:`. Por defecto **false**. |
| `voiceAvailable` | bool | Dictado habilitado (la host app lo pone a `ajuste de usuario && permiso de voz no denegado`). Por defecto true. |

### 2.3 API del core hacia el host (llamadas del host)

| Operación | Comportamiento |
|---|---|
| `new(config, delegate)` | Carga dispositivos de confianza, ajustes por dispositivo (purgando los de dispositivos que ya no son de confianza), deck (o el por defecto si falta/no valida). Arranca el hilo de entrada. |
| `start() → port` | Abre listeners (§4.1), calcula direcciones y nombres TLS, carga/renueva la identidad, lanza accept loop y housekeeping. Emite `Started(port, preferredPortTaken)` o `Failed(message)` (y devuelve error). Idempotente si ya corre. |
| `stop()` | Envía a cada sesión `bye{reconnect:true}` (§8.5), suelta toda la entrada, cierra el servidor, emite `SessionsChanged` y `Stopped`. |
| `isRunning()` | |
| `updateConfig(config)` | Reemplaza la config. Si cambió `allowShell` o `voiceAvailable` → envía `features` a cada sesión. Si cambió `hostName` o `linkHost` → emite `PairingChanged`. |
| `pairingInfo() → PairingInfo` | §3.2. |
| `renewPairing()` | Nuevo código + nuevo PIN; emite `PairingChanged`. |
| `setPinVisible(bool)` | La tarjeta con el PIN está/no está visible (§6.2). |
| `caCertificate() → bytes` | DER de la CA actual (vacío sin identidad). |
| `connectedDevices() → [ConnectedDevice]` | Ordenados por `connectedAt`. |
| `trustedDevices() → [TrustedDevice]` | Ordenados por `lastSeen` descendente; nombre sin la marca ZWSP (§7.4). |
| `disconnect(session)` | `bye` a esa sesión (§8.5). |
| `forgetDevice(id)` | Borra el dispositivo de confianza y sus ajustes; `bye` a sus sesiones recordadas; `DevicesChanged`. |
| `forgetAllDevices()` | Igual para todos; `DevicesChanged`. |
| `renameDevice(id, name)` | §7.4; `DevicesChanged`. |
| `respondApproval(id, allow)` | Resuelve una aprobación pendiente (§6.4). |
| `setPaused(bool)` / `isPaused()` | Pausa global del control (§8.7). |
| `deckJSON()` / `setDeckJSON(json)` (falla con mensaje) / `resetDeck()` | Exportar, importar (valida, guarda, difunde `deck`) y restaurar el deck por defecto. |
| `appsChanged()` | Vacía la caché de iconos y difunde `appsChanged`. |
| `permissionChanged()` | Reenvía `features` a cada sesión. |
| `setLayout(KeyboardLayout)` | Cachea, actualiza el mapa de caracteres del motor (§11.3) y difunde `layout`. |
| `setInputTiming(repeatDelayMs, repeatIntervalMs, doubleClickMs)` | §10.8. |
| `setVolumeState(value, muted)` | Recorta `value` a [0,1], cachea y difunde `volume` solo si cambió. |
| `clearVolumeState()` | Si había caché, la borra y difunde `volumeUnavailable`. |
| `voiceUpdate(session, VoiceUpdate)` | Reenvía a esa sesión como mensaje `voice` (§9.3). Un estado distinto de `listening` marca la voz de la sesión como inactiva. |
| `version()`, `initLogging(filter)` | Utilidades. Los logs **nunca** contienen el texto tecleado ni el contenido del portapapeles. |

Tipos de datos:

| Tipo | Campos |
|---|---|
| `PairingInfo` | `link`, `address`, `secureAddress`, `pin`, `expiresInSecs: u32`, `port: u16`, `addresses: [string]`, `vpnAddresses: [string]`, `caFingerprint` |
| `ConnectedDevice` | `session: u64`, `deviceId`, `name`, `model`, `address`, `connectedAt: i64 UNIX`, `secure: bool`, `remembered: bool` |
| `TrustedDevice` | `id`, `name`, `model`, `pairedAt: i64`, `lastSeen: i64`, `lastAddress` |
| `ApprovalRequest` | `id: u64`, `deviceName`, `model`, `address` |
| `AppEntry` | `id` (bundle id), `name`, `running`, `active`, `hidden` |
| `KeyboardLayout` | `id`, `name`, `iso: bool`, `keys: [KeyCap]` |
| `KeyCap` | `code: u16`, `base`, `shift`, `option`, `optionShift`, `dead: u8` (bit0 base, bit1 shift, bit2 option, bit3 optionShift) |
| `VoiceUpdate` | `state: Listening|Stopped|Unavailable|Error`, `text?`, `isFinal: bool`, `message?` |
| `AppOp` | `Open`, `Toggle`, `Hide`, `Quit` |
| `NativeCommand` | `MissionControl`, `Launchpad`, `LockScreen`, `SleepDisplay`, `Sleep` |

### 2.4 Host delegate (llamadas del core al host)

Todas se invocan fuera del hilo principal; el host las despacha a donde necesite.

| Responsabilidad | Firma conceptual | Notas |
|---|---|---|
| Eventos | `event(HostEvent)` | §2.5 |
| Listar apps | `apps() → [AppEntry]` | §15.2 |
| Icono de app | `appIcon(id, sizePx) → png?` | §15.2 |
| Operar app | `performApp(id, AppOp) → bool` | §15.2 |
| Comando nativo | `runNative(NativeCommand) → bool` | §15.5 |
| Abrir URL | `openURL(url) → bool` | §15.5 |
| Shortcut | `runShortcut(name) → bool` | §15.5 |
| Leer portapapeles | `readClipboard() → string?` | |
| Escribir portapapeles | `writeClipboard(text)` | |
| Pegar (inicio/fin) | `pasteBegin(text) → bool`, `pasteEnd()` | §11.5, §15.3 |
| Volumen | `setVolume(value?, muted?)` | §15.4 |
| Voz | `voiceBegin(session, locale?) → bool`, `voiceFeed(session, pcm)`, `voiceEnd(session, cancel)` | §15.6 |

### 2.5 Eventos al host (`HostEvent`)

| Evento | Cuándo |
|---|---|
| `Started(port, preferredPortTaken)` | Tras abrir listeners. `preferredPortTaken` = no se pudo usar `config.port` exacto. |
| `Stopped` | Tras `stop()`. |
| `Failed(message)` | `start()` falló. |
| `SessionsChanged` | Tras cada `welcome` y al terminar cada sesión. |
| `DevicesChanged` | Tras `welcome` de una sesión recordada; tras forget/forgetAll/rename. |
| `PairingChanged` | Código/PIN rotado (uso, caducidad, `renewPairing`), cambio de direcciones LAN, cambio de `hostName`/`linkHost`. |
| `ApprovalRequested(ApprovalRequest)` | Un teléfono pide aprobación. |
| `ApprovalEnded(id)` | La pendiente se resolvió, caducó o se canceló. |
| `Paired(name)` | Tras `welcome` de una sesión autenticada por `pair`, `pin` o `approve` (no por `token`). |
| `Notice(message)` | Falta el permiso de Accesibilidad (mismo límite de 4 s del §10.2). |

---

## 3. Red, direcciones y link de emparejamiento

### 3.1 Direcciones locales
- Se enumeran interfaces **solo IPv4**; se excluyen `127.0.0.0/8`, `169.254.0.0/16` y `0.0.0.0`.
- Clasificación por nombre de interfaz:

| Clase | Prefijos | Prioridad | VPN |
|---|---|---|---|
| Ethernet/Wi-Fi | `en` | 0 | no |
| VPN | `utun`, `ipsec`, `ppp`, `tun`, `tap`, `wg`, `tz`, `feth` | 2 | sí |
| Auxiliares | `awdl`, `llw`, `bridge` | 2 | no |
| Resto | — | 1 | no |

- Orden por (prioridad, IP, vpn); deduplicado por IP. La lista completa (con VPN) alimenta `addresses` y los nombres TLS; `vpnAddresses` son las marcadas VPN.

### 3.2 `pairingInfo()`
1. Si el código tiene ≥ 600 s, rotar código + PIN.
2. `ip` = primera dirección, o `127.0.0.1`.
3. Host del link según `linkHost`:
   - `HostName`: `hostName` sin puntos finales; si queda vacío, `ip`.
   - `IpAddress`: `ip`.
   - `Custom(s)`: `trim(s)`; esquema opcional (solo `http://` o `https://`, sin distinguir mayúsculas) que se descarta; admite `[IPv6]`; si no trae puerto se añade `:<port>` (o `[v6]:<port>`). Si no se puede interpretar, se usa el caso `HostName`.
4. `address = "http://{host}:{port}"`, `secureAddress = "https://{host}:{port}"`.
5. `link = "{address}/#pair={code}"` (siempre la dirección **http**).
6. `expiresInSecs = 600 − edad` (0 si ≥ 600); `pin` actual; `port` efectivo; `caFingerprint` (§5.5) o `""`.

---

## 4. Servidor HTTP

### 4.1 Listeners y puertos
- Se prueban `config.port + i`, `i = 0..19` (20 intentos), parando si se pasa de 65535. Con `port = 0`, un solo intento (efímero). Si todos fallan: error (`no port available` o el último).
- En cada puerto: listener IPv4 en `0.0.0.0` y, además, uno IPv6 en `[::]` con `IPV6_V6ONLY=1`, `SO_REUSEADDR=1`, backlog 128. Si IPv6 falla, se sigue solo con IPv4 (log).

### 4.2 Límite de conexiones
| Límite | Valor |
|---|---|
| Total abiertas | < 128 |
| Por IP | < 16 (IPv4 mapeada en IPv6 se normaliza a IPv4) |
| Por IP loopback con `allowLocalProxy` | < 64 |

Si se supera: se cierra la conexión sin respuesta (log).

### 4.3 HTTP y HTTPS en el mismo puerto
1. Leer sin consumir (peek) 1 byte, timeout **10 s**.
2. Si es `0x16` (TLS ClientHello): handshake TLS (ALPN `http/1.1`) con timeout **10 s**. Si no hay identidad TLS cargada: **cerrar en silencio** (sin alerta, sin log, sin aviso al teléfono).
3. En otro caso: HTTP en claro.

### 4.4 Identidad del cliente
- IP = peer. Si `allowLocalProxy` y el peer es loopback (`127.*`, `::1`): IP = **último** valor de `X-Forwarded-For` (trim), como IP o `IP:puerto`.
- `secure` = conexión TLS; con proxy, también si el **primer** valor de `X-Forwarded-Proto` es `https` (sin distinguir mayúsculas).
- Host efectivo = cabecera `Host`; con proxy, el primer valor de `X-Forwarded-Host`.

### 4.5 Lectura de la petición
| Regla | Valor |
|---|---|
| Tamaño máximo de cabecera | 16384 B (si se supera, se cierra la conexión) |
| Timeout de cabecera | 30 s en la primera petición del socket, 10 s en las siguientes |
| Keep-alive | `Connection: keep-alive` solo si **todas**: HTTP/1.0 con token `keep-alive` o HTTP/1.1 sin `close`; < 200 peticiones servidas en el socket; socket con < 120 s; < 96 conexiones abiertas en total. Si no: `Connection: close` y cierre tras responder. |

Validación en orden:
1. Método ≠ `GET` → **405**.
2. Hay `Transfer-Encoding`, o `Content-Length` ≠ `0` → **400**.
3. `Host` ausente o no aceptado (§4.6) → **421**.
4. `path == "/ws"` → WebSocket (§4.8); si no, rutas (§4.7).

### 4.6 Hosts aceptados (anti DNS-rebinding)
Normalización: quitar `:puerto` (solo si es u16 decimal válido), quitar punto final, minúsculas.

| Aceptado | Rechazado |
|---|---|
| `[IPv6]` literal (con o sin puerto); cualquier IP literal | sufijos sueltos `local`, `home.arpa`, `internal` |
| `localhost` | cualquier otro nombre con punto |
| nombre de una sola etiqueta `[A-Za-z0-9-]+` (salvo `local`, `internal`) | |
| nombres que terminan en `.local`, `.home.arpa` o `.internal` | |
| el host de `linkHost = Custom(...)` (§3.2) | |

### 4.7 Rutas
| Ruta | Respuesta |
|---|---|
| `GET /api/info` | `200` JSON con claves en orden alfabético: `{"name":computerName,"protocol":1,"secure":<bool §4.4>,"version":appVersion}`; `Content-Type: application/json`, `Cache-Control: no-store`. |
| `GET /api/icon?id=&size=&k=` | `k` debe ser el `sessionKey` de alguna sesión activa (comparación en tiempo constante) → si no **403**. `id` 1–512 bytes → si no **400**. `size`: entero sin signo de hasta 8 dígitos; ausente/inválido → 128; bucket: ≤64→64, ≤128→128, ≤256→256, resto→512. Caché en memoria por `(id, bucket)`; si falta, `appIcon(id, bucket)` en tarea bloqueante. Sin imagen → **404**. Con imagen: `image/png`, `Cache-Control: private, max-age=86400`. |
| `GET /remoto.crt` | DER de la CA, `Content-Type: application/x-x509-ca-cert`, `Content-Disposition: attachment; filename="Remoto.crt"`. Sin identidad → **404**. |
| `GET /ws` | §4.8 |
| cualquier otra | estáticos |

Estáticos:
- Dividir el path por `/`, ignorar segmentos vacíos; un segmento que empieza por `.` o contiene `\` o NUL → **404**. Unir a `webRoot`.
- Directorio → `index.html`. Inexistente: sin extensión → `webRoot/index.html` (fallback SPA); con extensión → **404**.
- Sin cliente web en absoluto: página HTML de reemplazo que explica que falta el cliente (`text/html; charset=utf-8`).
- `Cache-Control`: `public, max-age=31536000, immutable` para `/assets/*`; `no-cache` para el resto y para el fallback.
- `ETag` = `"<len hex>-<mtime ns hex>"` (minúsculas; mtime 0 si no hay). `If-None-Match` igual → **304**.
- `sw.js` lleva además `Service-Worker-Allowed: /`.

Content-Type por extensión:

| Ext. | Tipo | Ext. | Tipo |
|---|---|---|---|
| js, mjs | `text/javascript; charset=utf-8` | png | `image/png` |
| css | `text/css; charset=utf-8` | jpg, jpeg | `image/jpeg` |
| html | `text/html; charset=utf-8` | ico | `image/x-icon` |
| json | `application/json` | webp | `image/webp` |
| webmanifest | `application/manifest+json` | woff2 | `font/woff2` |
| svg | `image/svg+xml` | txt | `text/plain; charset=utf-8` |
| wasm | `application/wasm` | otra | `application/octet-stream` |

### 4.8 WebSocket (`/ws`)
| Comprobación | Si falla |
|---|---|
| `GET` | 405 |
| `Upgrade` contiene token `websocket` **y** `Connection` contiene `upgrade` | **426** |
| `Sec-WebSocket-Version == 13` | **400** + cabecera `Sec-WebSocket-Version: 13` |
| `Sec-WebSocket-Key` presente | **400** |
| `Origin` (si viene): quitar `esquema://`; el resto debe ser igual al host efectivo (sin distinguir mayúsculas) | **403** |

Sin `Origin` se acepta. Respuesta `101 Switching Protocols` con `Upgrade: websocket`, `Connection: Upgrade`, `Sec-WebSocket-Accept`. Límite WS: **64 MiB por mensaje y 16 MiB por frame**.

### 4.9 Formato de respuesta
Cada respuesta lleva, en este orden: línea de estado, `Content-Type`, `Content-Length`, `Connection`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`, `Content-Security-Policy`, cabeceras extra, línea vacía, cuerpo.

CSP fija:
```
default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self' ws: wss:; worker-src 'self'; manifest-src 'self'; media-src 'self' blob:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'
```
Frases de estado: `OK`, `Not Modified`, `Bad Request`, `Forbidden`, `Not Found`, `Method Not Allowed`, `Misdirected Request`, `Upgrade Required`, `Error`. Los cuerpos de error son texto plano breve.

---

## 5. TLS

### 5.1 Archivos en `dataDir`
| Archivo | Contenido |
|---|---|
| `identity.json` | `{"caName":string,"caExpires":i64 UNIX,"leafNames":[string],"leafExpires":i64 UNIX}` |
| `ca.key.pem`, `ca.cert.der` | Clave (PEM) y certificado (DER) de la CA |
| `leaf.key.pem`, `leaf.cert.der` | Clave y certificado del servidor |

Escritura atómica (§7.5). Claves ECDSA P-256 con SHA-256.

### 5.2 CA local
| Campo | Valor |
|---|---|
| Subject | CN = `"Remoto Local CA "` + 4 caracteres base64url aleatorios; O = `Remoto` |
| BasicConstraints | CA |
| KeyUsage | keyCertSign, cRLSign, digitalSignature |
| NameConstraints (permitidos, sin excluidos, sin IPv6) | DNS `local`, `localhost`; IPv4 `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`, `169.254.0.0/16`, `127.0.0.0/8` |
| Validez | `now − 1 día` … `now + 3650 días` |

### 5.3 Certificado del servidor
| Campo | Valor |
|---|---|
| SAN | `serverNames` (§5.4) |
| CN | primer nombre que termine en `.local`, o `Remoto` |
| KeyUsage / EKU | digitalSignature + keyEncipherment / serverAuth |
| Validez | `now − 1 día` … `min(now + 397 días, caExpires)` |
| Firma | la CA vigente |

### 5.4 `serverNames` y renovación
- `serverNames` = `["localhost", "127.0.0.1", lower(hostName sin puntos finales)] + cada IP local`, filtrado a **lo que permiten los NameConstraints** (IPv4 en los rangos de §5.2; DNS `local`, `*.local`, `localhost`, `*.localhost`; se descarta toda IPv6 y todo otro nombre), ordenado y sin duplicados.
- Al arrancar y cuando cambian los `serverNames` (housekeeping), se (re)carga la identidad con umbral = `now + 30 días`:
  - **CA** se conserva solo si su certificado y clave se leen/parsean, `identity.json` existe y `caExpires > umbral`. Si no, CA nueva (nombre nuevo); el teléfono deberá reinstalar el certificado.
  - **Hoja** se conserva solo si clave y certificado se leen, `leafNames` es idéntico (mismo orden) a los nombres actuales, `leafExpires > umbral` y la CA no cambió. Si no, hoja nueva.
- Si la carga falla: log y **se conserva la identidad anterior**. Sin identidad previa, HTTPS queda deshabilitado (TLS se cierra en silencio, `/remoto.crt` → 404, `caFingerprint = ""`).

### 5.5 Huella
`caFingerprint` = SHA-256 del DER de la CA, cada byte en hex **MAYÚSCULA** de 2 dígitos, unidos por `:` (95 caracteres).

---

## 6. Emparejamiento y autenticación

### 6.1 Código de emparejamiento y PIN
| Elemento | Regla |
|---|---|
| Aleatoriedad | CSPRNG. `randomToken(n)` = `n` bytes en base64url **sin padding**. |
| Código (QR) | `randomToken(18)` → 24 caracteres. |
| PIN | Entero uniforme en [0, 1 000 000) con 6 dígitos (ceros a la izquierda). Se re-sortea si: los 6 dígitos son iguales, o cada dígito es el anterior +1, o cada dígito es el anterior −1. |
| Vida | **600 s** comunes a código y PIN. Caducados (edad ≥ 600 s) → rotan ambos. Se comprueba al verificar, en `pairingInfo` y en housekeeping (cada 5 s; si rota o cambian las IP → `PairingChanged`). |
| Uso único | Un código o PIN correcto rota **ambos**. |
| Comparación | En tiempo constante. |

`checkCode(code)`: si caducó → rotar y fallar (`expiredCode`). Si coincide → éxito y rotar. Si no → `expiredCode`. No cuenta fallos.

### 6.2 Ventana del PIN
El PIN solo se acepta si está **abierto**: la tarjeta está visible (`setPinVisible(true)`) **o** no han pasado **180 s** desde que dejó de estarlo (al pasar de visible a oculta se fija `openUntil = now + 180 s`; mostrarla no cambia `openUntil`). Al arrancar, cerrado.

`checkPin(input, ip)`, en orden:
1. Quedarse solo con los dígitos ASCII de la entrada.
2. No abierto → `pinClosed`.
3. Si el mapa de fallos supera 1024 claves, podarlo.
4. Bloqueo por clave o global (§6.3) → `blocked` + `retryAfter`.
5. PIN caducado → rotar, contar fallo, `wrongPin`.
6. Coincide → éxito y rotar código + PIN. Si no → contar fallo, `wrongPin`.

### 6.3 Limitador de intentos
- **Clave de limitación**: IPv4 (incluida la mapeada en IPv6) o el prefijo /64 de una IPv6.
- Estado por clave: `lockedUntil?`, `last`, `count`, `lockouts`.
- `add(threshold)`:
  1. Si `now − last ≥ 3600 s` y no hay bloqueo activo → `count = lockouts = 0`.
  2. `last = now`; `count += 1`.
  3. Si `count ≥ threshold`: bloquear `lockouts < 5 ? 30 s << lockouts : 900 s` (30, 60, 120, 240, 480, luego 900 s); `count = 0`; `lockouts += 1`.

| Mapa | Umbral | Efecto adicional |
|---|---|---|
| PIN fallido | 5 | al saltar el bloqueo, rotar el PIN |
| Aprobación rechazada / caducada / abandonada | 3 | — |
| **Global** (todos los fallos de PIN) | ≥ 20 fallos en los últimos 60 s | bloquea a todos; `retryAfter = 60 s − edad del fallo más antiguo de la ventana` |

`retryAfter` se expresa en segundos enteros redondeando hacia arriba y nunca < 1.

### 6.4 Aprobación en la Mac (`approve`)
1. `allowApproval == false` → `rejected`.
2. Construir `ApprovalRequest{id, deviceName = displayName(name), model = clean(model,64), address = ip}`. Los ids de aprobación y de sesión salen del mismo contador creciente.
3. Bloqueo de aprobación para la clave → `blocked` + `retryAfter`.
4. Ya hay **2** pendientes (la tercera) → `busy`. Ya hay una pendiente con la misma clave de limitación → `busy`.
5. Registrar, emitir `ApprovalRequested`, enviar `{"t":"pending"}`.
6. Esperar hasta **120 s** la respuesta de `respondApproval`. Mientras tanto: responder `ping{id}` con `pong{id}`; ignorar otros mensajes.

| Resultado | Acción |
|---|---|
| Aprobado | aceptar (§6.5) |
| Rechazado | contar fallo de aprobación → `denied{rejected}` |
| Timeout 120 s | contar fallo → `denied{rejected}` |
| Socket cerrado | contar fallo → fin silencioso |

En todos los casos la pendiente se retira y se emite `ApprovalEnded(id)`.

### 6.5 Aceptar
- `name = displayName(hello.device.name)` (§7.4).
- Solo si `hello.remember == true`: emitir token de dispositivo (§7.2) y enviarlo en `welcome.token`; la sesión queda **recordada**. Si no, `token: null` y la sesión no es recordada.
- Con `auth.method = token` la sesión es siempre recordada y `welcome.token` es `null`.

---

## 7. Dispositivos de confianza

### 7.1 Archivo `dataDir/trusted.json`
JSON con sangría de 2 espacios:
```json
{
  "version": 1,
  "devices": [
    {"id": "…", "name": "…", "model": "…",
     "pairedAt": 1700000000, "lastSeen": 1700000000,
     "lastAddress": "192.168.1.20", "tokenHash": "<sha256 hex minúscula>"}
  ]
}
```
- `version` se escribe 1; al leer es obligatorio pero no se valida su valor.
- JSON corrupto o ilegible → log, renombrar a `trusted.json.corrupt` y arrancar vacío.
- El token en claro **nunca** se guarda: `tokenHash = hex(SHA-256(token))`.

### 7.2 Emitir (`issue(device, ip)`)
1. `token = randomToken(32)` (43 caracteres).
2. Borrar entradas con el mismo `id`.
3. Si quedan ≥ **64**, expulsar la de menor `lastSeen`.
4. Insertar `{id: clean(id,128), name: displayName(name), model: clean(model,64), lastAddress: ip, pairedAt = lastSeen = now, tokenHash}`.
5. Guardar y devolver el token.

### 7.3 Verificar (`verify(device, token, ip)`)
1. Buscar entrada con `tokenHash == sha256(token)` (tiempo constante) **y** `id == device.id`. Si no hay → `denied{unknown}`.
2. `lastSeen = now`, `lastAddress = ip`.
3. Si el nombre guardado no empieza por U+200B y `displayName(hello.name)` es no vacío y distinto → reemplazarlo.
4. Guardar solo si cambió el nombre o la IP, o si el `lastSeen` anterior tenía ≥ 3600 s.
5. Devolver el nombre (sin la marca U+200B).

### 7.4 Otras operaciones y saneado
- `rename(id, name)`: `name = "​" + clean(name, 64)`; guardar. La marca indica "nombre puesto en la Mac" y no se sobrescribe desde el teléfono. Se quita al presentar.
- `remove(id)`: borra y guarda solo si existía.
- `clean(s, max)`: elimina C0 (< 0x20), DEL y C1 (0x7F–0x9F), U+00AD, U+061C, U+180E, U+200B–U+200F, U+202A–U+202E, U+2064–U+206F y U+FEFF; corta tras `max` caracteres conservados; `trim`.
- `displayName(s) = clean(s, 64)`, o `"Unnamed device"` si queda vacío.

### 7.5 Persistencia en general
Todos los archivos se escriben de forma atómica: archivo temporal en la misma carpeta + `fsync` + `rename`. JSON corrupto → se registra, se aparta como `*.corrupt` (dispositivos y ajustes) o se ignora (deck, identidad) y se usa el valor por defecto.

---

## 8. Sesión WebSocket

### 8.1 Handshake
1. Primer mensaje con timeout **10 s**; si vence o se cierra el socket → fin silencioso. Frames binarios, ping y pong de WS se ignoran en esta fase.
2. El primer mensaje de texto debe parsear como `hello`. Si no (otro tipo o JSON inválido) → `bye{reconnect:false}` (motivo: se esperaba `hello`) y cierre.
3. `hello.v != 1` → `denied{incompatible}`.
4. `hello.device.id` debe tener 1–128 bytes, todos en 0x21–0x7E → si no, `denied{incompatible}`.
5. Autenticar según `hello.auth.method`:

| `method` | Fallos posibles |
|---|---|
| `token` | `unknown` |
| `pair` | `expiredCode` |
| `pin` | `rejected` (PIN desactivado), `pinClosed`, `blocked`(+`retryAfter`), `wrongPin` |
| `approve` | `rejected`, `blocked`(+`retryAfter`), `busy`; envía antes `pending` |

6. Tras `denied` se cierra el socket. Con éxito por `pair`/`pin` se emite `PairingChanged` (rotación).

### 8.2 `welcome`
Orden de campos normativo:
```json
{"t":"welcome",
 "v":1,
 "host":{"name":"<computerName>","version":"<appVersion>","os":"macOS"},
 "sessionKey":"<randomToken(18)>",
 "token":"<token>" | null,
 "features":{"voice":bool,"shell":bool,"secure":bool,"permission":bool},
 "deck":{…Deck…},
 "layout":{…KeyboardLayout…},
 "volume":{"value":0.0..1.0,"muted":bool},
 "paused":bool,
 "settings":{"settings":{…},"updatedAt":u64}}
```
| Campo | Regla |
|---|---|
| `token` | siempre presente; `null` si no se emitió |
| `layout`, `volume`, `settings` | se **omiten** si no hay valor |
| `sessionKey` | nuevo por sesión; solo sirve para `/api/icon` |
| `features.voice` | `config.voiceAvailable` |
| `features.shell` | `config.allowShell` |
| `features.secure` | la conexión es segura (§4.4) |
| `features.permission` | la app tiene permiso de Accesibilidad |
| `settings` | solo en sesiones recordadas, si hay ajustes guardados para `device.id` |
| `layout` JSON | `{"id","name","iso","keys":[{"code","base","shift","option","optionShift","dead"}]}` |

Inmediatamente después de enviar `welcome`, en este orden: `Paired(name)` (si la auth fue `pair`/`pin`/`approve`), `DevicesChanged` (si la sesión es recordada), `SessionsChanged`.

### 8.3 Bucle principal
- Espera simultáneamente: frame entrante, cola de salida de la sesión, tick de 1 s, señal de parada del servidor.
- **Cada frame recibido** (texto o binario) actualiza `lastSeen` de la sesión.
- Texto → mensaje (§9.1); JSON inválido o desconocido → se ignora (log) y además se suelta toda la entrada de la sesión. Binario → §9.2.
- Envío: cada mensaje con timeout de **5 s**; si falla o vence, la sesión termina.
- Watchdog: en cada tick, si `lastSeen` tiene **> 8 s** → fin de sesión sin `bye` (log).
- Fin de sesión (cualquier causa): quitar la sesión, soltar toda su entrada en el motor, cancelar su worker, si tenía voz activa `voiceEnd(session, cancel=true)`, emitir `SessionsChanged`.

### 8.4 Difusiones (a todas las sesiones activas)
| Origen | Mensaje |
|---|---|
| `deckSave` válido, `setDeckJSON`, `resetDeck` | `deck{deck}` (también al emisor; el cliente lo toma como copia confirmada) |
| `setLayout` | `layout{layout}` |
| `setVolumeState` con cambio | `volume{value,muted}` |
| `clearVolumeState` | `volumeUnavailable` |
| `setPaused` con cambio | `paused{paused}` |
| `appsChanged()` | `appsChanged` |
| `permissionChanged()`, `updateConfig` (shell/voz) | `features{features}` (por sesión, con su propio `secure`) |

### 8.5 `bye`
`{"t":"bye","reason":string,"reconnect":bool}`; tras enviarlo se cierra. Un motivo vacío tras `trim` se sustituye por "Disconnected.".

| Origen | Sentido del motivo | `reconnect` |
|---|---|---|
| primer mensaje no es `hello` | se esperaba un saludo | false |
| `stop()` / el servidor se detiene | la Mac dejó de compartir | **true** |
| `disconnect(session)` | la Mac cerró esta conexión | false |
| `forgetDevice(id)` (sesiones recordadas de ese id) | este dispositivo fue eliminado en la Mac; volver a emparejar | false |
| `forgetAllDevices()` (todas las recordadas) | se eliminaron todos los dispositivos; volver a emparejar | false |

### 8.6 Límites por sesión
| Límite | Valor | Al superarlo |
|---|---|---|
| Cola de acciones | 32 | `actionResult{ok:false}` "la Mac sigue ocupada con acciones anteriores" |
| Tareas bloqueantes simultáneas | 8 | `notice{level:"warning", code:"busy"}` "la Mac está ocupada, reintentar" |
| Texto (`text.text`, `edit.insert`, `clipboardSet.text`) | 65536 B | `notice{level:"warning", code:"tooLong"}` |

### 8.7 Pausa global
`setPaused(true)`: el motor vacía el movimiento pendiente y suelta todo; se descarta toda entrada; las acciones en curso o nuevas fallan ("detenido porque el control está en pausa o el dispositivo se desconectó"); los `shell` en curso se terminan (§13.2). `text` en pausa responde `notice{level:"warning", code:"paused"}`. Se difunde `paused`.

`shouldStop(session)` = pausa global **o** la sesión ya no está conectada.

---

## 9. Protocolo

Todos los mensajes JSON son objetos con discriminador `t`. Los campos opcionales ausentes toman el valor por defecto indicado. Campos desconocidos se ignoran.

### 9.1 Cliente → servidor (JSON)

| `t` | Campos | Comportamiento del servidor |
|---|---|---|
| `hello` | `v:u32`, `device:{id, name?="", model?=""}`, `auth`, `remember?:bool=false` | §8.1. Después del handshake se ignora. |
| `ping` | `id:any` | `pong{id}` con el mismo valor. |
| `key` | `code:u16`, `down:bool`, `mods?:u16=0`, `repeat?:bool=false` | §10.7 |
| `tap` | `code:u16`, `mods?:u16=0` | Solo si `code < 0x100` y `mods & 0xF0E0 == 0`; si no, se ignora. Pulsación atómica (§10.6, hold 12 ms). |
| `button` | `button:MouseButton`, `op:PressOp`, `mods?:u16` | `down`/`up`/`click` (§10.5). `mods` se acepta pero no se usa. |
| `media` | `key:MediaKey`, `op?:PressOp="click"` | §10.9 |
| `volume` | `value?:f32`, `muted?:bool` | `value` no finito se descarta; se recorta a [0,1]. `setVolume(value?, muted?)` en tarea bloqueante. Sin respuesta (el estado vuelve vía `volume`). |
| `text` | `text:string`, `mode?:TextMode="unicode"` | Límite §8.6; en pausa → notice `paused`. `unicode`/`keystrokes` → §11.2; `paste` → §11.5. |
| `edit` | `delete?:u32=0`, `insert?:string=""` | §11.4 |
| `release` | — | Suelta todo lo que la sesión tiene pulsado. |
| `action` | `action:Action`, `id?:any` | §13 |
| `apps` | — | `apps{apps:[{id,name,running,active,hidden}]}` (tarea bloqueante). |
| `appAction` | `id:string`, `op?:AppOp="toggle"` | `performApp`; si devuelve false → `notice{level:"error"}` "no se encontró la app". |
| `deckSave` | `deck:Deck` | Validar (§12.2) y guardar → difundir `deck`. Error → `notice{level:"error", code:"deck", message:<motivo>}`. |
| `voiceStart` | `locale?:string` | Si `!voiceAvailable` → `voice{state:"unavailable"}` (el navegador ya exige contexto seguro para el micrófono). Si no: marcar voz activa y `voiceBegin(session, locale)`; si devuelve false → desmarcar y `voice{state:"unavailable"}`. |
| `voiceStop` | `cancel?:bool=false` | Solo si la voz estaba activa: desmarcar y `voiceEnd(session, cancel)`. |
| `clipboardSet` | `text:string` | Límite §8.6; `writeClipboard(text)`. |
| `clipboardGet` | — | `clipboard{text: string|null}`. |
| `settingsSave` | `settings:any`, `updatedAt:u64` | Solo sesiones recordadas (si no, se ignora). §14.2. Error → `notice{level:"error"}`. |
| `settingsList` | — | §14.3 |
| `settingsCopy` | `from:string` | §14.4 |

Sub-objeto `auth` (tag `method`): `{"method":"token","token"}`, `{"method":"pair","code"}`, `{"method":"pin","pin"}`, `{"method":"approve"}`.

### 9.2 Cliente → servidor (frames binarios, little-endian)

| Byte 0 | Nombre | Longitud exacta | Layout | Efecto |
|---|---|---|---|---|
| `0x01` | Move | 9 | `u8, f32 dx, f32 dy` | §10.3 |
| `0x02` | Scroll | 10 | `u8, u8 phase, f32 dx, f32 dy` | §10.4 |
| `0x03` | Fling | 9 | `u8, f32 vx, f32 vy` | §10.4 |
| `0x04` | Touch | 1 | `u8` | detiene la inercia (§10.4) |
| `0x10` | Audio | impar ≥ 3 | `u8` + PCM Int16 LE mono 16 kHz | si la voz está activa y no `shouldStop` → `voiceFeed(session, pcm)` |

- Los f32 deben ser finitos; si no, el frame se descarta. Se convierten a f64 sin escala ni cambio de signo.
- **Todo** frame binario (válido, inválido o desconocido) cuenta como señal de vida para la sesión en el motor de entrada.
- Fases de scroll: `0` None (rueda), `1` Began, `2` Changed, `4` Ended, `8` Cancelled.
- El servidor nunca envía frames binarios.

### 9.3 Servidor → cliente (JSON)

| `t` | Campos |
|---|---|
| `welcome` | §8.2 |
| `pending` | — |
| `denied` | `reason:DenyReason`, `retryAfter?:u32` (omitido si no aplica; ≥ 1) |
| `pong` | `id` |
| `apps` | `apps:[{id,name,running,active,hidden}]` |
| `appsChanged` | — |
| `deck` | `deck` |
| `layout` | `layout` |
| `volume` | `value:f32`, `muted:bool` |
| `volumeUnavailable` | — |
| `paused` | `paused:bool` |
| `features` | `features:{voice,shell,secure,permission}` |
| `notice` | `level:"info"|"warning"|"error"`, `code?:string` (omitido si no hay), `message:string` |
| `actionResult` | `id?` (omitido si no hay), `ok:bool`, `message?` (omitido si no hay) |
| `clipboard` | `text:string|null` |
| `bye` | `reason:string`, `reconnect:bool` |
| `voice` | `state:"listening"|"stopped"|"unavailable"|"error"`, `text?`, `final:bool`, `message?` |
| `settings` | `settings:any`, `updatedAt:u64` |
| `settingsList` | `devices:[{id,name,model,updatedAt}]` |

### 9.4 Enums (grafía exacta)

| Enum | Valores |
|---|---|
| `DenyReason` | `unknown`, `wrongPin`, `pinClosed`, `expiredCode`, `rejected`, `blocked`, `busy`, `incompatible` |
| `MouseButton` | `left`, `right`, `middle`, `back`, `forward` (números CG 0–4) |
| `PressOp` | `click`, `down`, `up` |
| `AppOp` | `open`, `toggle`, `hide`, `quit` |
| `TextMode` | `unicode`, `keystrokes`, `paste` |
| `MediaKey` | `volumeUp`, `volumeDown`, `mute`, `brightnessUp`, `brightnessDown`, `playPause`, `next`, `previous`, `fastForward`, `rewind`, `illuminationUp`, `illuminationDown`, `illuminationToggle` |
| `SystemAction` | §13.3 (38 valores) |
| Códigos de `notice` | `permission`, `secureInput`, `tooLong`, `busy`, `paused`, `deck`, `settings` |

### 9.5 Máscara de modificadores (`mods`)
| Bit | Tecla | Bit | Tecla |
|---|---|---|---|
| `0x0001` | Command | `0x0100` | Right Command |
| `0x0002` | Shift | `0x0200` | Right Shift |
| `0x0004` | Option | `0x0400` | Right Option |
| `0x0008` | Control | `0x0800` | Right Control |
| `0x0010` | Fn | | |

---

## 10. Motor de entrada (macOS)

### 10.1 Infraestructura
- Fuente de eventos propia con estado *HID system*, `userData` = una FourCC propia de `Remoto`, intervalo de supresión de eventos locales 0. Todos los eventos se crean con esa fuente y se publican en el **HID event tap**.
- Bucle: calcula el siguiente deadline de los timers activos, espera un comando con ese timeout, procesa ese comando y todos los que ya estén en cola, ejecuta timers. Al cerrar: soltar todo y salir.

| Timer | Periodo / umbral |
|---|---|
| Pacer de movimiento | 4,167 ms (240 Hz) |
| Fling | 8,333 ms (120 Hz) |
| Fin automático de gesto de scroll | 300 ms sin eventos |
| Autorepetición | `repeatDelay` / `repeatInterval` |
| Watchdog de entrada | cada 250 ms |

Comandos del motor: `Input(session, input, now)`, `Alive(session)`, `Forget(session)` (la sesión pasa a una lista de olvidadas acotada a 256; se vacía el pacer y se suelta todo lo suyo), `SetPaused(bool)`, `SetTiming`, `SetLayout`, `Flush(ack)` (responde cuando todo lo anterior se procesó), `Shutdown`. "Esperar al motor" con timeout = 1 s; "terminar el motor" = espera sin timeout.

### 10.2 Filtros previos para cada `Input`
1. Pausa o `shouldStop(session)` → descartar.
2. Si no es `Move`, publicar antes el movimiento pendiente del pacer (orden movimiento → clic/tecla).
3. `Touch` y `Release` no requieren permisos.
4. Resto: comprobar permiso de Accesibilidad (caché 750 ms). Si falta: `notice{level:"warning", code:"permission"}` ("Remoto necesita permiso de Accesibilidad") y `HostEvent::Notice`. El evento se intenta publicar igualmente.
5. Entradas de tecleo (`key` down, `tap`, teclas de acción, texto, edit): si *Secure Event Input* está activo (caché 750 ms) → `notice{level:"warning", code:"secureInput"}` ("un campo de contraseña bloquea la escritura"). Se intenta publicar igualmente.
6. Límite de avisos: **uno por (tipo, sesión) cada 4 s**.

### 10.3 Puntero
- `Move`: ignorar no finitos y (0,0); recortar cada eje a ±4000; empujar al pacer. **No hay aceleración en la Mac** (la aplica el cliente).
- **Pacer** (estado: `pend`, `lastPush`, `avg=0.016 s`, `jit=0.002 s`, `start`, `deadline`):
```
push(dx,dy,now):
  si lastPush: dt = now-lastPush
    si dt < 0.1: sample = min(|dt-avg|, 0.034)
                 avg = clamp(0.2*dt + 0.8*avg, 0.004, 0.034)
                 jit = 0.85*jit + 0.15*sample
  lastPush = now; pend += (dx,dy); start = now
  deadline = now + min(avg + clamp(2*jit, 0.002, 0.010), 0.034)
entrega (cada tick y al recibir un Move, antes de push):
  si pend≠0 y now>start:
    si now>=deadline: emit=pend; pend=0
    si no: f=(now-start)/(deadline-start); emit=pend*f; pend-=emit
    start=now; publicar(emit)
```
- Publicar movimiento: base = posición actual del cursor, salvo que la última posición publicada esté a < 1,5 px en ambos ejes (entonces la última publicada, para conservar subpíxeles). Destino = base + delta. Si cae fuera de todas las pantallas activas (lista cacheada ≤ 1 s, descartando pantallas de ancho/alto < 1), recortar contra cada pantalla a `[x, x+w−1]×[y, y+h−1]` y elegir la más cercana. Tipo: `mouseMoved`, o `left/right/otherMouseDragged` si hay botón pulsado (el primero en orden Left, Right, Middle, Back, Forward). Campos delta X/Y = parte entera del delta real (tras recorte) + acumulador de fracción por eje. Flags = modificadores pulsados + CapsLock.

### 10.4 Scroll y fling
| Fase recibida | Acción |
|---|---|
| 0 | evento rueda (`phase 0, momentum 0`) con el delta |
| 1 Began | si había gesto activo, publicar `phase 4` con 0; activar y publicar `phase 1` con el delta |
| 2 Changed | si activo, `phase 2`; si no, activar y `phase 1` |
| 4 / 8 | si activo, publicar esa fase con 0 y desactivar |
| otra | ignorar |

- Antes: ignorar no finitos, recortar ±4000 y cancelar fling en curso (si su momentum ya empezó, publicar `momentum 3` con 0).
- Gesto activo sin eventos durante 300 ms → publicar `phase 4`.
- El core **no invierte** ejes (el signo lo decide el cliente).
- Evento: scroll en **píxeles**, 2 ejes; `wheel1 = trunc(dy+accY)`, `wheel2 = trunc(dx+accX)` (acumuladores de fracción que se ponen a 0 si la fase ∉ {0,2} o `momentum == 3`); continuo = 1; campos de fase y momentum; point delta enteros y fixed-point sin redondear; flags de modificadores; ubicación = cursor actual.
- **Fling** (`vx, vy`): cerrar gesto activo (`phase 4`); `speed = hypot`; si < 80 ignorar; recortar la velocidad a 12000; `start = last = now`.
```
tick (8,333 ms): dt = now-last; si dt < 0.0041665 esperar; last = now
  v *= exp(-max(friction,0.1)*dt)          # friction = 2.6
  si |v| >= 12 y now-start <= 4 s:
     publicar scroll{phase 0, momentum = empezado?2:1, delta = v*min(dt,0.024999)}
  si no: terminar; si empezado, publicar momentum 3 con 0
```
- `Touch`: cancela el fling (si su momentum empezó, publica `momentum 3`). No toca el gesto de scroll.

### 10.5 Botones y clics
- Tipos down/up: Left 1/2, Right 3/4, otros 25/26 (con número de botón). `clickState = max(clicks,1)`. Ubicación = cursor actual.
- `down`: si la sesión ya lo tiene pulsado, nada. Contador global por botón; solo el primer down publica. `clickState`: si el último clic fue del mismo botón, hace ≤ `doubleClick` ms y a ≤ 5 px → `anterior + 1` (sin tope); si no, 1. Se registra en la sesión.
- `up`: decrementar; al llegar a 0 publicar up con `clickState = (último botón == este) ? max(count,1) : 1`.
- `click` (desde `button op:click` con 1 clic, o acción `mouse` con 1–3): si el botón está pulsado, nada. 1 clic → misma detección de doble clic, down+up. 2–3 clics → pares down/up con `clickState` 1, 2(, 3) seguidos. Modificadores temporales (§10.6) alrededor si los hubiera.
- Mientras un botón está pulsado, los movimientos salen como *dragged*.

### 10.6 Teclado: modificadores, press/release, tap
Modificadores:

| Keycode | Tecla | Máscara CG (genérica \| lado) | Bit wire |
|---|---|---|---|
| 0x37 | Cmd izq. | 0x100000 \| 0x08 | 0x0001 |
| 0x36 | Cmd der. | 0x100000 \| 0x10 | 0x0100 |
| 0x38 | Shift izq. | 0x20000 \| 0x02 | 0x0002 |
| 0x3C | Shift der. | 0x20000 \| 0x04 | 0x0200 |
| 0x3A | Opt izq. | 0x80000 \| 0x20 | 0x0004 |
| 0x3D | Opt der. | 0x80000 \| 0x40 | 0x0400 |
| 0x3B | Ctrl izq. | 0x40000 \| 0x01 | 0x0008 |
| 0x3E | Ctrl der. | 0x40000 \| 0x2000 | 0x0800 |
| 0x3F | Fn | 0x800000 | 0x0010 |
| 0x39 | CapsLock | — (toggle real del bloqueo vía IOHID) | — |

Flags implícitos por keycode (se añaden al evento de esa tecla):

| Flag | Keycodes |
|---|---|
| `0xA00000` | flechas 0x7B–0x7E |
| `0x800000` | 0x40, 0x4F, 0x50, 0x5A, 0x60–0x65, 0x67, 0x69–0x6B, 0x6D, 0x6F, 0x71–0x7A |
| `0x200000` | 0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E, 0x51–0x59, 0x5B, 0x5C |

Eventos de teclado: flags = `flags | CapsLock(0x10000 si está activo; caché 750 ms) | 0x100` (no-coalesced); un modificador se publica como *flagsChanged* (down = su máscara de lado está en flags); autorepetición marca el campo correspondiente.

- `flags()` = OR de máscaras de todos los modificadores pulsados globalmente (refcount por keycode).
- `press(code)`: refcount; solo 0→1 publica (modificador → flagsChanged; otra → keyDown con `flags()|implícitos`). `release(code)`: 1→0 publica.
- **Modificadores temporales** `pressTemp(mods)`: recorrer (Ctrl izq 0x8, Ctrl der 0x800, Opt izq 0x4, Opt der 0x400, Shift izq 0x2, Shift der 0x200, Cmd izq 0x1, Cmd der 0x100, Fn 0x10). Bit izquierdo/genérico: saltar si algún modificador ya pulsado aporta esa máscara genérica. Bit derecho: saltar si esa tecla exacta está pulsada. Pulsar los que falten; si se pulsó alguno, pausa 8 ms. Se sueltan después en orden inverso tras 8 ms.
- `tap(code, mods, hold)`: `code == 0x39` → solo toggle de CapsLock. Si no: cancelar autorepetición, temporales (salvo si `code` es modificador), `press`, esperar `hold`, `release`, soltar temporales. `hold` = 12 ms (tap/acciones), 2 ms (tecleo de texto).
- `typeKey(code, mods)` (texto): si `code` ya está pulsado o es modificador → `tap(code, mods, 2 ms)`. Si no: cancelar repetición, temporales, flags = implícitos | máscaras de modificadores pulsados cuyo bit está en `mods`, keyDown directo, 2 ms, keyUp, soltar temporales.

### 10.7 Mensaje `key` y autorepetición
`down`:
1. `code == 0x39` → toggle CapsLock (el `up` de 0x39 no hace nada).
2. La sesión ya tiene `code` pulsado → ignorar.
3. Modificador (0x36–0x3F salvo 0x39) → `press` y anotarlo en la sesión. No repite.
4. Otra tecla → `temps = pressTemp(mods)`, `press(code)`, guardar `code → temps`. Si `repeat`: programar repetición (`primera = now + repeatDelay`, tope `now + 60 s`); si no, cancelar la repetición.

`up`: quitar de la sesión (si no estaba, nada); parar repetición si es la que repite; `release`; si tenía temporales, 8 ms y soltarlos en orden inverso.

Repetición (una sola tecla a la vez en todo el motor): cada disparo publica keyDown con autorepetición; siguiente = `deadline + interval`, salvo retraso > 3·interval (entonces `now + interval`). Se detiene al llegar al tope de 60 s o si la sesión dueña lleva ≥ 3 s sin señales. `tap`, `typeKey` y el tecleo de texto cancelan la repetición.

### 10.8 Tiempos (`setInputTiming`)
| Parámetro | Por defecto | Rango aceptado | Fuente en la host app |
|---|---|---|---|
| `repeatDelay` | 500 ms | 100–3000 | retardo de repetición del sistema |
| `repeatInterval` | 83 ms | 15–2000 (mín. efectivo 15 ms) | intervalo de repetición del sistema |
| `doubleClick` | 500 ms | 150–5000 | intervalo de doble clic del sistema |
| `friction` (fling) | 2,6 | fija | — |

La host app los envía al arrancar y cada 30 s (no hay notificación de cambio). Valores fuera de rango se recortan.

### 10.9 Teclas multimedia
- Por sesión, conjunto de teclas multimedia pulsadas. `down`: si no estaba → publicar down. `up`: si estaba → up. `click`: si no está pulsada, down + up.
- Publicación: evento *system-defined* (tipo 14), subtipo 8 (aux control buttons), `data1 = (NX_KEYTYPE << 16) | (down ? 0x0A00 : 0x0B00)`, por la conexión al servicio HID del sistema (abierta perezosamente y reutilizada). Si falla, cerrar la conexión y publicar el mismo evento como CGEvent (tipo 14, flags 0xA00/0xB00, subtipo 8, `data1`).

| MediaKey | NX_KEYTYPE | MediaKey | NX_KEYTYPE |
|---|---|---|---|
| volumeUp | 0 | next | 17 |
| volumeDown | 1 | previous | 18 |
| brightnessUp | 2 | fastForward | 19 |
| brightnessDown | 3 | rewind | 20 |
| mute | 7 | illuminationUp | 21 |
| playPause | 16 | illuminationDown | 22 |
| | | illuminationToggle | 23 |

### 10.10 Watchdog y liberación
- Cada 250 ms, para cada sesión con algo pulsado (teclas, botones, multimedia): si lleva más de 5 s enteros sin señales (≥ 6 s efectivos) → log y soltar todo lo de la sesión.
- Señal de vida = cualquier `Input` o `Alive` de la sesión (todo frame binario manda `Alive`).
- Orden de liberación (sesión o global): teclas (con sus temporales), luego botones, luego multimedia; también se detiene la autorepetición.

---

## 11. Texto

### 11.1 Límites
`text`, `edit.insert` y `clipboardSet`: ≤ 65536 bytes (§8.6). `edit.delete` se recorta a 4096.

### 11.2 Segmentación
`segments(s)` → lista de `Text(≤16 unidades UTF-16)` | `Newline` | `Tab`:
- `\t` → `Tab`; `\n`, `\r` y `\r\n` (uno solo) → `Newline`.
- Se descartan controles `< 0x20` (salvo los anteriores) y `0x7F–0x9F`.
- Un carácter fuera del BMP cuenta 2 unidades; se corta antes de pasarse de 16.

### 11.3 Tecleo
- Cancelar repetición; comprobar `shouldStop` antes de cada segmento (y de cada carácter en modo keystrokes); pausa de 2 ms antes de cada segmento salvo el primero.
- `Newline` → `typeKey(0x24)`; `Tab` → `typeKey(0x30)`.
- **unicode**: cada `Text` → un keyDown (keycode 0) con la cadena Unicode adjunta + keyUp sin cadena, flags 0x100.
- **keystrokes**: por carácter; si está en el mapa de la distribución → publicar lo acumulado como Unicode y `typeKey(code, mods)`; si no, acumular para Unicode.
- **Mapa de caracteres** (desde `KeyboardLayout`): por cada `KeyCap`, niveles en orden optionShift (mods 6, bit 3), option (4, bit 2), shift (2, bit 1), base (0, bit 0); se salta un nivel *dead* o cuya cadena no sea exactamente un carácter imprimible (≥ 0x20, fuera de 0x7F–0x9F). Si el carácter ya existe, se reemplaza solo por una combinación con **menos** bits de modificador (en empate se queda el primero).

### 11.4 `edit{delete, insert}`
`min(delete, 4096)` veces `typeKey(0x33 Backspace)` (parando si `shouldStop`), y luego `insert` en modo unicode. Un Backspace por unidad pedida; el cliente decide que la unidad sea el grafema.

### 11.5 Pegar (`text` con `mode:"paste"`)
En tarea bloqueante: si no `shouldStop`, `pasteBegin(text)`; si true → `tapChar('v', Cmd)` (⌘V resuelto con la distribución activa, §13.2 `keys`), esperar a que el motor lo publique, esperar **450 ms**, `pasteEnd()`. Si `pasteBegin` devuelve false → `notice{level:"error"}` "no se pudo usar el portapapeles".

---

## 12. Deck

### 12.1 Esquema (archivo `dataDir/deck.json`, mismo JSON que en el protocolo)
```
Deck     = { "version": 1, "pages": [DeckPage] }
DeckPage = { "id": string, "name": string, "columns": u8, "tiles": [Tile] }
Tile     = { "id": string, "label": string, "color"?: string, "icon"?: TileIcon, "action": Action }
TileIcon = {"kind":"symbol","name"} | {"kind":"emoji","text"} | {"kind":"app","id"}
```
`color` e `icon` se omiten al serializar si no existen.

### 12.2 Validación (servidor)
| Regla | Mensaje (orientativo) |
|---|---|
| `version == 1` | versión de deck no soportada |
| 1–24 páginas; ≤ 64 tiles por página | el deck tiene demasiadas páginas o botones |
| `page.id`, `tile.id` ≤ 128 bytes | id demasiado largo |
| `page.name`, `tile.label` ≤ 80 caracteres | etiqueta demasiado larga |
| `columns` 1–8 | columnas entre 1 y 8 |
| `color`: `#` + hex, longitud total 4, 5, 7 o 9 | color inválido |
| `icon`: `app` ≤ 512, `symbol` ≤ 128, `emoji` ≤ 64 bytes | icono demasiado largo |
| `action` | §12.3 con profundidad 0 |

### 12.3 `Action` (tag `kind`) y validación
| `kind` | Campos | Validación |
|---|---|---|
| `keys` | `code:u16`, `mods?:u16=0`, `char?:string` | `code ≤ 0xFF`, `mods < 0x20` (solo bits izquierdos/genéricos), `char` ≤ 16 bytes → "invalid key" |
| `text` | `text`, `enter?:bool=false` | ≤ 4096 bytes |
| `media` | `key:MediaKey` | — |
| `app` | `id`, `op?:AppOp="toggle"` | 1–512 bytes |
| `url` | `url` | ≤ 4096 bytes y contiene `:` |
| `system` | `name:SystemAction` | — |
| `shortcut` | `name` | 1–512 bytes |
| `shell` | `command` | ≤ 4096 bytes |
| `mouse` | `button:MouseButton`, `clicks?:u8=1` | 1–3 |
| `delay` | `ms:u32` | ≤ 10000 |
| `sequence` | `steps:[Action]` | ≤ 64 pasos y profundidad ≤ 2 (es decir, hasta 3 niveles de anidamiento); recursiva |

### 12.4 Deck por defecto
`version 1`, sin colores. Iconos `symbol` con nombres de la familia Lucide (o equivalentes propios).

Página `essentials` ("Essentials", 4 columnas):

| id | label | icon | action |
|---|---|---|---|
| mission-control | Mission Control | layout-grid | system missionControl |
| app-expose | App Windows | app-window | system appExpose |
| desktop | Desktop | monitor | system showDesktop |
| spotlight | Spotlight | search | system spotlight |
| space-left | Space Left | arrow-left-to-line | system spaceLeft |
| space-right | Space Right | arrow-right-to-line | system spaceRight |
| screenshot | Screenshot | scan | system screenshotArea |
| lock | Lock | lock | system lockScreen |
| previous | Previous | skip-back | media previous |
| play | Play / Pause | play-pause | media playPause |
| next | Next | skip-forward | media next |
| mute | Mute | volume-x | media mute |
| copy | Copy | copy | system copy |
| paste | Paste | clipboard | system paste |
| undo | Undo | undo | system undo |
| emoji | Emoji | smile | system emojiPicker |

Página `apps` ("Apps", 4 columnas): un tile por app con `id` = bundle id, `icon {kind:app,id}`, `action {kind:app,id,op:toggle}`: Finder (`com.apple.finder`), Safari (`com.apple.Safari`), Terminal (`com.apple.Terminal`), Music (`com.apple.Music`), Messages (`com.apple.MobileSMS`), Notes (`com.apple.Notes`), Calendar (`com.apple.iCal`), Settings (`com.apple.systempreferences`).

---

## 13. Ejecución de acciones

### 13.1 Cola y resultados
1. `action{action,id?}` → validar (§12.3); error → `actionResult{id, ok:false, message}` inmediato.
2. Encolar en la cola de la sesión (capacidad 32); llena → `actionResult{ok:false}` "ocupada".
3. El worker de la sesión ejecuta en serie, cada acción en un hilo bloqueante, con profundidad 0.
4. Al terminar: si había `id` → `actionResult{id, ok, message?}` **siempre**; sin `id` → solo si hubo error. Un pánico/caída → error "la acción falló".
5. Al empezar cada acción (y cada paso de secuencia): si `shouldStop` → error "detenido (pausa o desconexión)".

### 13.2 Semántica por tipo
| `kind` | Ejecución |
|---|---|
| `keys` | Si `char` es exactamente un carácter alfabético (Unicode) → `tapChar`: se pasa a minúscula, se busca en el mapa de la distribución **solo en nivel sin modificadores**; si está, se usa ese keycode; si no, `code`. En otro caso → `tap(code, mods)`. Hold 12 ms. No espera al motor. |
| `text` | Tecleo unicode (§11.3); si `enter`, después `tap(0x24)`. |
| `media` | `click` de esa tecla (§10.9). |
| `app` | `performApp(id, op)`; false → error "no se encontró la app". |
| `url` | Esquema = texto antes del primer `:`; debe ser `[A-Za-z0-9+.-]+` → si no, "ese tipo de enlace no está permitido". Comparación **sin distinguir mayúsculas**: `javascript` y `data` prohibidos; `file` solo si `allowShell`. Resto → `openURL(url)`; false → "la Mac no pudo abrir el enlace". |
| `system` | §13.3 |
| `shortcut` | `runShortcut(name)`; false → "no se pudo ejecutar el atajo". |
| `shell` | `!allowShell` → error "los comandos de shell están desactivados en los ajustes de la Mac". Si no: lanzar `/bin/zsh -lc <command>` en su propio grupo de procesos, stdin/stdout/stderr a null, cwd y entorno heredados. Error al lanzar → "no se pudo ejecutar el comando: …". Devuelve ok en cuanto arranca (*fire and forget*). Un vigilante comprueba cada 100 ms; si se activa la pausa/parada, envía SIGTERM al grupo y, pasado ≥ 1 s, SIGKILL. Sin timeout en otro caso. |
| `mouse` | `click(button, clamp(clicks,1,3))` (§10.5). |
| `delay` | Esperar al motor; dormir `min(ms,10000)` en trozos de 50 ms comprobando `shouldStop` (si se interrumpe → error "detenido"). |
| `sequence` | Profundidad > 2 → error "anidada demasiado profundo". Ejecutar pasos en orden con profundidad + 1; **abortar en el primer error** y devolverlo. |
| `runNative` false | error "la Mac no pudo hacerlo". |

### 13.3 Acciones de sistema
Tipos: **Tap** = `tap(code, mods)`; **Letra** = `tapChar(letra, mods)` (keycode según distribución, reserva por tabla ANSI §B.2); **Native** = esperar al motor y `runNative(cmd)`.

| name | Implementación | name | Implementación |
|---|---|---|---|
| missionControl | Native MissionControl | undo | Letra `z` + Cmd |
| appExpose | Tap Ctrl + ↓ (0x7D) | redo | Letra `z` + Cmd+Shift |
| showDesktop | Tap F11 (0x67) | copy | Letra `c` + Cmd |
| launchpad | Native Launchpad | cut | Letra `x` + Cmd |
| spotlight | Tap Cmd + Space (0x31) | paste | Letra `v` + Cmd |
| spaceLeft | Tap Ctrl + ← (0x7B) | selectAll | Letra `a` + Cmd |
| spaceRight | Tap Ctrl + → (0x7C) | find | Letra `f` + Cmd |
| appSwitcher | Tap Cmd + Tab (0x30) | newTab | Letra `t` + Cmd |
| lockScreen | Native LockScreen | closeTab | Letra `w` + Cmd |
| sleepDisplay | Native SleepDisplay | nextTab | Tap Ctrl + Tab |
| sleep | Native Sleep | previousTab | Tap Ctrl+Shift + Tab |
| screenshot | Tap Cmd+Shift + 3 (0x14) | back | Tap Cmd + `[` (0x21) |
| screenshotArea | Tap Cmd+Shift + 4 (0x15) | forward | Tap Cmd + `]` (0x1E) |
| screenshotTool | Tap Cmd+Shift + 5 (0x17) | reload | Letra `r` + Cmd |
| forceQuit | Tap Cmd+Opt + Esc (0x35) | zoomIn | Tap Cmd + `=` (0x18) |
| emojiPicker | Tap Ctrl+Cmd + Space | zoomOut | Tap Cmd + `-` (0x1B) |
| closeWindow | Letra `w` + Cmd | actualSize | Tap Cmd + `0` (0x1D) |
| quitApp | Letra `q` + Cmd | fullscreen | Letra `f` + Ctrl+Cmd |
| minimize | Letra `m` + Cmd | hideApp | Letra `h` + Cmd |

---

## 14. Ajustes por dispositivo

### 14.1 Almacenamiento
- Ruta: `dataDir/device-settings/<hex>.json`, `<hex>` = primeros 16 bytes de `SHA-256(deviceId)` en hex minúscula (32 caracteres). La carpeta se crea si falta.
- Contenido (sangría 2, escritura atómica): `{"version":1,"id":"<deviceId>","settings":{…},"updatedAt":u64}`. Corrupto → `*.json.corrupt`.
- Solo se guardan para dispositivos de confianza: al cargar se purgan los de ids no confiables; `forgetDevice` borra el suyo; `forgetAllDevices` borra todos.

### 14.2 `settingsSave{settings, updatedAt}` (sesión recordada)
1. `settings` debe ser objeto JSON → si no, error "los ajustes deben ser un objeto".
2. JSON compacto > 131072 bytes → error "ajustes demasiado grandes para guardarlos en la Mac".
3. Si lo guardado tiene `updatedAt` mayor, o igual con el mismo contenido → no-op.
4. Guardar en memoria y en disco (fallo de disco → solo log).

### 14.3 `settingsList`
Dispositivos de confianza **excepto el propio**, solo los que tienen ajustes, como `{id, name (sin marca), model, updatedAt}`, ordenados por `updatedAt` descendente → `settingsList{devices}`.

### 14.4 `settingsCopy{from}`
| Caso | Respuesta |
|---|---|
| Sesión no recordada | `notice{level:"warning", code:"settings"}` "activa 'recordar este dispositivo' para copiar ajustes" |
| `from` sin ajustes | `notice{level:"warning", code:"settings"}` "esos ajustes ya no están en la Mac" |
| Hay ajustes | `settings{settings, updatedAt}` del origen. No escribe nada para el destino (el cliente re-sube con su propio `settingsSave`). |

---

## 15. App de escritorio (macOS)

### 15.1 Forma y ciclo de vida
- App de barra de menú (sin Dock ni ventana principal); macOS 15+. Se vuelve app "regular" temporalmente mientras hay ventanas abiertas (ajustes, bienvenida) y vuelve a "accesoria" al cerrarlas.
- Arranca el core al iniciar; estados mostrados: arrancando, en marcha (puerto), fallo (mensaje), detenido.
- Tras arrancar: envía distribución de teclado y tiempos; se suscribe a cambios de fuente de entrada (→ `setLayout`), de volumen (→ `setVolumeState`/`clearVolumeState`) y de apps (lanzar, terminar, activar, ocultar, mostrar → `appsChanged()` con debounce de 0,4 s); sondea Accesibilidad cada 2 s (si cambia → `permissionChanged()`) y tiempos cada 30 s.
- Entitlements: Apple Events. Textos de privacidad: red local, reconocimiento de voz, carpetas con apps.
- Opcional: actualizaciones automáticas con feed firmado; elemento de inicio de sesión.

### 15.2 Apps e iconos
- Inventario: `.app` en `/Applications`, `/System/Applications`, `/System/Applications/Utilities`, `/Applications/Utilities`, `~/Applications` y carpetas extra elegidas por el usuario (incluidos discos externos); deduplicado por bundle id; caché de 60 s (se invalida al cambiar carpetas). Nombre = display name → bundle name → nombre de archivo.
- `apps()`: une instaladas + en ejecución (solo políticas de activación *regular*, no terminadas, excluida la propia app); `active` = en primer plano, `hidden` = oculta; ordenado por nombre sin distinguir mayúsculas.
- `appIcon(id, size)`: icono del bundle renderizado a PNG cuadrado de `size` px (recorte a 16–512).
- `performApp(id, op)`:

| op | Efecto | Devuelve |
|---|---|---|
| `open` | mostrar si está oculta, activar con todas sus ventanas; si no corre (o no se deja activar), abrirla | true si había app o URL |
| `toggle` | si está activa y visible → ocultar; si no → como `open` | |
| `hide` | ocultar | false si no corre |
| `quit` | terminar (no forzado) | false si no corre |

### 15.3 Portapapeles
- `readClipboard`: texto plano si existe.
- `writeClipboard(text)`: reemplaza el contenido con el texto.
- `pasteBegin(text)`: instantánea de todos los items/tipos actuales; limpiar; escribir el texto con los marcadores `org.nspasteboard.TransientType`, `org.nspasteboard.ConcealedType`, `org.nspasteboard.AutoGeneratedType` (vacíos) y `org.nspasteboard.source` = bundle id de `Remoto`; recordar el `changeCount`.
- `pasteEnd()`: restaurar la instantánea solo si el `changeCount` no cambió desde `pasteBegin`.

### 15.4 Volumen
- Dispositivo de salida por defecto (seguir sus cambios). Valor = volumen principal virtual (0–1); `muted` = mute de salida. Sin volumen ajustable → `clearVolumeState()`.
- `setVolume(value?, muted?)`: aplicar el volumen principal si es ajustable, o si no a cada canal del par estéreo preferido; aplicar mute si es ajustable.

### 15.5 Comandos nativos, URLs y Shortcuts
| Comando | Implementación |
|---|---|
| MissionControl | abrir `/System/Applications/Mission Control.app` |
| Launchpad | abrir `/System/Applications/Apps.app`; si no existe, `/System/Applications/Launchpad.app` |
| LockScreen | bloqueo inmediato de la sesión (API del sistema de bloqueo de pantalla) |
| SleepDisplay | `/usr/bin/pmset displaysleepnow` |
| Sleep | `/usr/bin/pmset sleepnow` |
| `runShortcut(name)` | `/usr/bin/shortcuts run <name>` |
| `openURL(url)` | rechazar esquemas `javascript` y `data`; `file` solo si `allowShell`; abrir con el sistema |

Los procesos se lanzan con E/S a null; el fallo se registra y devuelve false.

### 15.6 Voz
- Reconocimiento **en el dispositivo** (nunca en la nube), resultados parciales, puntuación automática, modo dictado. Locale = el del teléfono (`es-MX` → `es_MX`), o el del sistema.
- `voiceBegin`: cancela una sesión previa del mismo id. Sin autorización de voz, sin reconocedor para el idioma, sin soporte on-device o no disponible → `voiceUpdate{state:Unavailable, message}`. Si todo va bien → `Listening`.
- `voiceFeed`: PCM Int16 LE 16 kHz mono → buffer float (`/32768`) → al reconocedor.
- Segmentación en frases: cada resultado parcial no vacío se envía (`Listening`, `text`, `isFinal:false`) y reinicia un debounce de **1,2 s**; al vencer, se cierra el audio de esa frase y se abre otra para el audio siguiente. El final de una frase se envía como `Listening` con `text` y `isFinal:true`. Si el reconocedor termina una frase por su cuenta, se abre otra.
- `voiceEnd(cancel=false)`: cerrar el audio y esperar el final (máx. 2,5 s) → `Stopped` con el texto final (o sin texto) e `isFinal:true`. `cancel=true`: cancelar sin más.

### 15.7 Distribución de teclado
- Distribución activa (id, nombre localizado, ISO/ANSI según el tipo de teclado físico).
- Keycodes recorridos (51): `0x00–0x23`, `0x25–0x2F`, `0x32`, `0x5D`, `0x5E`, `0x5F`.
- Para cada uno, traducir con modificadores ninguno / Shift / Option / Option+Shift → `base`, `shift`, `option`, `optionShift`. Si la combinación deja un estado de tecla muerta, marcar el bit en `dead` y guardar como texto el acento aislado (resultado de pulsar Espacio después).
- Al cambiar la fuente de entrada → `setLayout`.

### 15.8 Permisos
- Accesibilidad (necesaria para publicar eventos): comprobar, pedir al sistema y abrir el panel de privacidad correspondiente.
- Reconocimiento de voz: pedir autorización; abrir su panel.

### 15.9 UI (funcional)
| Superficie | Contenido |
|---|---|
| Panel de barra de menú | Estado (arrancando / listo / fallo / detenido / falta Accesibilidad / dispositivo pidiendo aprobación), dispositivos conectados, "emparejar otro dispositivo", pausar/reanudar el control, abrir ajustes. |
| Tarjeta de emparejamiento | QR del `link`, PIN de 6 dígitos con cuenta atrás (`expiresInSecs`), botón de nuevo código y PIN, selector de dirección del QR (nombre `.local` / IP / personalizada). Mientras está visible → `setPinVisible(true)`; al ocultarse → `false`. Se refresca con `PairingChanged`. |
| Aprobación | Ventana/alerta por cada `ApprovalRequested` con nombre, modelo y dirección; Permitir / Rechazar → `respondApproval`; se cierra con `ApprovalEnded`. |
| Ajustes · General | Permitir control (= pausa), permitir dictado (requiere conexión cifrada en el teléfono), permisos, inicio de sesión, actualizaciones. |
| Ajustes · Teléfono | Pasos de conexión, PIN on/off, aprobación on/off, puerto, dirección personalizada, instalación del certificado CA (QR que apunta a `/remoto.crt`, huella SHA-256, instrucciones iOS/Android). |
| Ajustes · Dispositivos | Conectados (desconectar) y de confianza (renombrar, olvidar, olvidar todos; olvidar borra también sus ajustes). |
| Ajustes · Deck | Exportar/importar `Remoto Deck.json`, restaurar por defecto, permitir comandos de shell (con confirmación explícita y aviso de riesgo). |
| Ajustes · Avanzado | Repetir bienvenida, nivel de log, mostrar carpeta de datos, aceptar conexiones vía proxy local, reiniciar servidor. |
| Ajustes · Acerca de | Versión, reportar un problema. |
| Bienvenida | 3 pasos: introducción, permiso de Accesibilidad, conectar el teléfono. |

Preferencias persistidas (por defecto): `port` 8740, `linkHostMode` hostName, `customHost` "", `allowPin` true, `allowApproval` true, `allowShell` false, `allowLocalProxy` false, `voiceEnabled` true, `welcomeDone` false, `appFolders` [], `logFilter` info.

---

## 16. Cliente web (teléfono)

### 16.1 Estructura
- SPA servida desde `/` (rutas absolutas), sin router: la pestaña activa es `settings.tab ∈ trackpad|keyboard|deck|apps|media`. Vistas pesadas con carga diferida; si un chunk falla al cargar, recargar.
- Pantallas de nivel superior: **shell** (conectado, o reconectando tras haber estado conectado), **splash** (conectando con token y sin `denied`; a los 6 s ofrece "volver a emparejar"), **connect** (resto).
- Diseño compacto en horizontal con altura ≤ 500 px (barra lateral en vez de barra de estado + pestañas).
- Bloquear el zoom por gestos del navegador; altura de app = viewport visual; wake lock de pantalla mientras está conectado y visible (`keepAwake`).
- Tema `system|dark|light` aplicado al documento y a `theme-color`.
- Al recibir `welcome`, si `host.version` ≠ versión del propio cliente → recargar **una vez** por versión (guardas en sessionStorage `remoto.reloadedFor` / `remoto.reloadedAt`, ventana de 10 s).
- PWA: manifest (`start_url "/"`, `scope "/"`, `display standalone`, iconos 192/512 any+maskable y SVG). Service worker solo en contexto seguro: caché única, `skipWaiting` + `clients.claim`; solo GET del mismo origen excluyendo `/api/*`, `/ws` y `/remoto.crt`; navegaciones network-first con carrera de 3000 ms contra la caché (la respuesta tardía refresca la caché); resto network-first con caché de respaldo (para `/assets/*` también si la respuesta no es ok); al cambiar el HTML se purgan los `/assets/*` que ya no referencia.
- Archivos estáticos esperados: `/`, `/index.html`, `/manifest.webmanifest`, `/icon.svg`, `/icon-192.png`, `/icon-512.png`, `/apple-touch-icon.png`, `/sw.js`, `/voice-worklet.js`, `/assets/*`.

### 16.2 Almacenamiento local
| Clave | Almacén | Contenido |
|---|---|---|
| `remoto.deviceId` | localStorage | UUID (o 32 hex) creado una vez; en memoria si localStorage falla |
| `remoto.token` | localStorage | token del dispositivo |
| `remoto.settings` | localStorage | ajustes (§16.10), debounce 150 ms |
| `remoto.keyboards` | localStorage | `{active, boards[]}`, debounce 200 ms |
| `remoto.settingsSync` | localStorage | `{updatedAt, hash}` |

El deck **no** se guarda en el teléfono (vive en la Mac); solo `settings.deckPage`.

### 16.3 Conexión
- WebSocket a `ws(s)://<location.host>/ws` (`wss` si la página es https), `binaryType = arraybuffer`. `GET /api/info` (no-store) solo para mostrar "conectar a <name>".
- Estados: `idle | connecting | reconnecting | connected | pending | denied`.
- `connect(auth?)`: sin `auth` usa `{method:token}` si hay token; si no, `idle`. Un connect sin auth se ignora si hay un intento en curso con otro método.
- Timeout de apertura **5000 ms** (cuenta como fallo). En `open`: arrancar heartbeat y enviar `hello{v:1, device, auth, remember: settings.rememberDevice}`.
- `device = {id, name: deviceName.trim() || model, model}`; `model` por UA: `iPad | iPhone | iPod touch | Android phone | Android tablet | Windows PC | Mac | Browser` (un "Macintosh" táctil con > 1 punto de contacto = iPad).
- Mensajes binarios entrantes se ignoran.
- Reconexión con token: backoff `[250, 500, 1000, 2000, 3500, 5000]` ms indexado por intentos (tope en el último) × jitter `0.8 + 0.4·rand`; los intentos vuelven a 0 con `welcome`.
- Con `pin`/`pair`/`approve`: si en ese intento no llegó ningún mensaje, hasta 3 reintentos cada 1000 ms; luego `idle` con un motivo ("se perdió la conexión esperando la aprobación" si llegó algo, "no se pudo alcanzar la Mac" si no). Tras `welcome` se olvida el método y se usa el token.
- Heartbeat: `ping{id}` incremental cada **2000 ms** (máx. 8 pendientes). Sin **ningún** mensaje entrante durante **6000 ms** → reconectar. Latencia = EMA `round(0.7·lat + 0.3·rtt)` (primera muestra directa) con `pong`.
- `visibilitychange` a oculto: enviar `release` (si conectado), soltar modificadores y teclas, parar repetidores multimedia, `voiceStop{cancel:false}`, cancelar gestos en curso, guardar ajustes pendientes ya. A visible / `online` / `pageshow` persistido: si reconectando, o conectado con último mensaje > 6 s → reconectar ya (salvo socket abierto hace < 5 s y no obsoleto). Al volver visible, tras `welcome` y tras `paused:false`, re-pulsar en la Mac los modificadores bloqueados.
- Reglas de envío: JSON solo con socket abierto y `connected` (salvo `hello` y `ping`); antes de cualquier JSON que no sea `hello`/`ping`, vaciar el agrupador binario (conserva el orden movimiento → clic). Binario solo con `connected`.
- Agrupador binario: `move` acumula y vacía como mucho cada 6 ms; `scroll` acumula con la fase del primer evento del lote (Began fuerza vaciado previo; Ended/Cancelled vacían y envían `Scroll(fase,0,0)` inmediato); en cada vaciado primero Move (si ≠ 0) y luego Scroll (si hay fase); si `bufferedAmount > 65536` y no es forzado, reintentar a los 8 ms acumulando; `fling` vacía y envía; `touch` inmediato; al cerrar se descarta lo acumulado.

### 16.4 Emparejamiento (pantalla connect)
- `#pair=<code>` (o `&pair=` dentro del hash) al cargar → conectar con `pair` y borrar el fragmento de la URL (`history.replaceState`); en ese caso no se intenta el token al montar.
- PIN: campo numérico, se filtran no-dígitos, máx. 6, envío automático al completar 6.
- Botón "pedir aprobación a la Mac" → `approve`; con `pending`: pantalla de espera con nombre de la Mac y modelo, y Cancelar (desconecta conservando token).
- `welcome.token` presente → guardarlo.
- "Desconectar": cerrar y `idle` conservando el token. "Olvidar esta Mac": borrar token y cerrar (no se avisa al servidor).

| `denied.reason` | Estado | Sentido del mensaje |
|---|---|---|
| `wrongPin` | denied | el PIN no coincide (vaciar el campo) |
| `expiredCode` | denied | código caducado o ya usado; escanear el nuevo o usar PIN |
| `rejected` | denied | con PIN: el PIN está desactivado en la Mac; si no: la Mac no permitió el dispositivo / aprobación desactivada |
| `pinClosed` | denied | abrir el menú en la Mac para mostrar el PIN |
| `blocked` | denied | demasiados intentos, reintentar en `retryAfter` (o 30) s |
| `busy` | denied | la Mac ya atiende una solicitud de este dispositivo |
| `incompatible` | denied | versión distinta; botón recargar |
| `unknown` | idle; borra el token si la auth era por token | el dispositivo ya no está emparejado |
| otro | denied | no se pudo conectar |

En `denied` no se reconecta. `bye{reconnect:false}` → `idle` mostrando el motivo; `bye{reconnect:true}` → esperar el cierre y reconectar.

### 16.5 Mensajes entrantes en el cliente
| Mensaje | Efecto |
|---|---|
| `welcome` | `connected`, aplicar host/features/deck/volume/paused/sessionKey/layout, sincronizar ajustes (§16.11), vaciar el compositor en vivo, re-pedir `apps` si ya se habían pedido. |
| `deck` | reemplaza y pasa a ser la copia confirmada. |
| `layout`, `features`, `paused`, `volume`, `volumeUnavailable` | actualizan el estado (el slider de volumen no se pisa mientras se arrastra; `volumeUnavailable` oculta slider y porcentaje). `paused:true` → superposición "en pausa en la Mac". |
| `appsChanged` | si la lista estaba cargada, re-pedir `apps` (forzado). |
| `notice` | toast (nivel por defecto info). Mismo `code` reemplaza el toast anterior. `code:"deck"` revierte el deck a la copia confirmada; `code:"settings"` aborta una lista/copia de ajustes en curso. |
| `actionResult` | resuelve la promesa por `id`; sin id conocido y `!ok && message` → toast de error. |
| `voice` | §16.9 |
| `settings`, `settingsList` | §16.11 |

Toasts: máx. 3 visibles; 4,5 s (error 7 s). `features.permission == false` → indicador rojo que explica que falta Accesibilidad en la Mac.

### 16.6 Trackpad
Pointer Events con captura y eventos coalescidos; con ratón solo botón 0.

| Constante | Valor |
|---|---|
| Umbral de movimiento 1 dedo | 5 px |
| Umbral de scroll 2 dedos (centroide) | 7 px |
| Radio de segundo toque (tap-and-drag / doble tap) | 40 px |
| Umbral de swipe 3+ dedos (centroide) | 38 px |
| Pinch: \|spread/spread0 − 1\| | > 0,14 con centroide < 21 px |
| Paso de zoom | ×1,22 / ÷1,22 |
| Fling mínimo | 140 px/s |
| Ventana de velocidad / frescura de la última muestra / historial | 90 / 55 / 180 ms |
| Pulsación larga | 450 ms |
| Tap 1 / 2 / 3–4 dedos | ≤ 260 / ≤ 364 / ≤ 390 ms |
| Espera del clic diferido (tap-and-drag) | 260 ms |

Gestos:
- Primer dedo: enviar `Touch`; reiniciar el suavizado de aceleración. Si hay clic diferido y el toque está a ≤ 40 px del último tap (sin drag lock) → cancelar el clic y marcar *segundo toque*; si no, enviar el clic diferido ya. Programar pulsación larga (si `longPress ≠ off`, sin drag lock, sin segundo toque).
- Un dedo > 5 px: con segundo toque → `button{left,down}` y arrastre; con drag lock → arrastre; si no → apuntar. El primer movimiento lleva el desplazamiento desde el inicio. Antes del primer movimiento/scroll se "comprometen" los modificadores mantenidos (§16.7).
- Apuntar/arrastrar: solo el dedo primario; `Move(dx·g, dy·g)`.
- Dos dedos: pinch (si `pinchToZoom`) o scroll si el centroide supera 7 px → `Scroll(Began)` y luego `Changed` con el delta del centroide (cada dedo aporta `delta/n`).
- Pinch: al cruzar ×1,22 → `tap{code:24, mods:1}` (zoom in); ÷1,22 → `tap{code:27, mods:1}`; re-basar.
- 3+ dedos con centroide > 38 px: dirección por eje dominante (y+ abajo) → `action` de `threeFinger[dir]` o, con 4+, `fourFinger[dir]`; háptica.
- Al soltar el último dedo: drag lock activo → `button{left,up}`; segundo toque sin mover → **dos** `button{left,click}`; 1 dedo ≤ 260 ms con `tapToClick` → clic diferido 260 ms si `tapAndDrag`, si no `click left`; 2 dedos ≤ 364 ms con `twoFingerTapRightClick` → `click right`; 3/4 dedos ≤ 390 ms → acción `tap`. Arrastrando: con `dragLock` queda pulsado; si no, `up`. Scroll: `Scroll(Ended)` y, con `momentum` y velocidad ≥ 140 px/s, `Fling(vx,vy)` (velocidad = Σdelta de las muestras de los últimos 90 ms / max(16 ms, Δt) × 1000; 0 si < 2 muestras o la última tiene > 55 ms). Si un dedo se levanta durante un scroll, terminarlo así.
- Añadir dedo en espera/apuntando: cancelar pulsación larga, emitir el clic pendiente si había segundo toque, re-basar.
- Pulsación larga (1 dedo quieto): `drag` → `button{left,down}` y arrastre; `rightClick` → `click right`.
- Cancelación (pointercancel, desconexión, ocultar, desmontar): soltar botón si arrastraba; `Scroll(Cancelled)` si hacía scroll.

Aceleración (en el cliente):
```
dt = max(1, dt_ms);  v = hypot(dx,dy)/dt                 # px CSS / ms
tau = 25 + 15*clamp((pointerSpeed-1)/3, 0, 1)
s = (s<0) ? v : s + (v-s)*(1-exp(-dt/tau))                # reiniciado en cada Touch
sp(x,k) = k*log1p(exp(x/k))
z = max(0, 2.2 - sp(2.2 - sp((s-0.08)/0.9, 0.03), 0.1))
g = pointerSpeed * (0.8 + acc*z*1.4 + (1-acc)*0.25)       # acc = pointerAcceleration
Move = (dx*g, dy*g)
```
Scroll y fling: factor `scrollSpeed × 1,6 × (naturalScroll ? 1 : −1)`.

Franja de scroll (si `scrollStrip ≠ off`, lado `scrollStripSide`): `Touch` al tocar; primer movimiento → `Scroll(Began, 0, dy·f)`, luego `Changed`, al soltar `Ended`/`Cancelled`; solo eje Y; fling vertical con las mismas reglas (sin fling si estaba en modo mantener). En modo `short` con `scrollHold`, si el asa llega al tope: scroll continuo a `signo × min(2400, 360 + exceso×14)` px/s, tick 16 ms, dt ≤ 0,1 s.

Botones bajo el trackpad (`clickButtons`): Clic y Clic derecho con `down`/`up` (mantener uno + mover = arrastrar). Opcional: tira de modificadores (esc, tab, ctrl, opt, shift, cmd) y acceso al compositor.

### 16.7 Teclados
- Modo `keyboard`: `auto` (Mac si es tablet o ancho ≥ 560 px; si no, phone), `mac`, `custom`, `phone` (solo compositor).
- **Teclado Mac virtual**: filas ANSI o ISO según `layout.iso`; etiquetas desde la distribución recibida (por defecto US); tecla bajo el dedo o la más cercana a ≤ 24 px. Teclas normales → `key{down/up, mods, repeat: settings.keyRepeat}` con refcount por code. Fila F1–F12: si `(functionRow == media) XOR Fn activo` → F1/F2 brillo −/+, F3 `action system missionControl`, F4 `action system spotlight`, F5/F6 retroiluminación −/+, F7 previous, F8 playPause, F9 next, F10 mute, F11 volumen −, F12 volumen +; si no, la tecla F.
- **Máquina de modificadores**: tap ≤ 320 ms sin uso → *latched* (una vez); segundo tap ≤ 380 ms → *locked* (envía `key down` real, salvo Fn; otro tap lo libera con `key up`); mantener → *held* (`key down` real justo antes de la primera acción que lo usa, `key up` al soltar). `mods` enviado = latched ∪ Fn bloqueado; los bloqueados ≠ Fn no van en `mods`. Bits derechos solo desde las teclas derechas del teclado virtual. Un control en la barra de estado suelta todos.
- **Compositor**: en vivo (`liveTyping`) → `edit{delete, insert}` con diff por **grafemas** (prefijo común; nada si `delete==0 && !insert`), suprimido durante composición IME; Enter (sin Shift) → `tap{36}` y limpiar; Backspace vacío → `tap{51}`; con modificadores pendientes y un solo carácter → `tap` con code+mods de la distribución. El campo se vacía localmente al pasar de 2000 grafemas. Sin vivo → `text{text, mode: textMode}` al enviar. Botones: vivo on/off, pegar portapapeles del teléfono (`text{mode:"paste"}`), limpiar (local), micrófono (si `features.voice` y contexto seguro), flechas, Delete y Return (`key`).
- **Teclado físico** del teléfono: `keydown`/`keyup` globales (salvo foco en campo de texto, IME o diálogo abierto) → `key{code, down:true, repeat:true}` sin `mods` / `key{down:false}`; los modificadores físicos van como teclas propias; `keydown` repetidos de una tecla ya pulsada se descartan; `blur` suelta todo.
- **Teclados personalizados**: hasta 24; `Board = {id ≤32, name ≤32, cols 2..12, rows 1..8, trackpad:bool, keys}`; `Key = {id ≤32, x, y, w, h, action, label? ≤12}` sin solapes; `KeyAction = {kind:"key", code 0..127, mods 0..31} | {kind:"mod", mod} | {kind:"media", key} | {kind:"mouse", button: left|right|middle}`. Plantillas propias de ejemplo (p. ej. presentación, juego, edición). Se respaldan en la Mac solo dentro de `settingsSave`.

### 16.8 Deck, apps y multimedia
- **Deck**: tocar tile → `action{action, id}` (id incremental; si no hay `actionResult` en 15 s se da por ok); > 250 ms muestra "ejecutando"; `!ok` marca el tile como fallido 600 ms + háptica de error + toast. Mantener 550 ms → modo edición (reordenar arrastrando > 8 px; tocar abre el editor). Toda edición (tiles y páginas) clona el deck, lo modifica y envía `deckSave` de forma optimista; si no se puede enviar → revertir a la copia confirmada con aviso. Ids nuevos `p-`/`t-` + 10 caracteres base36. Página nueva `{columns:4, tiles:[]}`. Columnas mostradas = `round(columns × max(1, ancho/366) / max(deckButtonSize, 0.1))` en 1..12; separación 10 px. Paleta de colores propia; icono automático si falta (icono de app o símbolo de la acción). Editor: valida como §12 (límites cliente: 24 páginas, 64 tiles, label 80, texto 4096 B, 64 pasos, 3 niveles, delay ≤ 10000; URL `^[a-z][\w+.-]*:\S+` sin distinguir mayúsculas); los tipos `shortcut`, `mouse`, `sequence`, `delay` y `shell` solo con `showAdvanced`; `shell` solo si `features.shell`; `keys` por defecto ⌘C (`{code:8, mods:1, char:"c"}`).
- **Apps**: al mostrarse pide `apps` (throttle 3 s salvo forzado); filtros "abiertas"/"todas" (la búsqueda ignora el filtro), orden por nombre; iconos `<img src="/api/icon?id=…&size=round(css × min(dpr||2, 3))&k=sessionKey">` con reserva si falla o no hay `sessionKey`. Tocar → `appAction toggle`; mantener 500 ms → menú abrir (`open`), ocultar, salir, "añadir al deck" (tile app toggle en la página actual o la primera).
- **Multimedia**: previous/playPause/next (`click`); rewind/fastForward (`down`/`up`); volumen ±, brillo ±, retroiluminación ± con autorepetición en el cliente (`click` al pulsar, otra a los 420 ms y luego cada 110 ms); slider `volume{value, muted:false}` paso 0,01 con throttle 60 ms (el último valor siempre sale); botón mute `volume{muted:!muted}`; porcentaje = `round(value×100)`.

### 16.9 Dictado
- Requisitos: conectado, `features.voice`, contexto seguro, micrófono y AudioWorklet; si falta algo, error en el compositor.
- Micrófono mono con cancelación de eco, supresión de ruido y control de ganancia. Worklet propio (`/voice-worklet.js`) que diezma por vecino más cercano a 16 kHz, recorta a [−1, 1], convierte a Int16 (`s<0 ? s·32768 : s·32767`) y entrega bloques de **1600 muestras (100 ms)** + pico (para un vúmetro). La salida pasa por ganancia 0 al destino para mantener el grafo vivo.
- Cada bloque → frame `0x10 + PCM` (3201 B). Después de montar la captura se envía `voiceStart{locale: navigator.language}`.
- `voice`: `listening` con `text` → texto parcial; con `final && text` → añadirlo al compositor (con espacio si hace falta; en vivo sale por `edit`). `stopped` → añadir `text` si viene y parar captura. Otro estado → error (`message` o genérico) y parar.
- Parar: `voiceStop{cancel:false}` a mano u al ocultar; `cancel:true` ante errores; al perder la conexión se detiene localmente.

### 16.10 Ajustes locales
| Clave | Defecto | Rango | Clave | Defecto | Rango |
|---|---|---|---|---|---|
| `version` | 1 | | `pinchToZoom` | true | |
| `pointerSpeed` | 1.2 | 0.2–4 | `threeFinger` | up missionControl, down appExpose, left spaceRight, right spaceLeft, tap mouse middle | Action \| null |
| `pointerAcceleration` | 0.6 | 0–1 | `fourFinger` | up launchpad, down showDesktop, left nextTab, right previousTab, tap null | |
| `tapToClick` | true | | `keyboard` | auto | auto/mac/custom/phone |
| `twoFingerTapRightClick` | true | | `functionRow` | media | media/function |
| `longPress` | drag | drag/rightClick/off | `keyRepeat` | true | |
| `tapAndDrag` | true | | `textMode` | unicode | unicode/keystrokes/paste |
| `dragLock` | false | | `liveTyping` | true | |
| `clickButtons` | true | | `deckButtonSize` | 1 | 0.7–1.6 |
| `scrollSpeed` | 1 | 0.2–4 | `haptics` | true | |
| `naturalScroll` | true | | `theme` | system | system/dark/light |
| `momentum` | true | | `keepAwake` | true | |
| `scrollStrip` | short | short/long/off | `showTouches` | true | |
| `scrollStripSide` | right | right/left | `rememberDevice` | true | |
| `scrollHold` | true | | `deviceName` | "" | ≤ 40 |
| `showAdvanced` | false | | `tab` | trackpad | 5 pestañas |
| | | | `deckPage` | "" | id de página |

Al cargar se validan tipos y enums y se recortan los números. "Restablecer" restaura todo salvo `deviceName`, `tab` y `deckPage`. Háptica: `vibrate` select 12, light 16, medium 26, heavy 40, error [30, 50, 30] ms (en iOS se puede usar un interruptor oculto como alternativa).

### 16.11 Sincronización de ajustes con la Mac
- Blob: `{version:1, settings:{todas las claves salvo version, deviceName, rememberDevice, tab, deckPage}, keyboards:[Board]}`.
- Hash FNV-1a 32 bits de `JSON(settings) + JSON(keyboards sin ids)`; `updatedAt` en ms, estrictamente creciente (`max(now, prev+1)`).
- Tras un cambio sincronizable: `settingsSave` con debounce **1500 ms** (y al ocultar), solo si hay token, conexión y `updatedAt > lastSent`; si el JSON supera 131072 B no se envía y se avisa.
- En `welcome`: si `welcome.settings.updatedAt` > local → aplicar lo del servidor (acciones de 3/4 dedos inválidas vuelven al defecto); si lo local es más nuevo → `settingsSave`.
- Copiar desde otro dispositivo: `settingsList` (timeout 8 s) → lista con nombre, modelo y "actualizado hace…" ("no hay otros dispositivos" si vacía) → `settingsCopy{from}` (timeout 8 s) → `settings`: validar, aplicar, avanzar `updatedAt`, re-subir con `settingsSave` y confirmar; inválido → aviso.

---

## Apéndice A. Constantes

| Ámbito | Constante | Valor |
|---|---|---|
| Protocolo | versión `v` / `/api/info.protocol` | 1 |
| Sesión | timeout de `hello` | 10 s |
| Sesión | espera de aprobación | 120 s |
| Sesión | timeout de envío | 5 s |
| Sesión | watchdog de silencio (tick 1 s) | > 8 s |
| Sesión | cola de acciones / tareas bloqueantes | 32 / 8 |
| Sesión | texto máximo | 65536 B |
| Sesión | mensaje / frame WS máximo | 64 MiB / 16 MiB |
| Red | conexiones total / por IP / loopback con proxy | 128 / 16 / 64 |
| Red | intentos de puerto | 20 (base+0..19) |
| Red | peek / handshake TLS | 10 s / 10 s |
| Red | cabecera máx. / timeout 1.ª / siguientes | 16384 B / 30 s / 10 s |
| Red | keep-alive | < 200 peticiones, < 120 s, < 96 conexiones |
| Red | `/api/icon` id / buckets / defecto | ≤ 512 B / 64,128,256,512 / 128 |
| Red | caché iconos / assets | 86400 s / 31536000 s |
| Housekeeping | intervalo | 5 s |
| Auth | código / token / sessionKey | 18 / 32 / 18 bytes aleatorios (base64url) |
| Auth | vida de código y PIN | 600 s |
| Auth | gracia del PIN tras ocultarlo | 180 s |
| Auth | umbral PIN / aprobación | 5 / 3 fallos |
| Auth | bloqueos | 30·2ⁿ s (n<5), luego 900 s |
| Auth | reinicio del contador | 3600 s sin fallos |
| Auth | bloqueo global | ≥ 20 fallos de PIN en 60 s |
| Auth | claves rastreadas antes de podar | 1024 |
| Auth | aprobaciones pendientes | ≤ 2, 1 por clave |
| Confianza | máx. dispositivos | 64 |
| Confianza | id / name / model | 128 / 64 / 64 caracteres |
| Confianza | persistir `lastSeen` | si el anterior ≥ 3600 s |
| TLS | CA / hoja / backdate / renovación | 3650 d / 397 d / 1 d / < 30 d |
| Ajustes | tamaño máximo | 131072 B |
| Motor | pacer / fling / fin de scroll / watchdog | 4,167 ms / 8,333 ms / 300 ms / 250 ms |
| Motor | pacer avg inicial, jit inicial, límites | 0,016 s, 0,002 s, avg ∈ [0,004, 0,034], lead ≤ 0,034 |
| Motor | recorte de deltas | ±4000 |
| Motor | fling mínimo / máximo / corte / duración / fricción / dt máx. | 80 / 12000 / 12 / 4 s / 2,6 / 0,024999 s |
| Motor | doble clic distancia | 5 px |
| Motor | hold tap / tecleo / pausa modificadores | 12 ms / 2 ms / 8 ms |
| Motor | repetición: defecto delay/interval, tope, silencio | 500 / 83 ms, 60 s, 3 s |
| Motor | soltar por silencio | > 5 s (enteros) |
| Motor | caché permisos / secure input / CapsLock / pantallas | 750 / 750 / 750 ms / 1 s |
| Motor | avisos por (tipo, sesión) | 1 cada 4 s |
| Motor | subpíxel | 1,5 px |
| Texto | segmento | ≤ 16 unidades UTF-16 |
| Texto | backspaces máx. por `edit` | 4096 |
| Texto | espera tras ⌘V | 450 ms |
| Acciones | delay máx. / trozo | 10000 ms / 50 ms |
| Acciones | shell poll / SIGKILL tras | 100 ms / ≥ 1 s |
| Deck | páginas / tiles / label / id / columnas | 24 / 64 / 80 car. / 128 B / 1–8 |
| Deck | texto, URL, comando / nombre app o shortcut / char | 4096 / 512 / 16 B |
| Deck | pasos / profundidad | 64 / 2 (3 niveles) |
| Host | debounce appsChanged / sondeo permisos / sondeo tiempos | 0,4 s / 2 s / 30 s |
| Host | caché inventario de apps | 60 s |
| Host | pausa de voz / espera final | 1,2 s / 2,5 s |
| Cliente | ping / inactividad / apertura | 2000 / 6000 / 5000 ms |
| Cliente | backoff token | 250, 500, 1000, 2000, 3500, 5000 ms × 0,8–1,2 |
| Cliente | reintentos pin/pair/approve | 3 × 1000 ms |
| Cliente | flush binario / backpressure | 6 ms / 65536 B, reintento 8 ms |
| Cliente | timeout acción / list-copy | 15 s / 8 s |
| Cliente | debounce ajustes / sync / teclados | 150 / 1500 / 200 ms |
| Cliente | throttle apps / volumen | 3000 / 60 ms |
| Cliente | repetición multimedia | 420 ms, luego 110 ms |
| Cliente | modificador latch / lock | 320 / 380 ms |
| Cliente | pulsación larga deck / apps / trackpad | 550 / 500 / 450 ms |
| Cliente | splash → volver a emparejar | 6 s |
| Cliente | SW navegación / guarda de recarga | 3000 ms / 10 s |
| Cliente | toasts | 3 visibles; 4,5 s (error 7 s) |
| Audio | formato / bloque | PCM Int16 LE mono 16 kHz / 1600 muestras |

## Apéndice B. Keycodes

### B.1 Keycodes virtuales de macOS usados
A 0, S 1, D 2, F 3, H 4, G 5, Z 6, X 7, C 8, V 9, ISO§ 10, B 11, Q 12, W 13, E 14, R 15, Y 16, T 17, 1 18, 2 19, 3 20, 4 21, 6 22, 5 23, = 24, 9 25, 7 26, − 27, 8 28, 0 29, ] 30, O 31, U 32, [ 33, I 34, P 35, Return 36, L 37, J 38, ' 39, K 40, ; 41, \ 42, , 43, / 44, N 45, M 46, . 47, Tab 48, Space 49, ` 50, Delete 51, Escape 53, RightCmd 54, Cmd 55, Shift 56, CapsLock 57, Option 58, Control 59, RightShift 60, RightOption 61, RightControl 62, Fn 63, F1 122, F2 120, F3 99, F4 118, F5 96, F6 97, F7 98, F8 100, F9 101, F10 109, F11 103, F12 111, Home 115, PageUp 116, ForwardDelete 117, End 119, PageDown 121, Left 123, Right 124, Down 125, Up 126.

### B.2 Tabla ANSI de reserva para letras de acciones de sistema
Solo minúsculas: `a`0x00 `s`0x01 `d`0x02 `f`0x03 `h`0x04 `g`0x05 `z`0x06 `x`0x07 `c`0x08 `v`0x09 `b`0x0B `q`0x0C `w`0x0D `e`0x0E `r`0x0F `y`0x10 `t`0x11 `1`0x12 `2`0x13 `3`0x14 `4`0x15 `6`0x16 `5`0x17 `=`0x18 `9`0x19 `7`0x1A `-`0x1B `8`0x1C `0`0x1D `]`0x1E `o`0x1F `u`0x20 `[`0x21 `i`0x22 `p`0x23 `l`0x25 `j`0x26 `'`0x27 `k`0x28 `;`0x29 `\`0x2A `,`0x2B `/`0x2C `n`0x2D `m`0x2E `.`0x2F `` ` ``0x32; nombres: `up`0x7E `down`0x7D `left`0x7B `right`0x7C `tab`0x30 `space`0x31 `return`0x24 `delete`0x33 `escape`0x35 `f11`0x67. Cualquier otro nombre (incluidas mayúsculas) no existe.

---

## Apéndice C. Conformance checklist

Servidor HTTP
1. Una petición `POST /` responde 405; `GET /` con `Content-Length: 5` responde 400.
2. `Host: evil.example.com` responde 421; `Host: mac.local:8740`, `Host: 192.168.1.5`, `Host: [::1]:8740`, `Host: router.home.arpa` y `Host: mymac` se aceptan; `Host: local` se rechaza.
3. `/ws` con `Origin: http://otro:8740` distinto del Host responde 403; sin `Origin` hace upgrade; sin cabecera `Upgrade` responde 426; versión 12 responde 400 con `Sec-WebSocket-Version: 13`.
4. Toda respuesta lleva `X-Content-Type-Options`, `Referrer-Policy`, `X-Frame-Options` y la CSP exacta del §4.9.
5. `GET /api/info` devuelve exactamente las claves `name, protocol, secure, version` en ese orden, `protocol = 1`, `Cache-Control: no-store`.
6. `/api/icon` sin `k` válido → 403; `size=100` pide al host 128; `size=300` → 512; segunda petición igual no vuelve a llamar al host.
7. `/assets/x.js` lleva `immutable` y ETag; repetir con `If-None-Match` → 304. `/no-existe` (sin extensión) sirve `index.html` con `no-cache`; `/no-existe.js` → 404; `/.git/config` → 404.
8. Un ClientHello TLS en el puerto HTTP se atiende como HTTPS; sin identidad se cierra sin respuesta.
9. La 17.ª conexión simultánea desde una misma IP se cierra.
10. Si el puerto preferido está ocupado se usa el siguiente y `Started` lleva `preferredPortTaken = true`.

TLS
11. La CA tiene NameConstraints con exactamente los 8 subárboles del §5.2 y validez de 3650 días; la hoja ≤ 397 días y nunca más allá de la CA.
12. Los SAN no contienen IPv6 ni nombres fuera de `.local`/`localhost`; están ordenados y sin duplicados.
13. Reiniciar sin cambios conserva CA y hoja; cambiar de IP regenera solo la hoja; una CA a < 30 días de caducar se regenera.
14. `caFingerprint` tiene 95 caracteres en hex mayúscula separados por `:`.

Emparejamiento
15. El link es `http://<host>:<port>/#pair=<24 caracteres base64url>`.
16. El PIN nunca es `000000`, `123456`, `654321` ni similar; tiene 6 dígitos.
17. Un código usado una vez da `expiredCode` la segunda; también rota el PIN.
18. Con la tarjeta oculta desde hace > 180 s, un PIN correcto da `pinClosed`; a los 100 s se acepta.
19. 5 PIN incorrectos desde una IP → el 6.º intento da `blocked` con `retryAfter ≈ 30`; el siguiente bloqueo dura 60 s; tras el bloqueo el PIN cambió.
20. 20 fallos de PIN desde IPs distintas en 60 s bloquean también a una IP nueva.
21. `approve` envía `pending`; `respondApproval(false)` → `denied{rejected}`; 3 rechazos desde la misma IP → `blocked`; una segunda petición simultánea desde la misma IP → `busy`; sin respuesta en 120 s → `rejected` y `ApprovalEnded`.
22. `allowPin = false` → `pin` da `rejected`; `allowApproval = false` → `approve` da `rejected`.
23. `hello{v:2}` → `denied{incompatible}`; `device.id` con espacio o de 129 bytes → `incompatible`; primer mensaje `ping` → `bye{reconnect:false}`.
24. `denied` con `retryAfter` nunca lleva 0; sin bloqueo no lleva la clave.

Confianza y sesión
25. `remember:true` produce `welcome.token` de 43 caracteres; `remember:false` produce `token:null` y no escribe `trusted.json`.
26. `trusted.json` guarda `tokenHash` en hex minúscula de 64 caracteres y nunca el token.
27. Un token válido con otro `device.id` da `denied{unknown}`.
28. Un nombre renombrado en la Mac no cambia al reconectar con otro nombre.
29. El dispositivo 65 expulsa al de `lastSeen` más antiguo.
30. `welcome` tiene los campos en el orden del §8.2, `host.os == "macOS"`, omite `layout`/`volume`/`settings` cuando no hay valor y `features.permission` refleja Accesibilidad.
31. Tras `welcome` los eventos llegan en orden `Paired` → `DevicesChanged` → `SessionsChanged` (según corresponda).
32. Sin frames durante 9 s la sesión se cierra sin `bye`; con `ping` cada 2 s sigue abierta.
33. `stop()` envía `bye{reconnect:true}`; `forgetDevice` envía `bye{reconnect:false}` a sus sesiones recordadas y borra sus ajustes.
34. JSON malformado en sesión no cierra la sesión y suelta las teclas pulsadas.
35. `ping{id:"x"}` → `pong{id:"x"}`.

Protocolo y entrada
36. Frames binarios con longitud distinta (Move de 8 B) o NaN se ignoran pero mantienen viva la sesión.
37. `Move` de (5000, 0) se recorta a 4000; (0,0) no genera evento.
38. Dos `button click left` dentro de `doubleClick` y a ≤ 5 px producen clickState 1 y 2.
39. `Scroll` Changed sin Began previo publica fase Began; un gesto sin eventos 300 ms publica Ended.
40. `Fling` de 50 px/s no produce eventos; uno de 20000 se recorta a 12000 y termina en ≤ 4 s con momentum End; un `Touch` lo detiene.
41. `key{code:0, down:true, repeat:true}` repite tras `repeatDelay` y deja de repetir 3 s después del último mensaje de la sesión, y se suelta a los ~6 s sin señales.
42. `key` del mismo code dos veces sólo publica un down; `key{code:57}` alterna el bloqueo de mayúsculas real.
43. `tap{code:300}` y `tap{mods:0x20}` se ignoran.
44. `media{key:"volumeUp", op:"click"}` publica down+up system-defined con NX_KEYTYPE 0.
45. Sin permiso de Accesibilidad llega `notice{level:"warning", code:"permission"}` como mucho una vez cada 4 s por sesión.
46. Con un campo de contraseña activo, `text` produce `notice{code:"secureInput"}`.
47. Pausa: la entrada no llega a la Mac, una acción `delay` en curso termina con `ok:false` y se difunde `paused`.

Texto
48. `text` de 65537 B → `notice{level:"warning", code:"tooLong"}`.
49. `"a\r\nb\tc"` se teclea como `a`, Return, `b`, Tab, `c`; los caracteres de control se descartan; un texto de 40 caracteres BMP sale en 3 segmentos Unicode.
50. Modo keystrokes con distribución US teclea `A` como Shift+0x00.
51. `edit{delete:3, insert:"x"}` publica 3 Backspace y luego `x`.
52. `text{mode:"paste"}` llama a `pasteBegin`, publica ⌘V, espera ~450 ms y llama a `pasteEnd`; el portapapeles previo se restaura si nadie lo cambió.

Deck y acciones
53. `deckSave` con 9 columnas → `notice{level:"error", code:"deck"}` y el deck no cambia; uno válido se difunde como `deck` a todas las sesiones y persiste.
54. Color `#12` es inválido; `#1234` es válido.
55. `sequence` con 4 niveles de anidamiento → `actionResult{ok:false}` inmediato; 65 pasos también.
56. `action` sin `id` que tiene éxito no produce `actionResult`; con `id` siempre.
57. La 33.ª acción encolada sin procesar → `actionResult{ok:false}`.
58. `url` con `javascript:` o `JavaScript:` o `data:` falla; `file:` falla con `allowShell = false`; `https:` llama a `openURL`.
59. `shell` con `allowShell = false` falla con mensaje; con true devuelve ok de inmediato y pausar mata el proceso (SIGTERM, luego SIGKILL).
60. `system copy` con distribución AZERTY usa el keycode de la `c` de esa distribución; `system spotlight` publica Cmd+Space.
61. `keys{code:0x100}` y `keys{mods:0x100}` son "invalid key".

Ajustes por dispositivo
62. `settingsSave` desde sesión no recordada no escribe nada.
63. `settingsSave` con `settings` no objeto o > 131072 B → `notice{level:"error"}`; con `updatedAt` menor al guardado → no-op.
64. `welcome.settings` de una sesión recordada devuelve el último blob guardado.
65. `settingsList` excluye al propio dispositivo y ordena por `updatedAt` descendente.
66. `settingsCopy` desde sesión no recordada o de un origen sin ajustes → `notice{level:"warning", code:"settings"}`.

Host app
67. `appsChanged` llega a los teléfonos ≤ 0,4 s después de lanzar o cerrar una app.
68. `appAction toggle` sobre la app activa la oculta; sobre una no abierta la lanza.
69. Cambiar la fuente de entrada difunde `layout` con 51 teclas y `dead` correcto para teclas muertas.
70. Cambiar el volumen en la Mac difunde `volume`; un dispositivo sin volumen difunde `volumeUnavailable`.
71. Dictado: frases separadas por silencios de > 1,2 s llegan como `voice{state:"listening", final:true}`; `voiceStop{cancel:false}` termina con `voice{state:"stopped"}`; con `voiceAvailable=false`, `voiceStart` responde `unavailable`.

Cliente web
72. Sin mensajes entrantes durante 6 s el cliente reconecta con backoff y token.
73. `denied{unknown}` en auth por token borra el token local.
74. Antes de un `button` se envía el `Move` acumulado (orden conservado).
75. El cliente no envía nada salvo `hello`/`ping` si no está `connected`.
76. `#pair=` se borra de la URL tras leerlo.
77. Con `naturalScroll = false` los deltas de scroll se invierten en el cliente, no en la Mac.
