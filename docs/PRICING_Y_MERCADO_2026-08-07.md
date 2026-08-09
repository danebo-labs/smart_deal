# Danebo — Mercado, unidad de cobro y pricing (2026-08-07)

**Estado:** fuente canónica de dimensionamiento de mercado y decisión de unidad de cobro.
**Relación con el modelo de costos:** [SAAS_COST_MODEL_2026-06-12.md](SAAS_COST_MODEL_2026-06-12.md) sigue siendo la única autoridad sobre COGS variable y piso de precio. Este documento no lo reemplaza: le pone encima la capa de mercado y de unidad de cobro que ese documento deliberadamente no cubre.
**Reemplaza:** la referencia de pricing genérica de mayo de 2026 (`Documento sin título.pdf`), que se conserva solo como registro de lo que el mercado chileno está acostumbrado a ver, no como ancla de precio de Danebo. La razón está en la sección 6.

**Última actualización de datos:** conteo oficial del Registro Nacional de Ascensores al 3 de junio de 2026 (sección 2), que reemplaza los rangos estimados de universo de empresas, y parámetro de conversión EUR agregado por consistencia con el Plan General.

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

### Modelo C — por equipo gestionado: modelo recomendado para mantenedor

**Definición operativa, sin ambigüedad:** se cobra por equipo bajo contrato de mantención vigente en la cartera del cliente, **por mes, no por visita.** Si un técnico visita el mismo ascensor cinco veces en el mes, sigue siendo un cobro — igual que la mantenedora le cobra al edificio una tarifa mensual fija, sin importar cuántas veces vaya. Cobrar por visita sería peor en tres frentes: el ingreso colapsa en meses sin fallas, el cliente no puede presupuestarlo como línea fija, y crea el incentivo perverso de subregistrar visitas para pagar menos.

| Precio por equipo/mes | TAM (techo, 100% del universo, 44.000 equipos) | % de la mantención que ya cobra el cliente |
|---|---:|---|
| CLP 500 (0,013 UF) | ≈ USD 278.000 | 0,23%–0,63% |
| CLP 1.000 (0,026 UF) | ≈ USD 556.000 | 0,45%–1,25% |
| CLP 1.500 (0,038 UF) | ≈ USD 834.000 | 0,68%–1,88% |

**Escenario conservador de año 1**, no el techo: sobre 5 mantenedoras medianas convertidas, no sobre las 220.

| Tamaño de cartera por cliente | 5 clientes convertidos, a CLP 1.000/equipo | ARR |
|---|---:|---:|
| 60 equipos cada uno (mediano, ver sección 3.1 más abajo) | CLP 300.000/mes | ≈ USD 3.800 |
| 100 equipos cada uno | CLP 500.000/mes | ≈ USD 6.300 |

El primer contrato de noviembre, con una sola mantenedora mediana de 40–100 equipos, factura del orden de **CLP 40.000–100.000/mes** — no los CLP 300.000–600.000 que sugiere la escalera de rentabilidad de la sección 10 con un supuesto de 300–600 equipos por cliente. Esa cifra de 300–600 asumía un cliente grande desde el primer contrato, y es optimista: ver sección 3.1.

**Por qué este modelo resuelve el problema del piso de costo.** Nuestro COGS escala con consultas, es decir con técnicos, no con equipos. Cada técnico cubre del orden de decenas de equipos, así que un precio pequeño por equipo agrega a un ingreso por técnico saludable:

| Equipos por técnico | Ingreso/técnico/mes a CLP 1.000 | ¿Supera el piso? |
|---:|---:|---|
| 30 | USD 32 | Solo 50% de margen |
| 60 | USD 63 | Supera 70% con holgura |
| 100 | USD 105 | Muy holgado |

**Tensión interna que hay que resolver con datos de campo, no con un solo informante contingente.** Este documento estima 1.000–2.000 técnicos activos sobre 44.000 equipos, lo que da un promedio de **22–44 equipos por técnico** — justo en la zona de 30 donde el Modelo C solo alcanza 50% de margen, no 70%. Para que la tabla de arriba llegue holgada a 60–100 equipos por técnico, el ratio real tiene que estar por encima del promedio implícito en el propio supuesto de universo de técnicos. **Las dos cifras de este documento están en tensión entre sí, y la sección 8.1 reparte la pregunta entre Abel (empresa mediana) y Jesús (empresa chica) en vez de depender de un solo dato de Gonzalo — dos puntos de una distribución valen más que uno, y no dependen de que una sola relación comercial sobreviva.**

**Cupo de consultas incluido, con el piso de costo medido y confirmado en campo:**

| Margen objetivo | COGS disponible por equipo/mes | Consultas incluidas (a USD 0,0093 conservador) |
|---|---:|---:|
| 70% | USD 0,32 | **~32/equipo/mes** |
| 50% | USD 0,52 | ~53/equipo/mes |

La sesión de demo del 6 de agosto — [MATRIZ_DEMOS_PILOTOS_2026-08-07.md](MATRIZ_DEMOS_PILOTOS_2026-08-07.md), sección 1.1.a — midió un costo de **USD 0,0073 por interacción respondida**, dentro del rango esperado de USD 0,0061–0,0093 del `SAAS_COST_MODEL`. No cambia el piso de costo; lo confirma con un dato de campo real, no solo con carga sintética.

**El ratio equipos/técnico es la variable de pricing más importante que no tenemos, y Gonzalo puede darla en una frase.** Es la primera pregunta de mercado de la sección 8.

Ventajas adicionales del modelo por equipo: escala con el driver de ingreso del propio cliente (su cartera de contratos), es una línea proporcional y predecible en su presupuesto, se autoescala con el tamaño del cliente en vez de golpear igual a la microempresa que a la mediana (ver la tabla de resistencia del Modelo B más arriba), y desacopla nuestro precio de su rotación de personal — que en este rubro es alta y es precisamente uno de los dolores que el producto ataca.

### 3.1 Cuántos equipos tiene realmente una mantenedora mediana

El promedio nacional (44.000 equipos ÷ 220 mantenedoras ≈ 200) esconde una distribución muy desigual: el parque está concentrado en las multinacionales (Otis, Schindler, Thyssen, Kone) y en la cola larga de microempresas de un técnico-dueño que este mismo documento describe en la sección 2. Si las multinacionales concentran una porción sustancial del parque —esto es una estimación razonada, no un dato con fuente—, las 200+ empresas restantes se reparten un número bastante menor a 200 en promedio, y la mediana queda más abajo todavía por el sesgo de la cola. **Un primer cliente realista está en el rango de 40 a 100 equipos, no de 300 a 600.** La aritmética de la sección 10 se corrige con este dato.

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

| Contacto | Pregunta (formato indirecto) | Qué resuelve |
|---|---|---|
| **Gonzalo** | "¿Qué tan apretados son los márgenes de mantención hoy? ¿Cuánto espacio hay para que una herramienta nueva entre como costo adicional sin que duela?" | El supuesto de CLP 40.000 de margen por equipo (sección 5, tabla de resistencia del Modelo B) |
| **Daniel** | "¿Cómo es la estructura típica de facturación al edificio — por equipo o monto global por contrato? ¿Hay mucha variabilidad de precios entre empresas o está estandarizado?" | Valida el rango CLP 80.000–220.000 de Habitissimo (sección 4) contra un contratista que factura a varias mantenedoras, y decide si el Modelo C habla el idioma de facturación que el cliente ya usa |
| **Abel** | "En empresas del tamaño de Tecnicall, ¿un técnico lleva una cartera fija de equipos o va rotando según la contingencia?" | Un punto de la tensión del ratio equipos/técnico en empresa mediana (sección 5, Modelo C) |
| **Jesús** | "¿Cada técnico en tu empresa tiene una ruta fija de equipos o van asignando según las emergencias del día?" | Un punto del ratio en empresa chica — la cola larga que domina el conteo de la sección 2 |

Con dos o más respuestas de la tensión del ratio (Abel y Jesús) y una lectura de margen independiente (Gonzalo), la sección 5 deja de resolverse con un solo dato de una sola persona contingente y pasa a tener un rango de campo defendible en una postulación a fondos.

### 8.2 Preguntas que quedan para el almuerzo de septiembre con Gonzalo

Estas requieren tiempo y contexto presencial, y no caben en un mensaje corto:

1. ¿Cuántos servicios diarios por técnico, y cuántas consultas a manual por servicio?
2. ¿Cuánto factura una certificación, y cuántas alcanza a hacer un certificador en un día?
3. ¿Cuántos llamados por falla recibe al mes por cada 100 equipos en cartera? Es el proxy operativo más cercano a un dato público de incidencia que existe para este mercado, y calibra el cupo de consultas del correctivo.
4. ¿Quién firma el cheque de software en una mantenedora, y hasta qué monto pasa sin comité?
5. ¿Cuánto le cuesta a la empresa perder un técnico senior?
6. ¿Qué tamaño tiene el mercado informal de equipos sin certificar, desde lo que él ve en terreno?

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

1. **El encuadre correcto es participación en ingresos, no ahorro de horas.** CLP 1.000 por equipo es 0,45%–1,25% de lo que el cliente ya factura por ese equipo. Ese argumento se sostiene solo y no depende de estimar horas ahorradas, que además es exactamente la cifra que un comprador escéptico va a discutir.
2. **El valor no temporal tiene que entrar al pitch con evidencia, no como adorno:** retención de conocimiento cuando se va el especialista, reducción de la dependencia del jefe técnico como cuello de botella, y evidencia trazable para respaldar trabajos y pagos. Los tres salieron de entrevistas independientes y ninguno se mide en horas.
3. **Bajar el COGS es una palanca comercial, no solo técnica.** Cada dólar que baja el costo variable por usuario amplía el rango de precios defendibles. Esto conecta directamente con las reglas de costo de Bedrock del repositorio: perfil de inferencia global por defecto, retrieval adaptativo y compactación de prompt no son optimizaciones estéticas, son grados de libertad de pricing.

---

## 10. Aritmética de la escalera de rentabilidad bajo el modelo por equipo

Reemplaza la aritmética por técnico del plan general anterior. Supone CLP 1.000 por equipo y COGS conservador de USD 13,87 por usuario/mes.

| Hito | Fecha | Criterio medible |
|---|---|---|
| Primer contrato pagado | Noviembre 2026 | Una mantenedora mediana convierte desde el piloto de octubre. A **40–100 equipos** (sección 3.1, corregido desde el supuesto anterior de 300–600): CLP 40.000–100.000/mes (USD 42–105) |
| Danebo cubre su propio COGS | Diciembre 2026 | **Base combinada superior a ~850 equipos**, que a CLP 1.000/equipo da USD 895/mes contra un COGS de USD 416 para 30 usuarios: margen bruto 53%. Con clientes de 40–100 equipos, eso son **9 a 14 mantenedoras medianas**, no "dos clientes" — el objetivo de alto valor pasa a ser una mantenedora mediana-grande, no cualquier logo |
| Cubre el costo de vida del fundador | Q1 2027, explícitamente fuera de 2026 | CLP 3.500.000/mes exige del orden de 3.500 equipos a CLP 1.000, o ~2.300 a CLP 1.500: treinta y cinco a ochenta y siete mantenedoras del tamaño de la sección 3.1, o cuatro a seis si se logran clientes grandes de 300+ equipos |

El criterio de diciembre queda expresado como un número verificable — base combinada de equipos — y no como "dos clientes", porque dos clientes chicos no alcanzan el margen y dos clientes medianos lo superan con holgura. La cifra a vigilar es la base de equipos, no el conteo de logos. **Corregir el supuesto de tamaño de cliente (300–600 → 40–100 equipos) sube el número de logos necesarios en el mismo orden de magnitud, y es la razón de más peso para que la red de Gonzalo, que puede abrir puertas a clientes mediano-grandes en vez de solo microempresas, importe tanto como se plantea en el Plan General, sección 9.**

---

## 11. Qué queda pendiente antes de poder cotizar

El gate vigente es que no se cotiza sin precio decidido y costo por usuario medido. Lo que falta, en orden:

1. **Ratio equipos/técnico** (pregunta 1 a Gonzalo). Sin esto el modelo por equipo no se puede fijar.
2. **COGS de voz por dictado** (medición del mes de construcción). Sin esto el modelo por informe no tiene margen conocido.
3. **Volumen de consultas por técnico/mes**, por carga sintética representativa y por el laboratorio de Venezuela, para verificar que el cupo incluido no sea el que rompe el margen.
4. **Decisión interna de precio**, en septiembre, sobre las tres anteriores.

---

## 12. Fuentes

- **Registro Nacional MINVU, nómina de inscritos al 3 de junio de 2026** — fuente del conteo oficial de 220 mantenedoras, 56 certificadoras y 57 instaladoras. Es también la fuente que cierra la verificación del rol de Gonzalo: ATLAGICH Ascensores SpA figura como mantenedora, Rol 324, y no como certificadora (Plan General, sección 9.7).
- Registro Nacional MINVU, nóminas anteriores (2021, 2025) y Ley 20.296, conservadas para la serie histórica.
- Material de inspección de CENTRAVE A.G. sobre periodicidad, ítems de inspección y contenido de Carpeta Cero según Decreto 37 MINVU.
- Mercado Público, rubro 72101506: adjudicaciones de Puerto Montt, Hospital Lonquimay y Hospital de Linares.
- Habitissimo, rangos de mantención mensual por ascensor en mercado privado.
- Ocho entrevistas consolidadas, julio–agosto 2026, y reunión con Gonzalo del 6 de agosto de 2026.
- [SAAS_COST_MODEL_2026-06-12.md](SAAS_COST_MODEL_2026-06-12.md) para COGS y pisos de precio.
- Referencia de pricing genérica de mayo de 2026, conservada solo como lectura de expectativa de mercado.
