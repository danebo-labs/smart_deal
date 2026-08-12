# Danebo — Mercado, unidad de cobro y pricing (2026-08-07)

**Estado:** fuente canónica de dimensionamiento de mercado y decisión de unidad de cobro.
**Relación con el modelo de costos:** [SAAS_COST_MODEL_2026-06-12.md](SAAS_COST_MODEL_2026-06-12.md) sigue siendo la única autoridad sobre COGS variable y piso de precio. Este documento no lo reemplaza: le pone encima la capa de mercado y de unidad de cobro que ese documento deliberadamente no cubre.
**Reemplaza:** la referencia de pricing genérica de mayo de 2026 (`Documento sin título.pdf`), que se conserva solo como registro de lo que el mercado chileno está acostumbrado a ver, no como ancla de precio de Danebo. La razón está en la sección 6.

**Última actualización de datos:** conteo oficial del Registro Nacional de Ascensores al 3 de junio de 2026 (sección 2), que reemplaza los rangos estimados de universo de empresas, y parámetro de conversión EUR agregado por consistencia con el Plan General.

**Actualización del 11 de agosto de 2026 — primera respuesta de campo a las preguntas de mercado.** Daniel (contratista senior independiente) respondió la pregunta de estructura y variabilidad de precios. Es el primer dato de campo que entra a este documento y **corrige un supuesto propio en la dirección incómoda**: la utilidad del mantenedor no vive en la tarifa mensual de mantención sino en los correctivos y repuestos, y esa tarifa arrastra una obligación de cobertura de fallas y guardia 24/7 que no se factura aparte. Secciones nuevas 4.1 y 4.2; consecuencias en §5 (supuesto de CLP 40.000 marcado como cota superior), §8 (estado de la pregunta y siguiente toque), §9 (cambio de denominador del pitch) y §11 (pendiente nuevo).

**Segunda y tercera respuesta del mismo día, y entre las tres el documento cambia de estado.** El segundo audio llegó sin pedirlo y agregó un tercer tramo de ingreso —las modernizaciones son "lo jugoso"— además de matizar el hallazgo anterior: la mantención sí es rentable, pero no lo sería sin las reparaciones, y su función principal es retener al cliente (§4.3). El tercero respondió la rutina diaria y **desbloquea las dos cifras que faltaban**: 3–4 mantenciones por día, de donde se deriva una banda de **60–84 equipos por técnico**, y una cartera de **100–150 equipos** para una mantenedora mediana (§4.4 y §3.1). Con eso el pendiente 1 pasa de bloqueante a verificable, la tensión interna del Modelo C se resuelve a favor del margen de 70%, y el ticket del primer contrato se duplica respecto de la estimación anterior. Trae además el hallazgo de posicionamiento más fuerte del registro: **el técnico de mantención es hoy el que menos conocimiento tiene, y por decisión de costo del empleador** (§4.4).

**Regla de procedencia que aplica a todo lo anterior, y no es negociable.** Cada afirmación de estas secciones está marcada como dato de campo, derivación, especulación declarada por la fuente, o razonamiento propio del fundador. **La afirmación de que esta fuente trabaja con varias mantenedoras es heredada del registro de entrevistas y no está verificada** (§4.1): nada que exija lectura cruzada del rubro se apoya en ella.

**Regla de proceso que no cambia:** el precio se decide internamente y no se propone a ningún prospecto. A Gonzalo y a cualquier otro actor de mercado se le **preguntan** precios y volúmenes; no se le muestra el nuestro. Este documento existe para que en octubre exista una cifra decidida, no para llevarla a una conversación de septiembre.

---

## 1. Parámetros de conversión usados

| Parámetro | Valor de planificación |
|---|---|
| UF | CLP 39.000 |
| USD | CLP 950 |
| **EUR** | **CLP 1.050** |
| 1 UF | ≈ USD 41 |

Todas las cifras de este documento usan estos valores. Si cambian materialmente, las bandas se recalculan; las conclusiones de unidad de cobro no dependen del tipo de cambio.

El parámetro EUR no interviene en ningún cálculo de pricing —Danebo cobra en CLP o UF y su COGS está en USD— y se consigna aquí solo para que los tres documentos financieros compartan una única tabla de conversión. Su uso es el gasto del viaje del Plan General, sección 6.0.

---

## 2. Universo de empresas (Registro Nacional MINVU, Ley 20.296)

**Conteo oficial, ya no estimado.** Esta sección trabajaba con un rango defendible de 170–220 mantenedoras y 40–60 certificadoras. Se contó la nómina oficial del Registro Nacional de Ascensores **al 3 de junio de 2026** y el rango se reemplaza por el dato:

| Especialidad | Vigentes (feb 2021) | **Vigentes (3 jun 2026)** | Variación |
|---|---:|---:|---:|
| Mantenedoras | 171 | **220** | +29% |
| Certificadoras | 40 | **56** | +40% |
| Instaladoras | 54 | 57 | +6% |
| **Total** | 265 | **333** | +26% |

Las cifras que se traían como "techo optimista del rango" resultaron ser el dato real: hay exactamente 220 mantenedoras y 56 certificadoras vigentes. El conteo se hizo sobre el correlativo de cada sección de la nómina, no estimando.

Dónde está el crecimiento: **mantención y certificación crecen 29% y 40% en cinco años, mientras instalación se estanca en +6%.** Eso es lo que se espera de un parque que dejó de expandirse rápido y entró en régimen de cumplimiento obligatorio: el trabajo recurrente crece y la obra nueva no. Los dos segmentos que Danebo ataca son los dos que crecen, y no por casualidad — crecen porque la Ley 20.296 los volvió obligatorios y periódicos.

Esto no cambia ninguna conclusión de unidad de cobro —el problema del modelo por empresa es estructural, no de conteo— pero **elimina la horquilla de todos los TAM que se calculaban sobre un rango**, y da una cifra citable en una postulación a fondos, donde un rango estimado se lee como falta de rigor.

Dos matices que importan para el go-to-market más que el número total:

- **Concentración geográfica.** La gran mayoría está en Región Metropolitana y Valparaíso. Un go-to-market presencial en Santiago cubre la mayor parte del universo direccionable.
- **Fragmentación de tamaño.** Una parte importante son microempresas de un técnico-dueño con correo gmail. No son compradoras de SaaS con proceso de decisión; inflan el conteo de empresas y no el de ingresos. Esto refuerza, por una vía distinta, la conclusión de la sección 5: contar empresas es la peor forma de dimensionar este mercado.

---

## 3. Parque de equipos y cumplimiento

| Dato | Valor |
|---|---|
| Parque nacional (ascensores, montacargas, escaleras mecánicas) | 44.000–45.000 equipos |
| Registrados / certificados (2019) | ~17.000, con 98% de aprobación |
| Cumplimiento estimado (hacia 2020) | ~60% |
| Certificaciones anuales en régimen | 22.000–30.000 |

**Periodicidad de certificación**, confirmada contra material de CENTRAVE A.G. (asociación gremial de certificadores): cada 2 años en edificios de destino mayoritario vivienda, cada 1 año en destino equipamiento. Para edificios con recepción definitiva posterior al 21-03-2016, la certificación cae en el mes de la recepción definitiva. Cada certificación genera exactamente un informe de inspección con hallazgos individualizados por equipo — el artefacto que el certificador entrevistado describió como el resultado central de su trabajo.

**Lectura del tercio informal.** Alrededor de un tercio del parque está fuera de registro o atrasado. No es mercado de hoy: es demanda latente de certificación que se activa por fiscalización, no por producto. Es también la pregunta de mercado más interesante para hacerle a Gonzalo, porque nadie publica ese número y él opera en el segmento.

---

## 4. Precios reales del servicio que factura el cliente

Esto es lo que cobran nuestros clientes potenciales, y es la base sobre la cual se justifica cualquier precio nuestro.

| Referencia | Valor |
|---|---|
| Mantención mensual por ascensor (mercado privado) | CLP 80.000–220.000 |
| Puerto Montt: 9 ascensores | CLP 12,8M/año ≈ **CLP 119.000/ascensor/mes** |
| Hospital Lonquimay | ≈ CLP 11M/año |
| Hospital de Linares | CLP 30M / 24 meses |

El rubro tiene código propio en Mercado Público (**72101506**), de modo que el volumen anual completo del segmento público es scrapeable si en algún momento se necesita la cifra exacta. No es prioridad ahora, y la razón está en la evidencia de entrevistas: en el mandante institucional entrevistado, el criterio técnico pondera del orden de 5–6% de la evaluación y históricamente gana el proveedor más barato. El segmento público es un mal primer cliente para un producto que se vende por calidad técnica.

**Corrección a un supuesto propio.** El supuesto interno anterior de 1–2 UF/mes por equipo para mantención (CLP 39.000–78.000) estaba en el piso o por debajo del rango real de mercado. El mercado cobra más de lo que asumíamos. Esto es una buena noticia para el pricing: la base de ingresos del cliente sobre la que se calcula nuestra participación es mayor.

### 4.1 Cómo se fija realmente ese precio — respuesta de campo del 11 de agosto

Primera respuesta a la pregunta de estructura y variabilidad enviada el lunes 10 (sección 8.1). La fuente es Daniel, contratista senior independiente. Respondió por audio, largo, sin repreguntas, y **declaró él mismo el límite de su conocimiento**: "nunca he entrado en ese ramo, lo que yo te diga es muy superficial". Eso ordena cómo se usa la respuesta: lo que dice sobre estructura de costos y operación vale mucho, porque lo vive; el rango de precios vale como corroboración de una fuente secundaria, no como fuente primaria.

**Advertencia de procedencia, y aplica a todo lo que este documento apoye en él.** La afirmación de que "trabaja con **varias** mantenedoras" **es heredada del registro de entrevistas y no está verificada**: no aparece en ninguno de sus audios del 11 de agosto. Sobrevivió una exposición sin corrección —el mensaje del lunes 10 se la dijo de frente y él contestó sin desmentirla— pero eso es corroboración débil, no confirmación. **Consecuencia práctica:** su respuesta vale con seguridad como la rutina de un contratista senior; **no se puede presentar como lectura cruzada de varias empresas** hasta que él lo confirme. La pregunta de tamaño de cartera del segundo toque (sección 11) está redactada de modo que la respuesta confirme o desmienta el supuesto sin tener que preguntarlo.

**Responde exactamente lo que se preguntó: el precio no está estandarizado, y la variabilidad tiene drivers deterministas.** No es "cada empresa cobra lo que quiere" — es una función de atributos conocidos del equipo y del edificio.

| Driver | Cómo opera, en sus palabras | Qué significa para Danebo |
|---|---|---|
| **Número de paradas** | "No vas a cobrar lo mismo por un equipo de 5 paradas que por uno de 20" | El cliente ya cobra por atributo del equipo, no una tarifa plana. Una línea por equipo en la factura de Danebo no le resulta un formato ajeno |
| **Zona** | Lo Barnechea, Las Condes y similares pagan más: poder adquisitivo del edificio y costo de llegar — distancia y bencina | El desplazamiento es dinero real del cliente, no solo tiempo. Una visita evitada vale más que una hora ahorrada |
| **Acceso** | Se evalúa si el edificio no tiene estacionamiento y hay que pagarlo afuera | Confirma lo anterior con un costo que nadie estima desde un escritorio |
| **Quién negocia** | "Aquí se mueve mucho lo que son los temas de los administradores" | La tarifa la aprieta el administrador del edificio. No es cliente de Danebo, pero es la razón de que esa línea esté comprimida — y de que no sirva como denominador del pitch |
| **Tipo de cliente** | "Normalmente la gente busca los clientes corporativos, esos son los que más valen" | Criterio de targeting del outbound MINVU: mantenedoras con cartera corporativa antes que las de cartera de comités de administración |

**Rango que dio sin que se le lanzara ningún número:** mantenciones "entre 80, 100, 150" mil pesos, con la salvedad explícita de que es memoria de hace tiempo. **Cae en la banda baja-media de los CLP 80.000–220.000 de Habitissimo y no la contradice.** Dos consecuencias operativas de que el número haya salido espontáneamente: la banda de esta sección deja de depender de una sola fuente secundaria, y **la técnica de rescate con estimado desviado prevista para él queda gastada** — ya entregó el dato sin anclaje, así que el segundo toque tiene que gastarse en algo nuevo (Plan de Agosto, secciones 3.3.1 y 3.7).

### 4.2 Dónde vive realmente la utilidad del cliente, y por qué cambia el pitch

Esto es lo más valioso de la respuesta y **no se preguntó**: la utilidad del cliente no está principalmente en la tarifa mensual. Lo dijo en dos movimientos. **Él mismo matizó esta lectura en un segundo audio el mismo día (sección 4.3), y ese matiz manda sobre lo que sigue: la mantención sí es rentable, pero no lo sería sin las reparaciones.**

Primero, la recurrencia es un activo envidiable —"casi nada exige mantención mensual si no son los ascensores"; ni un auto, ni las bombas, ni los sistemas de incendio, ni los portones— **pero viene atada a una obligación de cobertura que no se factura aparte:**

- La tarifa mensual fija incluye la atención de fallas: "si es un equipo que te falla, el técnico tiene que ir cinco veces para allá, y eso normalmente entra dentro de la mantención, a menos que haya que hacer algún correctivo".
- Hay que garantizar guardia. La atención normal llega hasta las 22:00 y después se atienden atrapamientos y emergencias, con técnicos nocturnos.

Segundo, la utilidad aparece en otra línea: **"a esos 100 equipos hay que cambiarle piola, hay que cambiarle motor, hay que cambiarle botón… eso es lo que hace que el negocio sea relativamente rentable."** Y sobre la tarifa sola: "no te da mucho para cubrir una nómina". Su resumen del negocio fue una corrección directa al encuadre del fundador: **"no es tan negocio redondo como tú crees."**

**Tres consecuencias, y las tres mueven documentos:**

1. **El supuesto de CLP 40.000 de margen por equipo sobre la mantención queda marcado como probablemente alto** (sección 5, tabla de resistencia del Modelo B). Si la tarifa mensual cubre nómina, visitas ilimitadas por falla y guardia nocturna, el margen de *esa línea* es delgado. El margen del cliente hay que leerlo sobre **ingreso total por equipo: mantención + correctivos y repuestos.** La tabla no se recalcula todavía porque falta la proporción correctivo/mantención, que es el pendiente nuevo de la sección 11.
2. **El encuadre de venta cambia de denominador, no de lógica.** Presentar CLP 1.000 como "0,45%–1,25% de la mantención" es correcto aritméticamente y frágil frente a alguien del rubro, porque sabe que esa línea es la comprimida por el administrador. Contra el ingreso total por equipo el porcentaje es menor y el argumento no se apoya en la línea débil. La sección 9 se reescribe con esto.
3. **Aparece el argumento de valor más fuerte que se ha tenido, y no es ahorro de horas.** Si las vueltas por una falla que no se resuelve entran dentro de la tarifa, cada revisita es margen destruido con bencina y estacionamiento pagados por el cliente. Un asistente que ayude a dar con el problema en menos vueltas no "ahorra tiempo": **defiende el margen de la tarifa mensual, que es justamente lo que las revisitas se comen, y libera al técnico para los correctivos, que es donde el cliente factura.** Y el turno nocturno —técnico solo, sin jefe técnico disponible, con gente atrapada— es el momento de máximo valor de un asistente documental y un escenario concreto para el piloto de octubre.

**Lo que esta respuesta no da, y hay que no inventarlo:** cuántas revisitas tiene una falla típica, qué proporción del ingreso viene de correctivos, y cuánto de eso es reducible con mejor acceso a documentación. Sin esos tres números el argumento es una hipótesis bien fundada, no una cifra defendible.

### 4.3 Segundo audio del 11 de agosto — el matiz que él mismo puso, y la escalera de ingreso completa

Llegó **sin que se le pidiera**, minutos después del agradecimiento de cierre, explicando el motivo de la brevedad anterior: "estaba en un foso". Que un informante amplíe por iniciativa propia es la señal más fuerte de disposición que se ha recibido de cualquiera de los cuatro contactos.

**El matiz, textual, y corrige la sección 4.2 en un punto:** *"Lo que es el mantenimiento preventivo y correctivo, yo creo que se significa más de tener el cliente como tal… porque si es verdad que es rentable, pero si no hubiera reparaciones, no."* Es decir: **la mantención no es una línea que pierde, es una línea que se sostiene solo en conjunto con las reparaciones.** Su función principal es **tener el cliente** — el contrato es el vehículo de retención que da acceso al equipo donde después se factura lo demás. La formulación fuerte de 4.2 ("es donde cubre nómina") queda como lectura del fundador; **la del propio informante es más precisa y es la que se usa.**

**Aparece un tercer tramo de ingreso que no estaba en ningún documento:** *"sobre todo cuando vienen las modernizaciones, hacer reparaciones grandes, cambios de cables, ese tipo de cosas son bastante rentables."* La escalera completa queda así, y **no es un supuesto: los tres tramos y su orden salen de sus palabras.**

| Tramo | Función económica | Evidencia |
|---|---|---|
| Mantención mensual | Retener al cliente y dar acceso al equipo. Rentable solo en conjunto | "se significa más de tener el cliente como tal" |
| Correctivos y repuestos | Rentabilidad recurrente: piola, motor, botón | "eso es lo que hace que el negocio sea relativamente rentable" |
| Modernizaciones y reparaciones grandes | **Lo más rentable.** No es recurrente, es por evento | "bastante rentables… ahí es donde está lo jugoso del tema" |

**Y la utilidad escala con la cartera, no con la tarifa:** *"entre más equipos tengas, más reparaciones hay al mes… esas reparaciones se van haciendo mayor."* Consecuencia directa para el pricing: **el valor de la herramienta escala con la misma variable que la utilidad del cliente (equipos bajo contrato), lo que refuerza el Modelo C por equipo** — el precio crece exactamente donde crece el beneficio del cliente, sin tener que justificar nada.

**El stack de costo fijo que enumeró, y contra el que compite un precio por equipo:**

- Uno o dos vehículos.
- Técnico de mantención, y "cuando son rutas largas, uno o dos técnicos de mantención que las cubren".
- Un técnico saca fallas.
- Pago de guardias nocturnas y de fin de semana a ese mismo técnico: "aquí es exigente".
- Herramientas.

**Dato de calidad de llamada nocturna, y es un hallazgo de producto:** antes llamaban "a las 10, 11 de la noche porque se apagó una lámpara, dejaron las luces de cortesía encendidas". **La guardia se consume en llamados banales**, no solo en atrapamientos. Un asistente que resuelva ese tipo de consulta en el canal del conserje o del técnico ataca costo de guardia, que es costo fijo pagado. Añade que "ha bajado un poco por la inseguridad" — la frecuencia nocturna actual no se puede suponer a partir de esa anécdota.

**Tres cosas que este audio deja abiertas, y se registran abiertas:**

1. **El "saca fallas" aparece como línea propia del stack de costo.** La entrevista con Gonzalo indica que es **el mismo técnico de mantención en modo reactivo**, y la lectura del fundador —**razonamiento propio, no dato de campo**— es que el nombre existe sobre todo como distinción administrativa para el pago ("monto por falla" en la boleta), porque dividir el pago entre más personas no le conviene a nadie. Daniel lo enumera aparte pero también dice "a ese mismo técnico tienes que pagarle guardias", lo que es compatible con una sola persona. **Conflicto no resuelto y no se resuelve por deducción**: define si el ratio equipos/técnico se cuenta sobre una o dos personas, así que se cierra con Abel o Jesús, que administran nómina.
2. **Usó "100 clientes" y "100 equipos" de forma intercambiable** en el primer audio. **Hipótesis, no conclusión:** en su experiencia el cliente típico es un edificio con un ascensor, lo que ubicaría su punto de vista en el segmento residencial pequeño. La pregunta de tamaño de cartera del segundo toque (sección 11) la confirma o la descarta sin preguntarla de frente.
3. **Cuánta capacidad de ruta se come la atención de fallas.** Es lo que reconcilia el ratio con la rutina diaria, y es la primera pregunta del segundo toque.

### 4.4 Tercera respuesta del 11 de agosto — la rutina diaria, y el primer dato que permite derivar el ratio

Respuesta al segundo toque (Plan de Agosto, sección 3.8). **Es la que desbloquea el pendiente 1 de este documento**, y trae además el hallazgo de posicionamiento más fuerte recibido hasta ahora.

**Lo que dijo, textual y separado por nivel de certeza:**

| Dato | Textual | Cómo se usa |
|---|---|---|
| **Mantenciones por día** | "normalmente un técnico hace entre tres y cuatro mantenimientos diarios, dependiendo… a veces es como mucho, pero es lo que se maneja" | **Dato de campo.** Con el detalle de la forma del día: "dos ascensores en la mañana en un edificio y dos otros en la tarde" |
| **Excepción de edificio alto** | "hay edificios que son muy altos y tienen tres ascensores, y ahí pasa todo el día" | Techo real: la ruta se mide en ascensores, no en direcciones |
| **Cartera de una mediana** | "las empresas así medianas normalmente tienen 100, ciento y tanto de ascensores" | **Dato de campo**, sin hedge. Va a la sección 3.1 |
| **Cartera de una multinacional** | "me imagino que esas ya tienen como 1.000 equipos" | **Especulación declarada.** Orden de magnitud, no dato |
| **Técnico universal** | "antes existía algo como lo que tú dices, que había un técnico universal que tenía una ruta y ahí mismo sacaba las fallas de su ruta. Algunas empresas lo aplicaban; **en la actualidad, no sé**" | Cierra parcialmente el conflicto del saca fallas: el modelo existe y tiene nombre, pero **él declara no saber si sigue vigente.** No se concluye nada sobre el presente |
| **Falla oportunista** | "tú estás haciendo mantenimiento y falló un ascensor que está cerca, al lado, normalmente llaman a ese técnico" | La atención de fallas se asigna por proximidad y **come capacidad de ruta**, aunque no haya un rol dedicado |

**El ratio equipos/técnico se puede derivar, y hay que decir con claridad que es derivación y no dato reportado.** Él nunca dijo cuántos equipos lleva un técnico; dijo cuántas mantenciones hace en un día. Con la periodicidad mensual que exige la normativa (una visita por equipo por mes) y ~21 días hábiles:

| Paso | Cálculo | Resultado |
|---|---|---|
| Mantenciones por mes por técnico | 3–4 por día × ~21 días | **63–84 mantenciones** |
| Equipos en cartera por técnico | 1 visita mensual por equipo | **≈ 60–84 equipos** |
| Descuento por atención de fallas oportunista | No cuantificado, y él confirmó que ocurre | El extremo alto es un techo, no la operación real |

**Y hay una verificación cruzada que vale más que la derivación sola.** Sus dos audios anteriores dijeron, sin que se le preguntara, que una operación tiene "uno o dos técnicos de mantención" y que una mediana ronda los 100–150 equipos. 100–150 equipos ÷ 60–84 por técnico da **1,6 a 2,4 técnicos de ruta**, que es exactamente lo que enumeró en el stack de costo. **Tres afirmaciones dadas en momentos distintos y sin conocer el modelo cierran entre sí.** Eso es lo más cerca de validación que se puede obtener de un solo informante.

**Consecuencias directas en este documento:**

1. **La tensión interna del Modelo C se resuelve, y a favor del escenario bueno** (sección 5, tabla de equipos por técnico). El ratio de campo derivado (60–84) cae en la fila donde CLP 1.000 por equipo "supera 70% con holgura", no en la de 30 equipos que solo llegaba a 50%. **Lo que queda desmentido es el supuesto propio de 1.000–2.000 técnicos activos**: con 44.000 equipos y 60–84 equipos por técnico, el parque se cubre con del orden de **520 a 730 técnicos de ruta**. La cifra anterior probablemente contaba a todo técnico del rubro, no a los que hacen ruta de mantención.
2. **El primer contrato factura del orden del doble de lo modelado** (sección 3.1 y 10).
3. **El pendiente 1 pasa de bloqueante a confirmable.** La decisión de precio de septiembre ya tiene una banda defendible; Abel y Jesús pasan de fuente necesaria a verificación deseable.

**El hallazgo de posicionamiento, y no se preguntó por él:** *"en la actualidad el técnico de mantenimiento se podría decir que es el que menos conocimiento tiene, que eso no debería ser así, pero es lo que está pasando porque contratan mano de obra barata."*

Es la validación de usuario objetivo más fuerte que existe en el registro, por tres razones. Primero, **describe exactamente al usuario primario del producto**: el técnico que hace la ruta es el que menos sabe. Segundo, **da la causa estructural y económica**: no es un accidente ni una brecha de capacitación transitoria, es una decisión de costo del empleador que no va a revertirse. Tercero, **viene de una fuente neutral que lo dijo como crítica al rubro**, no como halago a la solución. Consecuencia comercial: el argumento no es "le ahorramos tiempo a un experto", es **"hacemos que la mano de obra que ya contrataste rinda como una más experta"** — alineado con la estrategia de costo que la empresa ya eligió, en vez de pedirle que la cambie. Consecuencia de producto, y es una restricción, no un beneficio: un usuario con menos conocimiento base **exige más rigor de evidencia y de resguardo de seguridad**, no menos, porque tiene menos capacidad de detectar una respuesta incorrecta. Eso refuerza las reglas de seguridad y trazabilidad del repositorio en vez de relajarlas.

**Lo que esta respuesta no da:** el tamaño de la empresa más chica, la incidencia de fallas al mes, y si el técnico universal sigue existiendo hoy. Los tres quedan sin fuente asignada y **no se deducen** — el presupuesto de toques con él está en cero (Plan de Agosto, sección 3.8).

---

## 5. Las cuatro unidades de cobro posibles, dimensionadas

Esta es la sección que decide el modelo de negocio. Cada modelo se evalúa por tres cosas: techo de mercado, si el ingreso por usuario supera el piso de costo del `SAAS_COST_MODEL`, y si el argumento de venta se sostiene.

### Modelo A — por empresa: descartado

Con el conteo oficial, el universo direccionable son **276 empresas** (220 mantenedoras + 56 certificadoras), no las 280 estimadas: 276 × 12 UF/año = 3.312 UF ≈ **USD 136.000 de TAM total**. Con una penetración realista de 10–20% en dos años, son USD 13.600–27.200 de ARR.

El dato oficial confirma el descarte en vez de rescatarlo: **la estimación optimista y el conteo real difieren en 1,4%**, así que aquí no había ningún upside escondido en la incertidumbre del universo. El problema es estructural y no de precio: el modelo cobra por cuenta empresarial en un universo de 276 cuentas, muchas de ellas microempresas de un técnico-dueño. Cobrar por empresa convierte un mercado chico en un mercado inviable. **Queda descartado como unidad de cobro, y se conserva como ancla de diseño:** cualquier propuesta cuyo techo se calcule multiplicando por el número de empresas está mal formulada.

### Modelo B — por técnico: viable solo a partir de 1 UF, y con resistencia esperable

El parque de 44.000 equipos implica del orden de **1.000–2.000 técnicos de terreno activos**.

| Precio por técnico/mes | TAM (techo, 100% del universo) | Ingreso por usuario/mes | ¿Supera el piso de costo? |
|---|---:|---:|---|
| 0,5 UF (CLP 19.500) | ≈ USD 246.000 | USD 20,5 | **No.** Está bajo el piso de 50% de margen (USD 27,74) |
| 1 UF (CLP 39.000) | ≈ USD 985.000 | USD 41,0 | Sí a 50% y 60%; **no** a 70% (USD 46,23) |

El hallazgo importante: **cobrar 0,5 UF por técnico opera bajo el costo variable conservador.** La banda "0,5–1 UF por técnico" que circulaba como intuición contiene un tramo que pierde dinero. Si se usa este modelo, el piso es 1 UF y no hay espacio para descuento por volumen sin romper el margen.

**El TAM de la tabla no es una proyección de año 1 — es el techo si convirtiéramos el 100% del universo, y confundir ambas cosas es el error más caro de este documento.** Un escenario conservador y defendible para el año 1, haciendo outbound propio sin canal comercial:

| Escenario año 1 | Empresas convertidas | Técnicos (1 por empresa) | ARR a 1 UF |
|---|---:|---:|---:|
| Conservador (10% en 220 mantenedoras) | 22 | 22 | ≈ CLP 10,3M ≈ **USD 10.800** |
| Realista para outbound propio sin canal | 3–8 | 3–8 | CLP 1,4–3,7M ≈ USD 1.500–3.900 |

USD 10.800 de ARR es el 24% de un mes de burn, no del año. Ningún escenario de Modelo B financia 2026; el propio §10 de este documento ya fecha la cobertura de costo de vida en Q1 2027, no antes.

**Por qué 1 UF genera resistencia aunque supere el piso de costo, y es un problema de encuadre, no solo de margen.** Si una mantenedora cobra CLP 80.000/mes por equipo y el margen operativo típico ronda CLP 40.000 después de sueldo del técnico, insumos y overhead, 1 UF (CLP 39.000) representa un **~98% de ese margen por equipo** si se factura por equipo, o una porción mucho más chica si se factura por técnico contra su cartera completa:

| Cómo se mide la resistencia | 1 UF representa |
|---|---:|
| Contra un solo equipo (margen ≈ CLP 40.000) | ~98% del margen — **inaceptable** |
| Contra la cartera de un técnico con 30 equipos (facturación CLP 2,4M/mes) | 1,6% de la facturación |
| Contra la cartera de un técnico con 10 equipos (microempresa) | 4,9% de la facturación |

**El precio es el mismo en las tres filas — lo que cambia es la unidad contra la que se compara.** Cobrar por técnico y compararlo contra "el margen de un solo ascensor" es exactamente el marco en el que 1 UF se ve carísimo, y es el marco que un comprador informado va a usar para objetar. Esto no invalida el Modelo B, pero exige presentarlo contra la cartera completa del técnico, nunca contra un equipo aislado — y es un argumento adicional, independiente del TAM, a favor del Modelo C.

**Advertencia del 11 de agosto sobre el supuesto de CLP 40.000.** Es una estimación propia, nunca fue un dato, y la respuesta de campo de la sección 4.2 apunta a que es alto para la línea de mantención: esa tarifa cubre nómina, visitas ilimitadas por falla y guardia nocturna hasta y después de las 22:00. Mientras no exista la proporción correctivo/mantención, **esta tabla se lee como cota superior de resistencia y no como el margen real del cliente**, y ningún argumento de venta se apoya en ella (sección 9).

### Modelo C — por equipo gestionado: modelo recomendado para mantenedor

**Definición operativa, sin ambigüedad:** se cobra por equipo bajo contrato de mantención vigente en la cartera del cliente, **por mes, no por visita.** Si un técnico visita el mismo ascensor cinco veces en el mes, sigue siendo un cobro — igual que la mantenedora le cobra al edificio una tarifa mensual fija, sin importar cuántas veces vaya. Cobrar por visita sería peor en tres frentes: el ingreso colapsa en meses sin fallas, el cliente no puede presupuestarlo como línea fija, y crea el incentivo perverso de subregistrar visitas para pagar menos.

**Confirmado en campo el 11 de agosto, incluido el ejemplo de las cinco visitas:** así cobra el propio cliente, y las vueltas por falla van dentro de la tarifa (sección 4.2). Cobrar por mes y no por visita no es solo mejor para Danebo — **es la unidad que el cliente ya usa con su propio cliente**, y cobrar por visita le pediría adoptar una unidad que él mismo no consiguió imponer frente al administrador del edificio. También confirma que la facturación al edificio se estructura por equipo, no como monto global opaco: el Modelo C habla el idioma de facturación que el cliente ya tiene instalado, que era la mitad de lo que la pregunta del lunes 10 iba a resolver.

| Precio por equipo/mes | TAM (techo, 100% del universo, 44.000 equipos) | % de la mantención que ya cobra el cliente |
|---|---:|---|
| CLP 500 (0,013 UF) | ≈ USD 278.000 | 0,23%–0,63% |
| CLP 1.000 (0,026 UF) | ≈ USD 556.000 | 0,45%–1,25% |
| CLP 1.500 (0,038 UF) | ≈ USD 834.000 | 0,68%–1,88% |

**Escenario conservador de año 1**, no el techo: sobre 5 mantenedoras medianas convertidas, no sobre las 220.

| Tamaño de cartera por cliente | 5 clientes convertidos, a CLP 1.000/equipo | ARR |
|---|---:|---:|
| 60 equipos cada uno (piso pesimista) | CLP 300.000/mes | ≈ USD 3.800 |
| 100 equipos cada uno | CLP 500.000/mes | ≈ USD 6.300 |
| **125 equipos cada uno (mediana según dato de campo, §3.1)** | **CLP 625.000/mes** | **≈ USD 7.900** |

El primer contrato de noviembre, con una sola mantenedora mediana, factura del orden de **CLP 100.000–150.000/mes** con el dato de campo del 11 de agosto (100–150 equipos, sección 3.1). Eso corrige dos veces en direcciones opuestas: hacia abajo los CLP 300.000–600.000 que suponía un cliente grande de 300–600 equipos desde el primer contrato, y **hacia arriba los CLP 40.000–100.000 de la estimación razonada anterior**. Sigue siendo un ticket chico en términos absolutos, y sigue siendo la razón por la que la base de equipos —no el conteo de logos— es la métrica a vigilar.

**Por qué este modelo resuelve el problema del piso de costo.** Nuestro COGS escala con consultas, es decir con técnicos, no con equipos. Cada técnico cubre del orden de decenas de equipos, así que un precio pequeño por equipo agrega a un ingreso por técnico saludable:

| Equipos por técnico | Ingreso/técnico/mes a CLP 1.000 | ¿Supera el piso? |
|---:|---:|---|
| 30 | USD 32 | Solo 50% de margen |
| 60 | USD 63 | Supera 70% con holgura |
| 100 | USD 105 | Muy holgado |

**Tensión interna que hay que resolver con datos de campo, no con un solo informante contingente.** Este documento estima 1.000–2.000 técnicos activos sobre 44.000 equipos, lo que da un promedio de **22–44 equipos por técnico** — justo en la zona de 30 donde el Modelo C solo alcanza 50% de margen, no 70%. Para que la tabla de arriba llegue holgada a 60–100 equipos por técnico, el ratio real tiene que estar por encima del promedio implícito en el propio supuesto de universo de técnicos. **Las dos cifras de este documento están en tensión entre sí, y la sección 8.1 reparte la pregunta entre Abel (empresa mediana) y Jesús (empresa chica) en vez de depender de un solo dato de Gonzalo — dos puntos de una distribución valen más que uno, y no dependen de que una sola relación comercial sobreviva.**

**Resuelta el 11 de agosto, a favor del escenario bueno, y con una advertencia de método (sección 4.4).** La rutina reportada en campo —3 a 4 mantenciones diarias— implica una cartera de **60 a 84 equipos por técnico** con periodicidad mensual, o sea la fila de 60 de la tabla de arriba: **CLP 1.000 por equipo supera 70% de margen con holgura.** El número que cae es el supuesto propio de 1.000–2.000 técnicos activos, que resulta ser un conteo de todo el rubro y no de técnicos de ruta; el parque se cubre con del orden de 520 a 730. **La advertencia:** el ratio es **derivado de la rutina, no reportado como ratio**, y el extremo alto no descuenta la capacidad que consume la atención de fallas por proximidad, que la misma respuesta confirma que existe. Se usa como banda de trabajo para decidir el precio en septiembre, y la confirmación con Abel o Jesús pasa de bloqueante a deseable.

**Cupo de consultas incluido, con el piso de costo medido y confirmado en campo:**

| Margen objetivo | COGS disponible por equipo/mes | Consultas incluidas (a USD 0,0093 conservador) |
|---|---:|---:|
| 70% | USD 0,32 | **~32/equipo/mes** |
| 50% | USD 0,52 | ~53/equipo/mes |

La sesión de demo del 6 de agosto — [MATRIZ_DEMOS_PILOTOS_2026-08-07.md](MATRIZ_DEMOS_PILOTOS_2026-08-07.md), sección 1.1.a — midió un costo de **USD 0,0073 por interacción respondida**, dentro del rango esperado de USD 0,0061–0,0093 del `SAAS_COST_MODEL`. No cambia el piso de costo; lo confirma con un dato de campo real, no solo con carga sintética.

**El ratio equipos/técnico era la variable de pricing más importante que no teníamos. Al 11 de agosto hay una banda derivada de campo: 60–84 equipos por técnico** (sección 4.4). Abel y Jesús siguen siendo los dos puntos de la distribución que la confirman —empresa mediana y empresa chica, sección 8.1— pero ya no bloquean la decisión de precio: la confirman o la corrigen.

Ventajas adicionales del modelo por equipo: escala con el driver de ingreso del propio cliente (su cartera de contratos), es una línea proporcional y predecible en su presupuesto, se autoescala con el tamaño del cliente en vez de golpear igual a la microempresa que a la mediana (ver la tabla de resistencia del Modelo B más arriba), y desacopla nuestro precio de su rotación de personal — que en este rubro es alta y es precisamente uno de los dolores que el producto ataca.

### 3.1 Cuántos equipos tiene realmente una mantenedora mediana

El promedio nacional (44.000 equipos ÷ 220 mantenedoras ≈ 200) esconde una distribución muy desigual: el parque está concentrado en las multinacionales (Otis, Schindler, Thyssen, Kone) y en la cola larga de microempresas de un técnico-dueño que este mismo documento describe en la sección 2. Si las multinacionales concentran una porción sustancial del parque —esto es una estimación razonada, no un dato con fuente—, las 200+ empresas restantes se reparten un número bastante menor a 200 en promedio, y la mediana queda más abajo todavía por el sesgo de la cola.

**Dato de campo del 11 de agosto, y reemplaza la estimación razonada por la primera cifra con fuente** (sección 4.4): *"las empresas así medianas normalmente tienen 100, ciento y tanto de ascensores. Las que son grandes así de marca como Schindler, Otis, me imagino que esas ya tienen como 1.000 equipos."*

| Segmento | Cartera | Confianza |
|---|---|---|
| Mantenedora mediana | **100–150 equipos** | **Media-alta.** Lo afirmó sin hedge y es el segmento que sí conoce de cerca |
| Multinacional de marca | ~1.000 equipos | **Baja: él mismo dijo "me imagino".** Es especulación declarada, se registra como orden de magnitud y no como dato |

**El rango del primer cliente sube de 40–100 a 100–150 equipos**, y la banda anterior queda como el piso pesimista. Es la corrección más favorable del mes: **duplica el ticket del primer contrato sin cambiar el precio unitario.** Dos cautelas que no se pueden saltar: el número describe el segmento en general y **no está verificado como lectura cruzada de varias empresas** (advertencia de procedencia, sección 4.1), y él no respondió cuál es la empresa más chica, así que el piso de la distribución sigue siendo la cola larga de microempresas de la sección 2. La aritmética de la sección 10 se recalcula con esto.

### Modelo D — por informe generado: modelo recomendado para certificador

22.000–30.000 certificaciones al año; se usa 26.000 como punto medio.

| Fee por informe | TAM anual |
|---|---:|
| 0,25 UF (CLP 9.750) | ≈ USD 267.000 |
| 0,5 UF (CLP 19.500) | ≈ USD 534.000 |
| 0,75 UF (CLP 29.250) | ≈ USD 801.000 |

Es el modelo que mejor calza con el dolor descubierto en entrevista: dictar en terreno y obtener el informe listo. Es medible por transacción, el corpus normativo es acotado y barato de alimentar, y el valor percibido por hora ahorrada es alto.

**Lo que falta para cerrarlo, y es honesto decirlo:** el COGS de un dictado de 15–20 minutos no está medido. Es un driver económico distinto al de una consulta de texto — minutos de audio, no tokens de una pregunta puntual — y su medición es un entregable explícito del mes de construcción de septiembre. Hasta entonces el margen de este modelo es una expectativa razonable, no un número.

Sobre el techo: del orden de 2.000 informes al mes en todo el país. Es un modelo de buen margen y volumen nacional bajo. **No es el que financia el sueldo en 2026;** el motor de ingresos de corto plazo es el mantenedor.

### Resumen de la decisión

| Segmento | Unidad de cobro | Estado |
|---|---|---|
| Mantenedor | **Por equipo gestionado**, con cupo de consultas incluido | Recomendado |
| Mantenedor (alternativa) | Por técnico, piso 1 UF, sin descuento bajo ese piso | Aceptable |
| Certificador | **Por informe generado** | Recomendado, pendiente de medir COGS de voz |
| Cualquiera | Por empresa | Descartado |
| Cualquiera | Por token, de cara al cliente | Descartado — ver sección 7 |

---

## 6. Por qué la referencia de pricing genérica no sirve como ancla

La referencia de mayo de 2026 fue construida sin contexto del rubro y propone, para SaaS con IA en Chile/LatAm:

| Plan de la referencia | Precio | Traducido a nuestro caso |
|---|---|---|
| Básico | USD 19–29/mes, 1 usuario | Bajo el piso de costo |
| Profesional | USD 49–79/mes, 3–5 usuarios | USD 10–26 por usuario: **bajo el piso** |
| Empresarial | CLP 150.000–500.000/mes | Para una mantenedora de 15 técnicos: USD 10,5–35 por usuario. Solo el techo del rango supera el piso de 60% |

**La conclusión es que esa referencia está calibrada para productos cuyo COGS es cercano a cero** — chatbots de FAQ, búsqueda semántica simple, asistentes sin multimodalidad. Danebo tiene un COGS variable conservador medido de USD 13,87 por usuario/mes. Aplicar esos rangos sin ajuste nos deja vendiendo bajo costo en dos de los tres planes.

Su utilidad real es otra, y no es menor: **dice qué está acostumbrado a ver el comprador chileno.** Un precio nuestro que se presente como "CLP 500.000 al mes" cae en el techo de una banda que el mercado reconoce como enterprise. Presentado como "CLP 1.000 por equipo" cae en una categoría que el comprador no tiene con qué comparar, y que se justifica sola contra su propia facturación. Eso es una ventaja de encuadre, no de precio.

**Lo que sí se toma de esa referencia:**

- **Cobrar el setup por separado.** La referencia sugiere CLP 400.000–1.000.000 para implementación con integraciones y CLP 1.000.000–3.000.000 para RAG avanzado con workflows. Nuestro onboarding de un manual de 200 páginas cuesta USD 5,32 medido contra factura. Un setup de CLP 400.000 cubriendo diez manuales tiene un COGS de USD 53 — margen de casi ocho veces, y financia exactamente el frente de corpus que Gonzalo señaló como el trabajo pesado. El `SAAS_COST_MODEL` ya pide facturar onboarding aparte, con su propio margen; la referencia confirma que el mercado lo acepta.
- **La lógica de asientos más consumo** como patrón dominante en B2B, que es la que sostiene el cupo incluido del modelo por equipo.

---

## 7. Por qué no se cobra por token al mantenedor — pero sí conviene mostrar consumo

La pregunta tenía dos partes que conviene separar: **cómo se factura** y **qué tan transparente es el consumo hacia el usuario**. La respuesta a la primera es no. A la segunda, parcialmente sí — son decisiones independientes.

**Por qué no se factura por token, de cara al cliente, con cuatro razones que se acumulan:**

1. **Una factura que el cliente no puede proyectar bloquea la decisión de compra.** La evidencia de entrevistas es explícita en que el precio domina y el criterio técnico pesa poco. Un modelo cuyo monto varía mes a mes obliga al comprador a defender internamente un número que no controla. En un mercado sensible al precio, eso no es un detalle de facturación: es una objeción estructural.
2. **Cobrar por consumo hace que el usuario se autocensure, y eso destruye justamente la señal que el piloto debe medir.** Si el técnico sabe que cada pregunta cuesta, pregunta menos. El piloto de octubre existe para medir adopción voluntaria; un modelo por token contamina la medición desde el diseño.
3. **"Token" no es una unidad de valor en el idioma del cliente.** "Por técnico", "por equipo" y "por informe" son unidades que el cliente ya usa para pensar su propio negocio. Un token no significa nada para un jefe técnico y menos para quien firma el cheque.
4. **No necesitamos transferirle la varianza, porque ya está acotada y medida.** El costo por consulta (USD 0,0061 esperado / USD 0,0093 conservador, confirmado en campo por la demo del 6 de agosto a USD 0,0073 — ver sección 5, Modelo C) y el techo contractual ya son conocidos. Un precio por equipo o por asiento con cupo incluido absorbe esa varianza sin exponerla.

**El riesgo inverso, que hay que nombrar porque es real:** si el producto resuelve una mantención preventiva en 1–2 consultas, el ingreso por token sería casi nulo justo cuando el producto funciona bien, y el onboarding del corpus (USD 5,32 por manual) nunca se paga. Facturar por token premia el mal desempeño del producto —más consultas porque no encuentra la respuesta— en vez de premiar la disponibilidad. Para mantención preventiva, lo que el cliente valora no es "cuántas veces preguntó" sino que el corpus esté listo cuando llegue el correctivo: eso se cobra por activo cubierto, no por consumo, igual que un seguro no se cobra por siniestro reportado.

**Dónde sí vive la medición por token: en dos lugares distintos, y solo uno de cara al usuario.** Internamente, como control de costo y como base para calibrar el cupo (sección 5, Modelo C). Y, opcionalmente, **como indicador de consumo visible en la interfaz** — mostrarle al técnico o supervisor cuántas consultas de su cupo mensual lleva usadas ("18 de 32 este mes"), sin traducir eso a un monto en pesos. Es útil porque le da al supervisor control y hace tangible el cupo, y es seguro porque no expone el costo real ni el margen: si algún día el cliente hace la cuenta de cuánto cuesta cada consulta y la compara contra lo que paga, la conversación de margen se vuelve pública en el peor momento posible. La forma correcta de trasladar consumo al cliente es un cupo explícito de consultas incluidas por técnico o por equipo, con excedente por bloque, no un precio por unidad de cómputo ni una cifra en pesos por consulta. Y para el certificador, la unidad transaccional natural ya existe y es el informe.

**Lo que falta medir para calibrar el cupo, y no es lo mismo que el costo:** cuántas consultas resuelven en promedio un evento de mantención, separando preventivo de correctivo. La intuición de que una preventiva sin hallazgos usa pocas consultas y un correctivo complejo puede usar muchas es razonable — es la misma forma de distribución de cola larga que tiene la resolución de incidentes de software, con la diferencia de que ahí el costo de un error se mide en reintentos, y aquí puede tocar un evento de seguridad. Ese dato de campo se obtiene del piloto de octubre y del laboratorio de Venezuela, no se supone. Gonzalo puede aportar el proxy operativo — llamados por falla al mes por cada 100 equipos en cartera — que es lo más cercano a un "número público" que existe para este mercado.

---

## 8. Preguntas de mercado — de una sola fuente a cuatro, y de directas a indirectas

Todas son preguntas, no propuestas: **preguntar precio y volumen de mercado siempre estuvo permitido** — lo que no se hace es revelar el precio propio ni proponer una cifra nuestra antes de tenerla decidida (sección 0, Plan General). Son la vía 2 del cierre de costos (volumen por entrevista experta) y, al mismo tiempo, lo que falta para fijar precio.

**Cambio de estrategia del 8 de agosto, con dos correcciones sobre el planteamiento original:**

**Primera corrección — la fuente.** El plan original concentraba estas preguntas en Gonzalo. Pero Abel, Daniel y Jesús tienen conversión de piloto 0% y no la van a tener (ver [MATRIZ_DEMOS_PILOTOS_2026-08-07.md](MATRIZ_DEMOS_PILOTOS_2026-08-07.md), sección 2.2) — lo que sí pueden dar sin fricción es exactamente esta información de mercado, porque la viven todos los días desde cuatro tamaños de empresa distintos (multinacional vía Gonzalo, mediana vía Abel, independiente vía Daniel, chica vía Jesús). Repartir las preguntas entre los cuatro convierte una sola fuente en un rango citable, y no depende de que la relación con Gonzalo sobreviva.

**Segunda corrección — el formato.** Preguntar directamente "¿cuál es tu margen?" o "¿cuánto ganas?" genera resistencia predecible: nadie regala esa cifra a alguien que le está por vender algo. El formato correcto es pedir **opinión experta sobre el mercado en general**, no datos de su propia empresa. La persona responde la opinión con facilidad, y en el camino suelta el dato como contexto de su respuesta.

| Pregunta directa (descartada) | Pregunta indirecta (la que se usa) |
|---|---|
| "¿Qué porcentaje de margen te queda?" | "¿Qué tan apretados están los márgenes en el rubro?" |
| "¿Cuánto cobras por mantención?" | "¿Está estandarizado el precio o hay mucha variabilidad entre empresas?" |
| "¿Cuántos equipos y técnicos tienes?" | "¿Cómo se distribuye la carga — cartera fija por técnico o rotación según contingencia?" |

### 8.1 Reparto de preguntas por contacto (mensajes del lunes 10 de agosto)

| Contacto | Pregunta (formato indirecto) | Qué resuelve | Estado al 11 ago |
|---|---|---|---|
| **Gonzalo** | "¿Qué tan apretados son los márgenes de mantención hoy? ¿Cuánto espacio hay para que una herramienta nueva entre como costo adicional sin que duela?" | El supuesto de CLP 40.000 de margen por equipo (sección 5, tabla de resistencia del Modelo B) | Mensaje enviado. Respondió lo operativo (manuales + ingenieros + almuerzo). **Margen sin respuesta** → se cierra en el almuerzo de septiembre; no se insiste por mensaje |
| **Daniel** | "¿Cómo es la estructura típica de facturación al edificio — por equipo o monto global por contrato? ¿Hay mucha variabilidad de precios entre empresas o está estandarizado?" | Valida el rango CLP 80.000–220.000 de Habitissimo (sección 4) contra un contratista que ve las tarifas desde el terreno, y decide si el Modelo C habla el idioma de facturación que el cliente ya usa | **Respondida el 11 ago, por audio y con textura, y ampliada en un segundo audio no solicitado.** No estandarizado; drivers: paradas, zona, acceso, y negociación con administradores. Rango espontáneo CLP 80.000–150.000, consistente con la sección 4. Facturación por equipo confirmada → el Modelo C habla el idioma del cliente. **Bonus no preguntado:** la utilidad vive en correctivos y, sobre todo, en modernizaciones; la mantención retiene al cliente (secciones 4.1 a 4.3). Rescate con estimado desviado **gastado**; segundo toque **gastado el mismo día en rutina diaria y tamaño de cartera, y respondido**: 3–4 mantenciones por día → 60–84 equipos por técnico derivados, mediana de 100–150 equipos, y el técnico de mantención como el eslabón de menor conocimiento por costo de mano de obra (sección 4.4). **Presupuesto de toques en cero.** **Peso de la fuente: rutina de un contratista senior, no lectura cruzada de varias empresas** (advertencia de procedencia, sección 4.1) |
| **Abel** | "En empresas del tamaño de Tecnicall, ¿un técnico lleva una cartera fija de equipos o va rotando según la contingencia?" | Un punto de la tensión del ratio equipos/técnico en empresa mediana (sección 5, Modelo C) | Mensaje enviado; respuesta pendiente. **Degradado de bloqueante a verificación** tras la respuesta de rutina del 11 de agosto (sección 4.4) |
| **Jesús** | "¿Cada técnico en tu empresa tiene una ruta fija de equipos o van asignando según las emergencias del día?" | Un punto del ratio en empresa chica — la cola larga que domina el conteo de la sección 2 | Mensaje enviado; respuesta pendiente. **Sigue siendo la única fuente prevista para el piso de la distribución**, que el dato de campo no cubrió |

Con dos o más respuestas de la tensión del ratio (Abel y Jesús) y una lectura de margen independiente (Gonzalo, ahora diferida al almuerzo), la sección 5 deja de resolverse con un solo dato de una sola persona contingente y pasa a tener un rango de campo defendible en una postulación a fondos. **Al 11 de agosto hay un punto de campo (sección 4.4) y sigue siendo uno: la banda de 60–84 equipos por técnico no se cita ante terceros como "dato de mercado" mientras venga de un solo informante y por derivación.**

**Dos lecturas de proceso del 11 de agosto, que valen para los dos mensajes que siguen pendientes.**

Primera: **el cambio de estrategia del 8 de agosto funcionó en la primera oportunidad de comprobarlo.** El contacto con 0% de conversión a demo respondió una pregunta de mercado en menos de 24 horas y con más textura de la pedida. Pedir opinión experta convierte donde pedir piloto no convertía, y eso confirma la regla de la matriz: a estos tres se les pide información, no compromiso.

Segunda: **respondió por audio y largo.** A un técnico de terreno le cuesta escribir y no le cuesta hablar, así que el segundo toque con Abel y Jesús invita explícitamente a contestar por audio ("mándame un audio si es más fácil"). Es la misma asimetría que sostiene la tesis de voz del producto, observada esta vez en el canal de descubrimiento — no es evidencia de adopción, pero sí de cuál es el canal de menor fricción para esta población.

### 8.2 Preguntas que quedan para el almuerzo de septiembre con Gonzalo

Estas requieren tiempo y contexto presencial, y no caben en un mensaje corto. **La pregunta de margen del mensaje del lunes 10 se suma a esta lista** porque no la respondió por texto:

0. **¿Qué tan apretados están los márgenes de mantención hoy en el rubro?** (pendiente del mensaje del 10 ago; protocolo de lectura en Plan de Agosto §3.2.1 — no anclar con estimado propio)
1. ¿Cuántos servicios diarios por técnico, y cuántas consultas a manual por servicio?
2. ¿Cuánto factura una certificación, y cuántas alcanza a hacer un certificador en un día?
3. ¿Cuántos llamados por falla recibe al mes por cada 100 equipos en cartera? Es el proxy operativo más cercano a un dato público de incidencia que existe para este mercado, y calibra el cupo de consultas del correctivo. **Actualización del 11 de agosto: esta pregunta tiene una fuente mejor y neutral.** Va primero a Daniel, que atiende las fallas y no tiene nada en juego (sección 11); con Gonzalo se usa para contrastar, no como fuente única.
4. ¿Quién firma el cheque de software en una mantenedora, y hasta qué monto pasa sin comité?
5. ¿Cuánto le cuesta a la empresa perder un técnico senior?
6. ¿Qué tamaño tiene el mercado informal de equipos sin certificar, desde lo que él ve en terreno?
7. **¿Qué proporción del ingreso de una mantenedora viene de correctivos y repuestos frente a la tarifa mensual de mantención?** Pregunta nueva del 11 de agosto, derivada del hallazgo de la sección 4.2. Es el denominador correcto del pitch de la sección 9 y lo único que permitiría recalcular la tabla de resistencia del Modelo B con un dato en vez de un supuesto. Ventaja táctica: es una pregunta de estructura de negocio, no de su margen, así que no activa el incentivo de sombrear del protocolo de lectura (Plan de Agosto, sección 3.2.1). **Y va a él y no a la fuente neutral por una razón registrada:** el agradecimiento enviado el 11 de agosto le comunicó a Daniel la conclusión sobre el peso de los correctivos, así que quedó anclado y su estimación de proporción ya no sería independiente (Plan de Agosto, sección 3.3.2).

**Cómo extraer su conocimiento sin revelar el precio propio, si insiste en preguntar el nuestro:** presentar la estructura sin la cifra — "he visto tres formas de cobrar esto: por técnico, por equipo en cartera, o por informe generado; ¿cuál crees que tu mercado aceptaría, y en qué rango?" — y, si vuelve a insistir, la respuesta honesta es que el precio todavía no está decidido porque el costo real se está midiendo, por eso se le pregunta a él.

---

## 9. El riesgo real del pricing: el ahorro de tiempo no financia el precio

Esto es lo más incómodo del análisis y conviene tenerlo por escrito antes de una negociación.

La regla de valor de la referencia genérica dice cobrar 10–20% del ahorro que se genera. Aplicada honestamente:

| Fuente de ahorro | Ahorro mensual estimado por técnico | 10–20% |
|---|---|---|
| Tiempo de búsqueda: 2–4 h/mes a CLP 8.000–12.000/h cargados | CLP 16.000–48.000 | CLP 1.600–9.600 |
| Una revisita evitada al mes a CLP 40.000–80.000 | CLP 40.000–80.000 | CLP 4.000–16.000 |

Ambos resultados quedan **por debajo del piso de costo por usuario** (CLP 26.000–44.000, equivalente a USD 27,74–46,23). Es decir: si el argumento de venta es exclusivamente ahorro de tiempo, el precio que ese argumento justifica no cubre nuestro propio COGS.

De ahí salen tres consecuencias concretas:

1. **El encuadre correcto es participación en ingresos, no ahorro de horas** — y desde el 11 de agosto, participación en el **ingreso total por equipo** (mantención mensual + correctivos y repuestos), no en la tarifa de mantención sola. CLP 1.000 contra el piso del rango de mantención es 1,25%; contra el ingreso total del equipo es bastante menos. El cambio de denominador importa por una razón táctica, no estética: **la tarifa mensual es la línea que el administrador del edificio ya tiene comprimida** (sección 4.1), así que apoyar el pitch ahí invita a la objeción "de ahí no me sobra nada", que es cierta. Ese argumento sigue sin depender de estimar horas ahorradas, que es exactamente la cifra que un comprador escéptico va a discutir.
2. **El valor no temporal tiene que entrar al pitch con evidencia, no como adorno:** retención de conocimiento cuando se va el especialista, reducción de la dependencia del jefe técnico como cuello de botella, y evidencia trazable para respaldar trabajos y pagos. Los tres salieron de entrevistas independientes y ninguno se mide en horas.
3. **Bajar el COGS es una palanca comercial, no solo técnica.** Cada dólar que baja el costo variable por usuario amplía el rango de precios defendibles. Esto conecta directamente con las reglas de costo de Bedrock del repositorio: perfil de inferencia global por defecto, retrieval adaptativo y compactación de prompt no son optimizaciones estéticas, son grados de libertad de pricing.

### 9.1 El argumento que sí puede financiar el precio: la revisita no facturada

Del hallazgo de la sección 4.2 sale un cuarto argumento, y es el primero que ataca dinero que el cliente pierde hoy en vez de tiempo que podría ahorrar.

**La mecánica, en el idioma del cliente:** la tarifa mensual incluye las vueltas por falla. Si un equipo queda fallando y el técnico va cinco veces, esas cinco visitas no se facturan — se pagan con bencina, estacionamiento (más caro justamente en las zonas que mejor pagan) y con horas de un técnico que en ese rato no está haciendo el correctivo que sí factura. Cada vuelta evitada devuelve margen dos veces: no gasta el desplazamiento y libera capacidad para la línea rentable.

| Por qué es mejor argumento que el ahorro de horas | Detalle |
|---|---|
| **Ataca el centro de utilidad** | Los correctivos y repuestos son donde el cliente gana, según la propia fuente de campo. Liberar capacidad ahí no es eficiencia abstracta, es ingreso |
| **El costo ya es visible para el cliente** | Bencina, estacionamiento y una visita que se agenda sin cobrar son partidas que él reconoce sin que se las estimen |
| **No exige creer una tasa horaria** | El argumento del ahorro de tiempo obliga a acordar cuánto vale una hora de técnico. Este no |
| **Tiene un momento de máxima intensidad identificado** | El turno nocturno posterior a las 22:00: técnico solo, emergencia o atrapamiento, sin jefe técnico disponible. Es el peor escenario operativo del cliente y el mejor caso de uso de un asistente documental |

**El límite honesto, que se respeta:** no hay dato de cuántas vueltas toma una falla típica ni de cuántas evitaría el producto. Sin eso, esto es una hipótesis bien fundada y no una cifra citable, y por eso **no se convierte en promesa de ahorro ante ningún prospecto**. Las dos formas de cerrarlo están fechadas: la pregunta de incidencia a la fuente neutral (sección 11) y la medición en el piloto de octubre, donde consultas por evento y resolución quedan instrumentadas.

**Y una regla que se deriva para toda conversación comercial:** el interlocutor de campo corrigió espontáneamente el encuadre del fundador con un "no es tan negocio redondo como tú crees". Cualquier pitch construido sobre la premisa de que al mantenedor le sobra margen va a recibir esa misma corrección, pero de un comprador y en el peor momento. La premisa correcta es la inversa: **el margen es delgado justo donde el producto puede protegerlo.**

---

## 10. Aritmética de la escalera de rentabilidad bajo el modelo por equipo

Reemplaza la aritmética por técnico del plan general anterior. Supone CLP 1.000 por equipo y COGS conservador de USD 13,87 por usuario/mes.

| Hito | Fecha | Criterio medible |
|---|---|---|
| Primer contrato pagado | Noviembre 2026 | Una mantenedora mediana convierte desde el piloto de octubre. A **100–150 equipos** (sección 3.1, dato de campo del 11 de agosto que reemplaza la estimación de 40–100): **CLP 100.000–150.000/mes (USD 105–158)** |
| Danebo cubre su propio COGS | Diciembre 2026 | **Base combinada superior a ~850 equipos**, que a CLP 1.000/equipo da USD 895/mes contra un COGS de USD 416 para 30 usuarios: margen bruto 53%. Con clientes de 100–150 equipos, eso son **6 a 8 mantenedoras medianas** (antes 9 a 14). **Y el supuesto de 30 usuarios queda validado por campo:** a 60–84 equipos por técnico (sección 4.4), 850 equipos son del orden de 10 a 14 técnicos de ruta más supervisores y saca fallas — el modelo de costo no está subdimensionando usuarios |
| Cubre el costo de vida del fundador | Q1 2027, explícitamente fuera de 2026 | CLP 3.500.000/mes exige del orden de 3.500 equipos a CLP 1.000, o ~2.300 a CLP 1.500: **23 a 35 mantenedoras medianas** de 100–150 equipos, o tres a cuatro si se logran clientes grandes de 1.000 equipos (orden de magnitud especulativo, sección 3.1) |

El criterio de diciembre queda expresado como un número verificable — base combinada de equipos — y no como "dos clientes", porque dos clientes chicos no alcanzan el margen y dos clientes medianos lo superan con holgura. La cifra a vigilar es la base de equipos, no el conteo de logos. **La serie de correcciones del supuesto de tamaño de cliente —300–600 estimado, luego 40–100 razonado, ahora 100–150 con dato de campo— sigue dejando el número de logos necesarios un orden de magnitud por encima del plan original, y es la razón de más peso para que la red de Gonzalo, que puede abrir puertas a clientes mediano-grandes en vez de solo microempresas, importe tanto como se plantea en el Plan General, sección 9.** Lo que cambió con el dato de campo es que el objetivo de diciembre pasa de 9–14 logos a 6–8, que es la diferencia entre inalcanzable y difícil.

---

## 11. Qué queda pendiente antes de poder cotizar

El gate vigente es que no se cotiza sin precio decidido y costo por usuario medido. Lo que falta, en orden:

1. ~~**Ratio equipos/técnico**~~ → **desbloqueado el 11 de agosto con banda derivada de campo: 60–84 equipos por técnico** (sección 4.4), más cartera de mediana de 100–150 equipos (sección 3.1). El modelo por equipo ya se puede fijar. **Lo que queda es verificación, no habilitación:** Abel (mediana) y Jesús (chica) confirman o corrigen la banda, y su silencio ya no detiene la decisión de septiembre. **Dos cautelas que viajan con el número:** es derivado de la rutina diaria y no reportado como ratio, y no descuenta la capacidad que consume la atención de fallas por proximidad. **Y una que es de procedencia:** vale como la rutina de un contratista senior; la afirmación de que ve varias mantenedoras es heredada y no verificada (sección 4.1), y su respuesta describió el segmento en general en vez de sus propias empresas, así que **el test de verificación quedó inconcluso**.
2. **COGS de voz por dictado** (medición del mes de construcción). Sin esto el modelo por informe no tiene margen conocido.
3. **Volumen de consultas por técnico/mes**, por carga sintética representativa y por el laboratorio de Venezuela, para verificar que el cupo incluido no sea el que rompe el margen.
4. **Incidencia de fallas y revisitas por falla, y proporción de ingreso correctivo frente a mantención.** Pendiente nuevo del 11 de agosto (sección 4.2). **Proporción de ingreso**: a Gonzalo en el almuerzo, porque Daniel quedó anclado en ese punto por el agradecimiento del 11 de agosto (Plan de Agosto, sección 3.3.2). **Incidencia y vueltas por falla: sin fuente asignada** — era el uso previsto del toque a Daniel, que se gastó en el ratio porque ese sí bloqueaba el precio, y con él el presupuesto de toques quedó en cero. Se retoma con Abel o Jesús si responden, o con el piloto de octubre, que lo mide en vez de preguntarlo. **No se deduce.** Calibra el cupo de consultas del correctivo y es lo que convierte el argumento de la sección 9.1 de hipótesis en cifra.
5. **Decisión interna de precio**, en septiembre, sobre las cuatro anteriores. No espera al punto 4 si no llega: el punto 4 mejora el argumento de venta, no el piso de precio.

---

## 12. Fuentes

- **Registro Nacional MINVU, nómina de inscritos al 3 de junio de 2026** — fuente del conteo oficial de 220 mantenedoras, 56 certificadoras y 57 instaladoras. Es también la fuente que cierra la verificación del rol de Gonzalo: ATLAGICH Ascensores SpA figura como mantenedora, Rol 324, y no como certificadora (Plan General, sección 9.7).
- Registro Nacional MINVU, nóminas anteriores (2021, 2025) y Ley 20.296, conservadas para la serie histórica.
- Material de inspección de CENTRAVE A.G. sobre periodicidad, ítems de inspección y contenido de Carpeta Cero según Decreto 37 MINVU.
- Mercado Público, rubro 72101506: adjudicaciones de Puerto Montt, Hospital Lonquimay y Hospital de Linares.
- Habitissimo, rangos de mantención mensual por ascensor en mercado privado.
- Ocho entrevistas consolidadas, julio–agosto 2026, y reunión con Gonzalo del 6 de agosto de 2026.
- **Respuesta de campo del 11 de agosto de 2026** de Daniel, contratista senior independiente, en tres audios de WhatsApp (el segundo no solicitado; el tercero en respuesta al segundo toque): rutina de 3–4 mantenciones diarias, cartera de 100–150 equipos en una mantenedora mediana y ~1.000 en multinacional de marca —esto último especulación declarada—, el modelo histórico del "técnico universal" con vigencia actual desconocida para él, y el técnico de mantención como el eslabón de menor conocimiento por contratación de mano de obra barata (sección 4.4). Más: drivers de precio (paradas, zona, acceso, negociación con administradores), rango espontáneo de CLP 80.000–150.000, obligación de cobertura de fallas y guardia 24/7 dentro de la tarifa mensual, escalera de ingreso en tres tramos con las modernizaciones como el más rentable, y stack de costo fijo (vehículos, técnicos de ruta, saca fallas, guardias, herramientas). Es la fuente de las secciones 4.1, 4.2 y 4.3. **Fuente de baja confianza declarada por él mismo en materia de precios y alta en materia de operación**, y no se atribuye ante terceros. **Alcance verificado: su propia rutina y lo que observa desde el terreno. La afirmación de que trabaja con varias mantenedoras es heredada del registro de entrevistas, no aparece en sus audios y está sin verificar** — cualquier conclusión que necesite lectura cruzada de varias empresas no puede apoyarse en él hasta confirmarlo.
- [SAAS_COST_MODEL_2026-06-12.md](SAAS_COST_MODEL_2026-06-12.md) para COGS y pisos de precio.
- Referencia de pricing genérica de mayo de 2026, conservada solo como lectura de expectativa de mercado.
