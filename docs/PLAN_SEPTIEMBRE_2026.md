# Danebo — Plan de Septiembre 2026 (mes de construcción)

**Ventana:** jueves 3 de septiembre (regreso) → viernes 2 de octubre de 2026.
**Construcción efectiva:** lunes 7 de septiembre → viernes 2 de octubre.
**Convención de este documento y de toda la planificación de Danebo:** solo días hábiles. Los fines de semana no se planifican ni se cuentan como capacidad.
**Documento padre:** [PLAN_GENERAL_2026-08-07.md](PLAN_GENERAL_2026-08-07.md) · **Precede a:** piloto en terreno de octubre.
**Documento anterior de la serie:** [PLAN_AGOSTO_2026-08-07.md](PLAN_AGOSTO_2026-08-07.md).

Este es el único mes de construcción real del semestre. Es el mes que decide si hay algo que llevar a terreno en octubre.

---

## 0. La pregunta que este documento responde

> ¿Por dónde se empieza el módulo certificador: por la generación del PDF, o por la plantilla?

**Por ninguno de los dos.** Se empieza por el modelo de datos del borrador persistente, y el exportable va al final. El razonamiento está en la sección 3.4, pero la versión corta es: la generación de PDF es la parte con menos incertidumbre técnica y con más probabilidad de cambiar cuando un certificador real vea el borrador por primera vez. Construirla primero es invertir en lo único que se puede rehacer en un día, antes de resolver lo que puede tomar tres semanas.

Y la plantilla de la que se parte **no es** la de los hermanos. Ver sección 3.5.

---

## 1. Capacidad real del mes

Dos restricciones que hay que planificar, no descubrir a mitad de camino.

**Jet lag.** El regreso es el jueves 3 de septiembre después de tres semanas de viaje. La productividad de los primeros días es baja y no sirve para trabajo de implementación sostenida. Planificar construcción para el 4 de septiembre es planificar para una capacidad que no va a existir.

**Fiestas Patrias.** El 18 de septiembre cae viernes y el 19 sábado, así que del 17 al 21 no contesta nadie en Chile: ni Gonzalo, ni sus técnicos, ni un certificador, ni un prospecto.

| Ventana (solo días hábiles) | Días | Calidad de la capacidad | Uso |
|---|---:|---|---|
| jue 3 – vie 4 sep | 2 | Nula. Reentrada | Nada. No se planifica trabajo |
| lun 7 – vie 11 sep | 5 | **Degradada por jet lag** | Trabajo de decisión y diseño, no de implementación: triage de hallazgos del viaje, modelo de datos del borrador en papel, almuerzo con Gonzalo |
| lun 14 – mié 16 sep | 3 | Plena | Implementación del borrador persistente |
| **jue 17, vie 18, lun 21 sep** | 3 | Plena para trabajo solitario, **nula con terceros** | Fiestas Patrias: medición de COGS de voz y carga sintética |
| mar 22 – vie 25 sep | 4 | Plena | Captura de voz y transcripción visible |
| lun 28 sep – vie 2 oct | 5 | Plena | Estructura del informe, exportable, decisiones |

**Total: 22 días hábiles, de los cuales 2 se pierden en reentrada, 5 están degradados y 3 son de trabajo estrictamente solitario.** La capacidad efectiva de implementación es del orden de **15 días hábiles**, no de un mes.

Tres consecuencias directas:

1. **La primera semana se usa para lo que el jet lag sí tolera.** Diseñar el modelo de datos, decidir la arquitectura de conectividad en papel y conversar con Gonzalo son tareas de criterio, no de resistencia. Debuggear una integración de audio a las tres semanas de vuelo es la peor forma de gastar esos días.
2. **El almuerzo con Gonzalo va el martes 8 o miércoles 9 de septiembre.** No el 4 —es la conversación de mayor peso del trimestre y no se llega a ella recién bajado del avión— y no la semana del 14, porque roza Fiestas Patrias y porque de esa conversación salen los insumos de la decisión de precio.
3. **Con 15 días efectivos, el mes no cabe completo.** Por eso existe la escalera de recorte de la sección 2.1: el orden en que se sacrifica alcance está decidido de antemano, no improvisado el 28 de septiembre.

---

## 2. Prioridades del mes, en orden

| # | Entregable | Bloquea a |
|---|---|---|
| 1 | Borrador de informe persistente y resumible | Todo el módulo certificador |
| 2 | Dictado con transcripción visible y editable | Piloto de octubre |
| 3 | Estructura de informe según los 8 ítems de inspección | Exportable |
| 4 | Exportable marcado como borrador | Demo a certificador |
| 5 | Costo de voz medido | Decisión de precio |
| 6 | Decisión de conectividad | Liberación del piloto |
| 7 | Decisión interna de precio | Cotización de octubre |

Nada fuera de esta lista se construye en septiembre.

### 2.1 Escalera de recorte, decidida de antemano

Con 15 días hábiles efectivos el mes no cabe completo. El orden en que se sacrifica alcance se decide ahora, en frío, y no el 28 de septiembre bajo presión:

| Orden de recorte | Qué se saca | Por qué se puede sacar |
|---|---|---|
| 1º | Exportable del informe | Es una vista HTML con hoja de impresión. Es trabajo de una tarde y va a cambiar cuando un certificador real lo vea. Se puede hacer en octubre |
| 2º | Estructura completa de los 8 ítems | Con 3 o 4 ítems representativos se valida el flujo. El resto es trabajo mecánico |
| 3º | Conversación hands-free del mantenedor | Se apoya en la misma capa de captura de voz. Si la capa existe, agregarla en octubre son días, no semanas |
| **Nunca** | Borrador persistente y captura de voz con transcripción visible | Son el corazón del mes. Sin ellos no hay nada que llevar a terreno en octubre y el mes fue un fracaso |

**El insight que hace esta escalera posible:** la captura de voz —transcripción con confirmación visible y editable— es **una sola capa compartida** por el dictado del certificador y la conversación del mantenedor. Se construye una vez. Lo que distingue a los dos módulos es lo que va encima: el certificador necesita borrador persistente, estructura y exportable; el mantenedor no necesita nada de eso. Por eso el mantenedor es el más barato de agregar y el primero que se puede posponer sin perder trabajo.

---

## 3. El módulo certificador

### 3.1 Lun 7 – mié 16 sep — borrador persistente

Dos ventanas para un solo entregable, deliberadamente: **diseño en la semana degradada (7–11 sep), implementación en la semana plena (14–16 sep).** Decidir el modelo de datos es trabajo de criterio y tolera el jet lag; escribir y depurar migraciones no.

Es prerrequisito técnico, no una mejora de UX. Hoy `ConversationSession` es una sesión rodante única por usuario: se busca por `account_id + identifier + channel`, guarda como máximo los últimos 20 mensajes (`MAX_HISTORY`) y se destruye y recrea sola a los 30 días de inactividad (`EXPIRY_DURATION`). Es memoria de trabajo del RAG y está optimizada para eso.

Un dictado de certificación es otra cosa: 15–20 minutos, ítem por ítem, con fotos, que el certificador necesita poder **pausar, retomar, revisar y corregir antes de firmar.** Con la arquitectura actual, una llamada entrante, una pérdida de cobertura en el foso o simplemente cerrar la app a mitad de un ítem bota el trabajo sin recuperación posible.

**Alcance, deliberadamente chico:**

- Un modelo nuevo y persistente para el borrador de informe: hallazgos ordenados por ítem de inspección y ubicación, foto asociada, referencia normativa citada por el propio certificador, estado (en progreso / listo para revisión / enviado).
- **No se toca `ConversationSession`.** Sigue existiendo tal cual para su propósito actual. Es una ruta caliente de latencia y no debe ganar complejidad nueva.
- Una lista mínima de "mis informes": solo los borradores propios del certificador, ordenados por fecha, con botón de retomar. No un browser genérico de conversaciones.
- Aislamiento y borrado por cuenta, extendiendo la misma promesa de gobernanza ya ofrecida a Gonzalo: aislado por cuenta, borrable, sin entrenar modelos.

**Lo que sigue en backlog y no se construye:** historial de conversaciones general del mantenedor y registro diagnóstico por equipo. El roadmap pide diseñar ambos juntos y solo después de validar demanda; esta sección es una excepción acotada y justificada, no una autorización para adelantar el ítem completo.

**Derivación determinista de la norma aplicable.** Dada la fecha de recepción municipal definitiva que el certificador ingresa, el grupo normativo y las normas que aplican se derivan en Rails, sin llamada al modelo:

| Grupo | Recepción definitiva | Eléctrico | Hidráulico |
|---|---|---|---|
| 1 | Anterior al 24-10-2010 | NCh3395/1:2016 | NCh440/2:2001 |
| 2 | 24-10-2010 a 28-02-2017 | NCh440/1:2000 | NCh440/2:2001 |
| 3 | Posterior al 01-03-2017 | NCh440/1:2014 | NCh440/2:2015 |

Es una regla de calendario, no un juicio técnico. Hacerla determinista ahorra una llamada al modelo y elimina la posibilidad de que el sistema alucine una norma. **Límite:** presentar la norma aplicable es una ayuda documental derivada de una fecha; no es una evaluación de cumplimiento.

### 3.2 Mar 22 – vie 25 sep — captura de voz y transcripción

**Gate no negociable:** la transcripción debe ser siempre visible y editable antes de que el dictado se incorpore al borrador. No se libera ninguna versión de voz que envíe audio directo a generación sin que el usuario vea y pueda corregir el texto reconocido.

Es especialmente crítico en nombres de marca, modelos y códigos de error, donde un error de transcripción no corregido produce una respuesta técnica incorrecta con apariencia de autoridad.

**Restricción de usabilidad heredada de la entrevista al certificador**, que es la razón de ser de todo el módulo: él abandonó una herramienta previa de IA porque las tablas rígidas no se adaptaban a la estructura variable de los ascensores y registrar el piso ya era engorroso; tardó más que con lápiz y papel y volvió al papel. Consecuencia de diseño: **la captura es dictado libre y la estructura se aplica después.** No se construyen formularios extensos ni se obliga a clasificar durante la inspección.

### 3.3 Lun 28 – mar 29 sep — estructura del informe

Los ocho ítems de inspección, que vienen del material de CENTRAVE A.G. y son el esqueleto del modelo de datos:

1. Carpeta de Ascensores
2. Cabina
3. Espacio de máquinas
4. Contrapeso
5. Caja de elevadores
6. Pozo de ascensores
7. Puertas y cerraduras
8. Suspensión, cables y amarras

La salida es el **Informe Final**: hallazgos individuales por equipo, estado y recomendaciones según la norma aplicable. Junto con el Certificado de Conformidad que el certificador emite en el portal MINVU, forma parte de la Carpeta de Ascensores ("Carpeta Cero") que exige la Dirección de Obras Municipales.

**Red line del módulo, sin ambigüedad:** Danebo transcribe y estructura lo que un certificador autorizado dicta. No evalúa cumplimiento, no clasifica gravedad, no decide si un equipo aprueba o reprueba, y no firma. Todo documento exportado sale marcado como **borrador**.

### 3.4 Mié 30 sep — el exportable, y por qué va al final

**Por qué no se empieza por el PDF:**

- Es la parte de menor incertidumbre técnica del mes. Renderizar una estructura de datos conocida a un documento es trabajo determinista y acotado; no hay nada que descubrir ahí.
- Es la parte con más probabilidad de cambiar. La primera vez que un certificador real vea el borrador va a pedir cambios de formato, orden y nomenclatura. Todo lo invertido antes de esa conversación se rehace.
- No desbloquea nada. El dictado y el borrador persistente desbloquean el piloto; el PDF solo desbloquea la entrega final, que en octubre todavía es opcional.

**Cómo se construye, en su versión más barata que sirve:** una vista HTML del informe con hoja de estilo de impresión, sin dependencia nueva y sin costo de servidor. Un certificador puede revisarla en pantalla, corregirla y generar un archivo desde el propio dispositivo.

**Cuándo se agrega generación de PDF del lado del servidor:** cuando un certificador real pida un archivo que deba adjuntar a la Carpeta Cero. No antes. Es una decisión de una tarde y no justifica ocupar la capacidad de un mes con 18 días útiles.

### 3.5 De qué plantilla se parte, y de cuál no

**No se parte** de la plantilla de los hermanos. El informe de Climb (Caracas) es un **informe correctivo de mantenedor**: reporte de falla del cliente, narrativa de acción correctiva con fotos, presupuesto de mano de obra y condiciones de pago. Es un artefacto útil y sirve como plantilla del artefacto **mantenedor** y para el laboratorio de Venezuela. No es el formato del certificador chileno y no debe filtrarse a este módulo.

**Pero sí se aprovecha su mecánica, y eso cambia el orden de pruebas.** El informe correctivo del mantenedor y el informe del certificador comparten exactamente el mismo mecanismo: dictar → transcribir → confirmar → estructurar → borrador editable. Lo que difiere es el formato de salida y el marco regulatorio, no el motor.

Consecuencia práctica: **el bucle completo se prueba primero en Venezuela**, con usuario real, artefacto real y riesgo comercial cero, antes de que lo toque un certificador chileno. Es la única forma de validar el mecanismo central del módulo sin quemar el contacto de TAQUIÓN-CERT, que solo se recontacta cuando el dictado funcione (ver [la matriz](MATRIZ_DEMOS_PILOTOS_2026-08-07.md), sección 2.5).

Dos delimitaciones que van juntas con eso: ese uso **no se monetiza** —lo único que produce para ellos es ahorro de costos, y con eso basta— y **no cuenta como cliente ni como señal de mercado.** Ver [Plan General](PLAN_GENERAL_2026-08-07.md), sección 10.

**Se parte** de la estructura de la sección 3.3: ocho ítems de inspección, grupos normativos y Carpeta Cero. Fuentes: material de inspección de CENTRAVE A.G. y Registro Nacional de Ascensores del MINVU.

**Verificación pendiente que no bloquea la construcción:** descargar la nómina oficial de certificadores autorizados del portal MINVU y confirmar si existe un formato de informe prescrito o si cada certificador usa el suyo dentro de la estructura de la norma. Si es lo segundo —lo más probable— el módulo debe permitir que el certificador ajuste el orden y la nomenclatura de sus ítems, lo que refuerza la decisión de dejar el exportable para el final.

### 3.6 El dato económico que cambia el margen de este módulo

Las normas de la sección 3.1 son exactamente **cinco**, lo que corrobora la estimación de Gonzalo de "unas cinco normas" como universo relevante de certificación. A USD 5,32 por onboarding de un manual de 200 páginas —cifra conciliada contra factura real— **el corpus completo del módulo certificador cuesta del orden de USD 27, una sola vez, y sirve para todos los certificadores del país.**

Contrasta con el corpus de mantenedor, que es extenso, por marca, y crece con cada cliente nuevo. Consecuencia comercial directa: el módulo certificador tiene costo marginal de corpus prácticamente nulo, lo que sostiene el modelo de cobro por informe generado con un margen que no se degrada al agregar clientes. Ver [PRICING_Y_MERCADO_2026-08-07.md](PRICING_Y_MERCADO_2026-08-07.md).

---

## 4. Conversación hands-free del mantenedor

Segundo módulo de voz, con la misma infraestructura de RAG y trazabilidad debajo. Sin conflicto de interés con el anterior: un mantenedor no puede certificar y viceversa, por restricción legal.

Flujo: consulta hablada sobre lo que el técnico está viendo, respuesta hablada, sin interacción manual. Se apoya en el `ConversationSession` rodante existente y **no necesita el borrador persistente**, porque no produce un documento que alguien deba firmar.

Aplica el mismo gate de transcripción visible y editable de la sección 3.2.

---

## 5. Jue 17, vie 18 y lun 21 de septiembre — medición

Trabajo que no requiere a ningún tercero y que por lo tanto encaja perfecto en la semana muerta.

### 5.1 COGS de voz

Es el único costo nuevo que el modelo vigente no cubre, porque introduce un driver económico distinto: minutos de audio, no tokens de una pregunta puntual. Un informe dictado de 15–20 minutos es una unidad de costo completamente distinta a una consulta suelta.

**Protocolo:** cinco dictados simulados con ruido de fondo real (taller, calle, sala de máquinas si es posible) y veinte frases técnicas representativas — códigos de repuesto tipo KM, nombres de marca, códigos de falla tipo A32.4. Entrega dos cosas a la vez:

- Costo real de transcripción y de eventual respuesta hablada, por minuto de audio.
- **Tasa de error de reconocimiento sobre jerga técnica en español chileno.** Este es el verdadero riesgo de la tesis de voz, más importante que el costo mismo: un error no detectado en un nombre de marca o modelo lleva a una respuesta técnica incorrecta.

### 5.2 Carga sintética de una jornada tipo

Definir una jornada representativa —foto + consulta a manual + código de error + una abstención esperada— y correrla contra el pipeline real, leyendo el costo desde los logs de invocación exactos y no desde una estimación. Costo de la prueba: centavos.

Revalida el piso de precio de [SAAS_COST_MODEL_2026-06-12.md](SAAS_COST_MODEL_2026-06-12.md) para una mezcla de uso que ya no es solo texto.

### 5.3 Batería de generalización del benchmark

El set de regresión actual cubre series de seguridad, que son aproximadamente 20% de las fallas reales. Se agrega una batería sobre variador de frecuencia, sistema de puertas y códigos de error de consola, sin retirar la regresión existente.

Insumo disponible: las preguntas que fallaron o devolvieron "no hay evidencia suficiente" durante las pruebas de los ingenieros/técnicos de Gonzalo en agosto (si los manuales llegaron a tiempo), más la telemetría de la demo del 6 de agosto.

### 5.4 Instrumentación de utilidad y conteo de consultas — bloqueante para vender un cupo

La sesión de demo del 6 de agosto expuso dos huecos de instrumentación que hoy son inocuos porque no hay piloto pagado, y dejan de serlo en cuanto exista un cupo de consultas facturado ([MATRIZ_DEMOS_PILOTOS_2026-08-07.md](MATRIZ_DEMOS_PILOTOS_2026-08-07.md), sección 1.1.a):

- **`correct_answer`, `resolved` y `technician_helpfulness` llegan vacíos** al reporte de piloto, y la verificación queda en `REQUIRES_HUMAN_REVIEW` sin revisar. Sin esto no hay forma de medir cuántas consultas resuelven realmente un evento de mantención — el dato que calibra el cupo por equipo del [PRICING_Y_MERCADO_2026-08-07.md](PRICING_Y_MERCADO_2026-08-07.md), sección 5 (Modelo C). Entregable: un mecanismo mínimo de encuesta post-interacción, aunque sea una sola pregunta de sí/no, antes del piloto de octubre.
- **El conteo de mensajes de usuario no coincide con el de interacciones atribuidas.** La sesión del 6 de agosto mostró 8 mensajes de usuario contra 27 interacciones de consulta atribuidas en el mismo período. Si no se puede contar preguntas de forma confiable, no se puede vender ni verificar un cupo mensual de consultas. Entregable: reconciliar el conteo antes de que exista cualquier oferta con cupo.

Ninguno de los dos requiere trabajo de investigación; son ajustes de instrumentación sobre el pipeline ya existente, y encajan en la semana muerta igual que 5.1 y 5.2.

#### 5.4.a Decisión del 8 de agosto sobre cómo medir utilidad

Se evaluaron tres mecanismos y se ordenaron por costo de desarrollo, corrigiendo un supuesto equivocado: **inferir automáticamente "la misma pregunta con otras palabras" no es más barato que un botón, es más caro** — comparar dos consultas por significado exige embeddings o una llamada extra al modelo, es decir costo por consulta y una violación de las reglas del repositorio (minimizar llamadas a Bedrock, lógica determinista antes que LLM).

| Opción | Desarrollo | Qué entrega | Decisión |
|---|---|---|---|
| Lectura del dossier de auditoría post-sesión | **Cero: ya existe.** `PilotMetricsReport` con `include_raw_questions` entrega pregunta, respuesta, citas y chunks por interacción, y ya calcula reformulaciones rápidas (ventana de 10 minutos, heurística determinista sin embeddings), preguntas repetidas por hash y repetición de uso en días distintos | A escala de piloto —decenas de consultas— alcanza para ver patrones y llenar a mano `correct_answer` / `resolved` / `technician_helpfulness` | **Se adopta ahora.** Requiere `PILOT_AUDIT_CAPTURE=true` en producción ([PLAN_AGOSTO_2026-08-07.md](PLAN_AGOSTO_2026-08-07.md), sección 2.2) |
| Botón 👍/👎 | Mínimo: una columna booleana y dos botones. Alimenta directo el campo que hoy llega vacío | La única forma de feedback que un técnico con guantes va a usar; texto libre jamás | **Condicional:** solo si cabe en septiembre sin desplazar el módulo certificador, que es la prioridad del mes |
| Detección automática de reformulación semántica | El más caro de los tres | Una señal ruidosa | **No se construye** |

**Por qué la reformulación no se persigue como señal automática:** la propia demo del 6 de agosto lo mostró — las consultas repetidas en el mismo minuto eran pruebas de estabilidad del fundador, no confusión del usuario, y las repeticiones ante una abstención eran reintentos, no insatisfacción con una respuesta. Distinguir "reformuló porque la respuesta fue mala" de "preguntó algo relacionado" o "reintentó por señal débil en el foso" es exactamente el tipo de inferencia que se equivoca en silencio.

**Y la señal conductual más dura ya está gratis en la telemetría: repetición de uso en días distintos**, que la matriz de demos define como la más difícil de falsear y que no requiere ni botones ni embeddings.

**Lo que ningún botón reemplaza:** la entrevista posterior con el técnico. Tiempo de resolución del incidente, consultas por evento y tiempo ahorrado contra el método anterior solo salen conversando. El botón mide si una respuesta gustó; la entrevista mide si el producto cambió el trabajo, y es lo segundo lo que se necesita para decidir precio y para el pitch de noviembre.

**Una pregunta que se agrega a esa entrevista, del hallazgo de campo del 11 de agosto:** cuántas vueltas tomó dar con el problema, y si alguna se evitó. La respuesta de un contratista independiente estableció que las visitas por falla van dentro de la tarifa mensual del cliente, así que **la revisita evitada es la unidad de valor que el mantenedor reconoce como plata** — más que los minutos ahorrados en una consulta. Es la única métrica del piloto que puede convertir el argumento comercial de la sección 9.1 del documento de pricing en una cifra defendible, y se mide preguntando, no instrumentando. **Sube de prioridad el 11 de agosto:** la incidencia de fallas y las vueltas por falla quedaron **sin fuente asignada** —el único toque disponible con la fuente neutral se gastó en el ratio, que bloqueaba el precio— así que el piloto pasa a ser el lugar donde ese número se mide en vez de preguntarse.

**Y dos preguntas más para la misma entrevista, que salen del hallazgo de usuario del 11 de agosto:** cuántos años lleva el técnico en el rubro, y a quién le preguntaba antes de tener la herramienta. La fuente de campo sostiene que el técnico de ruta es hoy el eslabón de menor conocimiento porque se contrata mano de obra barata; **si eso es cierto, el piloto debería mostrar más consultas por técnico y de nivel más básico de lo que el modelo de cupos asume**, y esa es una consecuencia de costo, no solo de discurso. Es la forma de verificar en terreno una afirmación que hoy tiene una sola fuente.

---

## 6. Jue 1 – vie 2 de octubre — decisiones

### 6.1 Conectividad

Decidir entre captura local con sincronización diferida, o degradación a grabación simple sin procesamiento inmediato.

**No se libera el piloto de octubre sin esta decisión tomada y probada al menos una vez en condiciones de conectividad intermitente real.** Dos entrevistados independientes mencionaron sin que se les preguntara que "se va el internet" en fosos y salas de máquinas. Un dictado de 15–20 minutos interrumpido es una pérdida de trabajo mucho más costosa que una consulta de texto que se reintenta con un tap.

La ruta de sincronización diferida depende del borrador persistente de la sección 3.1 como destino al que reconectar.

### 6.2 Precio

Decisión **interna**, con tres insumos que a esta altura ya existen o están en camino: el costo unitario conciliado, el costo de voz medido en la sección 5.1, y las respuestas de mercado de los cuatro contactos del lunes 10 de agosto más el almuerzo de septiembre con Gonzalo (la pregunta de margen quedó abierta el 11 de agosto y se cierra ahí).

**Lo que ya entró el 11 de agosto y no hay que volver a preguntar:** la facturación al edificio es **por equipo y por mes**, con precio construido sobre número de paradas, zona y acceso, negociado con el administrador del edificio y **sin estandarización** de rango; y la utilidad del mantenedor está en los correctivos, repuestos y modernizaciones, no en la tarifa mensual, que además incluye visitas por falla ilimitadas y guardia 24/7 — con el matiz que puso la propia fuente: la mantención sí es rentable, pero no lo sería sin las reparaciones, y su función principal es retener al cliente. Consecuencia directa para esta decisión: el piso de precio no cambia —sale del COGS medido— pero **el encuadre con el que se presenta sí**, y el supuesto de CLP 40.000 de margen por equipo se usa como cota superior y no como dato. Ver [PRICING_Y_MERCADO_2026-08-07.md](PRICING_Y_MERCADO_2026-08-07.md), secciones 4.1 a 4.3 y 9.1.

**Y las dos cifras que faltaban también entraron el 11 de agosto, así que esta decisión ya no está bloqueada por terceros:**

| Insumo | Valor | Cómo se usa en la decisión |
|---|---|---|
| Ratio equipos/técnico | **60–84 equipos por técnico** | Es una **derivación** de una rutina de campo de 3–4 mantenciones diarias, no un ratio reportado. Ubica el Modelo C en la zona donde CLP 1.000 por equipo supera 70% de margen, y desmiente el supuesto propio de 1.000–2.000 técnicos activos |
| Cartera de una mantenedora mediana | **100–150 equipos** | Dato de campo sin hedge. El primer contrato pasa a facturar CLP 100.000–150.000/mes, el doble de la estimación anterior |

**Cómo se decide con esto sin sobreleerlo, y esta es la parte que importa el 7 de septiembre.** Las dos cifras vienen de **un solo informante** y una es derivada, así que se usan para fijar el número —que es una decisión interna y reversible— y **no** para construir una afirmación de mercado ante un tercero. Si Abel o Jesús responden antes del 7, su dato entra como verificación y, si contradice la banda, **manda el suyo**: administran nómina y saben cuántos técnicos cubren cuántos equipos. Si no responden, se decide igual con la banda y se registra que el precio se fijó sobre una fuente. **Lo que no se hace es esperar:** el criterio del 30 de septiembre exige precio decidido, y la variable ya no está vacía.

**Un tercer insumo que no es numérico y cambia el pitch más que el precio:** la misma fuente estableció que el técnico de mantención es hoy el eslabón de menor conocimiento del rubro, porque el empleador contrata mano de obra barata. El argumento de la cotización de octubre deja de ser ahorro de tiempo para un experto y pasa a ser **hacer rendir a la mano de obra que el cliente ya eligió contratar**. Va con la estrategia de costo que el comprador ya tomó, y de paso explica por qué el cupo de consultas incluido tiene que ser generoso: un usuario con menos base pregunta más, no menos. Ver pricing, sección 4.4.

| Segmento | Unidad |
|---|---|
| Mantenedor | Por equipo gestionado, con cupo de consultas incluido |
| Certificador | Por informe generado |
| Onboarding de manuales | Cobrado aparte, con su propio margen |

Se decide en septiembre para tener cifra lista al cerrar el piloto de octubre, y **no se revela.** Gonzalo calibra respondiendo preguntas de volumen y facturación del rubro; no participa de la decisión ni conoce el número. Desarrollo completo en [PRICING_Y_MERCADO_2026-08-07.md](PRICING_Y_MERCADO_2026-08-07.md).

### 6.3 Agendar el piloto

Fecha concreta de octubre en el calendario, no una ventana abierta. Alcance de Fase 1 sin cambios: solo manuales de fabricante, cero datos internos de la empresa de nadie, el cliente controla qué entra.

---

## 7. Almuerzo con Gonzalo — martes 8 o miércoles 9 de septiembre

Presencial y con tiempo. **Estado al 11 de agosto:** Gonzalo ya confirmó el almuerzo a la vuelta por mensaje; falta anclar día/hora (proponer esta franja durante la semana 2 del viaje). Va en esa franja por dos razones: son días de capacidad degradada por jet lag, y una conversación de criterio los aprovecha mejor que una sesión de implementación; y de aquí salen insumos de la decisión de precio, que no pueden llegar después de Fiestas Patrias. Agenda:

1. Resultados de las pruebas que hicieron sus ingenieros (o técnicos) durante el viaje — si los manuales llegaron y hubo visto bueno a tiempo; si no, el estado del corpus y el plan de pruebas.
2. Las preguntas de mercado, **incluida la de margen** que no respondió por mensaje el 11 de agosto, y las que no caben en un texto corto: cuántas empresas reales conoce, escaladas por técnico al mes, costo de perder un técnico senior, cuánto factura una mantenedora mediana por equipo, y **quién firma el cheque de software en una mantenedora** — el vacío más grande del descubrimiento, porque las ocho entrevistas cubren usuarios y validadores técnicos y ninguna cubre a quien decide el gasto.
   - **Pregunta nueva, y es la mejor de la lista:** qué proporción del ingreso de una mantenedora viene de correctivos y repuestos frente a la tarifa mensual. Viene del hallazgo de campo del 11 de agosto y tiene una ventaja táctica sobre la pregunta de margen — es estructura de negocio, no rentabilidad propia, así que no activa el incentivo de sombrear.
   - **Cómo se escucha la respuesta de margen, ya que la aritmética dejó de servir de filtro.** Una fuente neutral confirmó que la línea de mantención es delgada, así que "están apretados" ya no es señal de que esté negociando. Lo que sí contradiría el campo es "este negocio no deja utilidad": eso se anota y no se debate. Protocolo completo en [Plan de Agosto](PLAN_AGOSTO_2026-08-07.md), sección 3.2.1.
   - **Dos verificaciones que ahora se pueden hacer sin preguntar de frente, porque hay cifras contra las que escuchar.** Si menciona cuántos equipos lleva un técnico o cuántos tiene su empresa, se contrasta en silencio contra la banda de 60–84 equipos por técnico y contra los 100–150 equipos de una mediana (sección 6.2). **No se le lanzan esas cifras para que las confirme** — es exactamente la técnica prohibida por el Plan de Agosto, sección 3.2.2, y él es el único de los cuatro con incentivo para sombrear. La pregunta sigue siendo abierta: cómo se organiza la carga de sus técnicos.
   - **Y una que sí conviene preguntar directo, porque decide el conteo de usuarios y por tanto el precio:** si el técnico que atiende fallas es una persona distinta del que hace la ruta, o el mismo en modo reactivo. La fuente de campo confirmó que el modelo del "técnico universal" existió y **declaró no saber si sigue vigente**, así que queda abierto y no se deduce. Es una pregunta de organización, no de dinero, y él la responde sin resistencia.
3. Estructura de participación: qué aporta concretamente, con qué dedicación, si aporta capital o solo trabajo, exclusividad, si su empleador está en conocimiento, y qué pasa si se retira en el mes tres. Las preguntas completas están en el Plan General, sección 9.3.

**Este almuerzo es para preguntar, no para decidir.** El punto de decisión sobre su participación es **después del piloto de octubre**, que es la primera vez que va a existir evidencia de aporte comercial real y no solo entusiasmo. La definición sí tiene que estar zanjada antes de noviembre, porque ahí llega el primer contrato y su rol comercial se define antes de la venta, no durante. Calendario completo en el Plan General, sección 9.8.

**Verificación ya cerrada, y define el diseño del mes:** la nómina MINVU al 3 de junio de 2026 registra a ATLAGICH Ascensores SpA como **mantenedora, Rol 324**, y no como certificadora; Gonzalo no figura como certificador autorizado. Es auditor técnico de una mantenedora, tal como indicaba el registro de entrevistas. **Consecuencia:** el módulo certificador de este mes se diseña contra CENTRAVE y el Decreto 37, con Carlos Schwartz (TAQUIÓN-CERT) como validador de formato, y no se espera un design partner por este lado. Ver Plan General, sección 9.7.

**Reglas que siguen vigentes en esta conversación:** no pronunciar "socio" primero, no revelar precio, no nombrar fuentes de entrevistas, mostrar el qué y nunca el cómo. La asimetría —producto existente financiado con caja propia frente a un aporte futuro y contingente— se tiene clara, se usa para no aceptar una estructura mala, y no se le dice a él.

---

## 8. Cortes de decisión del mes

| Fecha | Tipo | Qué se evalúa |
|---|---|---|
| **mié 16 de septiembre** | Corte serio | ¿El borrador persistente está en pie? Cae justo antes de Fiestas Patrias, al cierre de la ventana de implementación. Si el borrador no funciona, se activa la escalera de recorte de la sección 2.1 en ese momento, con dos semanas por delante y no con dos días |
| **mié 30 de septiembre** | Corte duro | Se decide sobre **indicadores adelantados, no sobre resultados de piloto**: manuales de Gonzalo en uso voluntario por sus ingenieros/técnicos, piloto de octubre agendado con fecha concreta, costo unitario y de voz medidos, uso real en Venezuela con señales de adopción |

El corte serio se movió del 15 al 16 de septiembre a propósito: el 15 cae a mitad de la ventana de implementación y no habría nada concluyente que evaluar. El 16 es el último día hábil antes del feriado y coincide con el fin de esa ventana.

Regla que se mantiene: si la información llega antes, no se espera artificialmente.

---

## 9. Lo que no se hace en septiembre

- Módulo administrador de edificios. Es una idea registrada, no trabajo. Primero hay que validar el módulo certificador.
- Browser genérico de historial de conversaciones del mantenedor y registro diagnóstico por equipo. Siguen condicionados a validación de demanda.
- Generación de PDF del lado del servidor antes de que un certificador real pida un archivo (sección 3.4).
- Cualquier función de voz sin transcripción visible y editable.
- Ampliar el piloto de Gonzalo a usuarios o documentos nuevos si hay un fallo crítico sin resolver.
- Consultoría externa como flujo de caja. Descartada hasta el 1 de noviembre; compite por el recurso escaso —horas de fundador— exactamente en el mes de construcción (Plan General, sección 11).
- Cotizar a nadie antes de que la decisión de precio de la sección 6.2 esté tomada.

---

## 10. Criterio de éxito del mes

Al viernes 2 de octubre, el mes fue exitoso si:

**Mínimo exitoso — no negociable, es lo que el mes existe para producir:**

1. Un certificador puede dictar un hallazgo, cerrar la app, volver y encontrar su borrador intacto.
2. La transcripción se muestra y se puede corregir antes de incorporarse al borrador.
3. El costo por minuto de audio y la tasa de error de transcripción sobre jerga técnica están medidos.
4. La decisión de conectividad está tomada y probada una vez en condiciones reales.
5. El conteo de consultas es confiable y existe al menos una señal mínima de utilidad resuelta por el usuario (sección 5.4). Sin esto no se puede vender ni verificar un cupo.
6. El precio está decidido internamente.
7. Hay fecha de piloto en el calendario.

**Objetivo deseable — primeros en la escalera de recorte de la sección 2.1:**

8. Existe un exportable revisable, marcado como borrador.
9. Los ocho ítems de inspección están completos, no solo tres o cuatro representativos.
10. La conversación hands-free del mantenedor funciona sobre la misma capa de voz.

Los diez son verificables. Ninguno requiere que Gonzalo diga sí a una sociedad. Y la distinción entre los dos bloques es la que evita declarar fracasado un mes que entregó lo que importaba: **si al 2 de octubre están los siete primeros y falta el exportable, el mes fue un éxito**, porque el exportable es trabajo de una tarde en octubre y el borrador persistente no lo es.
