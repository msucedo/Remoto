# Remoto: guía de diseño

Esta guía describe cómo se ve y cómo se comporta Remoto: la app de barra de menú para macOS y el cliente web que convierte el teléfono en trackpad, teclado, botonera, control multimedia y micrófono de dictado. No describe el protocolo ni la lógica de red; solo lo visual y la interacción. Todos los valores son concretos para que la interfaz se pueda reconstruir sin ver otra implementación.

Convenciones: en el cliente web las medidas están en px CSS; en la app de Mac, en puntos (pt). "Sugerencia" marca algo que conviene cambiar respecto al diseño de referencia (ver sección 6).

---

## 1. Principios

**Carácter visual**
- Sobrio y funcional. Una herramienta, no un escaparate: superficies planas, bordes de 1 px, pocas sombras, y un solo color de acento (azul).
- Sensación de hardware. Las teclas tienen una "sombra de canto" de 1 px debajo, el trackpad lleva una retícula de puntos tenue y los botones grandes de multimedia son redondos. Todo se puede pulsar con el pulgar sin mirar demasiado.
- Densidad media. Se aprovecha la pantalla del teléfono de borde a borde, con un margen lateral de 12 px y un espacio de 8 a 10 px entre bloques.
- Respuesta inmediata. Cada toque tiene un eco visual (cambio de fondo, escala, punto bajo el dedo) y, si el dispositivo lo permite, una vibración corta.
- Mismo idioma visual en claro y oscuro. El modo oscuro no es un negativo: tiene su propia paleta con acento más luminoso.
- En la Mac, nativo y discreto: SwiftUI estándar, formularios agrupados, símbolos SF y colores semánticos del sistema.

**Tono de los textos**
- Segunda persona, frases cortas, verbo primero. Ejemplo: "Escanea el código o escribe el PIN".
- Los errores dicen qué pasó y qué hacer después, en una sola frase. Ejemplo: "PIN incorrecto. Abre el menú de Remoto para ver el actual".
- Sin jerga técnica en la interfaz principal. Términos como "certificado", "puerto" o "bundle ID" solo aparecen en ajustes avanzados.
- Títulos y botones en mayúscula de oración ("Emparejar otro teléfono"), salvo los botones de la Mac, que siguen la convención de macOS en inglés (Title Case) si se localiza al inglés.
- Puntos suspensivos (…) en acciones que abren otra ventana o diálogo ("Ajustes…", "Exportar…") y en estados en curso ("Conectando…").
- Nada de exclamaciones ni emojis en textos de sistema. Las advertencias de seguridad son claras y sin dramatismo. Ejemplo: "Un botón de shell ejecuta cualquier comando como tú. Actívalo solo si todos los teléfonos emparejados son tuyos".
- Idiomas: inglés y español; el cliente web detecta el idioma del navegador y se puede forzar en Ajustes.

---

## 2. Tokens

### 2.1 Paleta del cliente web

| Token | Uso | Claro | Oscuro |
|---|---|---|---|
| bg | Fondo de la página | #f2f4f7 | #0e1116 |
| bg-2 | Tarjetas, hojas, barra de pestañas, tiles | #ffffff | #171b22 |
| bg-3 | Campos, botones secundarios, mensajes | #e6e9ef | #20252e |
| surface | Trackpad, riel de scroll, botones de clic | #e9ecf2 | #151a21 |
| surface-line | Bordes de 1 px y separadores | #d5dae3 | #262c36 |
| fg | Texto principal | #12161d | #eef1f6 |
| fg-2 | Texto secundario, iconos de botones | #4b5563 | #a7b0bf |
| fg-3 | Texto terciario, pestañas inactivas, pistas | #8a93a3 | #6d7685 |
| accent | Acento (pestaña activa, primario, foco) | #3b74e6 | #5b8cff |
| accent-fg | Texto sobre acento | #ffffff | #0b1020 |
| accent-soft | Relleno suave de acento | #3b74e6 al 14 % | #5b8cff al 18 % |
| ok | Conectado, interruptor encendido | #1f9d6b | #37c48b |
| warn | Reconectando, avisos | #c98a07 | #e7b23d |
| danger | Errores, acciones destructivas, grabando | #d6453d | #ff6b61 |
| key | Cara de tecla | #ffffff | #262c36 |
| key-pressed | Tecla pulsada | #cdd5e2 | #3a4250 |
| backdrop | Velo detrás de hojas y overlays | #0a0e16 al 42 % | #000000 al 55 % |

- Color de la barra del navegador (theme-color): #f2f4f7 en claro y #0e1116 en oscuro; se actualiza al cambiar de tema.
- Tema: Sistema (por defecto), Oscuro o Claro.
- Marca: degradado diagonal de #3aa7e0 (arriba a la izquierda) a #5b6cf0 (abajo a la derecha). Se usa en el ícono de la app web y en el sello de la pantalla de conexión.
- Paleta de los tiles de la botonera (nueve colores, en este orden): #e4572e rojo, #f3a712 ámbar, #a8c256 lima, #29bf9e verde agua, #3aa7e0 celeste, #5b6cf0 índigo, #9b5de5 violeta, #e05297 rosa, #7a8591 gris. Además está la opción "sin color".
- Toast de aviso: fondo warn con texto #1d1500. Toast de error: fondo danger con texto blanco.

### 2.2 Paleta de la app de Mac

Solo colores semánticos del sistema; nada de hex propios salvo el blanco detrás del QR.
- Estado: verde (listo o conectado), naranja (arrancando, falta un permiso o hay una solicitud pendiente), amarillo (en pausa), rojo (error al arrancar), gris (detenido).
- Avisos ("callouts"): el color del aviso al 12 % de opacidad como fondo, radio 8 pt.
- Acento: el tinte del sistema (lo que elija el usuario en Ajustes del Sistema).

### 2.3 Tipografía

- Web: la fuente del sistema (San Francisco en Apple, Roboto en Android, Segoe UI en Windows). Monoespaciada del sistema (SF Mono, Menlo) para bundle IDs y comandos de shell.
- Base: 15 px con interlineado 1.4.
- Escala web: 11 px (etiquetas de pestaña, teclas F), 12 px (nombres de apps), 13 px (texto pequeño, pistas, barra de estado, cabeceras de grupo), 14 px (toasts, resumen de pasos), 15 px (cuerpo y teclas), 16 px (todos los campos de texto, para que iOS no haga zoom al enfocarlos), 17 px (título de hoja), 19 px (títulos de overlay y de espera), 20 px (vista previa de tecla), 24 px (título de la pantalla de conexión), 30 px (campo de PIN).
- Pesos: 400 normal, 500 para segmentos y pasos, 600 para títulos, nombre de la Mac y botón primario.
- Cifras tabulares en latencia, porcentaje de volumen, PIN y valores de ajustes.
- Cabeceras de grupo en ajustes: 13 px, 600, MAYÚSCULAS, interletrado 0.05 em, color fg-3.
- Mac: estilos dinámicos del sistema (headline, callout, caption, title2, title3). El PIN usa la fuente monoespaciada del sistema, semibold, de 30 pt en la vista grande y 22 pt en la compacta.

### 2.4 Espaciado

- Margen lateral de las vistas: 12 px más el safe area horizontal.
- Separación entre bloques de una vista: 10 px (14 px en multimedia).
- Separación entre teclas: 5 px en el teclado Mac y 6 px en la fila de modificadores y en los teclados personalizados.
- Separación entre tiles de la botonera y entre apps: 10 px.
- Hojas: 16 px de padding horizontal y 12 px entre bloques.
- Mac: panel del menú con 14 pt de padding y 12 pt entre secciones; ventanas con 18 a 28 pt.

### 2.5 Radios

| Elemento | Radio |
|---|---|
| Teclas | 8 px |
| Campos de texto, celdas del selector de símbolos | 10 px |
| Botones, botones de icono, mensajes, toasts, segmentado (contenedor) | 12 px |
| Segmentado (opción interior) | 9 px |
| Tarjetas, grupos de ajustes, campo del redactor | 14 px |
| Botones de clic del trackpad, apps | 16 px |
| Tiles de la botonera, sello de marca | 18 px |
| Hojas (esquinas superiores), tarjeta de overlay | 20 px |
| Superficie del trackpad | 22 px |
| Riel de scroll | 23 px (cápsula) |
| Chips, píldoras, interruptores | totalmente redondeados |
| Mac: callouts 8 pt; QR 12 pt; caja de permiso en bienvenida 10 pt |

### 2.6 Sombras y profundidad

- Canto de tecla: 0 / 1 px / sin desenfoque, negro azulado al 18 % en claro y negro al 55 % en oscuro. Da la sensación de tecla física sin relieve.
- Sombra elevada (hojas, toasts, tile arrastrado, tarjeta de overlay): desplazamiento vertical de 10 px con 30 px de desenfoque al 18 % en claro; 12 px y 34 px al 50 % en oscuro.
- Opción seleccionada de un segmentado: 0 / 1 px / 3 px al 14 %.
- Mando del interruptor: 0 / 1 px / 3 px al 30 %.
- Overlay de pausa: desenfoque del fondo de 6 px además del velo.

**Orden de capas (de abajo arriba):** vistas (0) → tile arrastrado dentro de la cuadrícula (5) → overlay de pausa (40) → velo y hojas (50) → toasts (60). La pantalla de conexión y la de arranque ocupan toda la ventana en lugar de la interfaz principal; no se superponen.

### 2.7 Iconografía

- Web: [Lucide](https://lucide.dev) (licencia ISC), trazo de 2 px, esquinas y extremos redondeados. Tamaño por defecto 20 px; 22 px en la barra de pestañas; 14 px para el candado de la barra de estado; 16 px en teclas F, chevrons de filas y teclas de función; 18 px en las flechas del redactor y en el botón Enviar; 24 px en botones multimedia; 34 px en el botón grande de reproducir; 28 px en el sello de marca y en el tile "añadir"; 32 px en el overlay de pausa.
- Pestañas: puntero del ratón (Trackpad), teclado (Teclas), cuadrícula (Botonera), nota musical (Multimedia), ventana de app (Apps).
- El selector de iconos de tiles ofrece unos 65 símbolos de Lucide (ventanas, pantalla, búsqueda, captura, candado, encendido, luna, reproducción, volumen, brillo, portapapeles, deshacer, zoom, globo, casa, correo, calendario, carpeta, imagen, música, código, terminal, cohete, estrella, corazón, etc.). Si un nombre no existe se muestra un cuadrado neutro.
- Iconos de apps de la Mac: imagen real servida por la Mac, escalada con "contain"; si falla, el icono genérico de ventana al 60 % del tamaño.
- Mac: SF Symbols en todos lados, con el peso del texto que acompañan.

### 2.8 Movimiento

| Animación | Duración | Curva | Detalle |
|---|---|---|---|
| Entrada de hoja | 220 ms | cubic-bezier(0.2, 0.8, 0.2, 1) | Sube 40 px desde 60 % de opacidad |
| Velo (entrada y salida) | 180 ms | ease | Fundido; la hoja se retira del DOM a los 180 ms |
| Toast | 200 ms | ease | Mismo "subir" que la hoja |
| Desvanecer pista del trackpad | 400 ms | ease | Al primer toque |
| Pulsación de tile | 120 ms | ease | Escala a 0.95 |
| Pulgar del riel en reposo | 120 ms | ease | Vuelve al centro; mientras se arrastra, sin transición |
| Interruptor | 150 ms | ease | Fondo y desplazamiento del mando (20 px) |
| Spinner | 900 ms | lineal, infinito | Giro completo |
| Punto de reconexión | 1 s | ease-in-out, alterno | Opacidad de 100 % a 30 % |
| Micrófono grabando | 900 ms | ease-in-out, alterno | Mismo pulso |
| Tile ejecutando | 900 ms | lineal, infinito | Brillo de acento suave que barre de izquierda a derecha |
| Tiles en edición (bamboleo) | 300 ms | ease-in-out, alterno | Rotación de −1.2° a +1.2° |

Con "reducir movimiento" activo, todas las animaciones y transiciones se reducen a un instante y no se repiten.

### 2.9 Vibraciones (haptics)

| Patrón | Vibración (Android) | Cuándo |
|---|---|---|
| select | 10 ms | Pulsar una tecla, un modificador o un botón de clic |
| light | 15 ms | Tocar un tile, un botón multimedia o una app; deslizar con 3 o 4 dedos; activar el bloqueo de arrastre; soltar un tile reordenado |
| medium | 25 ms | Pulsación larga que inicia arrastre o clic derecho; entrar en edición de la botonera; abrir el menú de una app |
| heavy | 38 ms | Reservado |
| error | 28 ms, pausa de 45 ms, 28 ms | Errores |

- En iOS, Safari no expone la vibración; se obtiene un tic del sistema activando un interruptor nativo oculto. El patrón de error se aproxima con dos tics separados por 80 ms.
- Se pueden desactivar en Ajustes › General › Vibraciones.

### 2.10 Componentes base (web)

- **Botón:** alto mínimo 42 px, padding horizontal 16 px, radio 12 px, fondo bg-3 con borde surface-line, 6 px entre icono y texto. Variantes: primario (fondo accent, texto accent-fg, peso 600, sin borde), peligro (texto danger), enlace (sin fondo, texto accent, 36 px), pequeño (34 px, padding 12 px). Pulsado: brillo al 92 %. Deshabilitado: opacidad 50 %.
- **Botón de icono:** 40 × 40 px, radio 12 px, sin fondo, icono fg-2; pulsado con fondo bg-3. Variante de aviso con icono warn.
- **Chip:** 34 px de alto, cápsula, borde surface-line, fondo bg-2, texto fg-2. Activado: fondo accent-soft, texto y borde accent.
- **Control segmentado:** contenedor bg-3, radio 12 px, padding 3 px, 2 px entre opciones; opción de 32 px, peso 500, texto fg-2; la seleccionada lleva fondo bg-2, texto fg y sombra leve.
- **Campo de texto:** fondo bg-3, borde surface-line, radio 10 px, padding 10/12 px, 16 px; al enfocarse, borde accent.
- **Interruptor:** 50 × 30 px, pista surface-line, mando blanco de 24 px con 3 px de margen; encendido, pista ok (verde) y mando desplazado 20 px.
- **Spinner:** anillo de 30 px con trazo de 3 px surface-line y arco superior accent; versión pequeña de 16 px con trazo de 2 px.
- **Tecla:** fondo key, radio 8 px, canto de tecla, alto mínimo 40 px, 15 px; pulsada con fondo key-pressed; no seleccionable ni con menú contextual.

---

## 3. Cliente web

### 3.1 Estructura general

- Aplicación de una sola pantalla, sin zoom de página (gestos de pellizco y doble toque anulados), sin rebote de scroll y sin resaltado de toque. Se puede instalar como app (pantalla completa, orientación libre, fondo #0e1116).
- El alto se ajusta al viewport visible para que el teclado del teléfono no tape los controles.
- Con la opción "Mantener la pantalla encendida" (activa por defecto) se pide un wake lock mientras haya conexión y la página esté visible.
- Al ocultar la página se sueltan todas las teclas, botones y modificadores pulsados, se cancela cualquier gesto y se detiene el dictado.

**Retrato (por defecto)**, de arriba abajo:
1. **Barra de estado** (alto mínimo 44 px más el safe area superior; padding 4 px arriba y abajo, 12 px a la izquierda y 6 px a la derecha; texto 13 px fg-2). Contenido en fila con 6 px de separación:
   - Punto de conexión de 8 px: verde (ok) si está conectado; ámbar con pulso si está reconectando.
   - Nombre de la Mac en fg, peso 600, recortado con puntos suspensivos a un máximo del 45 % del ancho. Al reconectar muestra "Reconectando…".
   - Latencia ("23 ms") en cifras tabulares, solo si está conectado.
   - Candado de 14 px en fg-3: cerrado si la conexión está cifrada, abierto si no; el tooltip lo dice.
   - Espacio flexible.
   - Píldora de modificadores, visible solo si hay alguno activo: borde y texto accent sobre accent-soft, 14 px, interletrado 2 px, muestra los símbolos activos (por ejemplo "⌘⇧"). Si alguno está bloqueado, la píldora se rellena de accent. Al tocarla se sueltan todos y aparece un toast.
   - Escudo de aviso (botón de icono warn), solo si la Mac no tiene permiso de Accesibilidad; al tocarlo, un toast explica qué activar.
   - Engranaje de Ajustes.
2. **Vista activa**, que ocupa el resto del alto.
3. **Barra de pestañas** inferior: fondo bg-2, borde superior surface-line, padding 4 px más el safe area inferior. Cinco pestañas de igual ancho en este orden: Trackpad, Teclas, Botonera, Multimedia, Apps. Cada una tiene un icono de 22 px sobre una etiqueta de 11 px con 2 px entre ambos. Inactiva en fg-3; activa en accent. La pestaña elegida se recuerda.

**Apaisado en teléfono** (orientación horizontal y alto ≤ 500 px): la barra de pestañas se convierte en un riel vertical a la izquierda (borde derecho surface-line, iconos centrados verticalmente, sin etiquetas, padding 8/6 px por pestaña) y la barra de estado se reduce a 34 px de alto sobre la vista.

**Tabletas y pantallas ≥ 700 px de ancho:** las hojas se muestran como diálogo centrado con las cuatro esquinas redondeadas.

### 3.2 Fila de modificadores

Aparece sobre el trackpad, sobre el redactor de "Escribir" y en la hoja de escritura rápida. Es una fila de teclas de 38 px de alto que reparten el ancho: esc, ⇥, ⌃, ⌥, ⇧, ⌘. En el trackpad termina con un botón de teclado de 44 × 38 px con cara de tecla que abre la hoja "Escribir".

Los modificadores son "pegajosos":
- **Toque** (menos de 320 ms sin usarlo): queda *enganchado* y se aplica solo a la siguiente tecla o clic. Visual: fondo accent-soft, texto accent y anillo interior de 1.5 px accent.
- **Doble toque** (el segundo antes de 380 ms): queda *bloqueado* hasta volver a tocarlo. Visual: relleno accent con texto accent-fg.
- **Mantener y usar**: se comporta como una tecla real mientras el dedo esté encima. Visual: fondo key-pressed.
- Un toque sobre un modificador enganchado o bloqueado lo apaga.
- Los bloqueados se restauran tras reconectar.

### 3.3 Trackpad

**Disposición** (columna, 10 px entre bloques):
1. Fila de modificadores.
2. Área principal: la superficie táctil ocupa todo el espacio y, a su derecha (o a la izquierda, según ajuste), un riel de scroll de 46 px de ancho con 8 px de separación.
3. Barra de clic: dos botones de 52 px de alto, radio 16 px, fondo surface y borde surface-line, texto fg-2: "Clic" y "Clic derecho". Pulsados cambian a key-pressed con texto fg. Mandan el botón hacia abajo al tocar y hacia arriba al soltar, de modo que se puede mantener uno y arrastrar con el otro dedo. Se pueden ocultar en ajustes.

**Superficie:** radio 22 px, fondo surface, borde surface-line, con una retícula de puntos de 1 px en color surface-line cada 22 px. Abajo, centrada y a 16 px de los bordes, una pista en 13 px fg-3 del tipo "Mueve con un dedo · toca para clic · dos dedos para desplazar"; se desvanece en 400 ms al primer toque y no vuelve en esa sesión.

**Puntos de toque** (opción "Mostrar toques", activa por defecto): bajo cada dedo, un círculo de 44 px con relleno accent-soft, borde de 2 px accent y opacidad 80 %, que sigue al dedo y desaparece al levantarlo.

**Gestos y umbrales**

| Gesto | Resultado | Umbral |
|---|---|---|
| Mover un dedo | Mueve el puntero, con aceleración | Empieza tras 5 px |
| Tocar con un dedo | Clic | ≤ 260 ms |
| Tocar y volver a tocar cerca, luego arrastrar | Arrastre (doble toque y arrastrar) | Segundo toque a ≤ 40 px y antes de 260 ms |
| Doble toque sin moverse | Doble clic | Igual que el anterior |
| Mantener un dedo quieto | Empieza a arrastrar o hace clic derecho (configurable) | 450 ms; vibración medium |
| Tocar con dos dedos | Clic derecho | ≤ 364 ms |
| Mover dos dedos | Scroll con fases y, al soltar rápido, inercia | Empieza tras 7 px; inercia si la velocidad ≥ 140 px/s |
| Pellizcar | Zoom (⌘+ / ⌘−), un paso por cada 22 % de cambio | Se reconoce si la separación cambia más del 14 % y el centro se mueve menos de 21 px |
| Deslizar 3 o 4 dedos | Acción asignada (arriba, abajo, izquierda, derecha) | 38 px; vibración light |
| Tocar con 3 o 4 dedos | Acción asignada a "toque" | ≤ 390 ms |

- Si un dedo empieza a arrastrar y se activa "Bloqueo de arrastre", al levantarlo el arrastre continúa (vibración light) hasta el siguiente toque.
- Valores predeterminados de 3 dedos: arriba Mission Control, abajo Exposé de la app, izquierda y derecha cambian de escritorio, toque es clic central. De 4 dedos: arriba Launchpad, abajo mostrar escritorio, izquierda y derecha cambian de pestaña, toque sin acción.
- La velocidad para la inercia se calcula con los últimos 90 ms de movimiento y se descarta si el dedo se detuvo más de 55 ms antes de soltar.

**Riel de scroll**
- Pista en cápsula (radio 23 px) con fondo surface y borde surface-line, centrada verticalmente y con un 45 % del alto ("corto") o el alto completo ("largo"); también se puede ocultar.
- Pulgar de 44 px de alto con 7 px de margen lateral, radio 16 px, color fg-3 al 45 %. En reposo está en el centro.
- Al tocar, el pulgar salta bajo el dedo, se pinta de accent al 90 % y lo sigue sin transición; el desplazamiento vertical del dedo se convierte en scroll. Al soltar, vuelve al centro (120 ms) y, si hubo velocidad, aplica inercia.
- "Seguir desplazando al final del riel" (solo en el riel corto): si el dedo sale por encima o por debajo de la pista, el borde de la pista se pinta de accent y el scroll continúa solo a una velocidad de 360 px/s más 14 px/s por cada px fuera de la pista, hasta un máximo de 2400 px/s.

### 3.4 Teclas

Cabecera con un control segmentado de tres opciones que ocupa todo el ancho: **Mac**, **Personalizado** y **Escribir**. En modo automático se elige Mac en tabletas o con ancho ≥ 560 px, y Escribir en teléfonos en vertical; el modo se reevalúa al girar el dispositivo.

Todos los teclados en pantalla son multitáctiles: cada dedo pulsa la tecla que tiene debajo o, si cae en un hueco, la más cercana a menos de 24 px. Cada pulsación vibra con el patrón select. Si "Repetición de teclas" está activa, mantener una tecla la repite con los tiempos de la Mac.

**Teclado Mac**
- Seis filas con 5 px de separación, centradas verticalmente. Cada fila tiene como máximo 64 px de alto; la fila de funciones, 40 px. El texto de las teclas escala con el ancho (2.6 % del ancho de la ventana, entre 11 y 18 px).
- Fila 1: esc (1.5 unidades) y doce teclas de función en 11 px fg-2. Según el ajuste "Fila superior" muestran iconos multimedia de 16 px (brillo −/+, Mission Control, Spotlight, luz de teclado −/+, anterior, reproducir, siguiente, silencio, volumen −/+) o los textos F1 a F12. Mantener fn invierte la elección.
- Fila 2: números con ⌫ de 1.5 unidades. Fila 3: ⇥ de 1.5 y QWERTY. Fila 4: ⇪ de 1.8, letras y ⏎ de 1.7. Fila 5: ⇧ de 2.3 a ambos lados. Fila 6: fn, ⌃, ⌥, ⌘ (1.3), espacio (5 unidades, sin texto), ⌘ (1.3), ⌥, ←, una columna con ↑ y ↓ a media altura (11 px) y →.
- Con distribución ISO cambian la tecla junto al 1, la posición de la barra invertida y el ⇧ izquierdo (1.3 con una tecla extra a su lado).
- Las etiquetas vienen de la distribución activa en la Mac y cambian en vivo: en minúscula sin ⇧, en mayúscula o con el carácter alternativo si ⇧ o ⌥ están activos.
- Los modificadores usan los mismos estados visuales que la fila de modificadores.

**Escribir (redactor)**
- Columna: fila de modificadores, barra de herramientas, área de texto, línea de dictado y fila de teclas.
- Barra de herramientas: chip "En vivo" (activado o no), botones de icono para pegar el portapapeles del teléfono en la Mac, copiar el portapapeles del teléfono al de la Mac, traer el portapapeles de la Mac, borrar el campo y, alineado a la derecha, el micrófono.
- Área de texto: al menos 96 px de alto (120 px dentro de una hoja), radio 14 px, 16 px, con corrección ortográfica y mayúscula automática. El placeholder cambia según el modo: "Lo que escribas llega directo a la Mac…" en vivo, o "Escribe aquí…" si no.
- **En vivo** (por defecto): cada cambio se envía al instante como edición; Enter manda Return; borrar con el campo vacío manda ⌫; si hay un modificador enganchado, una sola letra se convierte en atajo (por ejemplo ⌘ + C). El texto local se vacía solo para no crecer sin límite.
- **Sin "En vivo"**: aparece el botón primario "Enviar" (icono de avión de papel de 18 px) y Enter envía todo el bloque.
- Fila de teclas de 44 px: ←, ↓, ↑, →, ⌫ y ⏎ como teclas con icono de 18 px; "Enviar" ocupa 1.6 veces el ancho de una tecla cuando se muestra.
- Al traer el portapapeles de la Mac se copia al del teléfono; si el navegador no lo permite, se inserta en el campo, con un toast que dice qué pasó en cada caso.

**Teclados personalizados**
- Barra superior: selector desplegable del teclado activo (máximo 60 % del ancho), espacio flexible y botón "Editar" (que pasa a "Listo", primario, en edición).
- Estado vacío, centrado, en fg-2: "Todavía no hay teclados personalizados" y botones "Nuevo teclado", "De plantilla: Presentación", "De plantilla: Mando de juego" y "De plantilla: Edición".
- Cuadrícula de 2 a 12 columnas y de 1 a 8 filas que llena el espacio con 6 px de separación. Cada tecla puede ocupar varias celdas, con texto de 17 px que se ajusta en varias líneas (interlineado 1.15). Una tecla puede ser una tecla con modificadores, un modificador pegajoso, una tecla multimedia o un botón del ratón.
- Opcionalmente, un mini trackpad debajo (al menos 120 px de alto, con los mismos gestos); la cuadrícula recibe entonces 1.2 veces más espacio.
- **Edición:** cada tecla lleva un contorno discontinuo accent de 2 px hacia dentro y tocarla abre su hoja. Debajo aparece una barra con "Añadir tecla", "Editar…" (nombre, columnas, filas, mostrar trackpad, eliminar teclado), "Nuevo teclado" y un selector "De plantilla".
- Hoja de tecla: etiqueta (máximo 12 caracteres), tipo, los campos del tipo (selector de teclas para "Tecla") y posición en cuatro números (columna, fila, ancho y alto). Si se solapa o no cabe, una línea en danger lo dice y no se guarda.
- Límites: 24 teclados, nombre de 32 caracteres. Si no queda celda libre, un toast pide añadir filas o columnas.

### 3.5 Botonera (deck)

**Cabecera:** a la izquierda, chips de página en una fila con scroll horizontal y sin barra visible (32 px, cápsula, borde surface-line, fondo bg-2, texto fg-2); la página activa se invierte (fondo fg, texto bg). A la derecha, un botón de lápiz para editar. En edición, el lápiz se sustituye por un engranaje (ajustes de página) y un botón primario pequeño "Listo", y al final de los chips aparece un "+" para añadir una página.

**Cuadrícula**
- Tiles cuadrados con 10 px de separación y scroll vertical (12 px de margen inferior).
- Columnas = columnas de la página (1 a 8) × (ancho / 366 px, si el ancho es mayor) ÷ "Tamaño de botones" (de 0.7 a 1.6), redondeado y limitado a entre 1 y 12. Así un teléfono en vertical muestra las columnas elegidas y una tableta escala sin que los tiles crezcan demasiado.
- **Tile:** radio 18 px, borde surface-line, fondo bg-2, contenido centrado con 6 px entre icono y etiqueta y 6 px de padding.
  - Icono: un símbolo al 36 % del lado del tile en color accent; un emoji al 50 %; el icono de una app al 55 %. En modo automático se usa el icono de la app si la acción abre una app y, si no, un símbolo según el tipo de acción.
  - Etiqueta: un 13 % del lado del tile, entre 10 y 14 px, máximo 2 líneas centradas, cortando palabras largas si hace falta.
  - Con color: el fondo mezcla un 22 % del color con bg-2, el borde lleva el color al 55 % y el icono se pinta del color.
- **Estados del tile**
  - Pulsado: escala 0.95 en 120 ms.
  - Ejecutando: si la acción tarda más de 250 ms, un brillo accent-soft barre el tile en bucle hasta que termina.
  - Falló: borde y anillo exterior de 2 px en danger durante 600 ms, más un toast con el motivo si la Mac lo envía.
- **Interacción**
  - Tocar ejecuta la acción (vibración light).
  - Mantener 550 ms entra en edición (vibración medium). Mover el dedo más de 8 px cancela la pulsación larga.
  - En edición, todos los tiles se bambolean. Arrastrar un tile más de 8 px lo levanta (encima de los demás, con la sombra elevada y opacidad 90 %) y lo hace seguir al dedo; soltarlo sobre otro tile lo mueve a esa posición (vibración light). Tocar un tile abre su editor. Al final aparece un tile "añadir" con borde discontinuo, sin fondo y un "+" de 28 px en fg-3.
  - En edición, tocar el chip de la página activa abre sus ajustes. Cambiar de pestaña sale de la edición.
- **Estados vacíos** (centrados, fg-2): "La Mac todavía no envió la botonera" (con botón "Añadir página" si hay conexión) y "Esta página está vacía. Mantén pulsado o toca Editar para añadir botones".
- Límites: 24 páginas, 64 tiles por página, 80 caracteres por etiqueta. Al superarlos aparece un toast de aviso.
- Si no hay conexión al editar, el cambio se revierte con un toast de aviso; si la Mac lo rechaza, también.

**Ajustes de página** (hoja): nombre, columnas (1 a 8), "Mover a la izquierda" y "Mover a la derecha", y abajo "Eliminar página" (peligro, con confirmación; no se puede borrar la última) y "Guardar" (primario).

**Editor de botón** (hoja ancha), de arriba abajo:
1. Etiqueta.
2. Editor de acción (ver abajo).
3. Icono: Automático, Símbolo, Emoji o Icono de app.
   - Símbolo: cuadrícula de celdas de al menos 44 px, cuadradas, con 6 px de separación y como máximo 220 px de alto (con scroll); cada celda tiene radio 10 px, borde surface-line e icono de 22 px; la elegida tiene borde accent, fondo accent-soft e icono accent.
   - Emoji: campo que se queda con el último carácter tecleado.
   - Icono de app: identificador de la app.
4. Color: muestras circulares de 34 px con 8 px de separación. La primera es "sin color", con una diagonal roja sobre bg-3. La elegida lleva un borde de 2 px en fg con un anillo interior del color de fondo.
5. Acciones alineadas a la derecha: "Eliminar" (peligro), "Duplicar" (inserta la copia justo después) y "Guardar" (primario). Al crear un botón solo aparece "Guardar".

**Editor de acción** (también se usa para los gestos de 3 y 4 dedos):
- Un selector "Tipo" con: Atajo de teclado, Sistema, Tecla multimedia, App, Escribir texto, Abrir enlace, App Atajos, Clic del ratón, Secuencia, Esperar y Comando de shell. Los tipos avanzados solo aparecen con "Mostrar acciones avanzadas", y el de shell solo si la Mac lo permite. Para gestos hay además "Nada".
- Campos por tipo: el selector de teclas; listas para acciones del sistema y teclas multimedia; para App, un botón "Elegir una app", el identificador y "Al tocar" (Mostrar u ocultar, Abrir, Ocultar, Salir); un área de texto con "Pulsar Return al final"; un campo URL; el nombre del atajo; un área monoespaciada para shell; botón y número de clics (1 a 3); un control deslizante de espera (de 50 a 5000 ms en pasos de 50).
- **Secuencia:** lista numerada de pasos con una línea de 2 px surface-line a la izquierda. Cada paso muestra un resumen en 14 px y peso 500, botones de subir, bajar y eliminar, y debajo su propio editor de acción. "Añadir paso" agrega una espera de 250 ms. Admite tres niveles de anidación y 64 pasos.
- Los errores de validación aparecen bajo los campos en danger, 13 px, y la línea desaparece cuando no hay error.
- **Selector de apps** (hoja): búsqueda arriba y lista de filas con icono de 32 px, nombre y un punto verde de 7 px a la derecha si la app está abierta; primero las abiertas y luego por nombre. Mientras carga muestra "Cargando apps…".

**Selector de teclas**
- "Tecla (escribe un carácter)": campo de 64 px de ancho, centrado y de 20 px, seguido de un desplegable "o una tecla especial" (flechas, F1–F20, Inicio, etc.). Escribir un carácter lo resuelve con la distribución de la Mac y añade ⇧ si lo necesita; si no existe, aparece en danger "Ese carácter no tiene tecla en esta distribución".
- "Modificadores": chips conmutables ⌃ ⌥ ⇧ ⌘ fn.
- Vista previa: una tecla dibujada (cara de tecla, canto, radio 10 px, 20 px, al menos 56 px de ancho) con la combinación resultante, por ejemplo "⌘⇧4".

### 3.6 Apps

- Cabecera en columna: segmentado "Abiertas" / "Todas" y debajo una búsqueda. Si hay texto, la búsqueda filtra entre todas las apps sin importar el segmento.
- Cuadrícula de columnas automáticas de al menos 84 px con 10 px de separación y scroll. Cada app: icono de 48 px, nombre de 12 px en máximo 2 líneas, padding 10/4 px, radio 16 px y sin fondo.
  - App al frente: borde accent y fondo accent-soft.
  - App abierta: punto de 5 px en fg-2 justo debajo del icono.
  - App oculta: icono al 55 % y etiqueta "OCULTA" en 10 px, mayúsculas, fg-3.
  - Pulsada: fondo bg-3.
- Tocar muestra u oculta la app (vibración light). Mantener 500 ms abre su hoja (vibración medium): cabecera con icono de 56 px, nombre en negrita e identificador monoespaciado pequeño; botones apilados "Traer al frente" (o "Abrir"), "Ocultar", "Salir" (peligro) y "Añadir a la botonera" (con un toast de confirmación).
- Estados: "Cargando apps…" y "No hay apps que mostrar", ambos centrados y en fg-2. La lista se pide a la Mac cada vez que se entra en la pestaña.

### 3.7 Multimedia y volumen

Vista con scroll vertical, 14 px entre bloques y 6 px de margen superior.
1. **Transporte**, centrado con 10 px de separación y 16 px de margen arriba: anterior, retroceder, reproducir/pausa, avanzar y siguiente. Los botones son círculos de 56 px con borde surface-line, fondo bg-2 e icono de 24 px. El central mide 84 px, con fondo accent, icono accent-fg de 34 px y sin borde. Pulsados: brillo al 85 % y escala 0.96. Retroceder y avanzar actúan mientras se mantienen.
2. **Tarjeta de volumen** (bg-2, borde, radio 14 px, padding 12 px, 12 px entre filas):
   - Fila "Volumen" con los botones bajar y subir. Mantenerlos repite: primera repetición a 420 ms y luego cada 110 ms.
   - Fila de control: botón de silencio (altavoz con onda o tachado; en rojo si está silenciado), control deslizante de 32 px de alto y color accent, y el porcentaje en un hueco de 44 px alineado a la derecha y en cifras tabulares. Silenciado, el deslizante baja al 45 %. Al arrastrarlo se envía el valor como mucho cada 60 ms y siempre al soltar; mientras se arrastra no lo pisan las actualizaciones de la Mac.
   - Si la Mac no informa el volumen, desaparece la fila de control, aparece una tecla de silencio junto a bajar y subir, y una nota pequeña en fg-2 lo explica.
3. **Tarjeta de brillo**: fila "Pantalla" con bajar y subir brillo, y fila "Luz del teclado" con bajar, alternar (al 80 % de opacidad) y subir. Todos repiten al mantenerse.

### 3.8 Dictado

- Vive en el botón de micrófono del redactor. Solo se muestra si la Mac ofrece dictado y la conexión es cifrada (https).
- Reposo: icono de micrófono de 20 px en fg-2.
- Grabando: el botón se rellena de danger con icono blanco de micrófono tachado y late (900 ms). Debajo, una barra de nivel de 3 px en danger que crece de izquierda a derecha según el volumen captado.
- Bajo el área de texto, una línea en cursiva fg-2 muestra el texto parcial que se va reconociendo; el texto definitivo se añade al campo (con un espacio si hace falta) y, en vivo, llega a la Mac.
- Errores en la misma línea, en danger y sin cursiva: sin conexión, dictado no disponible en la Mac, se necesita https, el navegador no graba audio, se denegó el micrófono, el dictado se detuvo.
- Tocar de nuevo detiene. Cambiar de app o perder la conexión también.

### 3.9 Conexión y emparejamiento

**Pantalla de conexión:** ocupa toda la ventana con 20 px de margen más los safe areas y una tarjeta centrada de hasta 400 px de ancho, con 14 px de separación y texto centrado.
- Sello de marca: 64 px, radio 18 px, degradado de marca y puntero blanco de 28 px.
- Título de 24 px: "Controla tu Mac desde este teléfono" o, si se conoce el nombre, "Emparejar con {nombre}".
- Pista en fg-2: escanear el QR del menú de Remoto o escribir el PIN de 6 dígitos.
- Línea de progreso: spinner pequeño y "Emparejando…" o "Conectando…".
- Caja de mensaje (padding 10/12 px, radio 12 px, fondo bg-3). En error, fondo danger al 14 % sobre bg-2 y texto danger.
- Acciones centradas: "Reconectar" (primario, si hay un token guardado y la sesión terminó sin error) o "Recargar" (primario, si las versiones no coinciden).
- Formulario del PIN, alineado a la izquierda: etiqueta "PIN de la Mac" (13 px, 600, fg-2), campo numérico de 30 px centrado con interletrado de 0.4 em, cifras tabulares, padding 14 px y seis puntos como placeholder. Al llegar a 6 dígitos se envía solo. Debajo, el interruptor "Recordar este dispositivo" y el enlace "Pedir permiso a la Mac".
- Si se llega con el enlace del QR, el emparejamiento empieza solo y el código se borra de la URL.

**Esperando aprobación:** spinner de 30 px, título de 19 px "Esperando a la Mac", texto "Acepta este {modelo} en {nombre} para terminar" y botón "Cancelar". El formulario y la pista se ocultan.

**Errores** (siempre con la causa y el siguiente paso): PIN incorrecto (el campo se vacía), enlace caducado, PIN desactivado en la Mac, solicitud rechazada, PIN no visible (hay que abrir el menú de la Mac), demasiados intentos (con cuenta atrás de segundos que se actualiza cada segundo), solicitud ya en curso, versiones distintas, dispositivo olvidado, rechazo genérico, y la Mac no responde.

**Pantalla de arranque** (cuando hay un token guardado): fondo bg, spinner y "Conectando con {nombre}…". A los 6 s aparece debajo (con un máximo de 320 px de ancho) un texto que pide revisar que la app esté abierta y en la misma red, y el botón "Emparejar de nuevo".

**Reconexión dentro de la app:** no se sale de la interfaz; el punto se vuelve ámbar con pulso y el nombre cambia a "Reconectando…".

**En pausa:** si la Mac pausa el control, un overlay cubre la interfaz con el velo, un desenfoque de 6 px y una tarjeta centrada (bg-2, radio 20 px, padding 24 px, hasta 340 px de ancho, sombra elevada) con un icono de pausa de 32 px, el título "En pausa en la Mac" (19 px) y una explicación en fg-2.

### 3.10 Hojas, ajustes, toasts y avisos

**Hojas**
- Velo a pantalla completa; la hoja sube desde abajo con todo el ancho hasta un máximo de 560 px (680 px en la variante ancha), radio de 20 px arriba, fondo bg-2 y sombra elevada. Su alto máximo es el de la ventana menos el safe area superior y 24 px.
- Cabecera: título de 17 px en negrita a la izquierda (padding 10/8/4/18 px) y botón X para cerrar a la derecha.
- Cuerpo con scroll propio (sin arrastrar el fondo), padding 16 px, 12 px entre bloques y el safe area inferior más 18 px abajo.
- Se cierra con la X o tocando el velo. Acciones al pie alineadas a la derecha, con el primario al final.
- Las confirmaciones destructivas (olvidar la Mac, eliminar página, restablecer) usan hoy el diálogo nativo del navegador (ver sugerencias).

**Filas de ajustes:** grupos con cabecera en mayúsculas y un cuerpo con fondo bg (un tono más hundido que la hoja), radio 14 px y padding 2/12 px. Filas de al menos 46 px separadas por líneas de 1 px; la última no lleva línea. Hay filas de interruptor, de desplegable (a la derecha, hasta el 55 % del ancho), de deslizante (etiqueta y valor arriba, control a todo el ancho debajo), de texto (etiqueta arriba, campo debajo) y de enlace (valor en fg-2 y chevron de 16 px).

**Hoja de Ajustes** (ancha), por secciones:
1. **Conexión:** la Mac (nombre · cifrado o no · latencia); nombre del dispositivo (40 caracteres como máximo, con el modelo como placeholder); "Recordar este dispositivo"; enlace para instalar el certificado (solo sin cifrar y si la Mac lo ofrece); botones apilados "Soltar todas las teclas y botones", "Copiar ajustes de otro dispositivo", "Desconectar" y "Olvidar esta Mac" (peligro).
2. **Trackpad:** velocidad del puntero (0.2 a 4, por defecto 1.2), aceleración (0 a 1, por defecto 0.6), tocar para clic, toque con dos dedos para clic derecho, doble toque y arrastrar, bloqueo de arrastre, pulsación larga (Arrastrar, Clic derecho, Nada), botones de clic, velocidad de scroll (0.2 a 4), scroll natural, inercia, riel de scroll (Corto, Largo, Nada), lado del riel, seguir desplazando al final, pellizcar para zoom y mostrar toques. Los deslizantes muestran su valor con dos decimales.
3. **Gestos con varios dedos:** subtítulos "Tres dedos" y "Cuatro dedos", cada uno con cinco filas (deslizar arriba, abajo, izquierda, derecha y tocar) que muestran la acción actual y abren una hoja con el editor de acción y "Guardar".
4. **Teclado:** modo (Automático, Teclado Mac, Personalizado, Escritura del teléfono), fila superior (Teclas multimedia o F1–F12), repetición de teclas, escritura en vivo y "Enviar texto como" (Unicode, Pulsaciones, Pegar).
5. **Botonera:** tamaño de los botones y "Mostrar acciones avanzadas".
6. **General:** tema, idioma (cambiarlo recarga la página), vibraciones, mantener la pantalla encendida, "Restablecer ajustes" (peligro, con confirmación; conserva el nombre del dispositivo, la pestaña y la página de la botonera) y, al pie, la versión del cliente y la de la Mac en 13 px, fg-2, centradas.

**Copiar ajustes:** hoja con una lista de dispositivos (icono de teléfono, tableta o pantalla de 24 px, nombre en negrita, modelo y "actualizado hace 5 min"). Estados: "Preguntando a la Mac…", error con "Reintentar" y "Ningún otro dispositivo tiene ajustes guardados".

**Toasts**
- Pila centrada arriba, justo debajo de la barra de estado (safe area superior más 48 px), con 6 px de separación y 16 px de margen lateral. Como máximo hay tres; si llega un cuarto, se descarta el más antiguo.
- Cada toast: hasta 480 px de ancho, padding 10/14 px, radio 12 px, 14 px, sombra elevada y la animación de subir. Los informativos invierten los colores (fondo fg, texto bg); los de aviso usan fondo warn y texto oscuro; los de error, fondo danger y texto blanco.
- Duran 4.5 s (7 s los de error) y se cierran al tocarlos. Un toast con la misma clave sustituye al anterior para no apilar repeticiones (por ejemplo, "sin conexión").
- Los avisos que envía la Mac se muestran también como toasts.

---

## 4. App de Mac

La app vive solo en la barra de menú (sin icono en el Dock). Mientras hay una ventana propia abierta (ajustes, emparejamiento, bienvenida o aprobación) pasa temporalmente a app normal para poder recibir el foco, y vuelve a ser accesoria al cerrarlas todas.

### 4.1 Ícono de la barra de menú

Símbolo de plantilla, monocromo, que cambia según el estado (por orden de prioridad):

| Estado | Símbolo (SF Symbols) |
|---|---|
| Un teléfono pide permiso | mano levantada, relleno |
| Control en pausa | rectángulo con pausa |
| Al menos un teléfono conectado | mano señalando, relleno |
| En espera | mano señalando, contorno |

La etiqueta de accesibilidad es "Remoto". Sugerencia: diseñar un símbolo propio para Remoto (ver 6.2).

### 4.2 Panel del menú

Ventana desplegable (estilo ventana, no menú) de 320 pt de ancho, 14 pt de padding y 12 pt entre secciones, alineada a la izquierda. Al abrirse refresca el estado y, si no hay ningún teléfono recordado, abre de entrada la sección de emparejamiento.

Orden de las secciones:
1. **Cabecera:** punto de estado de 8 pt, "Remoto" en estilo headline y, debajo, un resumen en caption secundario (dos líneas como máximo):
   - Arrancando… (naranja) · Detenido (gris) · No se pudo iniciar: motivo (rojo)
   - Un teléfono quiere conectarse (naranja) · En pausa: los teléfonos no controlan esta Mac (amarillo) · Esperando el permiso de Accesibilidad (naranja)
   - Conectado a {nombre} o "3 teléfonos conectados" (verde) · Listo en el puerto 8740 (verde)
2. **Solicitudes de aprobación**, una fila por solicitud (ver 4.7).
3. **Aviso de Accesibilidad**, si falta el permiso: callout naranja con escudo, una frase de explicación y el botón pequeño "Abrir ajustes de privacidad".
4. **Aviso de compilación sin cliente web** (solo en builds de desarrollo): callout amarillo con triángulo.
5. **Aviso de la Mac** (por ejemplo, un puerto ocupado): callout azul con "i" y el botón "Descartar".
6. **Conectados:** cabecera en caption semibold secundario y, por dispositivo, icono de iPhone, nombre en una línea y un candado secundario a la derecha si la conexión está cifrada (con tooltip "Cifrado"). Texto en estilo callout.
7. **Emparejar:** grupo desplegable titulado "Empareja tu teléfono" (o "Emparejar otro teléfono" si ya hay alguno) que contiene la tarjeta de emparejamiento compacta. Solo aparece si el servidor está activo.
8. Separador.
9. Interruptor pequeño "Permitir que los teléfonos controlen esta Mac" (deshabilitado si el servidor no está activo).
10. **Pie** con controles pequeños: "Ajustes…", "Reintentar" (solo si falló el arranque), espacio flexible y "Salir".

**Callout:** fila con un icono de color a la izquierda, texto callout que se ajusta en varias líneas y, debajo, las acciones en tamaño pequeño; padding 10 pt, fondo del color al 12 % y radio 8 pt.

### 4.3 Tarjeta de emparejamiento

Tiene dos tamaños: compacta (en el menú) y grande (en la ventana "Emparejar un teléfono", con 24 pt de padding, y en el último paso de la bienvenida). Mientras está visible, la Mac acepta el PIN; al cerrarse, deja de aceptarlo.

- **Solo en la grande:** título en title3 semibold "Escanéalo con la cámara del teléfono" y una nota secundaria sobre estar en la misma red. Todo centrado.
- **QR:** 240 pt (grande) o 170 pt (compacta), centrado, sobre una placa blanca con 10 pt de padding y radio 12 pt (blanca también en modo oscuro). Se escala sin suavizado para que los módulos queden nítidos y usa corrección de errores media. Si no se puede generar, muestra un símbolo de QR genérico. Su etiqueta de accesibilidad es "Código QR de emparejamiento".
- **PIN** (si está permitido): etiqueta "PIN" en caption semibold secundario, seguida de los seis dígitos en dos grupos de tres ("482 913"), monoespaciados y semibold (30 o 22 pt) y seleccionables.
- **Cuenta atrás:** "El código cambia en 4:37" en caption secundario con cifras monoespaciadas, actualizada cada segundo; al llegar a cero dice "Actualizando…" y se renueva sola. Al lado, el botón pequeño "Código nuevo".
- **Direcciones:** "O abre esta dirección en el teléfono:" en caption secundario y luego filas en callout monoespaciado, de una línea con corte en el centro, seleccionables y con un botón sin borde de copiar. En la grande (o si el enlace no usa la IP) se listan también las direcciones por IP. Las direcciones de VPN aparecen en caption2 como "Por VPN: …".
- Estados: "Cargando…" mientras no hay datos y "El servidor no está activo" si está detenido.

### 4.4 Ventana de ajustes

Ventana titulada "Ajustes de Remoto" de 560 × 520 pt con pestañas de icono y texto. Todos los paneles son formularios agrupados.

| Pestaña | Símbolo | Contenido |
|---|---|---|
| General | engranaje | **Control:** interruptor para permitir el control y fila de permiso de Accesibilidad. **Dictado:** interruptor para permitir el dictado desde teléfonos y fila de permiso de Reconocimiento de voz (explica que la transcripción ocurre en la Mac y que hace falta https). **Inicio:** "Abrir al iniciar sesión" (si macOS pide aprobarlo, una nota caption lo indica; los errores salen en rojo) y el botón "Mostrar la bienvenida otra vez". |
| Conexión | wifi | **Servidor:** campo de puerto de 90 pt con "Aplicar" (deshabilitado si no cambió o no es válido) y "Escuchando en 8740" a la derecha. Un error en rojo si el puerto está fuera de 1024–65535 y una nota si el preferido estaba ocupado. **Enlace de emparejamiento:** selector "Dirección del QR" (nombre .local, IP o personalizada; esta última muestra un campo), "Aceptar un PIN de 6 dígitos" y "Preguntar en esta Mac cuando un teléfono se conecte sin código". **Conexión cifrada:** explicación, QR de 110 pt para descargar el certificado junto a tres pasos numerados en caption (iPhone y Android), huella SHA-256 en caption2 monoespaciada y seleccionable, y "Exportar certificado…". |
| Dispositivos | iPhone | Ver 4.5. |
| Botonera | cuadrícula 3×2 | **Botonera:** explicación (se edita en el teléfono; aquí se respalda), "Exportar…", "Importar…" y, a la derecha, "Restablecer…" destructivo con diálogo de confirmación; una línea de resultado ("Guardado", "Importado" o el error). **Comandos de shell:** interruptor que, al encenderse, pide confirmación con un diálogo destructivo, y una advertencia en naranja (caption). |
| Avanzado | llave y destornillador | **Carpetas de apps:** nota, lista de carpetas (icono de carpeta, ruta con corte en el centro y botón para quitarla) y "Añadir carpeta…". **Red:** "Aceptar conexiones reenviadas por un proxy local" y "Reiniciar servidor". **Diagnóstico:** nivel de registro (Errores, Avisos, Info, Depuración), una nota de que se aplica al reiniciar y nunca incluye texto tecleado, y "Mostrar carpeta de datos". |
| Acerca de | "i" en círculo | Centrado: símbolo de 48 pt en el tinte, el nombre en title semibold, la versión y la compilación en callout secundario y una frase descriptiva centrada de hasta 380 pt. |

**Fila de permiso:** icono de check verde relleno (concedido) o de exclamación naranja (falta); título y, debajo, un detalle en caption secundario; a la derecha, solo si falta, botones pequeños como "Solicitar…" y "Abrir Ajustes".

### 4.5 Lista de dispositivos

Formulario agrupado con dos secciones:
- **Conectados ahora:** "Ningún teléfono conectado" (secundario) si no hay ninguno. Si los hay, cada fila tiene un icono (iPhone con candado si la conexión está cifrada), el nombre y, debajo, "modelo · IP · cifrado o sin cifrar" en caption secundario, más el botón pequeño "Desconectar".
- **Teléfonos recordados:** si está vacía, un texto que explica que los teléfonos emparejados se recuerdan para reconectar sin código. Cada fila tiene un icono, el nombre y, debajo, "modelo · visto hace 2 horas · última IP", con los botones pequeños "Renombrar" (que convierte la fila en un campo con "Guardar"; Return también guarda) y "Olvidar" (destructivo). Al final, "Olvidar todos…" destructivo con un diálogo que avisa que se desconectarán y se borrarán sus ajustes guardados.

### 4.6 Bienvenida

Se abre en el primer arranque (y desde Ajustes). Ventana "Te damos la bienvenida a Remoto" de 520 pt de ancho y 460 pt de alto (640 pt en el último paso). El contenido tiene 28 pt de padding y está alineado arriba; un separador lo divide del pie, que tiene 16 pt de padding, "Atrás" a la izquierda (desde el paso 2) y "Continuar" o "Listo" a la derecha como botón predeterminado (Return).

1. **Presentación:** título en title2 semibold ("Tu teléfono, como control remoto de esta Mac"), una frase secundaria (vive en la barra de menú y no hay que instalar nada en el teléfono) y cuatro filas de función, cada una con un icono en title3 en el tinte, en una columna de 28 pt, título en headline y detalle secundario: trackpad y teclado, botonera, multimedia y apps, dictado.
2. **Accesibilidad:** título, explicación de para qué se usa el permiso y una nota secundaria de que se puede hacer después. Una caja (fondo terciario al 50 %, radio 10 pt, padding 12 pt) con el estado: círculo discontinuo y "Todavía no está permitido", o check verde y "Accesibilidad activada". A la derecha, "Abrir ajustes de Accesibilidad", que lanza el aviso del sistema y abre el panel. El estado se actualiza solo.
3. **Conectar:** título "Conecta tu teléfono" y la tarjeta de emparejamiento grande. "Listo" marca la bienvenida como vista y cierra la ventana.

### 4.7 Panel de aprobación

Cuando un teléfono pide entrar sin código, la Mac suena y abre un panel flotante, titulado "Solicitud de emparejamiento", que queda por encima de las demás ventanas, aparece en todos los escritorios y también sobre apps a pantalla completa. Mide 380 pt de ancho y tiene 18 pt de padding:
- Título en headline: "Un teléfono quiere controlar esta Mac".
- Advertencia en callout secundario: permitirlo solo si es tuyo; podrá mover el puntero, escribir y usar la botonera.
- Una fila por solicitud: icono de iPhone con ondas en title2 naranja, el nombre en callout semibold ("Dispositivo desconocido" si no lo envía) y "modelo · IP" en caption secundario; a la derecha, los botones pequeños "Rechazar" y "Permitir" (este es el predeterminado, con Return). Fondo naranja al 12 % y radio 8 pt.
- Se cierra solo cuando no quedan solicitudes. Las mismas filas aparecen en el panel del menú.

### 4.8 Avisos de permisos

- **Accesibilidad:** sin este permiso no se puede controlar la Mac. Aparece en cuatro lugares que deben verse coherentes: el resumen del menú ("Esperando el permiso de Accesibilidad", en naranja), el callout del menú con su botón, la fila de permiso en Ajustes › General y el paso 2 de la bienvenida. En el teléfono aparece el escudo de aviso en la barra de estado.
- **Reconocimiento de voz:** fila en Ajustes › General › Dictado. Si se denegó, el botón abre los Ajustes del Sistema; si no, "Permitir…" lanza el aviso del sistema.
- **Inicio de sesión:** nota caption si macOS espera la aprobación en Ajustes del Sistema › General › Ítems de inicio.
- Todos los botones abren directamente el panel correspondiente de Privacidad y seguridad.

---

## 5. Accesibilidad

- **Etiquetas:** todo botón de solo icono lleva una etiqueta accesible y un tooltip con el mismo texto (ajustes, cerrar, portapapeles, micrófono, botones multimedia, símbolos del selector). El micrófono cambia su etiqueta a "Detener dictado" mientras graba; el silencio alterna entre "Silenciar" y "Activar sonido". Las pestañas y los segmentados usan roles de pestaña con estado seleccionado; los chips conmutables, estado pulsado; los interruptores, rol de interruptor. Las hojas son diálogos modales con su título como nombre. En la Mac, el ícono de la barra de menú se anuncia como "Remoto" y el QR tiene su etiqueta.
- **Regiones vivas:** los toasts informativos se anuncian de forma educada y los de error como alerta; la caja de mensajes de conexión y el texto parcial del dictado también son regiones vivas.
- **Contraste:** el texto principal (fg sobre bg) supera 15:1 en ambos temas, y el secundario (fg-2) supera 4.5:1. El terciario fg-3 queda por debajo de 4.5:1 en claro (unos 2.8:1 sobre bg; en oscuro, unos 4.1:1) y se usa en etiquetas pequeñas: ver sugerencias.
- **Tamaños táctiles:** la mayoría de los controles principales miden 44 px o más (teclas del redactor, botones de clic, multimedia, tiles, puntos de toque). Algunos quedan por debajo (botón de icono de 40 px, chips de 34, segmentado de 32, chips de página de 32, muestras de color de 34, fila de modificadores de 38): ver sugerencias.
- **Reducir movimiento:** se respeta la preferencia del sistema y se anulan todas las animaciones (bamboleo, barrido, pulsos, entradas de hojas). Los estados siguen siendo distinguibles por color y borde.
- **Teclado físico:** con un teclado conectado al teléfono, las pulsaciones se reenvían a la Mac salvo que haya un campo enfocado o una hoja abierta.
- **Mac:** controles estándar de SwiftUI, de modo que funcionan VoiceOver, el acceso completo por teclado y el texto dinámico de macOS sin trabajo extra; los botones predeterminados responden a Return.

---

## 6. Lo que conviene mejorar (sugerencias)

### 6.1 Cliente web

1. **Sugerencia: confirmaciones propias.** Sustituir el diálogo nativo del navegador por una hoja de confirmación de Remoto, con título, una frase de consecuencia y los botones "Cancelar" y la acción destructiva en danger.
2. **Sugerencia: contraste de fg-3.** Llevar fg-3 a #646b7a en claro (4.8:1 sobre #f2f4f7) y a #7f8898 en oscuro (5.3:1 sobre #0e1116 y 4.8:1 sobre #171b22), o reservarlo para elementos no textuales. Afecta a las etiquetas de pestañas inactivas (11 px), las pistas y las cabeceras de grupo.
3. **Sugerencia: objetivos táctiles de 44 px.** Llevar a 44 px de área táctil (aunque el dibujo sea menor) los botones de icono, los chips, el segmentado, los chips de página, las muestras de color y la fila de modificadores.
4. **Sugerencia: pestañas apaisadas sin nombre.** En el riel lateral se ocultan las etiquetas visualmente y con ello se pierde su nombre accesible. Hay que conservar la etiqueta para lectores de pantalla.
5. **Sugerencia: foco visible.** Hoy los botones no tienen indicador de foco. Añadir un anillo de 2 px en accent con 2 px de separación para quien navega con teclado físico.
6. **Sugerencia: un solo lenguaje de "pulsado".** Hoy conviven el cambio a key-pressed, el brillo al 92 % y al 85 % y la escala a 0.95 y 0.96. Basta con dos: color para teclas y escala de 0.96 para todo lo demás.
7. **Sugerencia: edición sin bamboleo.** Con "reducir movimiento" no se nota que la botonera está en edición. Añadir un contorno discontinuo y una pequeña asa de arrastre en cada tile, como en los teclados personalizados.
8. **Sugerencia: posición de teclas personalizadas.** Los cuatro campos numéricos son incómodos. Mejor colocar y redimensionar la tecla arrastrándola en la cuadrícula, y dejar los números como opción avanzada.
9. **Sugerencia: icono de app por identificador.** En el editor de botón, usar el mismo selector de apps en lugar de pedir que se escriba el identificador.
10. **Sugerencia: reproducción con estado.** El botón central usa un icono genérico. Mostrar reproducir o pausa según el estado real y, si la Mac lo ofrece, una tarjeta con lo que está sonando.
11. **Sugerencia: la pausa no debe atrapar.** El overlay de pausa tapa también los ajustes. Hay que dejar accesible al menos "Desconectar".
12. **Sugerencia: cambio de idioma sin recarga**, o avisar antes de recargar.
13. **Sugerencia: primario coherente.** En oscuro el texto sobre el acento es oscuro y en claro, blanco. Usar texto blanco en ambos temas sobre un relleno #3d6fe0 (4.6:1), y reservar #5b8cff para iconos y textos de acento en oscuro. El #3b74e6 actual con blanco da 4.35:1, justo por debajo del mínimo para texto de 15 px.
14. **Sugerencia: aviso de permiso persistente.** El escudo de la barra de estado solo lanza un toast. Mejor una banda fija bajo la barra de estado mientras falte el permiso.

### 6.2 App de Mac (HIG de macOS 26 y SwiftUI estándar)

1. **Sugerencia: escena de ajustes estándar.** Usar la escena de ajustes de SwiftUI (abierta con su enlace estándar y con ⌘, cuando la app está activa) en lugar de una ventana propia de tamaño fijo, y dejar que cada pestaña ajuste su alto al contenido con la animación del sistema.
2. **Sugerencia: Liquid Glass.** En macOS 26 la ventana del menú ya recibe el material de vidrio del sistema. Evitar fondos de color propios en los callouts y usar en su lugar controles agrupados estándar o el estilo de vidrio del sistema, con el color reservado para el símbolo.
3. **Sugerencia: símbolo propio.** Diseñar un símbolo de plantilla para Remoto (teléfono con un punto o una onda) con variantes por estado, en lugar de manos genéricas. Señalar las solicitudes pendientes con una variante con insignia, no con otro dibujo.
4. **Sugerencia: notificación en vez de pitido.** Para las solicitudes de aprobación, usar una notificación del sistema con las acciones "Permitir" y "Rechazar", y abrir el panel flotante solo si el usuario interactúa o si las notificaciones están desactivadas. El pitido actual sorprende y no se puede silenciar.
5. **Sugerencia: color de pausa.** El amarillo sobre vidrio claro apenas se lee. Usar gris con el símbolo de pausa, o naranja.
6. **Sugerencia: bienvenida sin saltos.** El cambio de 460 a 640 pt al llegar al paso 3 es brusco. Fijar un alto común o animar el cambio; añadir un indicador de pasos (tres puntos o "Paso 2 de 3").
7. **Sugerencia: localización.** Los textos de la Mac están fijos en inglés. Usar un catálogo de cadenas con inglés y español como en el cliente web.
8. **Sugerencia: campo de puerto.** Usar un campo numérico con formato y validación en vivo, o un campo con flechas, en lugar de texto libre con "Aplicar".
9. **Sugerencia: tamaño de controles.** El pie del menú y los botones de las filas usan tamaño pequeño. La HIG de macOS 26 prefiere el tamaño normal en ventanas de la barra de menú y deja el pequeño solo para inspectores densos.
10. **Sugerencia: Acerca de.** Moverlo al panel estándar de "Acerca de" del sistema (con créditos y licencia MIT) y quitarlo de las pestañas de ajustes, o añadir ahí un enlace al repositorio y a la licencia.
11. **Sugerencia: etiquetas en los botones de icono.** Dar etiqueta accesible a los botones de copiar dirección y de quitar carpeta, no solo un tooltip.
12. **Sugerencia: atajos.** Añadir ⌘Q para Salir y ⌘, para Ajustes dentro de la ventana del menú, y Esc para cerrar el panel de aprobación (equivale a no decidir todavía).
