# Gate A — Medición de topología T1 sobre `SEGURIDADES 1.1-1.pdf`

> **Veredicto: NO SUPERADO. La Fase 4 no queda autorizada.**
> Umbral exigido por [plan_conocimiento_visual.md](plan_conocimiento_visual.md): **≥85 % de
> aristas correctas y 0 incorrectas** en la muestra revisada.
> Medido: **63,6 % correctas y 4 incorrectas** en la muestra de 11 páginas; **82,6 % correctas y
> 4 incorrectas** revisando las 23 aristas del documento entero.
> Ninguna de las dos lecturas alcanza el umbral, y la condición "0 incorrectas" falla por 4.
>
> Este informe es además la verdad-terreno de la Fase 8, así que se entrega completo.

- **Fecha:** 2026-08-01
- **Ejecutado por:** Gate A · Opus 5
- **Entrada:** `SEGURIDADES 1.1-1.pdf`, 98 páginas, MediaBox `[0,0,960,540]`
- **Código medido:** `PdfLayoutExtractor` (Fase 2, `09c813b`) + `TopologyEdgeDeriver` (Fase 3,
  `ed8bd56`), sin modificar
- **Guiones de medición (comprometidos, para que el Gate A-bis mida lo mismo):**
  `script/gate_a/run.rb` · `walk.rb` · `page.rb` · `led.rb` · `sensitivity.rb` · `overlay.py`.
  Son instrumentos de medición offline; **nada de producción los invoca** y no cargan en el boot.
  Reproducción completa:

  ```bash
  bin/rails runner script/gate_a/run.rb          # -> tmp/gate_a_measurement.json
  bin/rails runner script/gate_a/walk.rb         # -> tmp/gate_a_walk.json (embudo de §3.1)
  bin/rails runner script/gate_a/led.rb          # -> tmp/gate_a_led.json
  bin/rails runner script/gate_a/sensitivity.rb  # barrido de constantes de §4.5
  GATE_A_PAGES=3 bin/rails runner script/gate_a/page.rb   # autopsia de cadenas de una página
  python3 script/gate_a/overlay.py 3 22 39       # dibuja las aristas sobre el PNG renderizado
  ```

  Ruta del PDF por `GATE_A_PDF`; por defecto la copia local de
  `~/Documents/Danebo/.../SEGURIDADES 1.1-1.pdf`. `overlay.py` espera los PNG en
  `tmp/gate_a_png/p-NN.png` (`pdftoppm -r 150 -png`).
- **Datos crudos (bajo `tmp/`, no versionados):** `tmp/gate_a_measurement.json` (98 páginas con
  geometría, aristas y motivo de rechazo por cadena), `tmp/gate_a_walk.json`, `tmp/gate_a_led.json`
- **Método de verificación visual:** cada arista derivada se **dibuja sobre la página
  rasterizada a 150 dpi** (`tmp/gate_a_png/overlay-NN.png`) y se compara con el cable realmente
  trazado. No se asumió nada: las 23 aristas se miraron una por una.

---

## 1. Resumen ejecutivo

| Medida | Valor |
|---|---|
| Aristas T1 emitidas en 98 páginas | **23** |
| Páginas con ≥1 arista | **22 / 98 (22,4 %)** |
| Páginas con `[]` | **76 / 98** |
| Aristas revisadas con visión | **23 / 23 (100 %)** |
| Aristas **correctas** | **19** |
| Aristas **incorrectas** | **4** (págs. 56, 61, 67, 97) |
| Precisión sobre el documento entero | **82,6 %** |
| Precisión en la muestra de 11 páginas / 10 secciones | **7/11 = 63,6 %** |
| Recall en esa muestra (aristas correctas ÷ relaciones que lee un humano) | **7 / 153 ≈ 4,6 %** |
| Páginas sin ninguna cobertura T1 | **76** (de ellas **58 son páginas de contenido**) |

**Lo que falla no es el umbral por poco: falla el supuesto.** Las cuatro aristas incorrectas no
son casos límite de tolerancia; son **tres modos de fallo estructurales** que el diseño de la
Fase 3 no contempla (§4). Y el recall del 4,6 % dice que T1, en este documento, no es un motor de
conocimiento: es un puñado de anclas. La consecuencia para la Fase 5 está en §7.

---

## 2. Aristas por página y total

23 aristas en 22 páginas. Las 76 restantes devuelven `[]`.

| Pág | Sección | `from` | `to` | Veredicto visual |
|---|---|---|---|---|
| 3 | ALJO | `FINALES` | `CONECTOR AI` | ✅ correcta |
| 3 | ALJO | `LIMITADOR` | `CONECTOR AI` | ✅ correcta |
| 11 | CARLOS SILVA | `Final carrera hidráulico (NO)` | `B6` | ✅ correcta |
| 12 | CARLOS SILVA | `PUERTAS MANUALES` | `BM2` | ✅ correcta |
| 14 | CARLOS SILVA | `STOP BOTO. CABINA` | `XP11` | ✅ correcta |
| 22 | CTA | `OBSTACULO` | `CN-112` | ✅ correcta ¹ |
| 25 | EDEL | `PTC MOTOR` | `M1` | ✅ correcta |
| 39 | EXCELSIOR | `CERROJOS EXTERIORES` | `HUE_1` | ✅ correcta |
| 44 | FAIN | `LIMITADOR` | `C300` | ✅ correcta |
| 52 | KONE | `BLOQUEO CABINA` | `CERROJOS EMBARQUE 2` | ✅ correcta ² |
| 56 | MP | `PISO SUPERIOR` | `CC2` | ❌ **INCORRECTA** |
| 61 | ORONA | `CERRADURAS EXTERIORES` | `B` | ❌ **INCORRECTA** |
| 63 | ORONA | `ALUMBRADO CABINA` | `J12` | ✅ correcta |
| 64 | ORONA | `LIMITADOR CONTRAPESO` | `J22` | ⚠️ correcta con reserva ³ |
| 67 | OTIS | `PUERTAS EXTE.` | `SE` | ❌ **INCORRECTA** |
| 76 | RECOBA | `LIMITADOR` | `C300` | ✅ correcta |
| 77 | RECOBA | `LIMITADOR` | `C300` | ✅ correcta |
| 78 | RECOBA | `LIMITADOR` | `C300` | ✅ correcta |
| 91 | SISTEL | `PTC MOTOR` | `X114` | ✅ correcta |
| 93 | THYSSEN | `BLOQUE C` | `LIMITADOR` | ✅ correcta |
| 94 | THYSSEN | `BLOQUE A` | `AFLOJACALES DOBLE DIFERENCAL` | ✅ correcta |
| 95 | THYSSEN | `BLOQUE A` | `STOP CUARTO POLEAS` | ✅ correcta |
| 97 | THYSSEN | `PUERTAS FRONTALES` | `PESTLLOS TECHO CABINA` | ❌ **INCORRECTA** |

¹ Corroborada por el propio texto de la página: la tabla LED imprime
`SERIE OBSTACULO (CN-112.SC Y CN-109.CC)`, y el cable azul derivado sale justamente del pin `SC`
de `CN-112`. Es la única arista del documento con confirmación textual independiente.

² Arista componente↔componente, no componente↔conector: el cable verde de `XLH8` recorre
`CERROJOS EMBARQUE 1` → `CERROJOS EMBARQUE 2` → `BLOQUEO CABINA`, y el tramo derivado es el
último. El contrato de la Fase 3 es etiqueta↔etiqueta, así que es válida.

³ El conductor magenta sale de `J22` (borne `P26`), **pasa por `LIMITADOR CABINA`** y termina en
`LIMITADOR CONTRAPESO`. La afirmación "`LIMITADOR CONTRAPESO` está unido a `J22`" es cierta —
comparten conductor— pero **se pierde el dispositivo intermedio**. Ver §4.4.

### Distribución por sección

| Sección (Apéndice E) | Páginas | Con arista | Aristas |
|---|---|---|---|
| ALJO | 2-7 | 1 | 2 |
| CARLOS SILVA | 8-14 | 3 | 3 |
| CTA | 15-22 | 1 | 1 |
| EDEL | 23-26 | 1 | 1 |
| ELECMEGON | 27-34 | 0 | 0 |
| ENIER | 35-36 | 0 | 0 |
| EXCELSIOR | 37-40 | 1 | 1 |
| FAIN | 41-46 | 1 | 1 |
| HATS_-_ASOCIADOS | 47-48 | 0 | 0 |
| INELCA | 49-50 | 0 | 0 |
| KONE | 51-53 | 1 | 1 |
| MP | 54-59 | 1 | 1 |
| ORONA | 60-65 | 3 | 3 |
| OTIS | 66-69 | 1 | 1 |
| RECOBA | 70-79 | 3 | 3 |
| SCHINDLER | 80-86 | 0 | 0 |
| SISTEL | 87-91 | 1 | 1 |
| THYSSEN | 92-98 | 4 | 4 |

**5 de las 18 secciones no reciben ni una sola arista.** Para las preguntas de esas marcas, T1 no
aporta nada.

---

## 3. Páginas con 0 aristas y por qué

### 3.1 El embudo completo, medido

Sobre las 98 páginas: **9 078 segmentos** (tras el corte de ruido de la Fase 2), **18 156**
extremos de segmento.

| Etapa | Cantidad | Se pierde por |
|---|---|---|
| Extremos de segmento | 18 156 | — |
| … en nudo de 3+ (bifurcación) | **9 706 (53,5 %)** | marcos, cajas dibujadas, tablas |
| … en nudo de 2 (codo interior de cadena) | 5 164 | no son finales |
| … extremos libres | **3 286** | — |
| Extremos libres que llegan a recorrer una cadena válida | 2 652 | 468 `>4 segmentos`, 166 bifurcación |
| **Cadenas** (cada una tiene 2 extremos) | **1 326** | — |
| … rechazadas por **unión T** | 639 (48,2 %) | el extremo toca el interior de otro segmento |
| … rechazadas por **extremo sin etiqueta impresa a ≤25 pt** | 563 (42,5 %) | §3.3 |
| … rechazadas porque **la cadena pasa junto a la etiqueta** | 46 | |
| … rechazadas por **dos etiquetas en rango** | 39 | |
| … rechazadas porque **el texto no es un nombre** | 13 | |
| … rechazadas por **bucle a la misma etiqueta** | **1** | §3.4 |
| **Emitidas** | 25 | |
| Tras deduplicar el par (una arista por par de etiquetas) | **23** | |

### 3.2 Clasificación de las 76 páginas sin arista

| Clase | Páginas | Cuántas |
|---|---|---|
| **Divisor sin líneas guía** (0 segmentos) | 2, 15, 23, 35, 41, 49, 51, 54, 60, 66, 87, 92 | 12 |
| **Divisor con sólo el adorno de esquina** (4-6 segmentos, 2 cadenas, ambas rechazadas por "pasa junto a la etiqueta") | 8, 27, 37, 47, 70, 80 | 6 |
| **Portada sin capa de texto** (40 segmentos, **0 palabras**: todo el rótulo es ráster) | 1 | 1 |
| **Contenido: cadenas formadas y rechazadas** | el resto | **57** |

Los 18 divisores son exactamente los del Apéndice E. **El Apéndice C decía "12 páginas con 0
segmentos (divisores)" y es correcto pero incompleto**: hay 18 divisores; 6 de ellos llevan un
adorno vectorial de 4-6 segmentos en la esquina. Ninguno tiene líneas guía. Que `[]` sea la
salida correcta en los 18 está confirmado.

### 3.3 El motivo dominante real: la regleta de bornes es un ráster

`extremo sin etiqueta impresa a ≤25 pt` es el 42,5 % de los rechazos y **el motivo dominante en
32 páginas**. La causa está medida y es siempre la misma: **la numeración de bornes del conector
está dibujada dentro de la foto/gráfico de la regleta, no en la capa de texto**.

Contraejemplo canónico, **página 17** (CTA – SR8P): un técnico lee ahí ~15 relaciones explícitas
con número de borne (`CERROJOS CABINA`→32/78, `LIMITADOR`→117/116, `TEMPERATURA MAQUINA`→85/84…).
T1 emite `[]`. De sus 25 cadenas, **20 mueren porque el extremo del lado del borne no encuentra
ningún texto**: los números `32 78 77 76 185 184 …` no existen en `words`; son píxeles.

Misma causa en 16, 18-21, 26, 28-33, 38, 48, 53, 69, 71, 74-75, 84, 88-90, 98.

### 3.4 Corrección a I-09: el bucle **no** es el mecanismo dominante

I-09 escribió que las líneas guía "son en su mayoría **bucles** … ambos extremos resuelven a la
misma etiqueta y no se emite nada". **Medido sobre las 98 páginas, la guarda de bucle
(`same_label_loop`) se dispara exactamente 1 vez** (página 98).

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

| Pág | Sección | Relaciones que lee un humano | Aristas T1 | Correctas | Incorrectas | Recall |
|---|---|---|---|---|---|---|
| 3 | ALJO | 12 | 2 | 2 | 0 | 17 % |
| 17 | CTA | 15 | 0 | 0 | 0 | 0 % |
| 22 | CTA | 15 | 1 | 1 | 0 | 7 % |
| 39 | EXCELSIOR | 14 | 1 | 1 | 0 | 7 % |
| 44 | FAIN | 11 | 1 | 1 | 0 | 9 % |
| 56 | MP | 19 | 1 | **0** | **1** | 0 % |
| 61 | ORONA | 16 | 1 | **0** | **1** | 0 % |
| 67 | OTIS | 12 | 1 | **0** | **1** | 0 % |
| 76 | RECOBA | 10 | 1 | 1 | 0 | 10 % |
| 91 | SISTEL | 14 | 1 | 1 | 0 | 7 % |
| 97 | THYSSEN | 15 | 1 | **0** | **1** | 0 % |
| **Total** | **10 secciones** | **153** | **11** | **7** | **4** | **4,6 %** |

**Precisión en la muestra: 7/11 = 63,6 %.** **Incorrectas: 4.** Ambas condiciones del gate fallan.

Se revisaron además las 12 aristas restantes del documento (págs. 11, 12, 14, 25, 52, 63, 64, 77,
78, 93, 94, 95): todas correctas, con la reserva de la 64. Sobre el documento entero la precisión
sube a **19/23 = 82,6 %** — sigue por debajo del 85 % y con 4 incorrectas.

### 4.2 Fallo A — el nombre del extremo es un fragmento de texto rotado (págs. 61 y 67)

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

### 4.4 Reserva — la serie con intermedio omitido (pág. 64)

`LIMITADOR CONTRAPESO -> J22` sale de un conductor que **atraviesa `LIMITADOR CABINA`**. La
guarda "la cadena pasa junto a la etiqueta" no salta porque el rótulo cae a la derecha del cable,
fuera de la holgura de una altura de línea. No es una arista falsa —el conductor es el mismo—
pero un técnico que reciba "LIMITADOR CONTRAPESO va a J22" **no sabrá que LIMITADOR CABINA está
en el mismo lazo**, que es justo el dato que importa cuando la serie está abierta.

Se cuenta como correcta a efectos del umbral y se registra como límite conocido.

### 4.5 Por qué el recall es del 4,6 % y no va a subir tocando constantes

Se midió el coste real de las dos constantes que I-09/I-10 señalaron como palancas, sobre las 98
páginas (`script/gate_a/sensitivity.rb`):

| Corte de ruido de Fase 2 | `MAX_CHAIN_SEGMENTS` | Aristas | Páginas |
|---|---|---|---|
| 20 pt (actual) | **4 (actual)** | **23** | **22** |
| 20 pt | 6 | 24 | 23 |
| 20 pt | 8 | 24 | 23 |
| 20 pt | 12 | 24 | 23 |
| 2 pt | 4 | **21** | 21 |
| 2 pt | 6 | 22 | 22 |
| 2 pt | 12 | 22 | 22 |

Dos resultados que corrigen el registro de hallazgos:

- **Subir el tope de cadena no compra nada.** De 4 a 12 segmentos: +1 arista en todo el
  documento. En la página 3, ni con tope 40 aparece una tercera arista.
- **Bajar el corte de ruido de la Fase 2 empeora la cobertura.** I-10 lo propuso como "el cambio
  más barato" para subir el recall. Medido: **23 → 21 aristas**, y en la página 3 **desaparece la
  arista `FINALES ↔ CONECTOR AI`**. El mecanismo que I-10 describió es correcto (esa arista se
  salvó porque el corte de ruido partió la polilínea en dos y el trozo de 1 segmento sí resolvió);
  su remedio está medido y es contraproducente: al reunir la polilínea entera, la cadena vuelve a
  chocar con la bifurcación y el tope de longitud.

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

| Medida | Valor |
|---|---|
| Páginas con tabla LED | **72 / 98** |
| Páginas **sin** tabla LED | 26 — las 18 divisoras, la portada, y 24, 28, 38, 39, 48, 53, 65 |
| Filas totales dentro de la caja de la tabla | 426 |
| Filas **bien formadas** (indicador + descripción de serie) | **272** |
| Filas de ruido (rótulos del dibujo que caen dentro de la banda) | 154, en 40 páginas |
| Páginas con extracción limpia (0 filas de ruido) | 32 |
| Variantes de cabecera | `LED`+`SERIE` · `LED`+`PLACA` · `LED`+`DESCRIPCION` |

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

**Límite conocido:** en 40 páginas la caja de la tabla se solapa en `y` con rótulos del dibujo o
con una segunda tabla lateral, y esas palabras entran como filas espurias (p. ej. p97 mete `CN32`,
`FINAL`, `STOP`, `REVISON`; p22 intercala las filas de la tabla `CONECTOR`/`SITUACION`).
Filtrarlas exige la coordenada `x` de la columna, no sólo la banda. **No es sangre para el Gate A**
— la tabla LED es texto plano que la ingesta actual ya lee bien — pero sí lo es para la Fase 8 si
alguien piensa generar `required` desde esta extracción sin limpiarla.

Volcado completo: `tmp/gate_a_led.json`.

---

## 7. Cobertura T1 y dimensionado de la Fase 5

| Población | Páginas |
|---|---|
| Total | 98 |
| Divisoras (T1 correctamente da `[]`, y T2 tampoco tiene relaciones que leer) | 18 |
| Portada (sin capa de texto; sólo T2 puede leerla) | 1 |
| **Páginas de contenido relacional** | **79** |
| … con ≥1 arista T1 | **22** |
| … con ≥1 arista T1 **correcta** | **18** |
| … **sin ninguna cobertura T1** | **57** |

**Lo que hay que dimensionar para la Fase 5 no son 18 páginas, son 79.** El plan escribía "en las
80 páginas donde ambos tiers aplican"; I-09 lo bajó a 22. La cifra buena para presupuestar T2 es:

- **T2 debe correr en las 79 páginas de contenido + la portada = 80.** En 57 es el **único** motor
  posible; en 22 T1 aporta un ancla y nada más.
- **T1 como verdad-terreno gratis para calibrar T2 (Gate B) son 19 aristas en 18 páginas.** No 80
  páginas, no 23 aristas. Y de esas 19, 3 (págs. 76/77/78) son la misma arista repetida en
  láminas casi idénticas, y otras 2 el mismo par `LIMITADOR↔C300` de la pág. 44. **El conjunto de
  calibración efectivo son ~15 pares distintos.** Es demasiado pequeño para medir precisión y
  recall de T2 con significancia; el Gate B tendrá que aceptar verdad-terreno humana además de T1,
  y este informe es el primer trozo de ella (153 relaciones leídas a mano en 11 páginas).
- **La palanca de cobertura que sí existe es la que I-09 dejó sin implementar:** el anclaje
  `images[].bbox` → etiqueta adyacente. Los dos modos de fallo de §4.3 son *bornes rasterizados*;
  un ancla foto→etiqueta no los arregla, pero sí ataca el 42,5 % de rechazos por "extremo sin
  etiqueta" del lado del **componente**. Es trabajo de la Fase 5, no de T1.

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

## 10. Veredicto y qué hay que resolver antes de reintentar el gate

**Gate A: NO SUPERADO. La Fase 4 no queda autorizada.**

| Condición | Exigido | Medido | |
|---|---|---|---|
| Aristas correctas en la muestra | ≥85 % | 63,6 % (7/11) | ❌ |
| Aristas correctas en el documento | ≥85 % | 82,6 % (19/23) | ❌ |
| Aristas incorrectas | 0 | **4** | ❌ |

Las cuatro incorrectas se agrupan en **dos defectos, ambos reparables y ninguno de ellos de la
Fase 4**:

1. **`PdfLayoutExtractor` no maneja texto rotado 90°** (Fase 2). Devuelve un `words` por glifo,
   con `bbox` invertido, y el orden de lectura sale al revés. Es la causa de las págs. 61 y 67, y
   contamina cualquier consumidor del contrato. **Hallazgo I-13.**
2. **`TopologyEdgeDeriver` confía en una unicidad que no puede comprobar** (Fase 3). Cuando el
   competidor legítimo de una etiqueta está rasterizado, la guarda de "exactamente una etiqueta
   en rango" da un falso positivo. Es la causa de las págs. 56 y 97. **Hallazgo I-14.**

Ambos son arreglos acotados, con contraejemplo medido y página de fixture identificada. Una vez
cerrados, el gate se puede reintentar **con el mismo guion y la misma muestra**, y esta vez con
verdad-terreno humana ya escrita (§4.1, §8) — que es la parte cara y ya está hecha.

Aunque se arreglen, hay que decidir a la vista de §7 **si 18-22 páginas con ~15 pares distintos
justifican el coste de las Fases 4 y 7 sólo por T1**. La recomendación de este informe es que
**no**: T1 debe entrar al contrato v8 junto con T2, no antes, porque por sí solo no mueve la
aguja de precisión que bloquea el piloto. Es una decisión humana, no del gate.
