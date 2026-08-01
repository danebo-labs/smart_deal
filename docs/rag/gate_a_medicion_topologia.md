# Gate A / Gate A-bis — Medición de topología T1 sobre `SEGURIDADES 1.1-1.pdf`

> **Veredicto vigente (Gate A-bis, 2026-08-01): SUPERADO.**
> Umbral exigido por [plan_conocimiento_visual.md](plan_conocimiento_visual.md): **≥85 % de
> aristas correctas y 0 incorrectas** en la muestra revisada.
> Medido tras 2b (`f4ab397`) y 3b (`1cb789b`): **19 aristas en 18 páginas, 19/19 correctas
> (100 %), 0 incorrectas**, revisadas **todas** con visión sobre la página rasterizada. En la
> muestra de 11 páginas el derivador emite 7, **7/7 correctas**, y las cuatro páginas de las
> aristas falsas del Gate A (56, 61, 67, 97) devuelven `[]`.
>
> **Superar el umbral no autoriza la Fase 4.** Falta la **decisión humana #4** del plan
> (¿Fase 7 con T1 solo o se espera a T2?), y el dato que la obliga sigue intacto: el **recall
> es del 4,6 %** (§4.1). Ver §10.
>
> **Veredicto histórico (Gate A, mismo día, código pre-2b/3b): NO SUPERADO** — 82,6 % correctas
> y 4 incorrectas sobre 23 aristas; 63,6 % en la muestra. Se conserva el diagnóstico en §4.2 y
> §4.3 porque es lo que definió las Fases 2b y 3b.
>
> Este informe es además la verdad-terreno de la Fase 8, así que se entrega completo. **Es uno
> solo:** el Gate A-bis lo reescribió en el sitio, no creó un informe nuevo.

- **Fecha:** 2026-08-01 (Gate A y Gate A-bis, en ese orden)
- **Ejecutado por:** Gate A · Opus 5 → Gate A-bis · Opus 5
- **Entrada:** `SEGURIDADES 1.1-1.pdf`, 98 páginas, MediaBox `[0,0,960,540]`
- **Código medido en el Gate A-bis:** `PdfLayoutExtractor` (Fases 2 + 2b, `09c813b` + `f4ab397`)
  + `TopologyEdgeDeriver` (Fases 3 + 3b, `ed8bd56` + `1cb789b`), sin modificar. El Gate A original
  midió el mismo código **sin** 2b ni 3b.
- **Guiones de medición (comprometidos, para que cualquier re-medición mida lo mismo):**
  `script/gate_a/run.rb` · `walk.rb` · `page.rb` · `led.rb` · `sensitivity.rb` · `overlay.py` ·
  `zoom.py`. Son instrumentos de medición offline; **nada de producción los invoca** y no cargan
  en el boot. Reproducción completa:

  ```bash
  bin/rails runner script/gate_a/run.rb          # -> tmp/gate_a_measurement.json
  bin/rails runner script/gate_a/walk.rb         # -> tmp/gate_a_walk.json (embudo de §3.1)
  bin/rails runner script/gate_a/led.rb          # -> tmp/gate_a_led.json
  bin/rails runner script/gate_a/sensitivity.rb  # barrido de constantes de §4.5
  GATE_A_PAGES=3 bin/rails runner script/gate_a/page.rb   # autopsia de cadenas de una página
  python3 script/gate_a/overlay.py 3 22 39       # todas las aristas de la página, en magenta
  python3 script/gate_a/zoom.py    3 22 39       # una arista por imagen, limpio | derivado
  ```

  Ruta del PDF por `GATE_A_PDF`; por defecto la copia local de
  `~/Documents/Danebo/.../SEGURIDADES 1.1-1.pdf`. Ambos guiones de dibujo esperan los PNG en
  `tmp/gate_a_png/p-NN.png` (`pdftoppm -f N -l N -r 150 -png -singlefile`).
- **Datos crudos (bajo `tmp/`, no versionados):** `tmp/gate_a_measurement.json` (98 páginas con
  geometría, aristas y motivo de rechazo por cadena), `tmp/gate_a_walk.json`, `tmp/gate_a_led.json`
- **Método de verificación visual:** cada arista derivada se **dibuja sobre la página
  rasterizada a 150 dpi** y se compara con el cable realmente trazado. No se asumió nada: en el
  Gate A se miraron las 23 una por una, y en el Gate A-bis las 19, otra vez, después del cambio.
  **`zoom.py` es nuevo del Gate A-bis y existe por un motivo medido:** `overlay.py` dibuja en
  magenta y varias láminas de este documento (p. 3, 14, 95) trazan sus cables **en magenta**, así
  que el overlay se confunde con el dibujo. `zoom.py` recorta la zona de **una sola** arista y
  pone lado a lado el render limpio y el derivado (polilínea amarilla sobre negro, más el `bbox`
  de las dos etiquetas citadas en cian, parseado de `evidence`). Sin esos dos cambios —una arista
  por imagen y un color que el documento no usa— la revisión de las págs. 3, 39 y 94 no es
  concluyente.

---

## 1. Resumen ejecutivo

| Medida | Gate A (pre-2b/3b) | **Gate A-bis (vigente)** |
|---|---|---|
| Aristas T1 emitidas en 98 páginas | 23 | **19** |
| Páginas con ≥1 arista | 22 / 98 (22,4 %) | **18 / 98 (18,4 %)** |
| Páginas con `[]` | 76 / 98 | **80 / 98** |
| Aristas revisadas con visión | 23 / 23 (100 %) | **19 / 19 (100 %)** |
| Aristas **correctas** | 19 | **19** |
| Aristas **incorrectas** | 4 (págs. 56, 61, 67, 97) | **0** |
| Precisión sobre el documento entero | 82,6 % | **100 %** |
| Precisión en la muestra de 11 páginas / 10 secciones | 7/11 = 63,6 % | **7/7 = 100 %** |
| Recall en esa muestra (aristas correctas ÷ relaciones que lee un humano) | 7 / 153 ≈ 4,6 % | **7 / 153 ≈ 4,6 %** |
| Páginas sin ninguna cobertura T1 | 76 (58 de contenido) | **80** (**61 de contenido**) |
| Secciones (de 18) sin ninguna arista | 5 | **7** |

**Las dos condiciones del umbral se cumplen y ninguna arista correcta se perdió.** Las cuatro
falsas resuelven a `[]` y no aparece ninguna nueva: son exactamente las mismas 19 aristas del
Gate A, revisadas otra vez una a una después del cambio. El precio es cobertura: **4 páginas y 2
secciones menos**.

**Lo que no cambió es el supuesto.** El recall sigue siendo del **4,6 %**: T1, en este documento,
no es un motor de conocimiento, es un puñado de anclas — y ahora un puñado más pequeño. Precisión
del 100 % sobre 19 aristas es un umbral superado, no una capacidad. La consecuencia para la Fase 5
está en §7 y la decisión que obliga, en §10.

**Tres límites conocidos, ninguno de ellos una arista falsa** (§4.4, §4.6, §4.7): 3 de las 19
aristas unen los dos extremos de un conductor que **atraviesa 1-2 dispositivos intermedios** que
la arista no nombra; 1 de las 19 se emite **sólo** porque el `bbox` de su etiqueta está inflado
por espacios finales sin tinta; y el arreglo de `CARLOS SILVA` que la Fase 2b dio por cerrado
**no funciona sobre el PDF real**.

---

## 2. Aristas por página y total

> ⚠️ **Reescrita por el Gate A-bis.** La salida vigente son **19 aristas en 18 páginas**; las 80
> restantes devuelven `[]`. La tabla de 23 aristas que había aquí describía el código anterior a
> 2b/3b y está sustituida: las cuatro falsas (56, 61, 67, 97) ya no se emiten. El antes/después
> publicable es **23 (Gate A) → 22 (tras 2b) → 19 (tras 3b)** (I-21).

Las 19, revisadas una a una con visión sobre el render a 150 dpi (`script/gate_a/zoom.py`):

| Pág | Sección | `from` | `to` | Veredicto visual (Gate A-bis) |
|---|---|---|---|---|
| 3 | ALJO | `FINALES` | `CONECTOR AI` | ✅ correcta — cable magenta, pin 4 de AI |
| 3 | ALJO | `LIMITADOR` | `CONECTOR AI` | ✅ correcta — cable **marrón**, no el azul marino ⁴ |
| 11 | CARLOS SILVA | `Final carrera hidráulico (NO)` | `B6` | ✅ correcta — cable verde, pin 1 |
| 12 | CARLOS SILVA | `PUERTAS MANUALES` | `BM2` | ✅ correcta ⁵ — cable rojo, pin 4 |
| 14 | CARLOS SILVA | `STOP BOTO. CABINA` | `XP11` | ⚠️ correcta con reserva ³ |
| 22 | CTA | `OBSTACULO` | `CN-112` | ⚠️ correcta con reserva ¹ ³ |
| 25 | EDEL | `PTC MOTOR` | `M1` | ✅ correcta — cable azul, pin 20, al `NTC 3D-5` |
| 39 | EXCELSIOR | `CERROJOS EXTERIORES` | `HUE_1` | ✅ correcta ⁶ — cable verde, pin 1 |
| 44 | FAIN | `LIMITADOR` | `C300` | ✅ correcta — cable azul, pin 1 |
| 52 | KONE | `BLOQUEO CABINA` | `CERROJOS EMBARQUE 2` | ✅ correcta ² |
| 63 | ORONA | `ALUMBRADO CABINA` | `J12` | ✅ correcta — cable azul `P189`, pin 1, al tubo LED |
| 64 | ORONA | `LIMITADOR CONTRAPESO` | `J22` | ⚠️ correcta con reserva ³ |
| 76 | RECOBA | `LIMITADOR` | `C300` | ✅ correcta — cable azul, pin 1 |
| 77 | RECOBA | `LIMITADOR` | `C300` | ✅ correcta — cable azul, pin 1 |
| 78 | RECOBA | `LIMITADOR` | `C300` | ✅ correcta — cable azul, pin 1 |
| 91 | SISTEL | `PTC MOTOR` | `X114` | ✅ correcta — cable marrón, pin 1, al `NTC 3D-5` |
| 93 | THYSSEN | `BLOQUE C` | `LIMITADOR` | ✅ correcta — cable gris, borne `70` |
| 94 | THYSSEN | `BLOQUE A` | `AFLOJACALES DOBLE DIFERENCAL` | ✅ correcta — cable verde, borne 10 |
| 95 | THYSSEN | `BLOQUE A` | `STOP CUARTO POLEAS` | ✅ correcta — cable magenta, borne `A4` |

**19 correctas, 0 incorrectas.** Las cuatro que el Gate A dio por falsas ya no se emiten:

| Pág | Arista falsa del Gate A | Motivo de rechazo hoy |
|---|---|---|
| 56 | `PISO SUPERIOR -> CC2` | `raster_rival` (guarda de 3b) |
| 61 | `CERRADURAS EXTERIORES -> B` | `no_label_at_terminal` — con el `bbox` corregido de 2b ya no hay etiqueta en rango ⁷ |
| 67 | `PUERTAS EXTE. -> SE` | `label_passed_by` — con el `bbox` corregido de 2b el cable **pasa por encima** de `SE` (I-21) |
| 97 | `PUERTAS FRONTALES -> PESTLLOS TECHO CABINA` | `raster_rival` (guarda de 3b) |

¹ Corroborada por el propio texto de la página: la tabla LED imprime
`SERIE OBSTACULO (CN-112.SC Y CN-109.CC)`, y el cable azul derivado sale justamente del pin `SC`
de `CN-112`. Es la única arista del documento con confirmación textual independiente.

² Arista componente↔componente, no componente↔conector: el conductor recorre
`CERROJOS EMBARQUE 1` → `CERROJOS EMBARQUE 2` → `BLOQUEO CABINA`, y el tramo derivado es el
**último**, entre dos dispositivos adyacentes de la serie. No omite ningún intermedio y por eso
no lleva reserva. El contrato de la Fase 3 es etiqueta↔etiqueta, así que es válida.

³ **Serie con intermedio omitido** — tres casos, no uno. La afirmación es cierta (los dos
extremos comparten conductor) pero el técnico no se entera de los dispositivos que hay en medio:
p14 el conductor magenta va de `XP11` pin 1 a `STOP BOTO. CABINA` **pasando por
`BOTONERA REVISION` y `BARANDILLA`**; p22 el cable azul de `CN-112.SC` a `OBSTACULO` **pasa por
`FOTOCELULA`**; p64 el conductor de `J22` (`P26`) a `LIMITADOR CONTRAPESO` **pasa por
`LIMITADOR CABINA`**. Ver §4.4 — el Gate A sólo había registrado el tercero.

⁴ De los dos cables que llegan a `LIMITADOR` desde `CONECTOR AI` (marrón y azul marino), la
polilínea derivada es la del **marrón**. La arista es la misma en cualquier caso.

⁵ Emitida **sólo** gracias a un `bbox` inflado por espacios finales: la tinta de `BM2` acaba en
x=126,9 y el extremo de la cadena está en x=186,2 — a 59,3 pt, muy fuera de
`TERMINAL_TOLERANCE_PT = 25`. El `bbox` que el extractor entrega llega hasta x=281,5. Es correcta
por lo que dibuja la lámina, no por lo que midió el derivador. Ver §4.6.

⁶ La página imprime `CERROJOS EXTERIORES` **dos veces** y el derivador cita el `bbox` de la
**otra** (la del cerrojo de abajo, a 24,4 pt del extremo; la que rotula el cerrojo que el cable sí
toca queda a 26,6 pt, fuera de tolerancia). El nombre emitido es correcto porque los dos rótulos
son idénticos — la coordenada de `evidence`, no.

⁷ Con el `bbox` de 2b la pág. 61 pasó primero por `TENSORA -> A 8 2 P` (I-21) y hoy no emite nada:
de sus 28 cadenas, 16 mueren por `no_label_at_terminal`, 1 por la guarda de rotación.

### Distribución por sección

| Sección (Apéndice E) | Páginas | Con arista | Aristas | Gate A |
|---|---|---|---|---|
| ALJO | 2-7 | 1 | 2 | = |
| CARLOS SILVA | 8-14 | 3 | 3 | = |
| CTA | 15-22 | 1 | 1 | = |
| EDEL | 23-26 | 1 | 1 | = |
| ELECMEGON | 27-34 | 0 | 0 | = |
| ENIER | 35-36 | 0 | 0 | = |
| EXCELSIOR | 37-40 | 1 | 1 | = |
| FAIN | 41-46 | 1 | 1 | = |
| HATS_-_ASOCIADOS | 47-48 | 0 | 0 | = |
| INELCA | 49-50 | 0 | 0 | = |
| KONE | 51-53 | 1 | 1 | = |
| **MP** | 54-59 | **0** | **0** | 1 / 1 ❌ falsa |
| **ORONA** | 60-65 | **2** | **2** | 3 / 3 (una falsa) |
| **OTIS** | 66-69 | **0** | **0** | 1 / 1 ❌ falsa |
| RECOBA | 70-79 | 3 | 3 | = |
| SCHINDLER | 80-86 | 0 | 0 | = |
| SISTEL | 87-91 | 1 | 1 | = |
| **THYSSEN** | 92-98 | **3** | **3** | 4 / 4 (una falsa) |

**7 de las 18 secciones no reciben ni una sola arista** (antes 5: se suman MP y OTIS, cuyas únicas
aristas eran falsas). Para las preguntas de esas marcas, T1 no aporta nada.

---

## 3. Páginas con 0 aristas y por qué

### 3.1 El embudo completo, medido

> ⚠️ **Reescrito por el Gate A-bis.** La mitad de arriba (geometría y recorrido de cadenas) es
> **idéntica** al Gate A —2b y 3b no tocan la formación de cadenas—; la mitad de abajo trae los
> **dos motivos de rechazo nuevos** de 3b, `rotated_label` y `raster_rival`.

Sobre las 98 páginas: **9 078 segmentos** (tras el corte de ruido de la Fase 2), **18 156**
extremos de segmento.

| Etapa | Cantidad | Gate A | Se pierde por |
|---|---|---|---|
| Extremos de segmento | 18 156 | = | — |
| … en nudo de 3+ (bifurcación) | **9 706 (53,5 %)** | = | marcos, cajas dibujadas, tablas |
| … en nudo de 2 (codo interior de cadena) | 5 164 | = | no son finales |
| … extremos libres | **3 286** | = | — |
| Extremos libres que llegan a recorrer una cadena válida | 2 652 | = | 468 `>4 segmentos`, 166 bifurcación |
| **Cadenas** (cada una tiene 2 extremos) | **1 326** | = | — |
| … rechazadas por **unión T** | 639 (48,2 %) | 639 | el extremo toca el interior de otro segmento |
| … rechazadas por **extremo sin etiqueta impresa a ≤25 pt** | 562 (42,4 %) | 563 | §3.3 |
| … rechazadas porque **la cadena pasa junto a la etiqueta** | 49 | 46 | +3: el `bbox` corregido de 2b hace que el cable pase por encima del rótulo (p. ej. pág. 67) |
| … rechazadas por **dos etiquetas en rango** | 38 | 39 | |
| … rechazadas porque **el texto no es un nombre** | 13 | 13 | |
| … rechazadas por **etiqueta rotada** (guarda de 3b) | **1** | — | numeración vertical de bornes; §4.2 |
| … rechazadas por **rival rasterizado** (guarda de 3b) | **4** | — | págs. 56 (1), 97 (2), 98 (1); §4.3 |
| … rechazadas por **bucle a la misma etiqueta** | **0** | 1 | la única (pág. 98) muere ahora una guarda antes, por `raster_rival` (I-21) |
| **Emitidas** | 20 | 25 | |
| Tras deduplicar el par (una arista por par de etiquetas) | **19** | 23 | |

Las columnas suman 1 326 en las dos lecturas. **El orden de las guardas importa** y no está atado
por ningún test: `DiagnosticDeriver#label_state` (en `script/gate_a/run.rb`) duplica a mano el de
`TopologyEdgeDeriver#sole_label_at` para poder atribuir un motivo por cadena. Si alguien reordena
uno sin el otro, este embudo miente (I-22).

### 3.2 Clasificación de las 80 páginas sin arista

> ⚠️ **Actualizado por el Gate A-bis:** 76 → 80. Las cuatro nuevas son 56, 61, 67 y 97, las de las
> aristas falsas. Los 18 divisores y la portada no cambian.

| Clase | Páginas | Cuántas |
|---|---|---|
| **Divisor sin líneas guía** (0 segmentos) | 2, 15, 23, 35, 41, 49, 51, 54, 60, 66, 87, 92 | 12 |
| **Divisor con sólo el adorno de esquina** (4-6 segmentos, 2 cadenas, ambas rechazadas por "pasa junto a la etiqueta") | 8, 27, 37, 47, 70, 80 | 6 |
| **Portada sin capa de texto** (40 segmentos, **0 palabras**: todo el rótulo es ráster) | 1 | 1 |
| **Contenido: cadenas formadas y rechazadas** | el resto | **61** |

Los 18 divisores son exactamente los del Apéndice E. **El Apéndice C decía "12 páginas con 0
segmentos (divisores)" y es correcto pero incompleto**: hay 18 divisores; 6 de ellos llevan un
adorno vectorial de 4-6 segmentos en la esquina. Ninguno tiene líneas guía. Que `[]` sea la
salida correcta en los 18 está confirmado.

### 3.3 El motivo dominante real: la regleta de bornes es un ráster

`extremo sin etiqueta impresa a ≤25 pt` es el 42,4 % de los rechazos y **el motivo dominante en
27 páginas** (5, 16-21, 26, 28-33, 38, 48, 53, 61, 69, 71, 74, 75, 84, 88-90, 98 — medido en el
Gate A-bis; el Gate A escribió 32, que era una estimación, no el conteo). La causa está medida y
es siempre la misma: **la numeración de bornes del conector está dibujada dentro de la
foto/gráfico de la regleta, no en la capa de texto**.

Contraejemplo canónico, **página 17** (CTA – SR8P): un técnico lee ahí ~15 relaciones explícitas
con número de borne (`CERROJOS CABINA`→32/78, `LIMITADOR`→117/116, `TEMPERATURA MAQUINA`→85/84…).
T1 emite `[]`. De sus 25 cadenas, **20 mueren porque el extremo del lado del borne no encuentra
ningún texto**: los números `32 78 77 76 185 184 …` no existen en `words`; son píxeles.

Misma causa en 5, 16, 18-21, 26, 28-33, 38, 48, 53, 61, 69, 71, 74-75, 84, 88-90, 98.

### 3.4 Corrección a I-09: el bucle **no** es el mecanismo dominante

I-09 escribió que las líneas guía "son en su mayoría **bucles** … ambos extremos resuelven a la
misma etiqueta y no se emite nada". **Medido sobre las 98 páginas, la guarda de bucle
(`same_label_loop`) se disparaba exactamente 1 vez** (página 98) — y **tras 3b, 0 veces**: esa
misma cadena muere ahora una guarda antes, por `raster_rival` (I-21). Mismo resultado, motivo
distinto.

El mecanismo real es anterior: los bucles **no llegan** a esa guarda. Un bucle
conector→componente→conector recorre más de 4 segmentos y muere en `MAX_CHAIN_SEGMENTS`, o pasa
por un nudo de 3+ y muere en la guarda de bifurcación. En la página 3, de 28 extremos libres,
**12 mueren por `>4 segmentos`** y ninguno por bucle.

La conclusión práctica de I-09 (los bucles no producen aristas, y eso es correcto) se sostiene.
Su explicación del porqué, no.

---

## 4. Tasa de acierto contra lectura humana

### 4.1 Muestra

11 páginas, **10 secciones distintas**, incluida la 3. Requisito del gate: ≥6 páginas de
secciones distintas incluida la 3. Se leyó cada página renderizada a 150 dpi y se contó **toda
relación dibujada que un técnico leería** (par dispositivo↔conector/borne, o dispositivo↔dispositivo
unidos por un cable trazado).

**La columna "relaciones que lee un humano" es la verdad-terreno cara y no se rehace.** Se contó
una sola vez, en el Gate A, y el Gate A-bis reusa exactamente la misma muestra para que el
antes/después sea comparable.

| Pág | Sección | Relaciones que lee un humano | Aristas T1 | Correctas | Incorrectas | Recall | (Gate A) |
|---|---|---|---|---|---|---|---|
| 3 | ALJO | 12 | 2 | 2 | 0 | 17 % | = |
| 17 | CTA | 15 | 0 | 0 | 0 | 0 % | = |
| 22 | CTA | 15 | 1 | 1 | 0 | 7 % | = |
| 39 | EXCELSIOR | 14 | 1 | 1 | 0 | 7 % | = |
| 44 | FAIN | 11 | 1 | 1 | 0 | 9 % | = |
| 56 | MP | 19 | **0** | 0 | **0** | 0 % | 1 arista, falsa |
| 61 | ORONA | 16 | **0** | 0 | **0** | 0 % | 1 arista, falsa |
| 67 | OTIS | 12 | **0** | 0 | **0** | 0 % | 1 arista, falsa |
| 76 | RECOBA | 10 | 1 | 1 | 0 | 10 % | = |
| 91 | SISTEL | 14 | 1 | 1 | 0 | 7 % | = |
| 97 | THYSSEN | 15 | **0** | 0 | **0** | 0 % | 1 arista, falsa |
| **Total** | **10 secciones** | **153** | **7** | **7** | **0** | **4,6 %** | 11 / 7 / 4 |

**Precisión en la muestra: 7/7 = 100 %. Incorrectas: 0.** Las dos condiciones del gate se cumplen.
(Gate A: 7/11 = 63,6 % con 4 incorrectas.)

Se revisaron además las 12 aristas restantes del documento (págs. 11, 12, 14, 25, 52, 63, 64, 77,
78, 93, 94, 95): todas correctas, con las reservas de §4.4 y §4.6. Sobre el documento entero la
precisión es **19/19 = 100 %** (Gate A: 19/23 = 82,6 %).

**El recall no se movió ni un punto: 7 / 153 ≈ 4,6 %.** Era de esperar —2b y 3b son guardas de
correctitud, no de cobertura— pero es el número que hay que tener delante al leer el 100 %: lo
que subió es la fiabilidad de lo poquísimo que T1 dice, no cuánto dice.

### 4.2 Fallo A — el nombre del extremo es un fragmento de texto rotado (págs. 61 y 67)

> ✅ **Cerrado por las Fases 2b (`f4ab397`) e 3b (`1cb789b`).** Se conserva el diagnóstico porque
> es lo que definió esas dos fases y porque el mecanismo sigue vivo en el documento: la guarda
> `rotated_label` se dispara 1 vez sobre las 98 páginas. **Ojo con la lectura fácil:** 2b arregló
> el `bbox` pero **no** el defecto de citar texto rotado — la pág. 61 pasó de
> `CERRADURAS EXTERIORES -> B` a `TENSORA -> A 8 2 P`, o sea sólo cambió qué basura se citaba
> (I-21). Lo que la mata es la guarda de 3b, no el `bbox`.

**El extractor de la Fase 2 rompe el texto girado 90°.** Los rótulos verticales de borne llegan a
`words` **glifo a glifo**, con `bbox` invertido (`x0 > x1`) o de altura cero.

Página 61, rótulos de la regleta `JC3` tal como salen de `PdfLayoutExtractor`:

```
"P"  [790.3, 306.9, 781.3, 312.4]     ← x0 > x1
"3"  [790.3, 312.5, 781.3, 317.5]
"5"  [790.3, 317.5, 781.3, 322.5]
"B"  [790.3, 322.6, 781.3, 329.2]
```

El borne impreso es `P35B`. El derivador se queda con `B` y emite
`CERRADURAS EXTERIORES -> B`. **`B` no es nada; no está impreso en la página.**

Página 67, la misma raíz con otro síntoma: el rótulo impreso del borne 2 de `P3` es **`ES`**, y
el agrupamiento por `y` descendente **invierte el orden de lectura del texto rotado**, así que se
emite `PUERTAS EXTE. -> SE`. La relación existe; **el nombre citado está escrito al revés**.

Bajo el contrato de la Fase 4 esto se renderiza como `ACTION: CERRADURAS EXTERIORES -> B` y
`ACTION: PUERTAS EXTE. -> SE`, y bajo el de la Fase 6b la respuesta queda **autorizada a
reproducirlo verbatim**. Es exactamente la cita falsa que el plan llama el peor fallo posible.

### 4.3 Fallo B — la guarda de unicidad no protege si el competidor es un ráster (págs. 56 y 97)

> ✅ **Cerrado por la Fase 3b (`1cb789b`).** La guarda implementada no es la que este informe
> sugería (*"el extremo cae dentro del `bbox` de una imagen y la etiqueta cae fuera"*): medida,
> esa redacción literal rechaza **todo**, porque cada página lleva dos imágenes de fondo a página
> completa. La regla que separa los cuatro casos con margen medido es **"ninguna otra etiqueta
> impresa con otro nombre puede estar más cerca de esa imagen que la candidata"** (I-20). Se
> dispara 4 veces en las 98 páginas.

La justificación de `TERMINAL_TOLERANCE_PT = 25` en `topology_edge_deriver.rb:87-92` es explícita:
*"Distance is NOT what makes this safe: the uniqueness rule is."* **La unicidad sólo funciona si
las etiquetas rivales están en la capa de texto.**

**Página 56 (MP – MICROBASIC).** El cable magenta va del borne `+24` de `CC1` al conector `CC2`.
Es un puente conector→conector. Los rótulos de borne de `CC1` (`109 111 112 … 120 +24 A B C D`)
**no existen en `words`**: son parte de la imagen de la regleta. El único texto a ≤25 pt del
extremo es `PISO SUPERIOR`, que está 22,9 pt más abajo y **pertenece a otro cable** (el rojo, del
borne 120 al display "10"). Se emite `PISO SUPERIOR -> CC2`: **una conexión que no está dibujada
en ninguna parte.**

**Página 97 (THYSSEN – CMC 4).** El cable magenta va del borne `C1` de `CN32` al dispositivo
`PUERTAS FRONTALES`. `C1`/`C2` son ráster. El texto más cercano al extremo superior es el
rótulo `PESTLLOS TECHO CABINA`, **a 14,1 pt y perteneciente a otro grupo del dibujo, arriba a la
derecha**. Se emite `PUERTAS FRONTALES -> PESTLLOS TECHO CABINA`: dos dispositivos reales de la
página que **no están unidos por ningún cable**.

Los dos casos son el mismo agujero: **la tolerancia de 25 pt es segura frente a etiquetas
impresas y ciega frente a etiquetas rasterizadas**, y este documento tiene la mayoría de sus
bornes rasterizados (§3.3).

### 4.4 Reserva — la serie con intermedio omitido (págs. 14, 22 y 64)

> ⚠️ **Ampliado por el Gate A-bis: son tres aristas de 19, no una.** El Gate A sólo había
> registrado la pág. 64. Al revisar las 19 con `zoom.py` aparecieron otras dos con el mismo
> mecanismo, y una de ellas (p14) omite **dos** dispositivos.

| Pág | Arista emitida | Dispositivos que el conductor atraviesa y la arista **no nombra** |
|---|---|---|
| 14 | `STOP BOTO. CABINA ↔ XP11` | `BOTONERA REVISION`, `BARANDILLA` |
| 22 | `OBSTACULO ↔ CN-112` | `FOTOCELULA` |
| 64 | `LIMITADOR CONTRAPESO ↔ J22` | `LIMITADOR CABINA` |

En los tres, la guarda "la cadena pasa junto a la etiqueta" no salta porque el rótulo cae a un
lado del cable, fuera de la holgura de una altura de línea; el conductor entra y sale del
**dibujo** del dispositivo, no de su rótulo. No son aristas falsas —el conductor es el mismo— pero
un técnico que reciba "LIMITADOR CONTRAPESO va a J22" **no sabrá que LIMITADOR CABINA está en el
mismo lazo**, que es justo el dato que importa cuando la serie está abierta.

Se cuentan como correctas a efectos del umbral y se registran como límite conocido. **Es el 16 %
de la salida de T1** (3 de 19), no un caso aislado, y la Fase 4 debería redactarlas sin sugerir
que el lazo tiene sólo dos elementos.

### 4.5 Por qué el recall es del 4,6 % y no va a subir tocando constantes

Se midió el coste real de las dos constantes que I-09/I-10 señalaron como palancas, sobre las 98
páginas (`script/gate_a/sensitivity.rb`), **re-corrido en el Gate A-bis** — las cifras absolutas
bajan ~4 aristas por las guardas de 3b; las dos conclusiones son idénticas:

| Corte de ruido de Fase 2 | `MAX_CHAIN_SEGMENTS` | Aristas | Páginas | (Gate A) |
|---|---|---|---|---|
| 20 pt (actual) | **4 (actual)** | **19** | **18** | 23 / 22 |
| 20 pt | 6 | 20 | 19 | 24 / 23 |
| 20 pt | 8 | 20 | 19 | 24 / 23 |
| 20 pt | 12 | 20 | 19 | 24 / 23 |
| 2 pt | 4 | **17** | 17 | 21 / 21 |
| 2 pt | 6 | 18 | 18 | 22 / 22 |
| 2 pt | 8 | 18 | 18 | — |
| 2 pt | 12 | 18 | 18 | 22 / 22 |

Dos resultados que corrigen el registro de hallazgos:

- **Subir el tope de cadena no compra nada.** De 4 a 12 segmentos: +1 arista en todo el
  documento. En la página 3, ni con tope 40 aparece una tercera arista.
- **Bajar el corte de ruido de la Fase 2 empeora la cobertura.** I-10 lo propuso como "el cambio
  más barato" para subir el recall. Medido: **19 → 17 aristas**, y en la página 3 **desaparece la
  arista `FINALES ↔ CONECTOR AI`** (con corte 2 pt y tope 12 la página 3 emite sólo
  `LIMITADOR ↔ CONECTOR AI`). El mecanismo que I-10 describió es correcto (esa arista se salvó
  porque el corte de ruido partió la polilínea en dos y el trozo de 1 segmento sí resolvió); su
  remedio está medido y es contraproducente: al reunir la polilínea entera, la cadena vuelve a
  chocar con la bifurcación y el tope de longitud.

### 4.6 Límite nuevo — el `bbox` de una etiqueta incluye sus espacios finales, que no tienen tinta

**Hallazgo del Gate A-bis, no visto por el Gate A.** El extractor mete los glifos de espacio en la
palabra y el `bbox` los abarca, así que una etiqueta reclama área donde **no hay nada impreso**.
Medido sobre las 98 páginas: **615 de 4 306 entradas de `words` (14,3 %) en 80 páginas** llevan
espacios finales, con tramos fantasma de hasta **889 pt** (`MICONIC BX -6200`, divisor p80).

Casos que tocan la salida de T1, medidos glifo a glifo:

| Pág | Etiqueta | Tinta real | `bbox` entregado | Extremo de la cadena | ¿Se emitiría sin el tramo fantasma? |
|---|---|---|---|---|---|
| 12 | `BM2` | x 105,6-**126,9** | x 105,6-**281,5** | x 186,2 | **No** — gap real 59,3 pt ≫ 25 |
| 11 | `B6` | x 43,7-**55,4** | x 43,7-**207,3** | x 79,7 | Sí — gap real 24,4 pt ≤ 25 |

Las dos aristas son **correctas** contra el dibujo (verificado con visión), así que el veredicto
del gate no cambia. Pero **1 de las 19 se emite por el motivo equivocado**, y el mecanismo es
exactamente el que hizo fallar el Gate A: el derivador cree que hay un nombre impreso donde sólo
hay papel. Aquí acertó porque el tramo fantasma se extiende **sobre la propia regleta que la
etiqueta rotula**; nada garantiza que la próxima vez apunte al sitio correcto.

Que no se descarte a la ligera: el `bbox` inflado alimenta también la guarda `raster_rival` de 3b
(`outranked_on_an_image?` compara distancias caja-a-caja) y la de unicidad. Es una decisión de la
Fase 2, no del Gate A-bis, y se registra como hallazgo.

### 4.7 `CARLOS SILVA` sigue saliendo `CARLOSSILVA` — el arreglo de 2b no aplica al PDF real

**Hallazgo del Gate A-bis.** I-19 dio por cerrado el hueco perdido del divisor de la página 8
cambiando `word_gap_tolerance` para usar la altura **menor** de los dos glifos adyacentes, y lo
verificó con un fixture sintético de `CARLOS`/`SILVA` a **14 pt y 6 pt**. Sobre el PDF real la
salida sigue siendo `CARLOSSILVA` — §5.2 y §9 de este informe **siguen vigentes tal cual**.

Medido glifo a glifo en la página 8:

```
C A R L O S   h=53,60          gap entre "S" y "S":  16,08 pt
S I L V A     h=52,76          tolerancia aplicada:  31,66 pt   (min(53,60; 52,76) × 0,6)
```

Las dos tipografías tienen **prácticamente la misma altura** (53,60 vs 52,76), así que tomar la
menor no cambia nada: la tolerancia sigue siendo 31,66 pt y se traga un hueco real de 16,08 pt.
La causa es `WORD_GAP_RATIO = 0.6`, que a cuerpo 53 pt da 32 pt cuando un espacio impreso a ese
tamaño mide ~14-16 pt. El fixture de 2b (14/6 pt) no reproduce el caso real: **el problema nunca
fue el cambio de tamaño, es el ratio**.

No afecta a ninguna arista (ningún divisor emite) y **no se arregla aquí** — tocar
`WORD_GAP_RATIO` mueve el agrupamiento de palabras de las 98 páginas y es trabajo de la Fase 2 con
su propia medición. Para la Fase 8, el verbatim bueno sigue siendo `CARLOS SILVA` y hay que
seguir corrigiéndolo a mano.

El techo no está en las constantes. Está en que **el documento dibuja series y bucles, no líneas
guía punto a punto**, y en que **los bornes que serían el otro extremo son píxeles**.

---

## 5. `section_path` derivado de las páginas divisoras, contra el Apéndice E

### 5.1 Hallazgo de contrato: el divisor da **2 niveles**, no 3

El plan describe `section_path` como "3 niveles derivados del divisor" y pone de ejemplo
`ALJO` / `CONTROL LEVEL 1B` / `ALTIUS` (página 2). **Eso no es una jerarquía.** Medido, la
página 2 imprime:

```
ALJO                        ← marca, y=517.9, centrada, cuerpo grande
-  CONTROL LEVEL 1B         ← viñeta, y=389.4
-  ALTIUS                   ← viñeta, y=324.6
```

`CONTROL LEVEL 1B` y `ALTIUS` son **hermanos**, no padre e hijo: son dos modelos de la marca ALJO,
y las páginas 3-6 son de `CONTROL LEVEL 1B` mientras que la 7 es de `ALTIUS`. El divisor entrega
**marca + lista de modelos**. El nivel 2 de una página de contenido sale de emparejar su propio
título con una de las viñetas de su divisor.

**Forma correcta:** `section_path = [MARCA, MODELO]`, con `section_identity == section_path.first`
(la marca) — lo que **preserva el invariante** de la Fase 4 y coincide con el backfill ya en
producción. El subtítulo completo de la página sigue siendo el heading `##` del cuerpo, como el
plan ya dice.

### 5.2 Las 18 divisoras, extraídas y contrastadas

Extracción 100 % limpia en las 18: la marca es el texto de mayor `y` del divisor y los modelos son
las viñetas `-`.

| Pág | Marca extraída | Apéndice E | Modelos impresos en el divisor |
|---|---|---|---|
| 2 | `ALJO` | ALJO | CONTROL LEVEL 1B · ALTIUS |
| 8 | `CARLOSSILVA` ⚠️ | CARLOS SILVA | HIDRA TPR50 · HIDRA TPR60 · HIDRA TPR70 · SIRIUS · KDT EVO |
| 15 | `CTA` | CTA | M8PC · SR8P · PREMONTADA · CR8PH · MR08 |
| 23 | `EDEL` | EDEL | K2 · K3 |
| 27 | `ELECMEGON` | ELECMEGON | EM 3000 · EM 2000 · EM 4000 · EM 1000 |
| 35 | `ENIER` | ENIER | MXL1 |
| 37 | `EXCELSIOR` | EXCELSIOR | EXCELSIOR · TOKIBAT 2007 |
| 41 | `FAIN` | FAIN | FAIN · EKM66 |
| 47 | `HATS_-_ASOCIADOS` ⚠️ | HATS-ASOCIADOS | ZEUS |
| 49 | `INELCA` | INELCA | HOMELIFT |
| 51 | `KONE` | KONE | MONOESPACE · EPB |
| 54 | `MP` | MP | 5000 · MICROBASIC · VIA SERIE |
| 60 | `ORONA` | ORONA | ARCA · ARCA BASICO · ARCA II · ARCA III |
| 66 | `OTIS` | OTIS | LB II · LCB II · GEN II |
| 70 | `RECOBA` | RECOBA | KSA 18 · EKM 64 · EKM 66 |
| 80 | `SCHINDLER` | SCHINDLER | MICONIC LX · SMART 001 CRIPS · SMART 001 · MICONIC BX -6200 · BIONIC 5 REL.2 -3300 · BIONIC 5 REL.4 -3300 |
| 87 | `SISTEL` | SISTEL | TW1 INAPELSA · TW1 ELECTRICO EMBARBA · TW1 HIDRAULICO EMBARBA · DELTA + |
| 92 | `THYSSEN` | THYSSEN | SERIE E · SERIE B · SERIE F · SERIE CMC 3 · SERIE CMC 4 · SERIE CMC 4+ |

**18/18 coinciden con el Apéndice E.** Dos discrepancias de verbatim, ambas del extractor o del
original, no de la tabla:

- **`CARLOSSILVA`** — la página **sí imprime `CARLOS SILVA` con espacio** (verificado con
  visión). El extractor pierde el espacio porque `SILVA` cambia de tipografía a mitad del rótulo.
  **Es un defecto de `PdfLayoutExtractor`** y afecta a cualquier etiqueta con cambio de fuente
  interno. Para la Fase 8 el verbatim correcto es `CARLOS SILVA`.
  ⚠️ **Confirmado vigente en el Gate A-bis:** la Fase 2b dio este defecto por cerrado (I-19) pero
  **su arreglo no aplica al PDF real** — la salida sigue siendo `CARLOSSILVA`. La causa medida no
  es el cambio de tamaño sino `WORD_GAP_RATIO`. Ver §4.7.
- **`HATS_-_ASOCIADOS`** — los guiones bajos **están en el PDF**. El Apéndice E los normalizó.
  Para la Fase 8 el verbatim es `HATS_-_ASOCIADOS`.

### 5.3 Título de página derivado (nivel 2), 98 páginas

El emparejamiento título→modelo funciona en las 96 páginas de contenido. Muestra:

| Pág | `section_path` derivado | Heading `##` del cuerpo (verbatim medido) |
|---|---|---|
| 3 | `[ALJO, CONTROL LEVEL 1B]` | `CONTROL LEVEL 1B –HIDRAULICO -PREMONTADA` |
| 7 | `[ALJO, ALTIUS]` | `ALTIUS` |
| 17 | `[CTA, SR8P]` | `CTA –SR8P (ELECTRICO Y HIDRAULICO)` |
| 25 | `[EDEL, K2]` | `EDEL-K2` |
| 63 | `[ORONA, ARCA II]` | `ARCA II` |
| 97 | `[THYSSEN, SERIE CMC 4]` | `CMC 4` |

Tabla completa de los 98 títulos en `tmp/gate_a_measurement.json`.

**Ojo con dos páginas mal atribuidas por marca:** las páginas 76, 77 y 78 caen en la sección
`RECOBA` (divisor pág. 70) pero se titulan `FAIN –EM66 - ELECTRICO` / `- HIDRAULCO`, y la 79 es
`EM66 -PLACA EKM 1000`. Lo mismo la 46 dentro de FAIN. Es fiel al PDF (RECOBA monta placa FAIN),
pero significa que **`section_identity` = marca del divisor y el título de la página pueden
nombrar marcas distintas**, y la Fase 8 no debe tratar eso como un error de ingesta.

---

## 6. Filas de tabla LED con su agrupación

Extraídas acotando la banda de la tabla por sus **propias reglas dibujadas** (`script/gate_a/led.rb`),
no por una ventana fija.

| Medida | Valor | Gate A-bis |
|---|---|---|
| Páginas con tabla LED | **72 / 98** | = |
| Páginas **sin** tabla LED | 26 — las 18 divisoras, la portada, y 24, 28, 38, 39, 48, 53, 65 | = (las 26 exactas) |
| Filas totales dentro de la caja de la tabla | 426 | **425** |
| Filas **bien formadas** (indicador + descripción de serie) | **272** | no rehecho ¹ |
| Filas de ruido (rótulos del dibujo que caen dentro de la banda) | 154, en 40 páginas | no rehecho ¹ |
| Páginas con extracción limpia (0 filas de ruido) | 32 | no rehecho ¹ |
| Variantes de cabecera | `LED`+`SERIE` (54) · `LED`+`PLACA`+`SERIE` (6) · `LED`+`DESCRIPCION` (2) | = ² |

¹ **`led.rb` re-corrido en el Gate A-bis:** el reparto de páginas (72/26, las 26 exactas) y las
variantes de cabecera son idénticos; el total de filas baja de 426 a **425** — una fila, efecto
del reagrupamiento de palabras de 2b. El corte bien-formada/ruido de la fila de arriba fue un
**juicio manual** del Gate A sobre sus 426 filas y **no se rehizo**: sigue valiendo con un margen
de ±1 fila. Si la Fase 8 va a generar `required` desde aquí, que rehaga ese corte con su propio
criterio y lo escriba.

² En 10 de las 72 páginas la cabecera arrastra además una **tercera columna espuria** (`J5`,
`XLH5`, `CAMBIO VEL.`, `EMBARQUE 2`…) que es un rótulo del dibujo cayendo en la banda — el mismo
límite conocido de abajo, visto desde la cabecera.

**Agrupación:** una fila es un conjunto de palabras que comparten línea base (`y` dentro de 4 pt),
ordenadas por `x`. La primera celda es el indicador, la segunda la serie. Ejemplos verbatim:

```
p3   ["DL2", "SERIE CERROJOS CERRADA"]
     ["DL3", "SERIE PUERTAS CERRRADA"]        ← tres R, como dice el Apéndice D
     ["DL4", "SERIE SEGURIDADES CERRADA"]
p22  ["SPH", "SERIE PUERTAS"]
     ["CONECTOR", "SITUACION"]                ← cabecera de una SEGUNDA tabla, misma banda de y
     ["SCR", "SERIE CERROJOS EXTERIOR"]
     ["CNC-x", "BORNAS EN CARRIL DIN"]        ← fila de esa segunda tabla
     ["SC", "SERIE CERROJOS CABINA"]
     ["SCI", "SERIE OBSTACULO (CN-112.SC Y CN-109.CC)", "CN-xxx", "BORNAS EN PLACA MR08"]
p76  ["SK0","SERIE SEGURIIDAD PRINCPAL"]      ← "SEGURIIDAD PRINCPAL" en el original
     ["SK1","SERIE PUERTAS CABINA -EXTERIORES"]
     ["SK2","SERIE CERROJOS CABINA -EXTERIORES"] ["H40","ASCENSOR SIN AVERIA"]
p85  ["LUEISK","ALENTACION CIRCUITO SEGURIDAD DESACTIVADA"]
     ["ISK","SERIE SEGURDADES CERRADA  KSS.1 –SEM.6"]
```

**Límite conocido** (medido de nuevo en el Gate A-bis, sin cambios): en ~40 páginas la caja de la
tabla se solapa en `y` con rótulos del dibujo o
con una segunda tabla lateral, y esas palabras entran como filas espurias (p. ej. p97 mete `CN32`,
`FINAL`, `STOP`, `REVISON`; p22 intercala las filas de la tabla `CONECTOR`/`SITUACION`).
Filtrarlas exige la coordenada `x` de la columna, no sólo la banda. **No es sangre para el Gate A**
— la tabla LED es texto plano que la ingesta actual ya lee bien — pero sí lo es para la Fase 8 si
alguien piensa generar `required` desde esta extracción sin limpiarla.

Volcado completo: `tmp/gate_a_led.json`.

---

## 7. Cobertura T1 y dimensionado de la Fase 5

| Población | Páginas | Gate A |
|---|---|---|
| Total | 98 | = |
| Divisoras (T1 correctamente da `[]`, y T2 tampoco tiene relaciones que leer) | 18 | = |
| Portada (sin capa de texto; sólo T2 puede leerla) | 1 | = |
| **Páginas de contenido relacional** | **79** | = |
| … con ≥1 arista T1 | **18** | 22 |
| … con ≥1 arista T1 **correcta** | **18** | 18 |
| … **sin ninguna cobertura T1** | **61** | 57 |

**Lo que hay que dimensionar para la Fase 5 no son 18 páginas, son 79.** El plan escribía "en las
80 páginas donde ambos tiers aplican"; I-09 lo bajó a 22 y el Gate A-bis lo deja en **18**. La
cifra buena para presupuestar T2 es:

- **T2 debe correr en las 79 páginas de contenido + la portada = 80.** En **61** es el **único**
  motor posible; en 18 T1 aporta un ancla y nada más.
- **T1 como verdad-terreno gratis para calibrar T2 (Gate B) son 19 aristas en 18 páginas.** No 80
  páginas, no 23 aristas. Y de esas 19, 3 (págs. 76/77/78) son la misma arista repetida en
  láminas casi idénticas, y otras 2 el mismo par `LIMITADOR↔C300` de la pág. 44. **El conjunto de
  calibración efectivo son ~15 pares distintos.** Es demasiado pequeño para medir precisión y
  recall de T2 con significancia; el Gate B tendrá que aceptar verdad-terreno humana además de T1,
  y este informe es el primer trozo de ella (153 relaciones leídas a mano en 11 páginas).
  **Esto no lo arregló el Gate A-bis y no lo va a arreglar nada de T1:** las 19 son ahora fiables,
  pero siguen siendo 19.
- **La palanca de cobertura que sí existe es la que I-09 dejó sin implementar:** el anclaje
  `images[].bbox` → etiqueta adyacente. Los dos modos de fallo de §4.3 son *bornes rasterizados*;
  un ancla foto→etiqueta no los arregla, pero sí ataca el 42,4 % de rechazos por "extremo sin
  etiqueta" del lado del **componente**. Es trabajo de la Fase 5, no de T1. La Fase 3b ya dejó
  medio camino hecho: `outranked_on_an_image?` **ya implementa** la relación "imagen ↔ etiqueta
  que la rotula" como ranking de cercanía, y se puede reutilizar en vez de reinventarla (I-20).

---

## 8. Resolución del caso `ACUÑAMIENTO` (Apéndice D, caso fixture #1)

**Salida del derivador: (c) ninguna arista. Correcta por evidencia, no por descarte.**

Medido en la página 3, con la etiqueta `ACUÑAMIENTO` en `bbox [573.9, 117.5, 633.0, 124.8]`:

```
extremo de segmento más cercano:  28,1 pt   en (638.2, 152.9)
segundo más cercano:              29,7 pt   en (639.4, 154.5)
tercero:                          65,0 pt
```

Ningún extremo de cadena cae dentro de `TERMINAL_TOLERANCE_PT = 25`. La proximidad en `x` —lo
único que habría puesto `ACUÑAMIENTO` en un conector— **no se consulta nunca**. Verificado además
que la abstención **no depende del tope de cadena**: con `MAX_CHAIN_SEGMENTS` en 4, 8, 16 y 40 la
página 3 emite siempre las mismas dos aristas.

**Verdad-terreno visual, leída de la lámina:** `ACUÑAMIENTO` está unido **sólo a `CONECTOR AG`**.
El cable verde sale del borne 8 de AG, baja, entra en `ACUÑAMIENTO`, sigue a `AFLOJACABLES`, sigue
a `BOTO. REVISION` y vuelve al borne 7 de AG. Es una serie de tres dispositivos en un solo lazo.

**Por tanto la lectura humana del Apéndice D contiene un error.** Puso `ACUÑAMIENTO` en **ambas**
listas (13 menciones para 12 etiquetas). No está en AI. Verdad-terreno corregida de la página 3,
verificada con visión sobre la lámina:

| Conector | Componentes unidos por cable trazado |
|---|---|
| `CONECTOR AI` | `FINAL CARRERA SUPERIOR` (vía bloque auxiliar 10/9 y enlace punteado) · `CERROJOS EXTERIORES` · `PUERTAS EXTERIORES` · `FINALES` · `STOP FOSO` · `POLEA TENSORA` (los tres en un lazo magenta) · `LIMITADOR` (dos cables: marrón y azul marino) |
| `CONECTOR AG` | `ACUÑAMIENTO` · `AFLOJACABLES` · `BOTO. REVISION` (lazo verde en serie) · `CERROJOS EMBARQUE 1` · `CERROJOS EMBARQUE 2` (lazo violeta en serie) |

**7 en AI, 5 en AG, 12 relaciones, 12 etiquetas, ninguna repetida.** Ésta es la verdad-terreno de
la página 3 para la Fase 8, y sustituye a la del Apéndice D.

Nota incómoda pero honesta: en este caso concreto la proximidad en `x` habría acertado
(`ACUÑAMIENTO` en x=574 está bajo AG). Que la regla prohibida acierte una vez no la valida —
habría fallado en `FINALES` (x=395, bajo AI, correcto) y en `STOP FOSO` (x=462, bajo AI,
correcto) por casualidad también, y no hay forma de saber cuándo miente. La abstención sigue
siendo la conducta correcta.

---

## 9. Verbatims medidos, para la Fase 8

Cadenas tal como las imprime el PDF. La Fase 8 debe usar **éstas**, no su forma corregida.

| Verbatim impreso | Paráfrasis que NO matchea | Dónde |
|---|---|---|
| `STOP FOSO` | "STOP FONDO" | p3 y ~30 más |
| `BOTO. REVISION` | "BOTÓN REVISIÓN" | p3 |
| `SERIE PUERTAS CERRRADA` | "CERRADA" | p3-p6 |
| `CONTROL LEVEL 1B –HIDRAULICO -PREMONTADA` | con espacio tras el guion | p3 |
| `PUERTAS EXTERORES` | "EXTERIORES" | p12, p22 |
| `TEPERATURA CUARTO MAQ.` | "TEMPERATURA" | p17 |
| `SERIE SEGURIIDAD PRINCPAL` | "SEGURIDAD PRINCIPAL" | p44, p76-78 |
| `AFLOJACALES DOBLE DIFERENCAL` | "AFLOJACABLES … DIFERENCIAL" | p94 |
| `PESTLLOS TECHO CABINA` | "PESTILLOS" | p97 |
| `SERIE SEGURDADES CERRADA` | "SEGURIDADES" | p85, p86 |
| `ALENTACION CIRCUITO SEGURIDAD DESACTIVADA` | "ALIMENTACION" | p85 |
| `HATS_-_ASOCIADOS` | "HATS-ASOCIADOS" | divisor p47 |
| `CARLOS SILVA` | el extractor devuelve `CARLOSSILVA` | divisor p8 |
| `SERIE OBSTACULO (CN-112.SC Y CN-109.CC)` | — | p22, tabla LED |

---

## 10. Veredicto

### 10.1 Gate A-bis (vigente): SUPERADO

| Condición | Exigido | Medido | |
|---|---|---|---|
| Aristas correctas en la muestra de 11 páginas | ≥85 % | **100 % (7/7)** | ✅ |
| Aristas correctas en el documento | ≥85 % | **100 % (19/19)** | ✅ |
| Aristas incorrectas | 0 | **0** | ✅ |

Verificación: **las 19 revisadas con visión**, no una muestra, cada una dibujada sobre su página
a 150 dpi y comparada con el cable trazado (`script/gate_a/zoom.py`). Suite y linter verdes con el
código medido: **2090 runs / 0 failures; 469 files, 0 offenses**.

Con tres límites conocidos registrados, ninguno de ellos una arista falsa: **§4.4** (3 de 19
omiten dispositivos intermedios de la serie), **§4.6** (1 de 19 se emite gracias a un `bbox`
inflado por espacios sin tinta) y **§4.7** (el arreglo de `CARLOS SILVA` de 2b no aplica al PDF
real).

### 10.2 Lo que el gate **no** autoriza

**La Fase 4 sigue bloqueada.** Superar el umbral era condición necesaria, no suficiente: el plan
exige además la **decisión humana #4** — *¿se ejecuta la Fase 7 (shadow ingest, único paso
irreversible) con las aristas de T1 solas, o se espera a tener también T2?* — y ésa la responde el
dueño del producto, por escrito, en el plan.

Los dos números que hay que tener delante al responderla:

| | |
|---|---|
| **Precisión de T1** | **100 %** (19/19), 0 incorrectas |
| **Recall de T1** | **4,6 %** (7 de 153 relaciones que un técnico lee en 11 páginas) |
| Cobertura | 19 aristas en **18 de 98** páginas; **~15 pares distintos**; 7 de 18 secciones sin ninguna arista |

La recomendación de este informe **no ha cambiado con el gate superado**: a la vista de §7, 18
páginas con ~15 pares distintos no justifican gastar el paso irreversible sólo por T1, porque el
riesgo #1 del plan —que el texto de topología diluya el embedding y **baje** el recall, el
mecanismo plausible del 62/88 → 57/88 ya medido— se paga entero por 19 aristas. La opción B del
plan (mergear la Fase 4 con el flag apagado, que es inerte por diseño, y esperar a T2 antes de la
Fase 7) desacopla las dos cosas sin tirar nada.

**Es una recomendación, no una decisión.** El gate se detiene aquí.

### 10.3 Gate A (histórico, mismo día, código pre-2b/3b): NO SUPERADO

| Condición | Exigido | Medido | |
|---|---|---|---|
| Aristas correctas en la muestra | ≥85 % | 63,6 % (7/11) | ❌ |
| Aristas correctas en el documento | ≥85 % | 82,6 % (19/23) | ❌ |
| Aristas incorrectas | 0 | **4** | ❌ |

Las cuatro incorrectas se agruparon en **dos defectos, ambos reparables y ninguno de ellos de la
Fase 4**:

1. **`PdfLayoutExtractor` no maneja texto rotado 90°** (Fase 2). Devolvía un `words` por glifo,
   con `bbox` invertido, y el orden de lectura al revés. Causa de las págs. 61 y 67.
   **Hallazgo I-13 → cerrado por la Fase 2b (`f4ab397`), con el matiz de I-21: el `bbox` quedó
   bien pero la cita rotada sólo la mata la guarda de 3b.**
2. **`TopologyEdgeDeriver` confía en una unicidad que no puede comprobar** (Fase 3). Con el
   competidor legítimo rasterizado, la guarda de "exactamente una etiqueta en rango" daba falso
   positivo. Causa de las págs. 56 y 97. **Hallazgo I-14 → cerrado por la Fase 3b (`1cb789b`),
   con la regla reformulada de I-20.**

Ambos resultaron ser arreglos acotados, y el gate se reintentó **con el mismo guion y la misma
muestra**, con la verdad-terreno humana ya escrita (§4.1, §8) — la parte cara, que sólo se hizo
una vez.
