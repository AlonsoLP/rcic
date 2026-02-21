# RCIC (RC Info Center) - Telemetry Dashboard para EdgeTX

![RCIC Telemetry](https://via.placeholder.com/800x400?text=RCIC+Telemetry+Dashboard) *(Opcional: añadir una captura real de la pantalla)*

**RC Info Center (RCIC)** es un *script* de telemetría ligero, rápido y altamente optimizado diseñado para emisoras de radio con **EdgeTX 2.9 o superior** (y OpenTX compatible). Proporciona un panel multifuncional dividido en pestañas, alertas de batería configurables en tiempo real, validación de coordenadas GPS y generación rápida de "Plus Codes" para localización.

---

## 🚀 Características Principales

- **Interfaz de 3 Pestañas (BAT, GPS, TOT):** Navegación rápida y fluida entre información de la Batería, Datos de Navegación GPS y Estadísticas Totales del Vuelo.
- **Multilenguaje Automático:** Detecta de forma inteligente el idioma de la emisora (Soporte para Español, Inglés, Francés, Alemán, Italiano, Portugués, Ruso, Polaco, Checo y Japonés).
- **Menú de Configuración Integrado:** Permite ajustar los parámetros de telemetría directamente desde la emisora sin tener que editar el código fuente mediante un panel visual (Overlay).
- **Generación de "Plus Codes":** Convierte tus coordenadas GPS en un [Plus Code](https://maps.google.com/pluscodes/) corto, facilitando compartir ubicaciones exactas si necesitas recuperar tu aeronave (incluso sin un mapa visible en la radio).
- **Rendimiento Optimizado:** Uso mínimo de CPU y memoria (Garbage Collection reducido mediante preasignación de variables y strings, además del cálculo de distancias matemáticas eficientes), asegurando que tu radio siempre responda instantáneamente y sin "lag".
- **Alertas Inteligentes de Batería:** Notificadores visuales parpadeantes y alertas de voz configurables (con audios del voltaje numérico exacto) para prevenir agotar la batería más allá de su zona segura. Dispone de perfiles LiPo, LiHV y LiIon.

---

## 📺 Pantallas y Funciones

La información vital se divide en visualizaciones lógicas. Para desplazarse se utiliza la **Rueda (Rotary)** o los botones **[+] / [-]** del hardware.

### 🔋 1. Pestaña BAT (Batería)
Es la pantalla principal focalizada en el monitoreo del sistema de propulsión.
- **Voltaje Total (RxBt):** Lectura nítida y en fuente gigante (DBLSIZE) del voltaje total que devuelve el receptor o sensor del modelo.
- **Voltaje por Celda (VCELL) / Celdas (CELLS):** Contabiliza de manera autónoma de cuántas celdas es la batería conectada de tu dron / avión y calcula su voltaje unitario.
- **Selector del Química de Batería:** Puedes alterar el rango con el que el script juzgará tu voltaje total pulsando **[ENTER]** en esta página:
  - **LiPo** (Mín 3.2v - Máx 4.2v)
  - **LiHV** (Mín 3.2v - Máx 4.35v)
  - **LiIon** (Mín 2.8v - Máx 4.2v)
- **Barra de Porcentaje Visual:** Una barra gráfica que se vacía dinámicamente y expone un porcentaje relativo con respecto al voltaje químico en tiempo real.
- **Alertas Visuales Parpadeantes:** En el hipotético caso de que el voltaje de la celda caiga por debajo del valor nominal del tipo de batería elegida, los indicadores relevantes se invertirán de color dinámicamente avisándote de que es hora de aterrizar.

### 🛰️ 2. Pestaña GPS (Navegación y Localización)
Visualizador principal de coordenadas si estás equipando a tu modelo de un módulo GNSS/GPS.
- **Coordenadas Lat / Lon:** Exposición pura y legible de Latitud y Longitud absolutas.
- **Detalle de la Señal GPS:** Informa siempre la cantidad de satélites enganchados (`SAT`) e inclusive expone la altitud actual (`ALT`). Muestra intermitente "ESPERANDO GPS" si los satélites mínimos configurados no logran crear aún un *fix* en el espacio de rastreo 3D.
- **URL Plus Code:** Un texto codificado bajo el estándar de Google `+CODE XXXX+XX` para transcribirlo rápidamente a un teléfono móvil o mapa en un rescate de nave sin conexión viva de internet en el mando.
- **Protección Ante Pérdida (LOST):** Si en pleno vuelo entra una caída de feed generalizada y falla el salto de los frames (telemetría crashea o la señal de radio se apaga), la pantalla empezará a dibujar unos potentes rectángulos gruesos en todos los lados del cuadro, guardando los últimos rastros en memoria por encima de cualquier otra ventana, garantizando así un backup infalible.
- **Salvar Captura de Pantalla:** Ejecutable pulsando **[ENTER]**; acciona la función *screenshot* interna del sistema operativo para exportar una fotografía rápida en formato BMP de las coordenadas hacia tu Tarjeta SD.

### 📊 3. Pestaña TOT (Totales y Estadísticas)
Dedicada al registro histórico y al fin de vuelo, es donde se acumula todo en memoria. Muestra el emparejamiento de las marcas de tiempo mínimas / máximas capturadas sin reiniciar.
- **MIN V (Voltaje mínimo):** Mantenimiento de la lectura de peor escenario de *sag*.
- **MAX AMP (Corriente Máxima):** Medición de carga de esfuerzo punta detectada por tu FC o shunt resistor.
- **MAX ALT (Altitud Máxima):** Máxima altitud vertical pura del despegue en base a 0 m.
- **DIST (Distancia Total):** Trayectoria y odometría generada sumando todos los movimientos de la latitud/longitud en tiempo real entre frame a frame y transformada en m / km.
- **VEL MAX (Velocidad Mín/Max):** Máximo empuje alcanzado del modelo respecto al suelo (GSpd).
- **MAX SAT (Satélites Máx):** Mayor concentración de satélites estáticos obtenidos durante la sesión.
- **CONS / DRAIN (Capacidad drenada):** Descuento directo en 'mAh' basados en los sensores de recuento amperimétrico (Capa) vital para no freír al modelo.
- **Botón RESET:** Resetéa estos valores contadores presionando **[ENTER]** cuando estás visualizando dicha etiqueta para despegar fresco al cambiar de batería. Aparecerá un aviso en la parte inferior afirmando `** RESET **`.

---

## ⚙️ Menú de Configuración Dinámico

En lugar de requerir conectar constantemente tu cable USB al computador o emplear engorrosos menús LUA nativos, la tecla que lanza la telemetría en la pantalla primaria (normalmente es un *long press* del botón **[TELE]**) invocará de forma central un menú de setup nativo para RCIC que superpone la acción de visualización gráfica en curso.

Para circular o cerrar presione la misma tecla de invocación. Los datos interactuables del recuadro de setup son los siguientes:
1. **UPDATE RATE:** Milésimos/módulo de recálculo (ejes cronológicos / `x ms`); cuanto más pequeño más carga CPU pide, cuanto más alto menos sensible pero más suave la máquina.
2. **BAT ALERT:** Toggle de prender/apagar (`ON/OFF`) cualquier algoritmo visual / auditivo de alerta por hundimiento de batería (útil en simuladores/pruebas).
3. **AUDIO:** Toggle sonoro. Te cantará o leerá numéricamente el voltaje remanente saltándose solo usar tonos acústicos base de hardware.
4. **ALERT INT. (Intervención de Alarma):** Pausa cronometrada entre canticos para que no saturar el buffer auditivo de tu radio incesantemente si sube o baja con el viento o el uso agresivo de alerones.
5. **ALERT STEP:** Decaimiento en voltios constante entre repeticiones. Por ejemplo; un *Step* seteado en `.10v` indica a la emisora cantar tu voltaje por voz únicamente sí tu batería desciende un total estático extra respecto la advertencia pasada (ej: bajó a "3.61v", advertir. Cantará otra vez de rebaje solo cuando lea \~"3.51v" o menos).

> 💡 *Uso dentro del Modo Configuración:* Mueve el cursor con **[+]** y **[-]**. Cuando desees cambiar un valor específico aprieta **[ENTER]**, notando que el texto invertido saltará de la categoría al valor en sí. Ahí rotas para definir el montante en números, seguidamente vuelves a usar **[ENTER]** o botón de retorno **[RTN]**. Cerrando este menú final (tecla [TELE]), desencadenamos una salvaguarda a micro-nivel persistente en tu tarjeta SD (crea un fichero pequeño textualmente en `/SCRIPTS/TELEMETRY/rcic.cfg`). Ya puedes apagar sin temor la controladora, todos los parámetros serán idénticos mañana.

---

## 🛠 Instalación Rápida

1. Sitúa tu modelo y descarga íntegramente el fichero original `rcic.lua`.
2. Habilita USB a la computadora si usas Companion / Cable; elige en tu Radio "USB Storage" (SD Card Mode).
3. Entra a la estructura interna estándar y abre la capeta matriz `/SCRIPTS/TELEMETRY/`.
4. Copia el susodicho archivo ahí (el fichero autosembrado de config no existe hasta el uso normal, es natural).
5. Desconéctate en modo *Safe USB*, vuelve a tu mando EdgeTX y encárgate de ir a preferencias físicas del modelo seleccionado (Típicamente pulsando *MDL* breve una vez).
6. Presiona pasar páginas (Page >) hasta las configuraciones de *TELEMETRY* o *DISPLAYS*.
7. Configura *Screen 1* modificando de "Nums/Bars" a **"Script"**, marcando luego el destino "rcic".
8. Salva las propiedades regresando a tu vista main de pilotaje principal, dejando oprimida el conector asignado. ¡Tus métricas ya lucirán impecables!

## 📝 Documentación Original y Licencia

Diseño algorítmico y matemático bajo la amparación de la Licencia Open-Source de rama **MIT** original.

**Derechos de Repositorio**
*(c) 2026 Alonso Lara.*

Puedes alterar, bifurcar o anexar la obra citando y acreditando amablemente de ser requerido el vínculo público subyacente de resguardo [github.com/AlonsoLP]. Libre para usos lucrativos o experimentales.
