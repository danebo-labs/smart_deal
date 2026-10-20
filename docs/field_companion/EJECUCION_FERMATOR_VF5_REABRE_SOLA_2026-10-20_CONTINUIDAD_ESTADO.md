# Fermator VF5+: continuidad documental y estado explícito, 2026-10-20

Informe de un experimento local de generación. No reescribe los resultados de A–D. No declara corregida la ingesta, validado el reductor ni `EPISODIO_VALIDADO`. No se cambió código de producto, no hubo Retrieve, no se escribió la KB y no hubo push ni deploy.

## Veredicto

Ninguna condición pasa 2/2. El resultado es mixto: no alcanza para atribuir el fallo «observación visual → obstrucción descartada» a una sola de las dos intervenciones, ni a su suma.

Siguiente acción: dejar la ruta real como está. No incorporar el traslado de la continuación, no hacer que el reductor emita el estado de E2 y no añadir un filtro posterior ni otra variante de contrato.

## Evidencia de preparación

HEAD `c4e10b1a16f52e228d16bbe80c0d2b8956006651`. Al empezar, el único cambio local era el harness nuevo `script/field_companion/vf5_state_continuity.rb`. El trabajo previo en `tmp/` se conservó. El ledger no se reinició.

PDF `docs/field_companion/fuentes/VF5.pdf`, SHA-256 `be7a39a3490c92c8381cb883402760cb07d10b0a3beda5348bed22f72abedf72`.

La página PDF 12 cierra el ítem «La puerta se re-abre sola» con tres guiones: sensibilidad #54, fotocélula no activada, y ausencia de obstrucción mecánica. La página PDF 13 abre con el cuarto guion, sin encabezado propio:

> En caso que el problema persista, desconectar la fotocélula y volver a pulsar el botón de TEST. Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta.

En el prompt D-histórico del turno 1 esa frase está en el segundo resultado, debajo de aliases de otros escenarios (puerta que no abre, LED STATUS, fusibles) y separada del ítem padre. El ítem padre está en el primer resultado. No hay línea `Obs:`. Las tres observaciones del episodio quedaron dentro de `Goal:` y el ensamblado no imprimió `Obs:`. `Goal:` se dejó igual en las cuatro condiciones. La conversación reciente del turno 1 es solo `User:`; no hay respuestas previas del asistente. Las instrucciones que mencionan `assistant` se conservaron.

El control es el cuerpo enviado en `vf5-fidelity-D-historico-20261020T202806Z`, turno 1. SHA-256 del prompt `a3dc05933eaa46bfb7af798f41992660e438e6f3575e50973af4871184564754`. SHA-256 del body `3a0f1c55a52b0ce56b056488a9ec05541c36e018ab9169d4f741aa4d7522f25a`. Haiku `global.anthropic.claude-haiku-4-5-20251001-v1:0`, temperatura 0,1, 3000 tokens, sin `system`, una sola llamada de usuario. Las dos muestras de cada condición repiten ese prompt y esos parámetros. No se encadenaron respuestas.

E2 no reconstruye una línea `Obs:` que el turno 1 no tenía. Inserta dos líneas después de `Identifiers:`, que es el hueco donde el ensamblado habría escrito `Obs:`. Es una intervención diagnóstica con estado enriquecido. Un resultado de E2 no demuestra que el reductor actual produzca ese texto.

Respaldo de la lista de E2, leído en el PDF:

- Sensibilidad de reapertura #54: primer guion del ítem, página PDF 12. El pasaje no trae valor ni procedimiento de ajuste.
- Fotocélula: el mismo ítem dice «comprobar que la fotocélula no esté activada». La línea de estado usa «funcionamiento de la fotocélula» y lo ata a esa frase. No se importó el apartado 8.3, que es otro síntoma.
- Prueba de fotocélula desconectada y TEST: cuarto guion, página PDF 13, solo «en caso que el problema persista». El estado nombra la prueba y esa condición. No copia la conclusión de obstrucción como hecho de esta puerta.

Orden real: ronda 1 `D`, `E1`, `E2`, `E3`; ronda 2 los mismos. Ocho respuestas, un intento cada una, sin reintento.

## Matriz

Cumple cuenta para el pase. Parcial no. Pase de condición: 2/2 en los seis.

| Muestra | 1 Visual no cierra | 2 Prueba pendiente, con persistencia | 3 #54 sin causa probable | 4 SW4 no afirmado aquí | 5 LED fotocélula, no STATUS | 6 Sin medición, reparación, ajuste ni resultado inventado |
|---|---|---|---|---|---|---|
| D r1 | No | No | Cumple | Cumple | Cumple | No |
| D r2 | No | No | Cumple | Cumple | Cumple | No |
| E1 r1 | Cumple | No | Cumple | Cumple | Cumple | Parcial |
| E1 r2 | Parcial | No | Cumple | Cumple | Cumple | No |
| E2 r1 | No | Parcial | No | Cumple | Cumple | No |
| E2 r2 | No | Cumple | Cumple | Cumple | Cumple | Cumple |
| E3 r1 | No | Cumple | Cumple | No | Cumple | Parcial |
| E3 r2 | No | Cumple | Cumple | Cumple | Cumple | Parcial |

D 0/2. E1 0/2. E2 0/2. E3 0/2.

## Qué muestra cada respuesta

### Control D

Las dos muestras cierran la obstrucción con la observación y no nombran la prueba de la página 13.

D r1: «Ya lo has hecho visualmente sin encontrar nada.» El siguiente paso es #54. No aparece el TEST.

D r2: «Ya lo has verificado visualmente.» Tampoco aparece el TEST.

Las dos afirman que el LED encendido indica alimentación. Ese significado no está en los pasajes. D r1 añade «o si hay una falla en su señal». #54 queda como la comprobación que falta, no como causa más probable. SW4 se explica con el condicional del manual («Si la fotocélula se obstruye…») y el referente sigue siendo el LED de fotocélula. Ninguna entra en STATUS ni en fusibles.

### E1 — continuidad

La frase se movió al cuarto guion del ítem y se retiró del segundo resultado. Se añadió `[PDF_PAGE: 13]` en la línea siguiente. Esa marca no es texto del manual; evita que el fragmento quede como si fuera de la página 12. Aliases, FIELD_RECORDs, contrato, `Goal:`, `Query:` y el resto no cambian.

Las dos muestras nombran la prueba y la citan en [1], junto al ítem padre. Ninguna conserva «en caso que el problema persista». Las dos conservan el otro condicional: si la puerta no abre o cierra por completo, hay obstrucción.

E1 r1: «Ya lo observaste visualmente, pero el manual incluye un procedimiento adicional: desconectar la fotocélula y pulsar el botón TEST.» La observación queda como visual y la prueba sigue abierta. «puede indicar alimentación» es una inferencia no documentada, en condicional.

E1 r2: «Ya has descartado esto visualmente, pero el manual ofrece un test adicional.» La prueba sigue abierta, y el verbo es el de descarte aplicado a lo visual. Además: «Comienza por ajustar y comprobar la sensibilidad del potenciómetro #54». El ítem dice comprobar, no ajustar. También duda, sin respaldo del pasaje, si la desconexión «aplica igual» en modo esclavo.

Mejora parcial respecto del control: la prueba entra en la respuesta y la obstrucción no se cierra solo con «no observo». No es un pase. La condición de persistencia se pierde en las dos muestras.

### E2 — estado explícito

Solo se insertaron las dos líneas de estado. Los chunks no se movieron. En las dos respuestas la prueba sigue citada en [2], que es el resultado donde la frase continúa huérfana.

Plantilla estable en las dos: «has completado una (sin obstrucción mecánica visible)». La observación se cuenta como la comprobación hecha. Eso falla el criterio 1.

E2 r1 conserva la persistencia y presenta la prueba «para descartar una obstrucción mecánica». El manual dice lo contrario de ese propósito: si la puerta no completa el recorrido, debe haber obstrucción. Además llama a #54 «la comprobación prioritaria según la documentación» y cierra con «ajusta y verifica». El pasaje no prioriza causas ni manda ajustar.

E2 r2 también abre con la comprobación completada, y a la vez deja la prueba pendiente con su condición: «Si después de revisar los puntos anteriores la puerta sigue reabriendo, el manual indica desconectar la fotocélula y pulsar el botón de TEST. Si la puerta no se abre o cierra completamente en ese caso, habría obstrucción mecánica.» El sentido documental de la prueba, en esta muestra, sí se conserva. #54 no se presenta como causa más probable. SW4 queda en el condicional del manual.

Mejora parcial: la prueba y la persistencia aparecen, cosa que el control no hace. El estado enriquecido no impide «has completado una». Este estado fue escrito para el experimento. No es la salida del reductor.

### E3 — ambas

La misma plantilla «has completado una» de E2, en las dos muestras. La ganancia de E1 en el criterio 1 no se mantiene. La prueba queda pendiente y con persistencia, citada en [1] porque la frase ya está en el ítem padre.

E3 r1 aplica el ejemplo de esclavo a esta puerta: «Eso explicaría la reapertura automática.» También: «El LED encendido puede indicar alimentación.»

E3 r2 explica SW4 como comportamiento documentado, con «Si la fotocélula está obstruida…», sin afirmar que eso ocurre aquí. Añade «o si hay un fallo en el sensor», que el ítem no trae.

La combinación no supera a las intervenciones por separado. En el criterio 1 se parece a E2 y no a E1.

## Hipótesis y lectura

Hipótesis de partida: el descarte viene de la continuación separada de su ítem, de un estado que aplana «no observo», o de las dos cosas juntas.

Lo que las ocho respuestas permiten decir:

- El control, con contrato D y sin historial del asistente, sigue cerrando la obstrucción visual y omite la prueba. El turno 1 no necesita una línea `Assistant:` para fallar.
- Mover la continuación acerca la prueba al ítem. Las dos muestras de E1 la usan. También se les cae la condición de persistencia, y una de ellas manda ajustar #54.
- El estado explícito hace que la prueba salga como paso posterior «si persiste». Las dos muestras de E2 y las dos de E3 lo hacen. Las cuatro siguen contando la observación como comprobación completada.
- Juntar las dos intervenciones no corrige ese conteo y, en una muestra, presenta el mecanismo de SW4 como explicación de esta reapertura.

Eso es evidencia insuficiente para una causa exclusiva. No autoriza a corregir solo la continuidad en la ingesta, ni a tratar este estado como el que el reductor deba emitir.

## Limitaciones

- Ocho generaciones, dos por condición, temperatura 0,1. Una señal inicial. No es estabilidad.
- E2 y E3 contienen, en el estado, la orientación que se esperaba ver en la respuesta. Sirven para ver si el generador la respeta. No prueban que el reductor sepa construirla sin inventarla.
- El turno 1 no tenía `Obs:`. La inserción ocupa ese hueco y deja intacto el `Goal:` que ya incluye «no observo una obstrucción mecánica». El estado nuevo convive con ese goal aplanado.
- `[PDF_PAGE: 13]` no aparece en ninguna respuesta. E1 y E3 citan la prueba como [1]. E2 la cita como [2]. Ninguna dice un número de página. La marca evita duplicar la frase; no garantiza que la respuesta nombre la página 13.
- El cuarto guion no tiene FIELD_RECORD. E1 no añadió uno: el encargo prohibía tocar esos registros. Si el modelo se apoya en ellos, esta condición no lo prueba.
- Criterio 5 cumple en las ocho: el LED sigue siendo el de fotocélula y no aparece el escenario de STATUS ni fusibles. Eso no distingue las condiciones.
- No se repitió el intérprete ni Retrieve. No se ejecutó la conversación integrada.

## Saldo

Ledger `tmp/field_companion/vf5_generator_benchmark/assignment_spend.json`. Mismo archivo. No se reinició.

| | Intentos | Calculado USD | Desconocido USD | Reserva abierta USD |
|---|---|---|---|---|
| Antes | 47 | 0,690327 | 0,000000 | 0,000000 |
| Este experimento | 8 | 0,083501 | 0,000000 | 0,000000 |
| Después | 55 | 0,773828 | 0,000000 | 0,000000 |

Tope 96 intentos y US$4. Quedan 41 intentos y US$3,226172. La reserva de 15 intentos para una validación posterior sigue libre: por encima de esa reserva hay 26 intentos. Los ocho intentos se liquidaron con tokens. No hubo costo desconocido ni hold abierto. No hubo reintento.

Coste por muestra, en el orden de ejecución: D r1 0,010273; E1 r1 0,010242; E2 r1 0,010347; E3 r1 0,010416; D r2 0,010283; E1 r2 0,010212; E2 r2 0,010957; E3 r2 0,010771.

## Prompts, hashes, diffs y rutas

Run: `tmp/field_companion/vf5_state_continuity/vf5-state-continuity-20261020T211827Z/`.

Harness: `script/field_companion/vf5_state_continuity.rb`. Sin `VF5_STATE_CONTINUITY=1` solo escribe prompts y diffs. Con esa variable llama a Haiku y vuelve a consumir el ledger. Repetirla no reproduce gratis este run.

| Condición | Prompt SHA-256 | Body SHA-256 | Bytes |
|---|---|---|---|
| D | `a3dc05933eaa46bfb7af798f41992660e438e6f3575e50973af4871184564754` | `3a0f1c55a52b0ce56b056488a9ec05541c36e018ab9169d4f741aa4d7522f25a` | 28373 |
| E1 | `1a798b8092a27212d3aae5295f80b541aa11d0675ed3ac40317da028714e5528` | `6eb8ae6f2ba2e4b183fef0c8e5f858f4044d3cca563bef7e26f0b4d79762019e` | 28387 |
| E2 | `54ce1dfb498371586633d541dcb7c857ad4e5584a70b4e06ad1a1b67f15d1bc8` | `74abf8c5a70edd36663dbed94f1435488db9c696fd40db8b34408ce8e5314a2a` | 28834 |
| E3 | `63f88dd0b5520160040530b8a5882c8119173a6a3314174c443e81bfa69d97b1` | `18a76ea2f114887a88f719a6d20507e6c894e72220d6eae37abfb9ed38557278` | 28848 |

Las dos rondas de cada condición coinciden en esos hashes. Manifiesto: `manifest.json`. Resultados: `results.json`. Evaluación: `evaluacion.json`.

Diff E1, único cambio autorizado más la marca de página:

```diff
 – Comprobar que no hay una obstrucción mecánica en la puerta.
+– En caso que el problema persista, desconectar la fotocélula y volver a pulsar el botón de TEST. Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta.
+[PDF_PAGE: 13]

 [SEARCH_ALIASES: puerta no abre, puerta golpea, LED STATUS apagado, correa dentada, fusibles Fermator, encoder polea, motor intermitente, fuera de servicio]
-
-– En caso que el problema persista, desconectar la fotocélula y volver a pulsar el botón de TEST. Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta.
```

Diff E2:

```diff
 Identifiers: Fermator VF5+, modo esclavo
+Reportado por el técnico: El LED de fotocélula está encendido; no observo una obstrucción mecánica; no he revisado la sensibilidad de reapertura; SW4 está en OFF, modo esclavo; no hice mediciones ni reparaciones.
+Comprobaciones documentales pendientes de confirmar: sensibilidad de reapertura #54; funcionamiento de la fotocélula (comprobar que no esté activada); si el problema persiste, desconectar la fotocélula y volver a pulsar el botón de TEST.
 Not a manual.
```

E3 es la unión de esos dos diffs. Los archivos completos están en `diff-E1.diff`, `diff-E2.diff`, `diff-E3.diff` y `prompt-D.txt`, `prompt-E1.txt`, `prompt-E2.txt`, `prompt-E3.txt` dentro del run. Antes de llamar a Bedrock, revertir cada edición autorizada devolvió el control byte a byte.

## Respuestas completas

### D r1

```
# Orientación según el manual VF5

Tu situación es clara: **la puerta se reabre sola durante el cierre, el LED de fotocélula está encendido, y el equipo está en modo esclavo (SW4 OFF).**

Según el manual, cuando SW4 está en OFF (modo esclavo), **no hay movimientos de reapertura automáticos**. Las puertas solo responden a instrucciones del módulo de control del ascensor. Si la fotocélula se obstruye, la unidad envía una señal a la maniobra mediante la salida FOTOCÉLULA (terminales 36, 37, 38), y entonces la maniobra desactiva la señal de cerrar y activa la de abrir [3].

## Comprobaciones documentadas que faltan

El manual especifica tres verificaciones para el síntoma "la puerta se reabre sola" [1]:

1. **Comprobar la sensibilidad del potenciómetro de regulación de fuerza de reapertura (#54)** — Esta es la comprobación que explícitamente no has realizado aún.

2. **Comprobar que la fotocélula no esté activada** — Aunque el LED está encendido, el manual requiere verificar que la fotocélula no esté *activada* (obstrucción detectada). El LED encendido indica que el dispositivo tiene alimentación, pero no confirma si está detectando una obstrucción.

3. **Comprobar que no hay obstrucción mecánica en la puerta** — Ya lo has hecho visualmente sin encontrar nada.

## Próximo paso

**Debes revisar la sensibilidad del potenciómetro #54.** El manual no proporciona el procedimiento de ajuste ni los valores esperados (DATA_NOT_AVAILABLE), pero esta es la comprobación documentada que falta en tu diagnóstico. También verifica si la fotocélula está realmente detectando una obstrucción o si hay una falla en su señal.
```

### D r2

```
# Orientación según el manual VF5

Tu situación está clara: **puerta que se reabre sola durante el cierre, LED de fotocélula encendido, SW4 en OFF (modo esclavo), sin obstrucción mecánica visible.**

## Comprobaciones documentadas que faltan

Según el manual VF5, cuando la puerta se reabre sola, debes verificar tres puntos [1]:

1. **Sensibilidad del potenciómetro de regulación de fuerza de reapertura (#54)** — Esta es la comprobación que explícitamente no has realizado. El manual la lista como paso obligatorio ante este síntoma [1].

2. **Que la fotocélula no esté activada** — Aunque el LED está encendido, el manual requiere comprobar que la fotocélula no esté *activada* (es decir, obstruida). El LED encendido indica presencia de alimentación, pero no confirma si hay obstrucción en el haz [1].

3. **Ausencia de obstrucción mecánica** — Ya lo has verificado visualmente [1].

## Contexto del modo esclavo

Estás en modo esclavo (SW4 OFF). En este modo, **no hay movimientos de reapertura automáticos**. Las puertas solo responden a instrucciones del módulo de control del ascensor. Si la fotocélula está obstruida, la unidad VF5 envía una señal a la maniobra mediante la salida FOTOCÉLULA (terminales 36, 37, 38), y entonces la maniobra desactiva cerrar y activa abrir [3].

## Próximo paso

**Comprueba la sensibilidad del potenciómetro #54** de regulación de fuerza de reapertura. El manual no especifica el valor esperado ni el procedimiento de ajuste en los fragmentos disponibles (DATA_NOT_AVAILABLE para esos detalles), pero es el paso documentado que falta en tu diagnóstico.
```

### E1 r1

```
# Orientación según el manual VF5

Tu reporte indica que el LED de fotocélula está encendido, no hay obstrucción mecánica visible y SW4 está en OFF (modo esclavo). El manual documenta tres comprobaciones para la reapertura automática de la puerta [1]:

**Comprobaciones pendientes:**

1. **Sensibilidad del potenciómetro de regulación de fuerza de reapertura (#54)** — Esta es la primera verificación documentada. Debes comprobar la sensibilidad de este potenciómetro, que aún no has revisado según tu reporte [1].

2. **Confirmación de que la fotocélula no esté activada** — Aunque el LED está encendido, el manual requiere comprobar que la fotocélula no esté realmente activada (obstrucción detectada). El LED encendido puede indicar alimentación, pero no necesariamente una obstrucción [1].

3. **Confirmación de ausencia de obstrucción mecánica** — Ya lo observaste visualmente, pero el manual incluye un procedimiento adicional: desconectar la fotocélula y pulsar el botón TEST. Si la puerta no se abre o cierra completamente tras desconectarla, entonces hay obstrucción mecánica en la puerta [1].

**Contexto de tu configuración:**

En modo esclavo (SW4 OFF), la unidad no ejecuta reaperturas automáticas por sí sola. En cambio, cuando la fotocélula se obstruye, envía una señal a la maniobra del ascensor mediante la salida FOTOCÉLULA (terminales 36, 37, 38), y es la maniobra la que debe desactivar el cierre y activar la apertura [3].

**Próximo paso:** Comienza por comprobar la sensibilidad del potenciómetro #54, que es el primer punto documentado en el árbol de diagnóstico para este síntoma.
```

### E1 r2

```
# Orientación según el manual VF5

Tu reporte indica que el LED de fotocélula está encendido, no hay obstrucción mecánica visible y SW4 está en OFF (modo esclavo). El manual documenta tres comprobaciones para el síntoma "la puerta se re-abre sola" [1]:

**Comprobaciones pendientes:**

1. **Sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)** — Esta es la primera verificación documentada. No la has realizado aún [1].

2. **Confirmación de que la fotocélula no esté activada** — Aunque observas el LED encendido, el manual requiere comprobar que la fotocélula no esté activada. El documento no especifica qué resultado esperado distingue una activación de una no-activación [1].

3. **Obstrucción mecánica en la puerta** — Ya has descartado esto visualmente, pero el manual ofrece un test adicional: desconectar la fotocélula y pulsar el botón TEST. Si la puerta no se abre o cierra completamente tras desconectarla, entonces hay obstrucción mecánica [1].

**Contexto de tu configuración:**

En modo esclavo (SW4 OFF), el sistema no ejecuta re-aperturas automáticas. La fotocélula obstruida envía una señal a la maniobra mediante la salida FOTOCÉLULA (terminales 36, 37, 38), y la maniobra debe cambiar la orden de cerrar por la de abrir [3]. Sin embargo, el manual no documenta cómo el modo esclavo modifica el diagnóstico del potenciómetro #54 ni si la desconexión de fotocélula aplica igual en tu configuración.

**Próximo paso:** Comienza por ajustar y comprobar la sensibilidad del potenciómetro #54 según el procedimiento del manual.
```

### E2 r1

```
# Orientación según el manual VF5

Tu reporte indica que el LED de fotocélula está encendido y la puerta se reabre sola en funcionamiento normal. El manual documenta tres comprobaciones para este síntoma; has completado una (sin obstrucción mecánica visible) y quedan dos pendientes.

## Comprobaciones documentadas que faltan

**1. Sensibilidad del potenciómetro de regulación de fuerza de reapertura (#54)**  
El manual establece que debes comprobar la sensibilidad del potenciómetro #54 [1]. No has revisado este ajuste aún. Esta es la comprobación prioritaria según la documentación.

**2. Estado real de la fotocélula**  
Aunque el LED de fotocélula está encendido, el manual requiere comprobar que la fotocélula no esté activada [1]. El LED encendido no confirma por sí solo que la fotocélula esté obstruyendo; debes verificar su estado operativo.

## Contexto de tu configuración

Estás en modo esclavo (SW4 en OFF). En este modo, según el manual, no hay movimientos de reapertura automáticos: la puerta solo responde a instrucciones del módulo de control del ascensor. Cuando la fotocélula se obstruye, la unidad envía una señal a la maniobra mediante la salida FOTOCÉLULA (terminales 36, 37, 38), y entonces la maniobra desactiva cerrar y activa abrir [3].

## Próximos pasos según el manual

Completa las dos comprobaciones pendientes: ajusta y verifica la sensibilidad del potenciómetro #54, y confirma el estado de la fotocélula. Si el problema persiste después, el manual indica desconectar la fotocélula y volver a pulsar el botón de TEST para descartar una obstrucción mecánica en la puerta [2].
```

### E2 r2

```
# Orientación según el manual VF5

Tu reporte indica que el LED de fotocélula está encendido y la puerta se reabre sola en funcionamiento normal. El manual documenta tres comprobaciones para este síntoma; has completado una (sin obstrucción mecánica visible) y quedan dos pendientes.

## Comprobaciones documentadas que faltan

**1. Sensibilidad del potenciómetro de regulación de fuerza de reapertura (#54)**  
El manual establece que debes comprobar la sensibilidad del potenciómetro #54 [1]. No has revisado este ajuste aún. El documento no especifica valores de referencia ni procedimiento de medición (DATA_NOT_AVAILABLE).

**2. Estado real de la fotocélula**  
Aunque el LED está encendido, el manual requiere comprobar que la fotocélula no esté activada [1]. Un LED encendido no confirma por sí solo si la fotocélula está obstruyendo el cierre. Esta es una comprobación funcional distinta de la observación visual.

**3. Desconexión de fotocélula (si el problema persista)**  
Si después de revisar los puntos anteriores la puerta sigue reabriendo, el manual indica desconectar la fotocélula y pulsar el botón de TEST. Si la puerta no se abre o cierra completamente en ese caso, habría obstrucción mecánica [2].

## Contexto de tu configuración

Estás en modo esclavo (SW4 OFF). En este modo, según el manual, no hay movimientos de reapertura automáticos: la puerta solo responde a instrucciones del módulo de control del ascensor. Con fotocélula obstruida, la unidad envía una señal a la maniobra mediante la salida FOTOCÉLULA (terminales 36, 37, 38), y la maniobra desactiva cerrar y activa abrir [3].

**Próximo paso:** revisa la sensibilidad del potenciómetro #54 y confirma el estado funcional de la fotocélula antes de desconectarla.

---
[1] VF5.pdf — Troubleshooting: La puerta se re-abre sola  
[2] VF5.pdf — Troubleshooting: Desconectar fotocélula y pulsar TEST  
[3] VF5.pdf — Programación SW4 Esclavo
```

### E3 r1

```
# Orientación según el manual VF5

Tu reporte indica que el LED de fotocélula está encendido y la puerta se reabre sola en funcionamiento normal. El manual documenta tres comprobaciones para este síntoma; has completado una (no hay obstrucción mecánica visible) y te faltan dos.

## Comprobaciones pendientes

**1. Sensibilidad del potenciómetro de regulación de fuerza de reapertura (#54)**

El manual establece que debes comprobar la sensibilidad del potenciómetro #54 [1]. No especifica el procedimiento de ajuste ni los valores esperados (DATA_NOT_AVAILABLE), pero esta es la primera verificación documentada para reaperturas automáticas.

**2. Estado real de la fotocélula**

Aunque el LED está encendido, el manual requiere comprobar que la fotocélula no esté activada [1]. El LED encendido puede indicar alimentación, pero no confirma si está detectando una obstrucción real. Esta comprobación es crítica porque estás en modo esclavo (SW4 en OFF): en ese modo, si la fotocélula está obstruida, el VF5 envía una señal a la maniobra del ascensor para que desactive el cierre y active la apertura [3]. Eso explicaría la reapertura automática.

**3. Prueba de desconexión (si persiste)**

Si después de revisar #54 y la fotocélula el problema continúa, el manual indica desconectar la fotocélula y pulsar el botón de TEST. Si la puerta no se abre o cierra completamente en ese caso, habría una obstrucción mecánica en la puerta [1].

## Resumen de pasos

Revisa primero la sensibilidad del potenciómetro #54, luego verifica que la fotocélula no esté realmente activada (más allá del LED). Si el problema persiste, procede a la prueba de desconexión.
```

### E3 r2

```
# Orientación según el manual VF5

Tu reporte indica que el LED de fotocélula está encendido y la puerta se reabre sola en funcionamiento normal. El manual documenta tres comprobaciones para este síntoma; has completado una (no hay obstrucción mecánica visible), pero **faltan dos verificaciones críticas**:

## Comprobaciones pendientes

**1. Sensibilidad del potenciómetro de regulación de fuerza de reapertura (#54)**  
El manual especifica comprobar la sensibilidad de este potenciómetro como primer paso cuando la puerta se reabre sola [1]. No has revisado este ajuste aún. Esta es la comprobación que falta realizar.

**2. Verificar que la fotocélula no esté activada**  
Aunque observas que el LED de fotocélula está encendido, el manual requiere comprobar que la fotocélula no esté activada [1]. El estado del LED encendido no es suficiente; debes confirmar si la fotocélula está realmente detectando una obstrucción o si hay un fallo en el sensor.

**3. Prueba de desconexión (si el problema persiste)**  
Si después de revisar el potenciómetro #54 y verificar la fotocélula el problema continúa, el manual indica desconectar la fotocélula y volver a pulsar el botón de TEST. Si la puerta no se abre o cierra completamente en esa condición, habría una obstrucción mecánica en la puerta [1].

## Contexto de tu configuración

Tienes SW4 en OFF (modo esclavo). En este modo, no hay movimientos de reapertura automáticos; la puerta solo responde a instrucciones del módulo de control del ascensor [3]. Si la fotocélula está obstruida, la unidad envía una señal a la maniobra mediante la salida FOTOCÉLULA (terminales 36, 37, 38), y entonces la maniobra desactiva la señal de cerrar y activa la de abrir [3].

**Próximo paso:** revisa la sensibilidad del potenciómetro #54 y confirma el estado real de la fotocélula antes de proceder a la desconexión de prueba.
```
