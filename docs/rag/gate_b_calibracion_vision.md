# ⛔ Gate B — Calibración de T2 (visión) contra T1 y contra lectura humana

**Documento:** `SEGURIDADES 1.1-1.pdf` (98 páginas) · **Modelo:** `claude-opus-4-8`, Messages API
directa · **Fase que lo produce:** Gate B de
[plan_conocimiento_visual.md](plan_conocimiento_visual.md) · **Fecha:** 2026-08-01/02

---

## 0. Veredicto

**NO SUPERADO en relaciones. SUPERADO en identidad de componente.**

| Umbral del gate | Medido | Resultado |
|---|---|---|
| Precisión de relaciones de T2 > 85 %, con 95 % de confianza | **88,2 %** (90/102), límite inferior Clopper-Pearson **81,6 %** | ❌ |
| — sobre láminas de regleta frontal con bornes numerados | 100 % (20/20), LI 86,1 % | ✅ |
| — sobre láminas de conectores pequeños dedicados | 100 % (17/17), LI 83,8 % | ⚠️ roza |
| — sobre láminas de regleta/conector denso con etiquetas apiladas | **81,5 %** (53/65), LI **71,8 %** | ❌ |
| Identidad de componente (campo no-relacional) | 100 % (38/38), LI **92,4 %** | ✅ |

**Consecuencia aplicada en código:** se ejecuta la degradación que el plan dejó escrita como
aceptable. T2 sigue corriendo y sigue aportando `documented_components`; **deja de emitir
relaciones**. Nuevo interruptor `INGESTION_VISION_TIER_RELATIONS_ENABLED` (apagado por defecto,
independiente de `INGESTION_VISION_TIER_ENABLED`). Todo `TOPOLOGY_EDGE` que llegue al cuerpo de un
chunk viene de T1. **Límite conocido del producto**, documentado en §9.

**Gasto real: $2,2216** de los $15 autorizados. La corrida se interrumpió antes de la iteración
final: la cuenta de Anthropic se quedó sin saldo (§8.3). El presupuesto **no** fue el límite.

---

## 1. Qué se midió y cómo

### 1.1 Conjunto de medición: 23 páginas, no 80

Unión de (a) las **11 páginas con verdad-terreno humana** del Gate A §4.1 (153 relaciones leídas a
mano) y (b) las **18 páginas donde T1 emite alguna arista** (19 aristas). Solape: 3 páginas.

```
3, 11, 12, 14, 17, 22, 25, 39, 44, 52, 56, 61, 63, 64, 67, 76, 77, 78, 91, 93, 94, 95, 97
```

Una pasada completa sobre las 23 costó **$1,4894** y produjo **193 relaciones** y **168
componentes**. Correr las 80 páginas T2 del documento habría costado ~$5,18 y no habría añadido
ni una relación juzgable: en las 69 páginas restantes **nadie puede decir si T2 acierta sin mirar
la lámina**, y ése es el recurso escaso de este gate, no el dinero.

### 1.2 Regla de juicio, fijada antes de contar

Cada relación se revisó **una a una contra la página renderizada a 150 dpi** (la misma resolución
que vio T2 y que vio el humano del Gate A), ampliando la zona del borne cuando la fila era densa.
Nunca contra otra salida del modelo.

- **Correcta** — un conductor dibujado une los dos extremos, directamente o a través de
  dispositivos intermedios **que la propia `evidence` nombra**. La segunda mitad no es un adorno:
  es la regla que el prompt de T2 se impone a sí mismo ("*If you can see intermediate devices on
  the same run, name them in `evidence`; never imply the run has only two elements*"), así que
  incumplirla es un fallo del modelo, no una severidad que invente este informe.
- **Incorrecta** — no hay conductor entre esos dos extremos, o un extremo está mal leído
  (borne vecino, etiqueta de otra fila, componente confundido con su propio número de pieza).
- **Defecto de evidencia** — el par es correcto pero la prosa miente sobre el color o el
  recorrido. Se cuenta aparte (§4.4); no resta precisión, pero es la señal que más correlaciona
  con los errores reales.

### 1.3 Las tres clases de "relación" que T2 emite

Descubierto al juzgar, y decisivo para leer cualquier porcentaje agregado: lo que T2 llama
`documented_connections` **no es una sola cosa**.

| Clase | Qué es | Ejemplo | n | Correctas | LI 95 % |
|---|---|---|---|---|---|
| (a) Transcripción borne↔etiqueta | qué nombre de hilo lleva impreso cada pin | `J12-1 ↔ P189` | 20 | 20 (100 %) | 86,1 % |
| (b) Conductor trazado | el borne o dispositivo A está unido a B por un cable dibujado | `32 ↔ CERROJOS CABINA` | 74 | 65 (87,8 %) | 79,7 % |
| (c) Lazo borne↔borne del mismo bloque | los dos extremos del mismo conector, unidos por una serie | `SC ↔ 37` (vía POLEA TENSORA y STOP FOSO) | 8 | 5 (62,5 %) | 28,9 % |

La clase (a) es fácil y sale perfecta; la clase (b) es la que el producto necesita y es la que
falla; la clase (c) es técnicamente cierta cuando lo es, y **operativamente inútil**: no nombra
ningún dispositivo, así que no responde a "¿a qué borne va el acuñamiento?".

**Un agregado que mezcle las tres favorece a T2 por composición**, no por acierto: en la
página 63, 15 de las 24 relaciones son de clase (a).

---

## 2. Precisión por tipo de lámina

El desglose que el gate exige, porque la muestra es deliberadamente desigual y el número agregado
lo esconde.

| Tipo | Páginas | n | ✔ | ✘ | Precisión | LI 95 % |
|---|---|---|---|---|---|---|
| **A. Regleta frontal, bornes numerados grandes, un cable por borne** | 17 | 20 | 20 | 0 | 100 % | **86,1 %** ✅ |
| **B. Conectores pequeños dedicados (2-3 polos, un dispositivo por conector)** | 97, 91, 77, 22 | 17 | 17 | 0 | 100 % | **83,8 %** ⚠️ |
| **C. Regleta/conector denso con etiquetas de hilo apiladas y cables largos** | 63, 93, 78, 76, 56, 25, 61, 67, 3, 39 | 65 | 53 | 12 | 81,5 % | **71,8 %** ❌ |
| **Total** | 15 páginas | **102** | **90** | **12** | **88,2 %** | **81,6 %** ❌ |

Detalle por página:

| Pág | Tipo | n | ✔ | ✘ | Errores |
|---|---|---|---|---|---|
| 3 | C | 1 | 0 | 1 | `10 ↔ 9`: dos redes distintas del bloque auxiliar unidas en un par |
| 17 | A | 20 | 20 | 0 | — |
| 22 | B | 2 | 2 | 0 | — |
| 25 | C | 3 | 1 | 2 | `20 ↔ SL` (SL sin hilo), `38 ↔ 39` (38 sin hilo) |
| 39 | C | 1 | 0 | 1 | `PTC MOTOR ↔ NTC 3D-5`: la etiqueta y el número de pieza del **mismo** componente |
| 56 | C | 4 | 3 | 1 | `109 ↔ PISO INFERIOR`: el rojo sale de **111** |
| 61 | C | 4 | 4 | 0 | los 4 son de clase (c) |
| 63 | C | 24 | 22 | 2 | `P29 ↔ CERRADURAS EXT.` (es P36), `P188 ↔ STOP REVISION` (es P32) |
| 67 | C | 5 | 5 | 0 | los 5 son de clase (a) |
| 76 | C | 5 | 4 | 1 | `SE5 ↔ CERROJOS EXTE.` (es SE7) |
| 77 | C | 1 | 1 | 0 | — |
| 78 | C | 6 | 4 | 2 | `SFH ↔ PUERTAS EXTE.` (es SE5), `SE6 ↔ CERROJOS EXTER.` (es SE7) |
| 91 | B | 1 | 1 | 0 | — |
| 93 | C | 11 | 9 | 2 | `CERROJOS EXT. ↔ 71` y `CERROJOS CABINA ↔ ZN`: cruzados (es 71↔CABINA, ZN↔EXTERIORES) |
| 97 | B | 14 | 14 | 0 | — |

### 2.1 El modo de fallo dominante: la celda vecina

**9 de los 12 errores son el mismo error**: T2 lee bien el nombre impreso y bien el dispositivo,
y **asigna el conductor a la celda equivocada de una fila de bornes**. `SE5` en vez de `SE7`,
`109` en vez de `111`, `P29` en vez de `P36`, `71` y `ZN` intercambiados. Nunca inventa un nombre
que no esté impreso; se equivoca de una a dos posiciones a lo largo de la regleta.

Esto es lo que hace que la degradación sea la decisión correcta y no una rendición: **el error no
se parece a una alucinación, se parece a un técnico mirando la lámina demasiado deprisa**, y
produce exactamente el tipo de dato que un técnico cablearía mal. Un `TOPOLOGY_EDGE` con el borne
vecino es peor que ningún `TOPOLOGY_EDGE`.

Los 3 errores restantes son de clase (c) o de confusión componente/número de pieza, y **sí** se
pueden arreglar con reglas de prompt (§8).

### 2.2 Por qué el tipo A sale perfecto

En la página 17 cada borne vive en su propia celda con el número impreso en grande y el cable
sale de un punto visible sobre ese número. No hay fila de etiquetas que alinear. T2 leyó las 20
relaciones, incluidos los bornes `32 78 77 76 185 184 85 84 75 74 34 73 33 72 71 70 117 116 17 16`
que **sólo existen como píxeles** dentro del ráster (I-15), y no falló ninguna.

La diferencia entre el 100 % del tipo A y el 81,5 % del tipo C no es de dificultad conceptual: es
de **resolución angular sobre la etiqueta**. Ver §10.

---

## 3. T2 contra T1: la verdad-terreno gratis no sirve, y se puede decir con un número

El gate se diseñó sobre la idea de usar las 19 aristas de T1 como verdad-terreno sin coste
humano. **Medido: no funciona, por una razón que no era la esperada.**

| Coincidencia de las 19 aristas de T1 en la salida de T2 | Cuántas |
|---|---|
| Par idéntico cadena a cadena | **2** (págs. 76 y 78, `LIMITADOR ↔ C300`) |
| Par idéntico tras quitar el número de pin a un extremo (`X114 1` → `X114`) | +2 (págs. 12 y 91) |
| No aparece de ninguna forma | **15** |

Dos causas, y las dos importan más que el resultado:

**(a) Granularidad distinta, no desacuerdo.** Donde T1 dice `PTC MOTOR ↔ X114`, T2 dice
`X114 1 ↔ PTC MOTOR`. T2 lee **el pin**; T1 lee **el conector**. No se contradicen: T2 es más
preciso. Pero son cadenas distintas.

**(b) Consecuencia directa sobre la política de conflicto.** `VisionTopologyExtractor#drop_traced`
descarta el par que T1 ya probó comparando cadenas normalizadas. Con esta granularidad,
**la deduplicación no se dispara casi nunca**: sobre las 19 aristas de T1 sólo habría bloqueado 2.
Si mañana se reactivaran las relaciones de T2 tal cual, producción emitiría el borde de T1 **y**
la variante pin a pin de T2 para la misma relación, y el chunk tendría dos registros de lo mismo
con dos redacciones distintas.

Y las 15 que no aparecen no son un fallo de T1: son páginas donde T2 leyó otra parte de la lámina
(pág. 44: T1 encuentra `LIMITADOR ↔ C300`, T2 emite 9 relaciones de otra regleta y ninguna de
ésa). **Los dos motores no compiten por la misma lámina; leen zonas distintas de ella.**

---

## 4. Qué ve T2 que T1 no puede ver — la pregunta que originó el Defecto 2

Respuesta empírica: **sí, y el margen es enorme, pero no en la dirección que se suponía.**

### 4.1 Relaciones dentro del ráster

Página 17: **T1 emite `[]`. T2 emite 20 relaciones, las 20 correctas.** Es el caso canónico de
I-15 (el 42,5 % de los rechazos de T1, dominante en 32 páginas, son extremos cuyo nombre vive
dentro del ráster de la regleta) y T2 lo resuelve entero. Página 97: T1 `[]`, T2 14 de 14
correctas. Página 56: T1 `[]`, T2 3 correctas de 4.

Sobre las 15 páginas juzgadas, T1 aporta 12 aristas y T2 aporta **90 relaciones correctas**.

**Sí: un lector con visión capta relaciones que el aplanado a texto destruyó.** El Defecto 2 era
real. Lo que este gate añade es la letra pequeña: las capta con una precisión que no llega al
umbral en el tipo de lámina más común del documento.

### 4.2 Identidad de componente — el campo que sí supera el umbral

38 identidades juzgadas contra la fotografía (págs. 17, 56, 63, 78, 93, 97): **38 correctas**,
límite inferior 92,4 %.

```
SOBRECARGA          → unidad de control de carga (módulo MICELECT MWR-4 con pantalla)
TEPERATURA CUARTO   → termostato rotativo de ambiente (dial CASEL)
TEMPERATURA MAQUINA → termistor NTC (dos patillas, marcado NTC 3D-5)
AMORTIGUADOR        → amortiguador de foso
IMP                 → display de siete segmentos
OBSTACULO           → riel detector de obstáculo
```

T1 **no puede producir ni una** de estas: no hay geometría de la que derivar "esto es un
termistor". Es capacidad nueva, no redundante, y es la que sobrevive a la degradación.

### 4.3 Agrupaciones semánticas

No medido. T2 no las emite como salida separada y el contrato v8 no tiene dónde ponerlas. Se deja
fuera de alcance en vez de inventar una medición.

### 4.4 Defectos de evidencia (no restan precisión, pero predicen el error)

En **6** de las 102 relaciones la prosa nombra un color que no es el del conductor seguido
(`P28 ↔ LIMITADOR CABINA` "conductor rojo" cuando P28 es gris; `73X ↔ STOP CUAR.POLEAS`
"conductor rojo" cuando es azul). **De las 12 relaciones incorrectas, la mitad venían acompañadas
de un color equivocado.** Es la señal barata: cuando T2 se inventa el color, suele haber seguido
el cable equivocado.

---

## 5. Cobertura, que no es precisión

Sobre las 11 páginas con verdad-terreno humana. **Estas cifras NO se mezclan con §2**: comparan
cuántas relaciones emitió T2 contra cuántas contó un humano, y las dos cuentas no siempre hablan
de las mismas relaciones (en la pág. 67 el humano contó 12 recorridos de dispositivo y T2 emitió
5 transcripciones pin↔etiqueta: cinco aciertos que no cubren ninguno de los doce).

| Pág | Relaciones que lee un humano (Gate A §4.1) | T1 | T2 emitidas | T2 correctas | Nota |
|---|---|---|---|---|---|
| 3 | 12 | 2 | 1 | 0 | |
| 17 | 15 | 0 | 20 | **20** | T2 encuentra **más** de las que contó el humano |
| 22 | 15 | 1 | 2 | 2 | |
| 39 | 14 | 1 | 1 | 0 | |
| 44 | 11 | 1 | 9 | sin juzgar | |
| 56 | 19 | 0 | 4 | 3 | |
| 61 | 16 | 0 | 4 | 4 | las 4 de clase (c) |
| 67 | 12 | 0 | 5 | 5 | las 5 de clase (a), 0 recorridos |
| 76 | 10 | 1 | 5 | 4 | |
| 91 | 14 | 1 | 1 | 1 | |
| 97 | 15 | 0 | 14 | **14** | |

No se publica un porcentaje de recall agregado **a propósito**: sumar la pág. 17 (donde T2 supera
el conteo humano) con la pág. 67 (donde acierta cinco cosas de otra categoría) produciría un
número que no significa nada. La lectura correcta es por página, y dice que la cobertura de T2 va
de **0 a >100 %** según el tipo de lámina — la misma partición del §2.

En las **69 páginas fuera de este conjunto, lo que T2 emita es cobertura no verificada.** No hay
verdad-terreno y nadie puede juzgarla sin abrir la lámina con visión. Ningún número de este
informe se extiende a ellas.

---

## 6. Coste real por página, medido

| | Medido aquí (23 páginas, prompt v1) | I-34 (3 páginas) |
|---|---|---|
| Media | **$0,0648** / página | $0,0675–0,0796 |
| Rango | $0,0391 (pág. 77) – $0,0965 (pág. 64) | — |
| Tokens de entrada | 132 574 (media 5 764) | ~5 400 |
| Tokens de salida | 33 058 (media 1 437) | ~1 700 |

Tarifa aplicada: `claude-opus-4-8`, $5 / MTok de entrada y $25 / MTok de salida, **API directa
siempre** (I-38: la llamada de visión sale por `ClaudeChunkingClient` antes del envío del batch,
así que el 50 % de descuento del Batch API cubre el chunking y no la visión).

**Proyección del documento entero:** 80 páginas T2 × $0,0648 = **~$5,18**. La estimación de I-34
($5,40) queda confirmada dentro del 5 %.

**Gasto real de este gate: $2,2216**
- corrida de humo, 1 página: $0,0833
- línea base v1, 23 páginas: $1,4894
- iteración v2, 10 páginas: $0,6489
- iteración v3: **$0** — no llegó a ejecutarse (§8.3)

---

## 7. No determinismo (refina I-35)

Dos corridas de la página 17 con el **mismo prompt v1**, con horas de diferencia: **20 relaciones
las dos veces, 17 idénticas, 3 distintas.** Y las 3 son la misma clase de decisión:

| Corrida 1 | Corrida 2 |
|---|---|
| `33 ↔ BOTONERA REVISION` | `33 ↔ ACUÑAMIENTO` |
| `72 ↔ BOTONERA REVISION` | `72 ↔ ACUÑAMIENTO` |
| `16 ↔ STOP FOSO` | `16 ↔ POLEA TENSORA` |

Las seis son **correctas**: `33`, `72` y `16` están en serie con todos esos dispositivos. Lo que
varía no es el acierto, es **cuál de los dispositivos de la serie elige nombrar como extremo**.

Esto precisa I-35 en dos direcciones:

1. **La varianza no toca la precisión.** No hay que inflar el tamaño de muestra por
   no-determinismo: las dos corridas puntúan igual.
2. **La varianza sí rompe el `RECORD_ID`.** Y ahora se sabe exactamente dónde: en las relaciones
   **en serie**, no en las directas. Las 17 relaciones directas fueron byte a byte reproducibles.
   Si algún día se reactivan las relaciones de visión, la huella idempotente no puede incluir el
   extremo lejano de una serie.

---

## 8. Iteración del prompt

### 8.1 v1 — línea base (`vision_topology_v1`, fp `4c1d0103d79c…`)

102 relaciones juzgadas. **88,2 %, LI 81,6 %.** Falla. Diagnóstico en §2.1.

### 8.2 v2 — "omite si la fila es densa" (`vision_topology_v2`, fp `0a8fbd6f98b0…`)

Cuatro reglas nuevas contra los tres modos de fallo: leer la celda por posición, **omitir la
relación si no se puede resolver una celda de su vecina**, prohibir el par borne↔borne del mismo
bloque, y prohibir confundir un componente con su número de pieza.

Medido sobre las 10 páginas donde se concentraban los errores (mismas páginas, mismo juez):

| | v1 | v2 |
|---|---|---|
| Relaciones emitidas | 89 | **66** (−26 %) |
| Correctas | 77 | 58 |
| Precisión | 86,5 % | **87,9 %** |

**La regla de omitir no compró nada.** +1,4 puntos de precisión (dentro del ruido) a cambio de un
cuarto de la cobertura. Arregló casos concretos —la pág. 39 dejó de emitir el falso
`PTC MOTOR ↔ NTC 3D-5`, la pág. 3 pasó a 2 de 2, la pág. 63 corrigió el intercambio P28/P29— y
rompió otros: la pág. 97 cayó de **14 relaciones correctas a 4**, la pág. 76 empeoró de 4/5 a 2/4,
y aparecieron extremos con formato nuevo (`J10-2 (P35B)`, o el índice de pin `1` en lugar de la
etiqueta impresa `75`), que es exactamente lo que el contrato v8 no puede tener: **el mismo
extremo escrito de dos maneras en la misma página**.

Conclusión de la iteración, que es un resultado y no una excusa: **el error dominante es
perceptivo, no instruccional.** Pedirle al modelo que se abstenga cuando duda no le enseña a
distinguir `SE5` de `SE7`; le enseña a callarse, y se calla también donde acertaba.

### 8.3 v3 — no medido (`vision_topology_v3`, fp `36f8c3bb3a8d…`)

Escrito conservando de v2 sólo lo que arregló una clase de error sin costar cobertura (nada de
par borne↔borne, un componente no es su número de pieza, una sola forma escrita por extremo,
ningún color que no se haya seguido) y **eliminando la cláusula de omisión**.

**No se ejecutó ni una llamada con este texto.** Al lanzar la medición, la API devolvió
`400 invalid_request_error: "Your credit balance is too low"` en las 10 páginas. El saldo de la
cuenta de Anthropic se agotó; el presupuesto de $15 del gate estaba al 15 %.

> ⚠️ **v3 es una hipótesis, no una versión medida, y está en el repositorio como texto activo.**
> Con las relaciones apagadas por defecto no cambia ningún `TOPOLOGY_EDGE`, pero sí cambia la
> prosa de `documented_components`, que tampoco está medida bajo v3. Quien reanude esto **mide v3
> antes de creerle nada**, sobre las mismas 23 páginas y con la misma regla de juicio de §1.2, y
> compara contra los números de §2 de este informe. La huella del prompt se registra en cada línea
> `vision_topology_page`, así que la atribución está garantizada.

---

## 9. Decisiones fijadas

### 9.1 Política de conflicto: **T1 gana siempre** — confirmada, con una advertencia

`VisionTopologyExtractor#drop_traced` se **confirma** tal como está: donde la geometría ya probó
un par, la arista determinista se queda y la lectura de visión del mismo par se descarta.

Pero §3 midió que **esa deduplicación casi no se dispara** (2 de 19), porque T2 nombra el pin y
T1 el conector. La política es correcta y a la vez casi inerte. Si algún día se reactivan las
relaciones de visión, hace falta además una normalización de extremo (`X114 1` → `X114`) antes de
comparar, o el mismo hecho llegará al chunk dos veces.

### 9.2 Extremos compuestos (hereda I-36): **se aceptan como convención documentada**

T2 emite `J10-3`, `J12-7`, `J23-1`: el conector y el número de borne existen impresos por
separado, la cadena unida no. Decisión: **se acepta**, con dos razones medidas.

1. Es la lectura **más precisa**, no menos: donde T1 dice `X114`, T2 dice de cuál de los tres
   pines se trata (§3).
2. Prohibirla obligaría a T2 a emitir el conector desnudo, que es exactamente la granularidad que
   ya tiene T1, y el tier dejaría de aportar nada nuevo en esos casos.

Queda registrado como límite: **el token `J10-3` no existe en el PDF**, así que ninguna búsqueda
literal del documento lo encuentra. Con las relaciones apagadas la decisión es hoy inerte; se
documenta para que la Fase 8 no la vuelva a abrir desde cero.

### 9.3 Degradación a campos no-relacionales — **aplicada**

La salida obligatoria que el plan había previsto para este caso, implementada, no sólo escrita:

- `IngestionVisionFlag.relations_enabled?` → `INGESTION_VISION_TIER_RELATIONS_ENABLED`,
  **apagado por defecto**, independiente del flag del tier.
- Con el flag del tier encendido y éste apagado: T2 rasteriza, recorta, llama, paga, devuelve
  `documented_components`… y **cero aristas**. El embudo sigue midiendo: las relaciones
  descartadas se cuentan en `rejections.relations_disabled_by_gate_b` de la línea
  `vision_topology_page`, así que cualquier corrida futura dice cuánta cobertura cuesta la
  degradación.
- Dos tests nuevos fijan las dos mitades: el defecto de producción (componentes sí, aristas no) y
  que el interruptor reactiva las aristas sin tocar el flag del tier.

### 9.4 Límite conocido del producto

> **Danebo no deriva relaciones de topología por visión.** Las relaciones entre dispositivos y
> bornes que el sistema cita provienen únicamente del trazado geométrico determinista (T1), que
> tiene precisión medida del 100 % sobre 19 aristas y una cobertura del 4,6 % de lo que un técnico
> lee en la lámina. El motor de visión aporta identidad de componente, no conexiones. Motivo: la
> precisión medida de las relaciones de visión (88,2 %, límite inferior 81,6 % al 95 % de
> confianza) no alcanza el 85 % exigido, y su modo de fallo dominante —asignar un cable al borne
> vecino— produce justo el error que un técnico cablearía.

---

## 10. La palanca que sí ataca el fallo medido (para quien reanude)

No es un prompt. Los 9 errores de celda vecina ocurren cuando la fila de bornes ocupa 40-60 px de
la página renderizada a 150 dpi, y **desaparecen al ampliar**: cada uno de ellos se resolvió sin
ambigüedad recortando esa zona a 300 dpi durante el juicio.

`PdfPageRasterizer` ya sabe recortar (`#crop`), y `VisionTopologyExtractor#build_crops` ya recorta
—pero sólo **imágenes pequeñas rotuladas**, nunca regletas: una regleta de bornes es un ráster
grande, no un `size_class: :small`. La ampliación que el juez humano necesitó para decidir es la
que el modelo no tuvo.

**Trabajo propuesto (Fase 5b, no ejecutado aquí):** detectar la fila de bornes como región y
mandarla como recorte a 300 dpi junto a la página completa, igual que ya se hace con los
componentes fotografiados. Es una hipótesis con una predicción falsable: debería mover el tipo C
y dejar el tipo A y el B donde están. Cuesta una pasada de 23 páginas (~$1,50) comprobarla.

---

## 11. Reproducir esta medición

```bash
# Corrida (INGESTION_VISION_TIER_ENABLED lo pone el propio script):
GATE_B_PAGES=3,11,12,14,17,22,25,39,44,52,56,61,63,64,67,76,77,78,91,93,94,95,97 \
GATE_B_OUT=tmp/gate_b_v1_baseline.json GATE_B_LABEL=v1_baseline GATE_B_THREADS=4 \
  bin/rails runner tmp/gate_b_run.rb

# Láminas para juzgar, a la misma resolución que vio el modelo:
pdftoppm -f 17 -l 17 -r 150 -png "…/SEGURIDADES 1.1-1.pdf" tmp/gate_b_png/p17
# y la ampliación de una fila de bornes concreta:
pdftoppm -f 78 -l 78 -r 300 -png -x 780 -y 990 -W 720 -H 560 "…" tmp/gate_b_png/z78_c200b
```

`tmp/gate_b_run.rb` pasa `traced_edges: []` a propósito: la política de conflicto se aplica en el
informe, no en la corrida, para que la misma salida sirva para medir T2 contra T1 (que necesita la
lectura cruda del par que T1 ya probó) y para mostrar qué guardaría producción (que lo descarta).

Artefactos: `tmp/gate_b_v1_baseline.json`, `tmp/gate_b_v2_iter1.json`, `tmp/gate_b_smoke.json`,
`tmp/gate_b_v3_iter2.json` (vacío, sin saldo) y sus `.log` con una línea `vision_topology_page`
por página —tokens, DPI, recortes, embudo de rechazos y huella del prompt.
