# Danebo — Plan General (2026-08-07)

**Reemplaza:** [PLAN_GENERAL_2026-08-06.md](PLAN_GENERAL_2026-08-06.md), que a su vez reemplazó la planificación general de julio.
**Motivo de esta actualización:**

1. La demo con Gonzalo del 6 de agosto se ejecutó y superó lo esperado: aparece la posibilidad real de un mentor y potencial socio con visión comercial de mercado, lo que ahorra tiempo y dinero de descubrimiento y fortalece una repostulación a fondos.
2. Entran datos de mercado verificables — registro MINVU, parque de equipos, licitaciones públicas — que permiten fijar unidad de cobro con anclas reales en vez de intuición.
3. El módulo certificador se aterriza contra el formato chileno real (Ley 20.296, ítems de inspección de CENTRAVE, Carpeta Cero según Decreto 37 MINVU).
4. Se incorpora el feedback evaluado de Start-Up Chile Ignite —ranking, notas por criterio y observaciones textuales— como hoja de ruta de la repostulación, con la regla explícita de no darle crédito al runway (sección 8.1).
5. El runway se recalculó con las cifras reales de caja, el gasto del viaje leído en euros y el depósito a 30 días: **9,2 meses de caja libre desde el 1 de septiembre**, y la brecha de reconciliación que se creía crítica queda cerrada (secciones 6.1 a 6.3).
6. Se recupera material de julio y de la planificación de diciembre que seguía siendo válido y se había perdido de vista.
7. Se separa explícitamente el track Gonzalo del roadmap de Danebo, con un plan B propio.

**Documentos hijos:** [Plan de Agosto](PLAN_AGOSTO_2026-08-07.md) · [Plan de Septiembre](PLAN_SEPTIEMBRE_2026.md) · [Mercado y pricing](PRICING_Y_MERCADO_2026-08-07.md) · [Matriz de demos y pilotos](MATRIZ_DEMOS_PILOTOS_2026-08-07.md)

---

## 0. Reglas fijas que no cambian

Ninguna sección de este documento puede contradecirlas:

- No pronunciar "socio" primero. La secuencia es asesor → asesor recurrente → socio, y emerge; no se propone.
- No revelar precio propio. Se preguntan precios, no se proponen.
- No nombrar fuentes de entrevistas.
- Mostrar el qué, nunca el cómo: sin arquitectura, sin modelos, sin costos.
- Danebo no certifica, no diagnostica, no determina operatividad y no reemplaza criterio técnico autorizado.
- **Toda planificación cuenta solo días hábiles.** Los fines de semana no se planifican ni se cuentan como capacidad, en ningún documento de esta serie.

---

## 1. Decisión central

La pregunta de julio — si existe dolor real — está respondida con ocho entrevistas y cuatro perfiles de alto encaje. La pregunta vigente es más exigente:

> ¿El mismo asistente, operado por voz en terreno — dictado para el certificador, conversación hands-free para el mantenedor — resuelve el problema de usabilidad que el canal de texto no resolvió, a un costo que sostiene un negocio con clientes pagando antes de fin de año?

Todo lo demás — corpus, arquitectura RAG, guardrails — es infraestructura al servicio de esa pregunta, no el producto.

---

## 2. Tesis: el problema era el canal

> El conocimiento documental multimarca ya existía en la propuesta original. Lo que faltaba no era más contenido ni más precisión, sino un canal de interacción compatible con las condiciones reales de terreno: manos ocupadas, guantes, grasa, poca luz, apuro. La voz no es una función adicional; es la interfaz que hace utilizable lo que el RAG ya sabe.

La evidencia es convergente y no inducida: el certificador entrevistado probó una herramienta de IA con formularios y fotos, tardó más que con lápiz y papel, y volvió al papel. Dos entrevistados independientes mencionaron los guantes sin que se les preguntara. La síntesis de las ocho entrevistas lo dejó como hipótesis crítica: la respuesta correcta no basta, tiene que ser más fácil que el método actual.

**Frase base de producto:**

> "Danebo es un asistente técnico de campo que se opera por voz. Consulta manuales, dicta hallazgos y genera informes con fuentes trazables, sin reemplazar el criterio del técnico, mantenedor o certificador autorizado."

---

## 3. Dos artefactos, dos modelos de negocio, una tecnología

| | Certificador | Mantenedor |
|---|---|---|
| **Vive de** | Su informe de inspección | La reparación; regala su informe como valor agregado |
| **Interacción** | Dictado en terreno, ítem por ítem, con foto adjunta | Conversación hands-free sobre lo que está viendo |
| **Salida** | Borrador de informe que él revisa, corrige y firma | Respuesta hablada + trazabilidad de lo consultado |
| **Corpus** | Normas técnicas chilenas (acotado, barato de alimentar) | Manuales de fabricante (extenso, cientos de páginas × decenas de marcas) |
| **Unidad de cobro** | Por informe generado | Por equipo gestionado |
| **Conflicto de interés** | Ninguno: un mantenedor no puede certificar y viceversa (restricción legal) | |

**Techo relativo, para no equivocar el orden.** El parque nacional genera 22.000–30.000 certificaciones al año, del orden de 2.000 informes al mes en todo el país. Es un modelo de buen margen y volumen nacional bajo: no es el que financia el sueldo en 2026. El motor de ingresos de corto plazo es el mantenedor. El detalle completo de dimensionamiento está en [PRICING_Y_MERCADO_2026-08-07.md](PRICING_Y_MERCADO_2026-08-07.md).

---

## 4. El módulo certificador, aterrizado

Esto es lo que faltaba definir antes de construir en septiembre. La estructura ya no es una hipótesis: viene del material de inspección de CENTRAVE A.G., la asociación gremial de certificadores.

**Los ocho ítems de inspección** que estructuran el informe y, por lo tanto, el modelo de datos del borrador:

1. Carpeta de Ascensores
2. Cabina
3. Espacio de máquinas
4. Contrapeso
5. Caja de elevadores
6. Pozo de ascensores
7. Puertas y cerraduras
8. Suspensión, cables y amarras

**La norma aplicable depende del año de recepción municipal definitiva del edificio:**

| Grupo | Recepción definitiva | Ascensor eléctrico | Ascensor hidráulico |
|---|---|---|---|
| 1 | Anterior al 24-10-2010 | NCh3395/1:2016 | NCh440/2:2001 |
| 2 | 24-10-2010 a 28-02-2017 | NCh440/1:2000 | NCh440/2:2001 |
| 3 | Posterior al 01-03-2017 | NCh440/1:2014 | NCh440/2:2015 |

**Periodicidad:** cada 2 años en destino vivienda, cada 1 año en destino equipamiento. Para edificios con recepción definitiva posterior al 21-03-2016, la certificación cae en el mes de la recepción definitiva.

**La salida es el "Informe Final"**, que detalla individualmente los hallazgos de los equipos, su estado y las recomendaciones, según la norma que aplica. Junto con el Certificado de Conformidad emitido por el certificador en el portal MINVU, forma parte de la Carpeta de Ascensores ("Carpeta Cero") que exige la Dirección de Obras Municipales.

### 4.1 Una decisión de diseño que ahorra una llamada al modelo

La selección del grupo normativo es una **regla de calendario**, no un juicio técnico: dada la fecha de recepción definitiva que el propio certificador ingresa, el grupo y las normas aplicables se derivan de forma determinista en Rails. Esto es exactamente lo que pide la regla de arquitectura del repositorio — lógica determinista antes que una llamada adicional al modelo — y además es más seguro: no hay margen para que el sistema alucine una norma.

**Con un límite explícito que no se cruza:** presentar la norma aplicable es una ayuda documental derivada de una fecha. No es una evaluación de cumplimiento. Danebo no decide si el equipo cumple esa norma.

### 4.2 Red line del módulo

- Danebo **transcribe y estructura** lo que un certificador autorizado dicta en terreno: hallazgo, ítem de inspección, ubicación, foto, referencia normativa que el propio certificador identifica.
- Danebo **no evalúa cumplimiento**, no clasifica gravedad, no decide si un equipo aprueba o reprueba, y no firma nada.
- El certificador revisa, edita y firma. La firma y el juicio profesional son y siguen siendo suyos.
- Todo documento exportado por Danebo sale marcado como **borrador** hasta que sale de Danebo.

Frase de producto para este módulo:

> "Danebo transcribe y organiza el dictado del certificador en un borrador de informe con evidencia fotográfica asociada. El certificador revisa, corrige y firma. Danebo no evalúa cumplimiento ni determina aprobación."

### 4.3 De qué formato NO se parte

El formato de informe que aportaron los hermanos (Climb, Caracas) es un **informe correctivo de mantenedor**: reporte de falla del cliente, narrativa de acción correctiva con fotos, presupuesto de mano de obra y condiciones de pago. Es un artefacto útil y sirve como plantilla del **artefacto mantenedor** y del laboratorio de Venezuela. No es el formato del certificador chileno y no debe filtrarse a ese módulo. El módulo certificador de Chile parte de la estructura de la sección 4, no de esa plantilla.

### 4.4 Restricción de usabilidad heredada de la entrevista

El certificador entrevistado abandonó una herramienta previa porque las tablas rígidas no se adaptaban a la estructura variable de los ascensores y registrar el piso ya era engorroso. Consecuencia de diseño, no de UI: **la captura es dictado libre y la estructura se aplica después.** No se construyen formularios extensos ni se obliga a clasificar durante la inspección.

---

## 5. Pricing: la decisión y su calendario

El desarrollo completo está en [PRICING_Y_MERCADO_2026-08-07.md](PRICING_Y_MERCADO_2026-08-07.md). Lo que el plan general fija:

| Segmento | Unidad de cobro |
|---|---|
| Mantenedor | **Por equipo gestionado**, con cupo de consultas incluido |
| Certificador | **Por informe generado** |
| Onboarding de manuales | Cobrado aparte, con su propio margen |
| Por empresa | Descartado: techo de mercado de USD 138k, inviable |
| Por token de cara al cliente | Descartado |

**Por qué no por token, resumido:** una factura que el cliente no puede proyectar bloquea la decisión de compra en un mercado donde el precio domina; cobrar por consumo hace que el técnico se autocensure y contamina la medición de adopción que el piloto existe para hacer; "token" no es una unidad de valor en el idioma del cliente; y no necesitamos transferir una varianza que ya tenemos acotada. La medición por token se queda adentro, como control de costo y base de los cupos.

**El riesgo real, por escrito antes de negociar:** el ahorro de tiempo por sí solo no financia el precio. Aplicando la regla de cobrar 10–20% del ahorro, tanto el tiempo de búsqueda como una revisita evitada al mes dan cifras por debajo de nuestro propio piso de costo por usuario. El encuadre que sí se sostiene es participación en los ingresos que el cliente ya factura: CLP 1.000 por equipo es 0,45%–1,25% de la mantención mensual de ese equipo. Ese argumento no depende de estimar horas y no es discutible por un comprador escéptico.

**Calendario.** El precio se decide internamente en septiembre, sobre costo medido y sobre las respuestas de mercado que dé Gonzalo, para tener cifra lista al cerrar el piloto de octubre. Gonzalo ayuda a **calibrar**, respondiendo preguntas de volumen y de facturación del rubro; no participa de la decisión ni conoce el número.

---

## 6. Runway y caja

### 6.0 Parámetros de conversión

Fijos para toda la serie de documentos. No se recalculan por documento.

| Parámetro | Valor |
|---|---:|
| USD | CLP 950 |
| **EUR** | **CLP 1.050** |
| UF | CLP 39.000 |

El parámetro EUR se agrega porque el control de gastos del viaje está en euros. El resumen de esa planilla dice "USD" y "montos en USD", pero la columna de detalle está rotulada "Monto EU" y el gasto ocurrió en Europa: **se lee todo en euros** y el encabezado se trata como error de rótulo.

### 6.1 Situación al 7 de agosto de 2026

| Fuente | Monto |
|---|---:|
| Depósito a plazo fijo, renovable a **30 días** | CLP 51.000.000 |
| Cuenta corriente | CLP 2.000.000 |
| AFC por recibir | CLP 4.000.000 |
| **Subtotal** | **CLP 57.000.000** |
| Saldo comprometido del viaje (**EUR 3.500** × 1.050) | − CLP 3.675.000 |
| **Caja operativa disponible** | **≈ CLP 53.300.000** |

Se usan EUR 3.500 y no los EUR 3.400 de la planilla como criterio conservador. Esos EUR 100 de margen equivalen a CLP 105.000 y **absorben la comisión internacional y el spread cambiario** de pagar con tarjeta en moneda extranjera (1,5%–3% en Chile, ≈ CLP 70.000 sobre ese monto), así que no se suman aparte.

**El reloj arranca el 1 de septiembre, no hoy.** El presupuesto mensual de CLP 3.500.000 de agosto ya está gastado —la mesada de USD 250 a los padres va dentro de él, no aparte— así que el saldo de la tabla ya refleja el consumo de agosto. Contar agosto otra vez sería descontarlo dos veces.

| Burn mensual de planificación | Runway total desde el 1 de septiembre | Se agota alrededor de |
|---|---:|---|
| CLP 3.200.000 | 16,7 meses | fines de enero 2028 |
| CLP 3.500.000 | 15,2 meses | principios de diciembre 2027 |

**Reserva intocable**, heredada de la planificación de diciembre y que se mantiene: seis meses de burn, CLP 21.000.000, como piso de decisión y no de operación. Descontada la reserva, la caja de decisión libre es de CLP 32.300.000, equivalente a **9,2 meses de ejecución antes de tocar el piso**, contados **desde el 1 de septiembre de 2026**.

Esa es la cifra que importa: no hay 15 meses de libertad, hay 9.

**Caja libre mes a mes**, a un burn de CLP 3.500.000:

| Fecha | Caja libre | Meses libres restantes |
|---|---:|---:|
| 1 sep 2026 | CLP 32,3M | 9,2 |
| 1 oct 2026 | CLP 28,8M | 8,2 |
| 1 nov 2026 | CLP 25,3M | 7,2 |
| **1 dic 2026** | CLP 21,8M | **6,2** |
| 1 ene 2027 | CLP 18,3M | 5,2 |
| 1 mar 2027 | CLP 11,3M | 3,2 |
| 1 may 2027 | CLP 4,3M | 1,2 |
| ~10 jun 2027 | CLP 0 | 0 — se toca la reserva |

Al agotarse la caja libre la reserva de CLP 21.000.000 sigue **intacta**: son seis meses más al mismo burn, hasta principios de diciembre de 2027, lo que cuadra con los 15,2 meses de runway total.

**Dos lecturas que hay que tener presentes sobre esta tabla.**

La reserva no es operación, es piso de transición: cuando se entra en ella la decisión ya se tomó. La fecha límite real es **junio de 2027**, no diciembre, y por eso los gates de octubre y diciembre caen muy antes. El gate del 31 de diciembre encuentra 6,2 meses libres más 6 de reserva, que es margen suficiente para decidir sin apuro — exactamente para lo que existe.

Y toda la tabla supone un burn de CLP 3.500.000. Si el burn efectivo estuviera más cerca de CLP 5.000.000, la caja libre pasa de 9,2 a **6,5 meses** y la reserva de 6 a **4,2 meses**. Ese es el motivo para vigilar el burn real contra el presupuesto, no solo el saldo.

### 6.2 Reconciliación de caja — cerrada

Esta sección advertía de una brecha de CLP 8.000.000 sin desglose. **La brecha era un error de cálculo: no se estaba contando el burn normal como salida legítima.** Con el dato de que el presupuesto de agosto ya está consumido, la aritmética cierra:

| Concepto | Monto |
|---|---:|
| Caja base de julio | CLP 60,45M |
| AFC recibido (de CLP 10,8M esperados, quedan 4,0M) | CLP 6,8M |
| **Ingreso acumulado desde el 1 de julio** | **CLP 67,25M** |
| Saldo líquido hoy | CLP 53,0M |
| **Salida acumulada** | **CLP 14,25M** |
| — Burn de julio | 3,5M |
| — Burn de agosto, ya gastado | 3,5M |
| — Viaje pagado: EUR 3.600 × 1.050 | 3,78M |
| — Calibración de Danebo: USD 500 + CLP 200.000 | 0,68M |
| — Extraordinarios de julio autorizados: tabla de surf 1,0M, computadora 0,5M, colchón 0,3M | 1,8M |
| **Total explicado** | **CLP 13,26M** |
| **Residuo sin explicar** | **≈ CLP 1,0M** |

CLP 1.000.000 sobre dos meses de gasto doméstico es ruido de conciliación, no una fuga. **La reconciliación baja de P1 crítica a chequeo de rutina**, y se levanta la restricción de no tocar el presupuesto.

**Salvedad que mantiene la tarea con vida:** la caja base de CLP 60,45M de julio y los CLP 1,8M de extraordinarios se arrastran del plan anterior. Si alguno era estimación y no dato real, la brecha reaparece. Un cruce rápido de cartolas lo confirma, pero ya no es una alarma.

### 6.3 Liquidez del viaje — detalle operativo a confirmar antes del 11 de agosto

Los EUR 3.500 se gastan durante el viaje pero salen de caja cuando se paga el estado de cuenta de la tarjeta, en un solo pago apenas se libere el depósito. Eso evita cuotas e intereses y simplifica la contabilidad: es una salida única, no un arrastre de tres meses.

Con vencimiento a 30 días hay una ventana de liberación mensual, así que el pago se calza contra un vencimiento en vez de romper el depósito. Quedan dos detalles por confirmar en el banco — no son riesgo grande, son molestos de descubrir en el mesón:

1. **Fecha de facturación de la tarjeta contra fecha de vencimiento del depósito.** Si la tarjeta vence antes del próximo vencimiento, quedan CLP 2.000.000 en cuenta corriente frente a un cargo de ≈ CLP 3.675.000. Es un problema de calendario, no de fondos.
2. **Si el producto permite retiro parcial**, o si obliga a romper todo el capital y re-depositar. En el segundo caso el re-depósito reinicia el reloj de 30 días y posiblemente a otra tasa.

### 6.4 Gasto de Danebo

- Gasto extraordinario de calibración ya ejecutado: USD 500 en APIs de Anthropic y CLP 200.000 en herramientas de desarrollo. **No es costo normal por usuario** y no debe contaminar el modelo de costos.
- Tope de gasto operativo de Danebo hasta el piloto: se mantiene la disciplina de julio y agosto. No se abre presupuesto nuevo sin señal comercial concreta.
- El COGS variable medido y sus pisos de precio están en [SAAS_COST_MODEL_2026-06-12.md](SAAS_COST_MODEL_2026-06-12.md), que sigue siendo la única autoridad de costos.

---

## 7. Las tres agujas

Recuperado de la planificación de diciembre porque sigue siendo el mejor filtro de foco semanal que se ha escrito para este proyecto. Cada semana debe mover una de estas tres, en este orden:

1. **Primer pago.** Valida que existe un negocio.
2. **Comprador entrevistado.** Valida que existe presupuesto. Sigue siendo el vacío más grande: las ocho entrevistas cubren usuarios y validadores técnicos, y ninguna cubre a quien firma el cheque.
3. **Capital no dilutivo.** Extiende runway y trae la red y la accountability que faltan.

Si una semana no movió ninguna de las tres, fue una semana de mantenimiento, no de avance. Vale tenerlas, pero hay que saber cuántas van seguidas.

---

## 8. Capital no dilutivo y bancarización

| Frente | Estado | Regla |
|---|---|---|
| Start-Up Chile / CORFO | Repostulación, con tracción real de piloto. Ver 8.1 | La primera postulación fue rechazada en posición 431 de 587. **Cero crédito en el runway.** Postular con contrato firmado y con el rol de Gonzalo formalizado, no antes |
| Banco de Chile / B-Startup | Reunión del 05-08-2026 favorable. Ejecutivo identificado, dispuesto a incorporar la cuenta a su cartera | Secuencia: Inicio de Actividades → Cuenta FAN Emprende → avisar al ejecutivo. Sin costo de mantención |
| AWS Activate vía B-Startup | Potencial, sin garantía: alianza en armado, cupos internos por definir | **No basar ninguna decisión financiera en esos USD 5.000** |
| Platanus / Start-Up Chile | Ventanas a revisar en octubre–noviembre, con usuario pagando | Postular con tracción, no con idea |
| Mentoría | Vía programas y mentores de dominio | **No pagar mentoría en efectivo.** Lo que compran los programas no es conocimiento, es red y accountability |

Se registra el hito bancario tal cual ocurrió: Danebo fue considerado compatible con la etapa temprana que atiende B-Startup, sin que estar pre-revenue fuera un obstáculo, y el ejecutivo recomendó partir con una cuenta sin mantención y escalar productos según evolución.

### 8.1 El feedback de Start-Up Chile, leído en serio

Fuente: carta de resultado de la Dirección Start-Up Chile, instrumento **Start-Up Chile Línea 2 "Ignite", generación 12**, proyecto `danebo.ai`, código `26IGN-319562`, convocatoria del 4 de mayo de 2026. Se recibieron 587 postulaciones y participaron 279 evaluadores.

**Resultado: posición 431 de 587, nota final 3,43.** No fue un rechazo por poco.

| Criterio | Danebo | Promedio de los que avanzaron | Brecha |
|---|---:|---:|---:|
| Participantes | 3,75 | 5,89 | −2,14 |
| Valor del proyecto | 3,63 | 5,43 | −1,80 |
| — Oportunidad de mercado | 4,00 | 5,48 | −1,48 |
| — Producto o servicio | 3,75 | 5,39 | −1,64 |
| — **Tracción / validación comercial** | **2,50** | 5,29 | **−2,79** |
| — Impacto en Chile | 4,00 | 5,53 | −1,53 |
| Potencial de crecimiento | 2,88 | 5,24 | −2,36 |
| — Escalabilidad | 3,00 | 5,33 | −2,33 |
| — **Estrategia de crecimiento** | **2,75** | 5,16 | **−2,41** |
| **Nota final** | **3,43** | **5,46** | **−2,03** |

**Matiz que juega a favor:** 5,46 es el *promedio* de los proyectos que avanzaron, no el puntaje de corte. El corte está por debajo de esa cifra, así que la distancia real a superar es menor que la que sugiere la tabla.

**Lo que dijeron textualmente, y qué lo arregla:**

| Criterio | Observación de los evaluadores | ¿Lo arregla el roadmap actual? |
|---|---|---|
| Participantes | "Brechas relevantes en experiencia específica y en la existencia o calidad de **redes de apoyo y vínculos estratégicos**" | **Sí, y es la mejora más grande disponible.** No cuestionan la capacidad técnica, cuestionan la red. Gonzalo —14 años de rubro, red de mantenedoras— más la relación con B-Startup son respuesta directa |
| Tracción | "No se logra evidenciar que las actividades de validación comercial o tracción descritas sean lo suficientemente fuertes... no es determinante para demostrar un real interés del mercado objetivo" | **Sí.** Piloto de octubre y contrato pagado de noviembre atacan la peor nota y la mayor brecha |
| Producto o servicio | "Margen para mejorar en su valor agregado frente a potenciales y/o actuales competidores" | **Sí.** Es la objeción de ChatGPT, hoy con respuesta de cuatro pilares (sección 13), y la voz como interfaz no existía en la postulación de mayo |
| Oportunidad de mercado | "Espacio de mejora para evidenciar con mayor precisión el potencial real de la propuesta para capturar dicho mercado frente a la competencia" | Parcialmente, y mejor de lo que estaba: [PRICING_Y_MERCADO_2026-08-07.md](PRICING_Y_MERCADO_2026-08-07.md) aporta el dimensionamiento que faltaba, ahora con **conteo oficial** del registro MINVU (220 mantenedoras, 56 certificadoras) en vez de rangos estimados. El evaluador pedía "mayor precisión" literalmente: un rango se lee como falta de rigor, un conteo con fuente y fecha no |
| Escalabilidad y estrategia de crecimiento | "Información insuficiente sobre la existencia de un plan y metodología que permita el crecimiento exponencial y el escalamiento a nuevos mercados. **Los antecedentes son mínimos**" | **No.** Un piloto no arregla esto. Es un vacío documental, ver abajo |

**La tensión que hay que resolver por escrito, y que hoy no está resuelta.** El dimensionamiento honesto de mercado —TAM chileno de USD 278–834k en el modelo por equipo— hace más difícil, no más fácil, sostener una narrativa de "crecimiento exponencial y escalamiento a nuevos mercados". Chile se encuadra como **beachhead**, y el vector de expansión que se argumenta es **el mismo motor de voz + RAG aplicado a otros servicios de campo regulados**: el mecanismo de dictar en terreno, confirmar transcripción y producir un informe trazable no es específico de ascensores, y ahí el mercado direccionable es de otro orden de magnitud.

**Lo que explícitamente NO se usa como argumento de expansión: Venezuela.** Es un mercado completamente distinto —otra regulación, otra estructura de precios, otra realidad económica— y entrar ahí sería empezar de cero. Presentarlo como beachhead regional solo porque hay una empresa familiar operando allá es el tipo de antecedente que un evaluador descuenta de inmediato, y con razón. Venezuela es laboratorio, no camino de crecimiento (sección 10.1).

Si el vector regional se argumenta, tiene que ser sobre mercados donde exista un régimen de certificación obligatoria comparable al chileno, con datos que hoy no se tienen. Eso hay que escribirlo con método, no con adjetivos, y es el único entregable de postulación que no sale gratis del roadmap.

**Reglas que se derivan, y son las que importan:**

1. **Cero crédito en el runway.** Con 431 de 587, la expectativa honesta es baja, y aun aprobado el desembolso llega con rezago y sujeto a formalización. Es upside, no plan. Mismo tratamiento que los USD 5.000 de AWS Activate.
2. **La fecha de postulación sigue la decisión de Gonzalo, no la fuerza.** Postular sin su rol formalizado desperdicia la mejora más grande disponible en el criterio de peor brecha después de tracción. Si en noviembre él no ha decidido, se postula en la ventana siguiente.
3. **Verificar la línea correcta antes de repostular.** La carta invita explícitamente a "postular nuevamente a un próximo llamado a este concurso o a otros instrumentos". Con un cliente pagando, conviene revisar si Ignite sigue siendo el instrumento adecuado o si corresponde una línea posterior, donde la tracción pasa de ser la debilidad a ser el argumento. No asumir la fecha ni la generación: confirmarlas.
4. **El scorecard es una hoja de ruta gratis.** Las tres notas bajo 3,0 son exactamente lo que producen el piloto de octubre y el contrato de noviembre. El plan no cambia; lo que hay que hacer es **guardar la evidencia mientras se ejecuta**: acuerdo de piloto, métricas de uso, costo por consulta, carta de intención, rol formalizado. Así la próxima postulación es armado y no creación.
5. **Tope de tiempo: tres días hábiles**, y solo después de que exista el contrato. La postulación no puede comerse el mes de construcción ni el piloto, que son justamente lo que la hace competitiva.

**Nota de disciplina para esas conversaciones:** en la reunión funcionó no sacar CORFO, el viaje, la voz, los certificadores ni la regulación. Se explicó MVP → entrevistas → demos/piloto → validar comercialmente → medir costos → pricing, y el interlocutor pudo devolver el negocio con sus propias palabras. Ese es el nivel de compresión correcto para un interlocutor financiero.

---

## 9. Gonzalo: qué cambia, qué se conversa y qué no se apura

### 9.1 Por qué cambia el panorama

La demo del 6 de agosto **se ejecutó y superó lo esperado**: él la probó con sus propias preguntas técnicas difíciles en vez de mirarla, y de ahí salió espontáneamente la objeción competitiva más valiosa del descubrimiento. Es la única demo ejecutada del trimestre y abre la posibilidad de **mentoría y sociedad**.

Gonzalo aporta algo que no se compra con caja y que habría costado meses conseguir solo: criterio comercial de un rubro que él conoce por dentro, red de contactos, y una lectura de estrategia de mercado probablemente más acertada que la propia. Eso ahorra tiempo y dinero de descubrimiento, y le da forma a un emprendimiento que hasta ahora era técnicamente sólido y comercialmente ciego. También fortalece una postulación a fondos en noviembre: un equipo con conocimiento de mercado puntúa distinto que un fundador técnico solo.

Eso justifica tratarlo como el activo más valioso aparecido en cuatro meses. **No justifica acelerar la conversación de sociedad, ni forzar reuniones.**

### 9.2 La asimetría que ordena cualquier estructura

Conviene nombrarla antes de negociar, sin decírsela a él: el producto ya existe, funciona, y fue financiado con caja propia durante cuatro meses de riesgo asumido en solitario. El aporte de Gonzalo es futuro y contingente. Esa asimetría no lo desmerece, pero define la forma correcta de cualquier estructura: **participación que se gana contra hitos cumplidos, no que se otorga por entrada.**

### 9.3 Qué preguntas hay que resolver antes de comprometer nada

Se resuelven en conversación presencial, no por mensaje, y la primera oportunidad es el almuerzo de la primera semana de septiembre:

- ¿Qué aporta concretamente: red, conocimiento de mercado, conducción de la venta, acceso a manuales? ¿Con qué dedicación — horas comprometidas o mejor esfuerzo?
- ¿Aporta capital o solo trabajo?
- ¿Quién financia COGS e infraestructura? Hoy los financia el fundador.
- ¿Cómo se reparte utilidad antes de que exista utilidad? La respuesta correcta es que no se reparte: se define participación con vesting e hitos, y retiros solo cuando la empresa los sostenga.
- ¿Exclusividad? ¿Vendería a competidores de su empleador?
- ¿Su empleador conoce y aprueba su involucramiento?
- ¿Qué pasa si se retira en el mes tres? Sin cliff y sin vesting, esa pregunta la contesta un abogado y sale caro.
- Expansión regional: en qué condiciones, con qué mercados, y si es una ambición compartida o una proyección propia.

**Conflicto de interés a resolver explícitamente:** Gonzalo es comercial activo de una empresa mantenedora. Un socio comercial que además es empleado de un cliente potencial genera preguntas legítimas en ambas direcciones, y no se resuelven por defecto a favor de avanzar rápido.

### 9.4 El dilema: ¿confiar en su participación? ¿Hace falta un plan B?

Hay señales sólidas de que sí va a participar: agendó la demo, la probó él mismo con sus propias preguntas técnicas difíciles, el resultado superó lo esperado, se comprometió a entregar manuales, ofreció a sus técnicos y aceptó un almuerzo estratégico. Nadie hace eso por cortesía.

El dilema se disuelve al separar dos cosas que se están confundiendo en una sola:

| | ¿Se puede confiar? | Por qué |
|---|---|---|
| **Participación operativa**: acceso a sus técnicos, manuales de su red, criterio de mercado en conversación | **Sí** | Ya está ocurriendo, no le cuesta nada continuar, y si se cae, se pierden semanas, no la empresa |
| **Participación estructural**: socio, conducción comercial, equity, go-to-market | **No se puede depender** | La decisión no es solo suya: depende de su empleador, de su situación familiar, de su apetito de riesgo y de que Danebo siga pareciéndole atractivo en tres meses |

**La regla que resulta: confiar en él operativamente, no depender de él estructuralmente.** No es desconfianza, es aritmética de dependencias.

### 9.5 Sobre el plan B: sí, pero no el que se está imaginando

Un plan B no es un plan paralelo que se construye y se mantiene. Eso sería caro, partiría el foco y es exactamente lo que no hay que hacer con 15 días hábiles de construcción en septiembre.

Un plan B aquí es **una pregunta contestada de antemano**: si Gonzalo dice no en septiembre, ¿qué se hace el lunes siguiente? Si eso se puede responder en tres frases, el plan B existe y no cuesta nada:

1. Outbound directo sobre el registro MINVU: **220 mantenedoras y 56 certificadoras**, conteo oficial de la nómina al 3 de junio de 2026, pública y verificable, con dirección y teléfono por empresa.
2. El módulo certificador sigue igual: su estructura viene de CENTRAVE y MINVU, no de Gonzalo (sección 4).
3. Los hermanos siguen cubriendo el laboratorio y el formato de informe correctivo del artefacto mantenedor (sección 10).

Listo. Ese es el plan B completo. No requiere documento propio, ni pipeline paralelo, ni inversión de cobertura.

**Lo único que sí vale la pena ejecutar como seguro, y cuesta una hora:** probar outbound una vez, a escala mínima, antes de noviembre. Cinco correos a mantenedoras de la nómina MINVU. Eso convierte el plan B de hipótesis en canal medido.

Y aquí está la parte que resuelve el dilema del gasto: **ese test hay que hacerlo igual, incluso si Gonzalo dice sí.** Un contrato conseguido a través de un solo contacto personal no demuestra un negocio replicable, y el propio dato de la matriz lo respalda — cuatro contactos cálidos de entrevistas produjeron cero pilotos, así que la red de contactos no es un canal de adquisición. El plan B y lo que hace falta de todas formas son la misma cosa, así que el seguro sale gratis.

### 9.6 Tripwire: cómo saber antes de tener que apostar

No hace falta decidir hoy si se confía en Gonzalo. Hacen falta tres observaciones fechadas, baratas y verificables, que responden la pregunta antes de que haya algo en juego:

| Fecha | Observación | Qué significa si no ocurre |
|---|---|---|
| **Primera semana de viaje** | ¿Llegan los manuales que prometió? | Es la señal más temprana y más barata de todas. **Es la observación clave, y es mejor señal que un café**: una reunión puede fallar por agenda, un enlace de Drive no. Un compromiso concreto incumplido tras un recordatorio suave es información de primer orden |
| **Durante el viaje** | ¿Sus técnicos usan el sistema de forma voluntaria? | Si él no logra que su propio equipo lo pruebe, tampoco va a lograr que un cliente lo compre. Se mide en `bedrock_daily_costs`, sin preguntarle |
| **Antes del 3 de septiembre** | ¿Confirma fecha concreta del almuerzo? | Una fecha que se posterga dos veces es un no que todavía no se dice |

Si las tres ocurren, la confianza está ganada con evidencia y no con optimismo. Si la primera no ocurre, se activa el outbound de la sección 9.5 en septiembre en vez de noviembre, y no se pierde el trimestre.

**Nota deliberada: el café del 10 de agosto no está en esta tabla.** Que no ocurra no es señal de nada — la agenda de un ejecutivo comercial un lunes cualquiera no dice nada sobre su interés, y forzar el viaje a Santiago con hora de dentista el mismo día y vuelo el martes tendría un costo real por un beneficio marginal. El primer acercamiento presencial ya ocurrió el 6 de agosto y salió mejor de lo esperado; la conversación que sí exige presencia es el almuerzo de septiembre. Ver [Plan de Agosto](PLAN_AGOSTO_2026-08-07.md), sección 3.

**Regla dura que cierra el tema:** ninguna decisión de producto, ningún gasto y ninguna fecha de este roadmap depende de que Gonzalo diga sí. El track de sociedad corre en paralelo y no desvía el plan. Lo mejor que se puede hacer ahora es **sacar los pilotos con él sin proyectarse más allá de eso.**

### 9.7 Verificación cerrada: es auditor de mantenedora, no certificador

Esta sección era una verificación pendiente. **Ya se ejecutó contra la fuente oficial y el resultado es concluyente.**

**Fuente:** nómina del Registro Nacional de Ascensores (MINVU) al 3 de junio de 2026, documento público.

| Hallazgo | Detalle |
|---|---|
| ATLAGICH ASCENSORES SPA figura en el registro | Sí, como **MANTENEDOR, Rol 324**, con dirección en Providencia y representante legal Rafael Atlagich |
| ATLAGICH figura como certificadora | **No.** No aparece en la sección de certificadores |
| Gonzalo Salazar figura a título personal como certificador | **No.** El registro inscribe empresas y su representante legal; su nombre no aparece en ninguna de las 56 certificadoras |

Esto confirma lo que ya decía el registro de entrevistas: es Ejecutivo Comercial / Auditor Técnico en una mantenedora desde mayo de 2023, y su "auditoría técnica" es auditoría visual de **ingreso a cartera** — evaluar si la empresa acepta un equipo en mantención. No es certificación legal. En su propia entrevista quedó anotado que **la certificación no apareció como usuario objetivo**.

**Consecuencias, que son las que importan:**

1. **El módulo certificador de septiembre se diseña contra CENTRAVE y el Decreto 37, no contra Gonzalo.** Es exactamente lo planificado, y ahora está confirmado en vez de supuesto. Carlos Schwartz (TAQUIÓN-CERT) sigue siendo la fuente de validación de formato.
2. **Su peso está del lado mantenedor**, que es el motor de ingresos de 2026 de todas formas. Como puerta de entrada al segmento con más equipos y al piloto de octubre, no baja de valor: el aporte que estaba en juego era el de design partner del módulo certificador, no el comercial.
3. **Se evitó un error caro:** diseñar el módulo asumiendo un usuario validador que no existe habría costado el mes de septiembre completo.
4. **El puente hacia CENTRAVE hay que construirlo por otra vía.** No llega por él.

Anotación sobre el peso relativo: un certificador tendría más peso específico para el módulo de septiembre, y esa lectura era correcta. Pero eso no es lo que hay, y el plan ya estaba escrito para el escenario que se confirmó — así que no cambia ninguna fecha.

### 9.8 Calendario de decisión del track Gonzalo

La señal de que quiere ser parte del proyecto fue fuerte, y por eso mismo lo inteligente es ir por pasos en vez de apostar. La forma de hacerlo sin postergar indefinidamente es separar dos cosas que suelen confundirse: **preguntar** y **decidir**.

| Momento | Qué ocurre | Qué NO ocurre |
|---|---|---|
| Agosto, durante el viaje | Se recogen las dos primeras señales del tripwire: manuales y uso voluntario de sus técnicos | No se conversa estructura |
| **Almuerzo de septiembre** | **Se hacen las preguntas** de la sección 9.3: aporte concreto, dedicación, capital o trabajo, exclusividad, conocimiento del empleador, vesting y cliff | **No se decide ni se compromete nada.** Es una conversación de levantamiento, no de cierre |
| **Después del piloto de octubre** | **Punto de decisión.** Es la primera vez que existe evidencia de si aporta comercialmente de verdad o solo tiene buenas intenciones | — |
| Antes de noviembre | La definición tiene que estar zanjada, porque noviembre es el primer contrato y si él participa del lado comercial eso se define **antes** de la venta, no durante | — |

**Por qué el punto de decisión es después de octubre y no es postergar.** Hoy hay entusiasmo y una demo exitosa; eso no es evidencia de aporte comercial. Después del piloto se sabrá si consiguió que sus técnicos usaran la herramienta, si su lectura de mercado fue específica o genérica, si se involucró en serio con las preguntas de estructura, y si su empleador es un obstáculo real — dato subestimado, porque es empleado de una mantenedora y eso puede bloquear todo independientemente de sus ganas.

**Qué se gana con esperar hasta ahí:** cinco datos duros en vez de una impresión. **Qué se pierde:** nada, porque la fase de asesor y acceso a técnicos no requiere ninguna estructura societaria para funcionar.

La restricción de disponibilidad personal no obliga a decidir en septiembre. Obliga a **preguntar** en septiembre, que es distinto y es más barato.

---

## 10. Venezuela y el rol de los hermanos

Es el laboratorio, no el mercado. La empresa de los hermanos importa Orona y opera en Caracas, sin cobro y con cuenta de datos aislada.

### 10.1 Tres delimitaciones que no se negocian

**No se monetiza, y no es la intención.** El módulo de informe del mantenedor implementado allá es exclusivamente piloto. Lo único que produce para ellos es ahorro de costos, y con eso basta. No hay línea de ingresos, no hay proyección de ingresos, y no entra en ninguna cifra de la escalera de rentabilidad.

**No son mentores, y no se cuentan como tal.** No es una mentoría directa ni una disponibilidad sin límites: es una empresa familiar con su propia operación que ayuda cuando puede. Por eso no figuran como equipo, ni como asesores, ni como red de apoyo — tampoco en una postulación a fondos, donde inflar ese vínculo sería exactamente el tipo de antecedente que un evaluador descuenta.

**El mercado venezolano es completamente distinto al chileno.** No es una extensión ni un mercado adyacente: entrar ahí sería empezar de cero, con otra regulación, otra estructura de precios y otra realidad económica. En consecuencia, **Venezuela no se usa como argumento de expansión regional** ni como beachhead de nada. Está en el plan porque es un laboratorio disponible, no porque sea un camino de crecimiento.

### 10.2 Lo que sí valida, y es más de lo que parecía

El aporte real es mayor que "probar la voz en un foso ruidoso", porque **el informe correctivo del mantenedor y el informe del certificador comparten exactamente la misma mecánica: dictar → transcribir → confirmar → estructurar → borrador editable.** Lo que cambia entre ambos es el formato de salida y el marco regulatorio, no el mecanismo.

Eso convierte a Venezuela en la prueba funcional del mismo pipeline que se construye en septiembre, con usuario real y artefacto real, y con riesgo comercial cero:

- El bucle completo de dictado a informe, extremo a extremo, antes de que lo toque un certificador chileno.
- Adopción voluntaria del canal de voz frente al texto.
- Condiciones acústicas reales de foso y sala de máquinas.
- Tasa de error de transcripción sobre jerga técnica real en terreno.
- Si el borrador persistente sobrevive de verdad a una interrupción en terreno.

Es la única fuente de uso real disponible antes de octubre, y ahora también la única forma de probar el mecanismo central del módulo certificador sin quemar el contacto de TAQUIÓN-CERT.

### 10.3 Lo que no valida

Demanda del mercado chileno, precio, o disposición a pagar. El sesgo familiar garantiza que lo usen, así que ese uso no es evidencia de mercado y no cuenta como cliente.

**Y el límite de formato, que es el más fácil de cruzar por accidente:** aportan la plantilla del informe correctivo del **artefacto mantenedor**, no el formato del certificador chileno, que viene de CENTRAVE y MINVU. Confundir ambas cosas metería un formato venezolano de mantención dentro de un módulo regulatorio chileno.

**Nota de discurso, ya usada con éxito:** el dolor se descubrió en Venezuela; la validación comercial es en Chile, independiente y con actores no relacionados. Los hermanos no forman parte del equipo ni cumplen rol de mentoría. Esa delimitación fortalece la historia de validación en vez de debilitarla.

---

## 11. Consultoría como flujo de caja: no, y con fecha para reevaluarlo

La pregunta era si conviene abrir un servicio de consultoría por cuenta propia como flujo de caja. La respuesta es **no entre el 7 de septiembre y el 31 de octubre**, y la razón no es ideológica:

La consultoría compite por el recurso más escaso exactamente en el mes de construcción y en el piloto. Con 15 meses de runway y 9 meses de caja de decisión libre, **la caja no es la restricción vinculante; el tiempo hasta la evidencia sí lo es.** Vender horas convierte el recurso escaso — horas de fundador — en el recurso abundante. Es el intercambio equivocado en el peor momento posible.

**Se reevalúa el 1 de noviembre**, y solo si el primer contrato no cerró. Si en ese momento se abre, con dos condiciones: que sea asesoría de IA/RAG posicionada bajo la marca Danebo, de modo que alimente la misma narrativa y la misma red, y que tenga un tope de horas semanales declarado por escrito. Consultoría genérica de Rails no cumple ninguna de las dos.

---

## 12. Prioridades

Esta es la sección que decide qué se hace cuando no alcanza el tiempo.

### P0 — no negociable, nada las desplaza

1. **Idioma español por defecto** antes de entregar acceso a los técnicos de Gonzalo. Bloqueante: en la demo del 6 de agosto la lectura de consola salió en inglés y él lo notó. Sin café confirmado, esto sube de importancia: los manuales pueden llegar cualquier día del viaje y el acceso hay que poder entregarlo en ese momento.
2. **Conseguir los manuales de Gonzalo**, por el canal que sea. El entregable es el archivo, no la reunión. El café del 10 de agosto no está confirmado y no se fuerza; el track pasa a asincrónico con un toque semanal durante el viaje.
3. **Cerrar fecha del almuerzo estratégico de septiembre**, ahora que el impulso de la demo está en su punto máximo y no en tres semanas desde Europa.
4. **Módulo certificador en septiembre:** borrador persistente, dictado, transcripción visible y editable. El mes tiene 15 días hábiles efectivos por el jet lag del regreso y Fiestas Patrias, así que el alcance se recorta según la escalera ya decidida y no se improvisa.
5. **"La IA pide el manual" cuando hay evidencia mezclada de varios fabricantes.** Sube de P1 a P0 con evidencia medida: la sesión del 6 de agosto registró 36,4% de abstención global, y el patrón dominante es retrieval que trae hasta 7 fabricantes a la vez para una pregunta que no nombra ninguno — el sistema correctamente se niega a mezclarlos, pero abstiene en silencio en vez de preguntar "¿de qué fabricante?". Los chunks recuperados ya traen el fabricante en metadata, así que el arreglo no pide una llamada extra al modelo. Ver [MATRIZ_DEMOS_PILOTOS_2026-08-07.md](MATRIZ_DEMOS_PILOTOS_2026-08-07.md), sección 1.1.a.
6. **Medición del COGS de voz** en septiembre.
7. **Decisión interna de precio** en septiembre.
8. **Piloto en terreno en octubre**, primer contrato en noviembre.

### P1 — se hace si P0 no está en riesgo

9. **Cruzar fecha de facturación de las tarjetas con el vencimiento del depósito a 30 días**, antes del 11 de agosto (sección 6.3). Evita romper el depósito fuera de ciclo y perder intereses devengados.
10. **Test de outbound sobre el registro MINVU**: cinco correos a mantenedoras de la nómina pública, antes de noviembre. Una hora. Es simultáneamente el plan B y el canal que hay que validar aunque Gonzalo diga sí (sección 9.5).
11. **Un intento más con Abel**, con un pedido de un minuto en vez de un piloto: que mande un manual y su pregunta más difícil, y recibe la respuesta con página exacta en 24 horas. Ya ofreció su Drive, así que es la señal de intención más alta que se dejó sin convertir. Cuesta un mensaje.
12. **Decisión de conectividad** para terreno sin red.
13. **Laboratorio de Venezuela activo** durante el viaje.
14. **Batería de generalización** del benchmark: variador de frecuencia, sistema de puertas, códigos de error de consola.
15. **Bancarización:** Inicio de Actividades → FAN Emprende → avisar al ejecutivo.
16. **Crear cuenta propia por contacto antes de cada demo.** La sesión del 6 de agosto corrió bajo la cuenta de Abel porque no se creó una para Gonzalo a tiempo. No afectó el resultado cualitativo, pero mezcló telemetría y hay que evitarlo desde la próxima demo (matriz, sección 1.1).
17. **Repostulación a Start-Up Chile**, no antes de que exista contrato firmado y el rol de Gonzalo formalizado. Tope de tres días hábiles. Cero crédito en el runway (sección 8.1).
18. **Escribir el vector de escalamiento**: Chile como beachhead y el motor de voz + RAG aplicado a otros servicios de campo regulados. Sin apoyarse en Venezuela, que es otro mercado. Es el único criterio del scorecard que el roadmap no resuelve por sí solo.

### P2 — con tiempo sobrante

19. **Cruce de cartolas** para confirmar la caja base de julio y los extraordinarios (sección 6.2). Bajó de P1: la brecha que motivaba la urgencia era un error de cálculo y ya está explicada.
20. **Batch de UX móvil:** división vertical de la pantalla priorizando la imagen sobre los checkboxes, botón de envío que no dispare con Enter en móvil, y mensaje de progreso cuando el procesamiento de un archivo pasa los 20 segundos.
21. **Prueba comparativa reproducible** contra ChatGPT con el mismo manual cargado, documentando los cuatro pilares de la sección 13.

### Backlog explícito — no se elimina, no se toca ahora

- Módulo administrador de edificios. Queda como **idea registrada**, no como trabajo. Primero hay que aterrizar y validar el modelo certificador. Antecedente que el propio Gonzalo aportó: la app de Orona para edificios fracasó con los comités de administración.
- Historial genérico de conversaciones del mantenedor y registro diagnóstico por equipo.
- Licitaciones públicas como canal: ciclo largo y dominado por precio, con el criterio técnico ponderando del orden de 5–6%. Se revisita con un cliente que ya venda al sector público.
- Podcast y videocast: siguen pausados hasta después del piloto.
- Dashboard comercial, billing, SaaS self-serve, programa fundador formal, AWS Partner Network, RLAIF, fine-tuning, integraciones WhatsApp/CRM, on-premise, API/SDK, SSO, internacionalización.
- Meta de USD 1M ARR: se conserva como visión, no como objetivo operativo de 2026.

### Descartado — fuera de foco, no vuelve a la mesa en 2026

- Ecommerce, punto de pago, tarjetas de crédito, nodo Lightning, fintech.
- Aplicación para empresas de seguridad y para supermercados.
- Servicio de delivery.
- Metas de USD 20.000 mensuales o USD 300.000 anuales enunciadas sin escalera: quedan reemplazadas por la escalera de la sección 14.
- Pagar mentoría en efectivo.

---

## 13. Objeción competitiva de primer orden: "le cargo el manual a ChatGPT y es gratis"

Gonzalo la planteó en vivo sin que se le preguntara, y cualquier prospecto técnico la va a repetir. Es la objeción más peligrosa del segmento mantenedor porque compara contra una alternativa gratuita y conocida. La respuesta no puede apoyarse en un solo argumento, porque un prospecto técnico va a probar el sistema en el momento — Gonzalo ya lo hizo.

| Pilar | IA de consumo genérica | Danebo |
|---|---|---|
| **Multicuenta** | Una sesión personal, sin aislamiento entre cuentas de una misma empresa ni gobierno de qué manual ve cada técnico | Cada empresa y cada técnico opera sobre su propio espacio de datos, sin fuga entre cuentas |
| **Calibración sobre uso real** | Modelo fijo de propósito general: no aprende de tu operación ni del vocabulario del rubro | Cada consulta, respuesta, cita y vacío de evidencia queda registrado, y ese registro es lo que permite calibrar contra el rubro ascensores y mejorar con el uso |
| **Anti-alucinación** | Puede inventar una respuesta plausible con la misma confianza que una correcta | Cuando la evidencia no está en el documento cargado, lo declara en vez de inventar. Es un control observable, no una instrucción de prompt |
| **Contexto acotado** | Pierde el hilo en conversaciones largas y mezcla información de otros temas | Mantiene la conversación acotada a la cuenta y al documento activo |

**Respuesta calibrada, sin prometer infalibilidad:**

> "Danebo es multicuenta: tu empresa y tus técnicos operan en un espacio de datos propio, aislado del de cualquier otro cliente. Cada pregunta, respuesta y evidencia citada queda registrada, y ese registro de uso real es lo que nos permite calibrar y mejorar la precisión para el rubro ascensores — mejora con cada consulta, no es una promesa estática. Cuando la respuesta no está respaldada por el manual que cargaste, te lo dice en vez de inventar. Y mantiene la conversación acotada a tu cuenta y al documento activo, sin mezclarse con otros temas como te va a pasar con ChatGPT a la tercera o cuarta pregunta seguida. Pruébalo tú mismo con una pregunta difícil, ahora."

Se evitan deliberadamente las afirmaciones absolutas — "garantiza la precisión", "no alucina", "nunca pierde contexto" — porque contradicen el principio de honestidad calibrada del resto del pitch y son una trampa retórica frente a alguien que diseñó su propio protocolo de prueba: basta un contraejemplo en vivo para que una garantía absoluta destruya más confianza de la que la comparación con ChatGPT jamás pondría en riesgo. La invitación a probar en vivo no es retórica: ya ocurrió espontáneamente y se mantiene como parte fija de la demo.

---

## 14. Escalera de rentabilidad

| Hito | Fecha | Criterio medible |
|---|---|---|
| Primer contrato pagado | Noviembre 2026 | Una mantenedora **mediana** convierte desde el piloto de octubre. A **40–100 equipos** (corregido desde el supuesto anterior de 300–600, ver [PRICING_Y_MERCADO_2026-08-07.md](PRICING_Y_MERCADO_2026-08-07.md), sección 3.1): CLP 40.000–100.000/mes |
| Danebo cubre su propio COGS | Diciembre 2026 | Base combinada superior a ~850 equipos: USD 895/mes contra COGS de USD 416, margen bruto 53%. Con clientes de 40–100 equipos son **9 a 14 mantenedoras**, no dos — el objetivo pasa a ser una mantenedora mediana-grande, no cualquier logo |
| Cubre el costo de vida del fundador | Q1 2027, explícitamente fuera de 2026 | Del orden de 3.500 equipos: treinta y cinco a ochenta y siete mantenedoras del tamaño típico, o cuatro a seis si se consiguen clientes grandes de 300+ equipos |

El criterio de diciembre está expresado como base de equipos y no como "dos clientes", porque dos clientes chicos no alcanzan el margen y dos medianos lo superan con holgura. **La cifra a vigilar es la base de equipos, no el conteo de logos.** Corregir el tamaño de cliente esperado (300–600 → 40–100 equipos) sube de orden de magnitud cuántos logos hacen falta, y es la razón de más peso para que la red de Gonzalo —que puede abrir puertas a clientes mediano-grandes en vez de solo microempresas— importe tanto como se plantea en la sección 9.

**Por qué el tercer hito queda fuera de 2026, a propósito.** Cubrir CLP 3.500.000 mensuales exige cuatro a seis empresas cerradas, con una fuerza de ventas y un ciclo de decisión B2B que hoy no existen. Fijarlo como meta de diciembre produciría sensación de fracaso ante un resultado — dos clientes, negocio rentable en su propio COGS — que en realidad es un avance sólido para el primer trimestre de operación comercial real.

---

## 15. Riesgos abiertos

| Riesgo | Estado | Dónde se resuelve |
|---|---|---|
| **Conectividad en terreno.** Dos entrevistados independientes mencionaron que "se va el internet" en fosos y salas de máquinas. Un dictado de 15–20 minutos interrumpido es una pérdida de trabajo mucho más costosa que una consulta de texto que se reintenta con un tap | Decisión de arquitectura pendiente: captura local con sincronización diferida, o degradación a grabación simple sin procesamiento inmediato | Entregable del mes de construcción |
| **Latencia de respuesta en terreno.** La sesión del 6 de agosto midió p50 de 4,4s y p95 de 9,3s por consulta (hasta 13,2s en el peor caso por usuario), con las manos sucias o con guantes y la atención dividida entre el equipo y el teléfono. Es tolerable para una consulta puntual; no está medido si lo es para un flujo de varias consultas seguidas durante una falla | Sin decisión de UX todavía — mensaje de progreso ya está en el backlog P2 de UX móvil | Septiembre, junto con la medición de COGS de voz |
| **COGS de voz desconocido.** Minutos de audio es un driver económico distinto a tokens de una pregunta puntual | Sin medir | Medición dedicada en septiembre |
| **Ratio equipos/técnico desconocido.** Es la variable que decide si el modelo por equipo supera el piso de costo | Sin dato | Pregunta 1 a Gonzalo |
| **El ahorro de tiempo no financia el precio** | Identificado y cuantificado | Encuadre de participación en ingresos, sección 5 |
| **Comprador nunca entrevistado.** Ocho entrevistas cubren usuarios y validadores técnicos; ninguna cubre a quien firma | Vacío abierto desde julio | Aguja 2, sección 7 |
| **Corpus.** "No es tan fácil conseguir los manuales de Kone, Otis, Schindler" | Frente de trabajo con fuente identificada: Gonzalo aporta manuales de su red, y los manuales de fabricante circulan en grupos de técnicos | Fase 1 del piloto se limita a manuales de fabricante, cero datos internos de ninguna empresa |
| **Precisión sobreindexada.** El set de regresión cubre series de seguridad, que son aproximadamente 20% de las fallas reales | Se mantiene como regresión y se agrega batería de generalización | P1, sección 12 |

---

## 16. Fechas de decisión

Se recupera la estructura de dos cortes de la planificación de julio, que se había perdido, y se agregan los cortes comerciales:

Todas las fechas caen en día hábil, a propósito: un corte de decisión agendado en fin de semana es un corte que no se hace.

| Fecha | Tipo | Qué se evalúa |
|---|---|---|
| miércoles 16 de septiembre | Corte serio | Estado del borrador persistente, al cierre de la ventana de implementación y justo antes de Fiestas Patrias. Si no está en pie, se activa la escalera de recorte con dos semanas por delante |
| miércoles 30 de septiembre | Corte duro | Decisión sobre indicadores adelantados, no sobre resultados de piloto: manuales de Gonzalo en uso voluntario por sus técnicos, piloto de octubre agendado con fecha concreta, costo unitario y de voz medidos, uso real en Venezuela con señales de adopción |
| viernes 30 de octubre | Gate comercial | ¿El piloto produjo disposición a pagar? Si no, el problema es de propuesta de valor y no de volumen: replantear antes de gastar más runway en outreach |
| jueves 31 de diciembre | Gate de runway | ¿Hay base combinada de ~850 equipos (9–14 mantenedoras de 40–100 equipos, o menos si alguna es mediana-grande) o capital no dilutivo en camino? Encuentra 6,2 meses de caja libre más 6 de reserva, así que hay margen para decidir sin apuro. Si no hay ninguno de los dos, el gate de enero es decidir pivote de segmento con los datos de la matriz. **El capital no dilutivo no cuenta como "en camino" hasta que esté adjudicado** (sección 8.1) |

**Regla que se mantiene:** si la información llega antes, no se espera artificialmente. Y una decisión de "sin señales reales" activa el plan alternativo de carrera profesional del anexo J de julio, sin cambios: Danebo se convierte en portfolio técnico y caso de estudio para roles de CTO, arquitecto o AI Systems Engineer, no en un fracaso.

---

## 17. Resumen del cambio de foco

| | Plan del 6 de agosto | Este plan |
|---|---|---|
| Unidad de cobro | Por técnico o por informe, sin dimensionar | Por equipo gestionado y por informe, con TAM y contraste contra el piso de costo |
| Módulo certificador | Distinción legal definida, estructura no | Ocho ítems de inspección, grupos normativos y derivación determinista de la norma |
| Gonzalo | Track asesor → socio | Demo registrada como ejecutada y por sobre lo esperado; asimetría nombrada; preguntas de estructura; tripwire de tres observaciones fechadas; y la decisión de no forzar el café del 10 de agosto |
| Plan B | Los cuatro contactos cálidos de entrevistas | Outbound sobre el registro MINVU. Cuatro contactos cálidos produjeron una sola demo ejecutada: la red de descubrimiento no es un canal de adquisición |
| Runway | No revisado | CLP 53,3M operativos, con el viaje leído en euros y el depósito a 30 días; 9,2 meses de caja libre desde el 1 de septiembre —agosto ya está gastado y no se cuenta dos veces— con la reserva de 6 meses intacta detrás; la brecha de CLP 8M era error de cálculo y queda en ≈ CLP 1M de ruido |
| Consultoría | No considerada | Descartada hasta el 1 de noviembre, con condiciones si se abre |
| Capital no dilutivo | "Postular a CORFO en noviembre" | Scorecard real de Start-Up Chile Ignite: 431/587, nota 3,43 contra 5,46. Cero crédito en el runway, fecha atada a la decisión de Gonzalo, y un vacío documental identificado en escalabilidad |
| Venezuela | Laboratorio de voz y acústica | Además, prueba funcional del mismo bucle dictado → informe del módulo certificador. Con tres límites explícitos: no se monetiza, los hermanos no son mentores ni red de apoyo, y no se usa como argumento de expansión regional |
| Prioridades | Implícitas | P0/P1/P2, backlog y lista de descartes explícita |
| Cortes de decisión | Solo 30 de septiembre | 16 y 30 de septiembre, 30 de octubre, 31 de diciembre, todos en día hábil |
| Capacidad de septiembre | Un mes completo de construcción | 15 días hábiles efectivos: jet lag de regreso y Fiestas Patrias, con escalera de recorte decidida de antemano |

Lo que no cambia: la tesis de la voz como canal, los red lines regulatorios, la disciplina de foco, y que Venezuela es el laboratorio y Chile el mercado.
