# Preparación — Reunión con Gonzalo Salazar · viernes 11 de septiembre de 2026

**Estado:** documento operativo de preparación. Se cierra el 11-sep con el resultado real.
**Hora y lugar:** 09:30, cerca del metro Manuel Montt, Providencia.
**Pendiente logístico crítico:** el 10-sep se envió por error "mañana 4pm cerca metro Providencia". Hay que corregirlo hoy y confirmar 09:30 en Manuel Montt. Si no responde antes de las 08:00, ir igual a las 09:30.

---

## 0. Contexto mínimo para alguien que llega nuevo

Danebo es un asistente documental con IA para técnicos de ascensores en Chile: consulta manuales, planos y diagramas por texto e imagen, con respuestas apoyadas en fuentes citadas. Fundador solo (Lahiri Sánchez), etapa de demo y validación comercial. **No hay product-market fit, ni ingresos, ni clientes pagos, ni pilotos con uso sostenido.**

Gonzalo Salazar Campos es **gerente comercial de ATLAGICH Ascensores SpA**, mantenedora inscrita en el registro MINVU (Rol 324, nómina al 3-jun-2026). Familia con tres generaciones en el rubro; su abuelo partió en ascensores en Chile y en los noventa había una decena de Salazares en Schindler. Tuvo su propia empresa certificadora durante dos o tres años en Santiago, a cargo de operaciones, saliendo a terreno y redactando informes. Hoy no es certificador inscrito.

Historia de la relación: entrevista de descubrimiento (remunerada, él aceptó el pago) → demo el 6 de agosto → entregó una biblioteca de ~2,88 GB → se ingirieron 180 PDF, 10.442 páginas, seis marcas, con US$255,21 de gasto real → credenciales enviadas el 26-ago sin uso confirmado → silencio → él propuso y reconfirmó esta reunión.

**Reglas de método que gobiernan todo lo que sigue:** distinguir siempre dato de campo, derivación, especulación declarada por la fuente y razonamiento propio. No tratar silencios como rechazo ni elogios como compromiso. No proponer equity, exclusividad, sueldo, comisión ni sociedad como si fueran estándares.

---

## 1. Objetivo único

> Salir con un piloto acordado: **nombre de la persona, caso, fecha de inicio y fecha de revisión.**

La revisión de la aplicación es el vehículo, no el objetivo. La conversación comercial se difiere explícitamente hasta que exista uso.

**Criterio de éxito de la reunión:** hay nombre y fecha, o hay fecha en que él entrega el nombre.
**Criterio de éxito del piloto:** al menos una persona completa dos sesiones reales sin asistencia, y en la devolución identifica una consulta que le sirvió y una que falló.

Si sales con entusiasmo, ideas de módulos y conversación de sociedad pero sin nombre ni fecha, **la reunión fracasó**. Si sales solo con el piloto, fue exitosa.

### Los tres desenlaces posibles

| Lo que él haga | Lo que haces | Lectura |
|---|---|---|
| Nombra 1–2 personas y acepta fecha | Cierras, lo repites en voz alta, lo mandas por escrito esa tarde | Éxito. Escenario B del Plan General §9.4 |
| Entusiasmo e ideas, sin nombres | "Me encanta, y para conversarlo con algo real necesito que alguien la use dos semanas. ¿Quién y cuándo?" Si no puede hoy: **fecha en que te dice el nombre** | Éxito parcial. Un solo seguimiento y después nada |
| Elogios, "faltan más manuales", "sigamos conversando" | No insistes ni ofreces cargar más corpus. Agradeces, resuelves custodia del corpus por escrito, sigues con Carlos y el registro MINVU | Escenario A/C. Lo supiste en 45 minutos |

---

## 2. Estado real del producto — qué existe y qué no

Esto es lo más importante de tener claro antes de sentarse, porque determina qué se muestra y qué se describe.

| Capacidad | Estado |
|---|---|
| Consulta documental multimarca sobre corpus propio, con cita de documento y página | **Existe y está en producción.** Es lo que se demuestra |
| Comprensión de fotos: consolas, tarjetas, planos, esquemas | **Existe.** Medido en la demo del 6-ago |
| Declaración de ausencia de evidencia cuando la respuesta no está en el corpus | **Existe.** Es un control observable |
| Trazabilidad de sesión: qué se preguntó, qué documento y página respondió, latencia | **Existe** |
| Aislamiento por cuenta y usuarios nominales | **Existe.** Falta crear los usuarios nominales de Gonzalo |
| Subdominio propio por cliente | **Existe en producción**, con un caso real corriendo |
| Apuntar el dominio propio del cliente hacia Danebo | **Posible, con trabajo manual.** No es autoservicio |
| Circuito de voz del certificador: dictar → transcripción editable → confirmar → borrador persistente → cerrar y reabrir | **En construcción.** Borrador persistente sí; integración de audio extremo a extremo estaba planificada para el 14–16 de septiembre |
| Voz conversacional manos libres para el técnico de mantención, con respuesta hablada | **No existe. Es visión, no producto** |
| Informe final en PDF, ocho ítems de certificación, clasificación de gravedad, decisión de cumplimiento | **Fuera de alcance deliberadamente** |
| Módulo de administradores / carpeta cero | **No construido** |

**Regla que se deriva:** el circuito de voz del certificador y la voz manos libres del mantenedor son **dos productos distintos**. El primero es dictado a borrador; el segundo es conversación hablada con respuesta hablada. Gonzalo puede confundirlos. No los presentes como lo mismo.

---

## 3. Preparación de hoy, jueves

1. **Corregir el "4pm"** y confirmar viernes 09:30 en Manuel Montt.
2. **Ejecutar las 12 preguntas de prueba de la sección 4** contra la cuenta piloto (`piloto.danebo.ai`, corpus de Gonzalo). Anotar cuáles fallan.
3. **Decidir si el circuito de voz se muestra**: solo si aguanta cinco recorridos completos seguidos en el teléfono, sin fallo. Si no, se describe hablado.
4. **Dejar la app abierta y logueada en el teléfono**, con la biblioteca de sus 180 documentos a la vista.
5. **Cargar dos o tres fotos propias de terreno** en la galería, por si él no trae ninguna.
6. **Imprimir o tener a mano la hoja de bolsillo** (sección 14).

### Corpus disponible en la cuenta piloto

| Marca | PDFs | Páginas |
|---|---:|---:|
| KONE | 62 | 5.488 |
| Thyssen / TKE | 37 | 1.307 |
| BLT | 30 | 1.274 |
| OTIS | 24 | 1.194 |
| Fuji Yida | 23 | 1.141 |
| Mitsubishi | 4 | 38 |
| **Total** | **180** | **10.442** |

### El alcance de las seis marcas está completo

La aritmética cierra sin huecos: **208 PDFs en las seis carpetas − 25 duplicados exactos − 3 sobre 50 MB = 180 ingeridos**, 10.442 páginas, nueve tandas cerradas el 24 de agosto. De los tres excluidos por tamaño, **los dos de OTIS se recuperaron**: se partieron por rangos de página y entraron en la tanda `07`, y está verificado que son recuperables en la cuenta del piloto.

### El único hueco real, para no improvisar si él cae en él

**Cerrado hoy, 10-sep.** `otis_2000.pdf` (17 págs, fallaba en el parseo) y los
tres sueltos de BLT/Conectores (`05.- BLT-ES_PLC input.pdf`, `08.- BLT-ES_PLC
output.pdf`, `Conectores QS.pdf`, descartados por el filtro) estaban
corregidos en el código desde agosto pero nunca se habían vuelto a subir. Se
verificó contra producción (cuenta 3) que los tres PLC/Conectores ya estaban
`complete` desde el 25-ago (`BulkUpload` 12) — el hueco real era sólo
`otis_2000.pdf`. Re-ingerido hoy: `BulkUpload` 15 `complete`, US$1,20 all-in,
retrieval verificado (entra en las tres primeras posiciones de 5 para una
consulta sobre el documento). Detalle completo en
[`INGESTA_PILOTO_GONZALO_2026-08-20.md`](INGESTA_PILOTO_GONZALO_2026-08-20.md).

| Qué | Páginas | Por qué |
|---|---:|---|
| `KONE_Parts_2002.pdf` | 608 | Excluido a propósito: catálogo de repuestos, bajo valor para diagnóstico en campo. Si pregunta por un número KM de repuesto Kone, no está |

**Hueco de contenido efectivo: 0 páginas.** Sólo queda fuera el catálogo de
repuestos, excluido por decisión de producto, no por falla técnica.

### Lo que está en el Drive y nunca estuvo en el alcance

Gonzalo autorizó indexar **solo las seis marcas del plan inicial, no la carpeta entera**. Las otras 17 carpetas suman 365 PDFs y 15.904 páginas: Schindler (2.311), Fermator (3.158), variadores (1.920), Hyundai (1.761), escaleras (3.791). **No es material pendiente: es material fuera de acuerdo.**

---

## 4. Las 12 preguntas para probar la app hoy

**Ninguna de estas se hace delante de Gonzalo.** Son para saber dónde estás parado. El viernes él elige marca y él formula.

**Códigos de falla**
1. BLT — "¿Qué significa el código de error de la tarjeta MPK 708A y qué reviso primero?"
2. BLT — "Tengo un código de error en un BL6, ¿qué indica?"
3. OTIS — "¿Qué significan los códigos de la serie LG-Sigma en un OTIS?"
4. Thyssen — "En un CMC-3 hidráulico, ¿qué se revisa cuando el equipo no responde a la llamada?"

**Parámetro o procedimiento**
5. KONE — "¿Cómo se hace la puesta en servicio de la placa LCB II y qué se verifica antes de energizar?"
6. KONE — "¿Qué hace la tarjeta LCE y dónde está su configuración?"
7. BLT — "¿Cuáles son los pasos de puesta en marcha del MPDK136 / MPDK176?"
8. Fuji Yida — "¿Cómo se parametriza el variador en un Yida y qué valores trae por defecto?"

**Foto, plano o esquema**
9. OTIS — foto de consola / URM: "¿Qué equipo es esto y qué me está mostrando?"
10. Mitsubishi o BLT — "En el plano, ¿por dónde va el circuito de la serie de seguridad y en qué bornes?"
11. Variador — "¿Cómo se configura un WEG en lazo abierto para un ascensor?"

**Trampa deliberada**
12. Schindler o Fermator — "¿Qué significa este código en un Schindler?" **La respuesta correcta es que no hay evidencia**, porque esas marcas no están indexadas. Esta es la que demuestra el control anti-invención.

---

## 5. Guion minuto a minuto

### 0–3 · Apertura con su propia idea

En la primera entrevista, sin que se le preguntara, Gonzalo dijo que lo valioso sería retener el conocimiento **para la empresa y no para el técnico**, y tener una **base de datos multimarca** de historial de fallas. Esa fue idea suya. Devuélvesela con atribución:

> "En nuestra primera conversación me dijiste algo que se me quedó: que lo valioso no era que el técnico consultara el manual, sino que el historial de fallas por marca quedara en la empresa y no en el técnico, y que existiera una base multimarca. Con tus manuales eso es exactamente lo que hay hoy. Quiero mostrarte cómo quedó y saber si sigues pensando lo mismo."

Hace tres cosas: reconoce su aporte intelectual, encuadra la demo en el terreno que él **aprobó** en vez del que **objetó** (la consulta al manual, que objetó dos veces), y abre natural la conversación de licencia del corpus.

### 3–18 · Revisión en el teléfono

| Paso | Qué haces |
|---|---|
| Biblioteca | Abres la lista: 180 documentos, seis marcas, los suyos. No dices nada más |
| Consulta | "Elige una marca y hazle la pregunta que le harías a un técnico nuevo." Tres iteraciones. **Él** pregunta |
| Foto | Una foto suya de consola, tarjeta o plano. **Nunca de componente quemado** (ver §6) |
| Vacío declarado | Pregunta de Schindler o Fermator. El sistema declara que no tiene evidencia |
| Traza | Le muestras la sesión: cada pregunta, documento y página que respondió, latencia, y las consultas sin evidencia |
| Cupo | Consumo de consultas por usuario. **Sin pesos, nunca** |

Cuando el sistema responda un código, **dices su frase antes que él**: *"y esto no reemplaza el tester; el código puede decir puertas y ser el variador."* Que escuche que tú sabes eso vale más que cualquier respuesta del sistema.

### 18–21 · El circuito de voz del certificador

Solo demo si cumplió el criterio de los cinco recorridos. Si no, se describe hablado con los límites declarados antes de tocar nada:

> "Esto transcribe y ordena lo que dicta un certificador y lo deja como borrador editable. No evalúa cumplimiento, no clasifica gravedad, no aprueba ni rechaza, no firma. Eso es del certificador."

Y la pregunta que sí le sirve, porque **él lo vivió** con su propia certificadora:

> "Cuando tenías tu certificadora y hacías los informes tú mismo, ¿cuánto se te iba escribiendo el informe después de la visita?"

### 21–35 · Descubrimiento

Las preguntas de la sección 7.

### 35–42 · Cierre del piloto

Nombre, caso, fecha de inicio, fecha de revisión. **Evitar el 17 al 21 de septiembre** (Fiestas Patrias reduce disponibilidad).

### 42–45 · La visión, y solo aquí

Ver sección 9. Treinta a sesenta segundos, y al servicio del piloto.

---

## 6. Sus objeciones y la respuesta correcta

Son objeciones técnicas de alguien que auditó equipos. Una demo que las ignore falla delante de él. **Dos de ellas son correctas y hay que concederlas.**

| Objeción, en sus palabras | Validez | Respuesta |
|---|---|---|
| "El código te dice falla en puertas y el problema es del variador de frecuencia" | **Correcta, y la más importante** | No presentes la respuesta del manual como diagnóstico: "esto te dice qué dice el manual y de qué página, y cuándo el manual no alcanza. El diagnóstico sigue siendo del técnico con el tester" |
| "Sacar información de los manuales es hacer la mitad de la pega. Los manuales no te garantizan nada" | **Correcta** | Concédela y reencuádrala: la mitad que Danebo hace es la que hoy consume a ingeniería de campo leyendo página por página mientras el técnico espera en terreno |
| "Cuando encuentras el componente quemado, ya salió la falla" | **Correcta, y mata un argumento usado antes** | **No abrir con foto de componente quemado.** Usar consola con código, tarjeta con designador, o plano |
| "Esos manuales no me sirve que se los metan en la aplicación, yo ya los tengo en el computador y busco con control+F" | **Es la objeción ChatGPT en versión más dura**, porque Ctrl+F es gratis y ya está en su máquina | Tres respuestas: Ctrl+F exige saber en qué archivo buscar y tenerlo abierto; no funciona sobre 180 documentos de seis marcas a la vez; y sobre todo **la carpeta la tiene él, no el técnico en el foso** |
| "¿No genera falsa confianza en el técnico?" | **Riesgo real**, y él lo confirmó | Por eso el sistema declara cuándo no tiene evidencia y cita página. El paso del vacío declarado responde esto sin discurso |
| "Le cargo el manual a ChatGPT y es gratis" | Es la objeción competitiva de primer orden | Los seis pilares de la sección 8 |

### Lo que él sí compró, sin que se le preguntara

> "Retener esa información, que no sea para los técnicos, sino también para la empresa. Acá hay un historial de falla de esta marca, que puede ser genial para las empresas. Tenemos una base de datos multimarca."

Y: *"muy difícil conseguir especialistas, y cuando se te va uno buenísimo, te hacen un daño enorme."*

**Ese es el eje de la reunión.** No la consulta al manual, que objetó. El valor que él ya reconoció es que el conocimiento quede en la empresa y sea multimarca.

### El mejor argumento comercial disponible, y es de él

> "Si voy a tomar unos equipos de marca que no conozco, que tengo que leerme mil manuales, que quizás necesito códigos, que necesito una consola, no los tomo en mantención porque no lo hacemos."

Eso no es tiempo perdido: es **contrato rechazado**. Danebo amplía qué equipos puede aceptar una mantenedora. Ataca ingreso, no eficiencia. No exige que nadie crea una tasa horaria. No se apoya en la tarifa mensual, que es la línea comprimida por el administrador del edificio. Y es su propia restricción, dicha antes de ver el producto.

Corolario de targeting: las mantenedoras **multimarca que toman todo** y después sufren buscando la falla son el mejor prospecto. Las selectivas como la suya compran otra cosa: poder dejar de ser selectivas.

---

## 7. Preguntas a Gonzalo, con la respuesta que buscas y cómo leerla

| # | Pregunta | Qué buscas | Cómo leer la respuesta |
|---|---|---|---|
| 1 | "¿Qué esperabas ver hoy? ¿Qué te haría decir 'esto sirve' o 'esto no'?" | Su criterio de evaluación, antes de abrir la app | Si tiene criterio concreto, está evaluando en serio. Si es vago, está siendo cortés |
| 2 | "Me contaste que cuando el técnico no resuelve, escala a ingeniería de campo y ahí se van a los manuales y las consolas. ¿Cuántas veces por semana pasa hoy, y quién es esa persona?" | Frecuencia real del dolor y **el nombre del usuario del piloto** | Una frecuencia y un nombre es la mejor respuesta posible de toda la reunión. Un "depende" sin número es señal de que el dolor no es tan agudo como parecía |
| 3 | "Dijiste que no toman equipos de marcas que no conocen. ¿Cuánta cartera dejan pasar al año por eso, y qué tendría que existir para que sí la tomaran?" | Convertir tu mejor argumento en una cifra **suya** | Si da un número, tienes el argumento de venta con dato de campo. Si dice "poca", el argumento se debilita y hay que saberlo |
| 4 | "¿Cómo te imaginas participando, y cuánto tiempo real tienes en los próximos 30 días?" | Disponibilidad concreta antes de cualquier estructura | Horas concretas = escenario B. "Cuando pueda" = capacidad cero, y se planifica así |
| 5 | "Si esto se le vende a otras mantenedoras, ¿te genera un problema con tu empresa?" | Conflicto con el empleador. Él es el **comercial** de una mantenedora | Si duda o minimiza, es un riesgo que hay que resolver antes de cualquier acuerdo |
| 6 | "Tú auditas los equipos y la gerencia de servicio aprueba el ingreso a cartera. Para software, ¿quién decide y hasta qué monto pasa sin comité?" | Quién firma. Él **no** es el decisor | Cualquier respuesta sirve: es el dato que falta desde julio en el registro de entrevistas |
| 7 | "De lo que factura una mantenedora por equipo, ¿qué proporción viene de la mantención mensual y qué proporción de correctivos, repuestos y modernizaciones?" | El denominador correcto del pitch | Solo si sobra tiempo. Es pregunta de estructura de negocio, no de su margen, así que no activa resistencia |
| 8 | **Cierre:** "Si probamos con uno o dos ingenieros tuyos durante dos semanas, ¿quiénes serían, qué caso usarían y cuándo lo revisamos?" | El único resultado que importa | Ver los tres desenlaces de la sección 1 |

Obligatorias: 1, 2, 4, 5 y 8. Las demás si el tiempo alcanza.

---

## 8. "¿En qué se diferencia de ChatGPT?" — seis pilares

| # | Pilar | Cómo decirlo |
|---|---|---|
| 1 | Multicuenta y aislamiento | "Tu empresa y cada técnico operan en su propio espacio de datos. Ningún otro cliente ve tus manuales, y tú decides qué manual ve cada técnico" |
| 2 | Anti-invención con fuente | "Cuando la respuesta no está en el manual que cargaste, te lo dice en vez de inventar. Y cuando sí está, te dice documento y página" |
| 3 | Trazabilidad y auditoría por técnico | "Queda registro de qué preguntó cada técnico, qué respondió, de qué documento y página, y cuánto demoró. Sirve para respaldar un trabajo y para saber qué no encuentra tu gente" |
| 4 | Calibración sobre uso real | "Ese registro es lo que permite calibrar la precisión para ascensores. Mejora con el uso; no es un modelo fijo de propósito general" |
| 5 | Contexto acotado | "La conversación se mantiene pegada a tu cuenta y al documento activo. No se mezcla ni se contradice a la tercera pregunta" |
| 6 | Consumo visible y gobernado | "Ves cuántas consultas lleva cada técnico de su cupo del mes. Una cuenta de ChatGPT compartida no te da eso" |

Cierre obligatorio: **"pruébalo tú mismo con una pregunta difícil, ahora."**

**Prohibido decir:** "te garantizo la precisión", "no alucina", "nunca pierde contexto". Basta un contraejemplo en vivo para destruir más confianza de la que la comparación con ChatGPT pone en riesgo.

**Corrección importante sobre el pilar 6:** dashboard de **consumo y uso**, jamás de costos en pesos. Mostrar "18 de 32 consultas este mes" es útil y seguro; traducirlo a dinero expone el costo real y el margen.

**Puente al cierre:** la traza por técnico solo funciona con usuarios nominales. Hoy no los hay. *"Para que esto quede atribuible por persona necesito nombre y correo de cada ingeniero; con credenciales compartidas pierdo justo el dato que hace valiosa la traza."*

---

## 9. La visión de voz manos libres — cómo presentarla

**Qué es:** el técnico deja el teléfono en el piso, con guantes y grasa, y conversa. Pregunta hablando, la aplicación responde hablando y lo va guiando hacia la solución. Si hace falta, le pide una foto. Es la interfaz que hace utilizable lo que el sistema ya sabe.

**Por qué importa:** la evidencia de las entrevistas es convergente y no inducida. Un certificador probó una herramienta de IA con formularios y fotos, tardó más que con lápiz y papel y volvió al papel. Dos entrevistados mencionaron los guantes sin que se les preguntara. La respuesta correcta no basta: tiene que ser **más fácil que el método actual**.

**Cómo presentarla el viernes:**

- **El piloto se hace con lo que existe hoy**: consulta documental multimarca, fotos, evidencia citada y traza. La voz no condiciona el piloto ni se ofrece como parte de él.
- **La visión se cuenta al final, en los últimos tres minutos**, después de tener nombre y fecha. No al principio.
- **Se enuncia como visión, sin comprometer nada.** No hay fecha, no hay promesa, no hay alcance. La formulación es en primera persona y sobre el rumbo: "hacia dónde va esto", no "qué vas a recibir".
- Frase de la visión: *"Que el técnico deje el teléfono en el piso, pregunte hablando y la aplicación le conteste hablando y lo vaya guiando. Con guantes, con poca luz, sin soltar la herramienta. Eso es lo que ninguna herramienta del mercado hace hoy, y es hacia donde va Danebo."*
- **Al servicio del piloto:** *"Lo que me tiene indeciso es cuál de los tres módulos construyo a fondo primero — mantenedor, certificador, administrador. El piloto es lo que me lo dice."*

**Si el circuito de voz del certificador está estable, mostrarlo es la mejor carta de la reunión.** No porque sea el producto del piloto, sino porque él ya vio el sistema de consulta y esto le muestra que hay una segunda capa avanzando. Con dos condiciones: cinco recorridos limpios probados hoy, y los límites declarados antes de tocar nada. Es una demostración de rumbo, no una oferta.

**Riesgos que hay que manejar:**

1. **No confundir los dos productos de voz.** El circuito del certificador (dictar → transcribir → confirmar → borrador) está en construcción. La voz conversacional manos libres del mantenedor **no existe**. Si él pregunta cuándo, la respuesta honesta es que depende de que el piloto muestre que vale la pena.
2. **No prometer fechas.** Ninguna.
3. **La sorpresa vale una sola vez.** Si la juegas al inicio, la conversación se va a especular sobre módulos y no vuelve al piloto. Guárdala para el cierre, donde convierte el entusiasmo en razón para participar.
4. **En la demo del 6 de agosto él vio potencial cuando se mencionaron los tres módulos.** Eso es un dato a favor de mencionarlos; no es un permiso para que sean el tema.

---

## 10. El corpus: qué es de quién, y qué decirle

### La separación que hay que tener clara

| Qué | De quién | Por qué |
|---|---|---|
| Los PDFs de manuales | **De los fabricantes** (Otis, Kone, Thyssen, BLT) | Ni él ni tú tienen título. Él tenía acceso y custodia y te dio una copia |
| El acceso, la red y la curaduría | **Suyo, y es su aporte real** | Conseguir 622 PDFs en 23 carpetas requiere haber trabajado en el rubro y conocer gente. Eso no se compra |
| El índice derivado y el pipeline | **Tuyo** | Lo construiste y lo pagaste. Pero es obra derivada de material de terceros: tu pago no habilita redistribuirlo |

**Pagar el indexado no te hace dueño de nada.** Es tu costo de procesamiento. Y no crea una deuda de Gonzalo ni un derecho tuyo sobre su aporte.

### Qué decirle, y por qué conviene

Sí conviene decirle que fue valioso: es cierto, es lo que más le importa a alguien motivado por pertenencia al rubro y no por dinero, y es la puerta al permiso de alcance. Lo que **no** haces es decir el monto ni insinuar que eso obliga a nadie.

> "Quiero decirte algo con claridad: los manuales que me pasaste son lo más valioso que he recibido en todo este proyecto. Sin eso no tendría con qué probar nada real. Están aislados en tu cuenta y no los he usado con nadie más. Y te quiero preguntar dos cosas: ¿se quedan solo ahí, o hay un escenario en que sirvan de base para otros clientes? Y si fuera lo segundo, ¿qué te gustaría a cambio?"

**Lo que no puede pasar:** que se entere después de que reutilizaste su biblioteca. Preguntar ahora es la única opción, y hoy es el mejor momento porque todavía no hay ningún cliente que lo necesite.

### Si pregunta por qué no cargaste todos sus manuales

> "Las seis marcas que acordamos están cargadas completas: unas 10 mil páginas, 180 documentos. En el Drive venía bastante más —Schindler, Fermator, Hyundai, escaleras, variadores, otras 15 mil páginas— y eso no lo toqué, porque no era lo que habíamos conversado y porque indexar tiene un costo real por página. Si algo de eso sirve para lo que probemos ahora, lo cargo."

Nota de precisión, por si él revisa: **el alcance acordado está completo, no a medias.** Lo único fuera dentro de las seis marcas es un catálogo de repuestos de Kone de 608 páginas, excluido por decisión. Las ~20 páginas que fallaron por defectos técnicos ya corregidos (`otis_2000.pdf` y tres sueltos de BLT/Conectores) están re-ingeridas y verificadas al 10-sep.

Sin dólares. Sin reclamo. Si él ofrece cargar el resto: primero probemos con lo que hay y midamos qué no encuentra.

### Si se retira de la mesa

Borrar la cuenta piloto, borrar el índice derivado, **borrar también la copia local del computador**, y confirmarlo por escrito. Quedarse los archivos "por si acaso" convierte un problema de relación en un problema legal, con material de fabricantes de por medio. El dinero está perdido: fue una decisión propia y no se usa nunca como argumento con él.

### La base de conocimiento común — hipótesis estratégica

Si el corpus de seis marcas sirve de base para varios clientes, el COGS de ingesta del cliente 2, 3 y 4 es casi cero y solo cargan lo exclusivo suyo. Eso baja la activación, acelera la venta y crea una barrera de entrada difícil de copiar, porque conseguir manuales exige red en el rubro.

Tres condiciones antes de convertirlo en argumento comercial:

1. **Permiso escrito de Gonzalo**, con alcance, retención y borrado.
2. **Revisión legal de propiedad intelectual.** Compartir manuales de fabricante entre clientes es una pregunta de los fabricantes, no de Gonzalo. Su permiso es necesario y no suficiente.
3. **Fuentes alternativas**, para que la base común no dependa de una sola persona: hermanos con Orona, otros técnicos, clientes que aporten los suyos, sitios de pago. Hay que construirlas pase lo que pase.

**Cuánto falta para cubrir el grueso del parque chileno:** Schindler, Hyundai, Fermator y variadores suman 9.150 páginas, unos US$243 al costo medido. **No se gasta ahora:** el Plan de Septiembre fija cero compra de corpus hasta el 2 de octubre, y el dato que justifica ese gasto lo produce el piloto — qué porcentaje de consultas cae en "no hay evidencia" y de qué marcas. Que las seis marcas cubran el 80% de las consultas es hipótesis, no dato.

---

## 11. Precio, activación y modelo de negocio

### Qué cubre la activación, y se puede decir sin cifra

No es solo indexar: es crear la cuenta aislada, los usuarios nominales por técnico, y el subdominio propio del cliente. Existe ya un cliente corriendo en su propio subdominio. Apuntar el dominio propio del cliente es posible y requiere trabajo manual.

> "La activación no es solo cargar manuales. Es dejar a tu empresa con su propio espacio: usuarios por técnico, biblioteca aislada, y si quieres en su propio dominio. Ya tengo un cliente corriendo así. Eso se cobra aparte del uso mensual, porque es trabajo por empresa."

No prometer el dominio propio como inmediato ni como autoservicio.

### Si quiere hablar del modelo de negocio

No lo esquives —él ofreció ayudar y esquivarlo se lee como no tener respuesta— y no abras números. Cambias de rol: en vez de contestar, preguntas.

1. > "Justo eso quiero resolver bien. He visto tres formas de cobrar esto: por técnico, por equipo en cartera, o por informe generado. Tú conoces el mercado mejor que yo: ¿cuál crees que una mantenedora acepta, y en qué rango?"
2. Si insiste: > "Todavía no está decidido, y no es evasiva: el costo real lo estoy midiendo y falta el de la voz. Fijarlo antes de medirlo sería inventarlo. Por eso te pregunto a ti."
3. Si vuelve a insistir: > "Te lo digo en octubre, con el costo medido y el resultado de una prueba real encima."
4. Puente: > "De hecho, el modelo lo define lo que aprenda del piloto: cuántas consultas usa un técnico al mes, qué encuentra y qué no. Armemos la prueba y el modelo lo conversamos con datos."

### Por qué no se abren los números

1. **No están decididos.** El COGS de voz no está medido; el margen del modelo por informe es una expectativa, no un número.
2. **Él es el gerente comercial de una mantenedora, o sea de un cliente potencial.** Es la última persona a la que se le revela precio antes de tenerlo decidido. Su oficio es negociar precios en este mercado, y una cifra dicha hoy queda como ancla para siempre.
3. **La regla propia lo prohíbe** y se escribió antes de esta reunión: se preguntan precios, no se proponen.

### Números internos, para el fundador — nunca para la mesa

| Concepto | Valor |
|---|---|
| COGS recurrente | US$9,54 esperado / US$13,87 conservador por usuario/mes (1.000 consultas + 200 fotos) |
| Costo por consulta respondida | US$0,0073 medido en la demo del 6-ago |
| Ingesta | US$0,0244–0,0265/pág con capa de texto; hasta US$0,0514/pág si es 100% escaneado |
| Corpus de Gonzalo | US$255,21 all-in, 9.650 páginas facturadas |
| Onboarding de un manual de 200 págs | US$5,32 medido contra factura |
| Piso de precio | 50% margen = US$27,74/usuario/mes · 60% = US$34,68 · 70% = US$46,23 |
| Unidad decidida | Mantenedor: por equipo gestionado, con cupo. Certificador: por informe |
| Hipótesis de precio | CLP 1.000 por equipo/mes. Certificador: 0,25–0,75 UF por informe, **sin validar** |
| Activación, propuesta interna | CLP 800.000 hasta 2.000 págs + CLP 200 por página adicional. Con base común compartida: CLP 400.000–600.000 |

**Verificación de que la suscripción se sostiene sola:** una mantenedora de 125 equipos son 3–4 usuarios; COGS conservador CLP 40.000–53.000 contra CLP 125.000 de ingreso, o sea 58–68% de margen bruto. El setup es margen adicional, no lo que salva el modelo.

**Corrección de denominador que hay que tener clara:** los CLP 125.000 no son lo que cobra la mantenedora, son lo que se le cobra a ella. Ella factura CLP 10 a 27 millones al mes con 125 equipos. Danebo es 0,45%–1,25% de su facturación, y una activación de CLP 2,5M es ~17% de **un** mes suyo, por única vez. El administrador de edificio no es el comprador: es el cliente de la mantenedora.

**Contradicción de cifras que no está reconciliada:** el alcance operativo reporta 10.442 páginas y la auditoría de ingesta 9.650 facturadas. La diferencia es compatible con el filtro que descarta páginas antes de facturar, pero no está conciliada página a página. Si se cita, decir "unas 10 mil páginas".

---

## 12. Qué NO decir

- Precio propio, COGS, los US$255,21, el runway, cifras de caja.
- CORFO. Si pregunta por fondos: *"Postulé a Start-Up Chile en mayo, no quedó. El feedback fue claro: faltaba validación comercial. Vuelvo a postular cuando tenga uso real y ojalá un cliente pagando."* Sin montos, sin sueldos, sin "si tú participas".
- Expansión regional. Si pregunta por crecimiento: *"Chile primero, con ascensores. El motor de dictar, confirmar y dejar un informe trazable sirve para otros servicios regulados de terreno, pero eso viene después de que un cliente chileno pague."* Y vuelves.
- Arquitectura, modelos, dashboards de tokens, consola de ingesta.
- El corpus de otro cliente.
- "Socio", equity, exclusividad, comisión, sueldo. Si él los trae, escuchas, agradeces y difieres a después del piloto.
- Garantías absolutas de precisión.
- Fechas de entrega de la voz manos libres.

---

## 13. Cierre y seguimiento

Repetir en voz alta antes de despedirse, y enviar por escrito esa misma tarde:

> Gonzalo, gracias por hoy. Lo que acordamos: [Nombre] y [Nombre] prueban Danebo con los manuales de [marcas] en [caso] desde el [fecha]. Yo les mando acceso e instrucciones el [fecha]. Nos juntamos el [fecha] para revisar qué preguntaron, qué respondió y qué no sirvió. Si algo de esto no es así, corrígeme.

**Responsables:** tú habilitas, instrumentas y mides. Él nombra y consigue que usen. Si lo segundo no ocurre, no hay piloto, y eso es un dato.

**Qué se registra en cada recorrido:** finalización, tiempo comparado con el método actual declarado por el usuario, correcciones, recuperación tras interrupción, pasos que exigieron ayuda, repetición voluntaria, costo y minutos, y qué parte del resultado usó o descartó.

### Alternativas de colaboración, por conveniencia

1. **Colaboración por objetivo, sin estructura** (recomendada): nombra 1–2 usuarios y un caso; tú habilitas y devuelves resultado en fecha. Cero dinero, cero equity, cero exclusividad.
2. **Comisión sobre dinero cobrado**, solo si el piloto funciona y él produce una conversación con un decisor. Se conversa en octubre, por escrito, contra factura pagada.
3. **Asesoría recurrente o relación estructural**, solo después de aporte repetido y verificable, con abogado. No se menciona salvo que él la proponga.

No se ofrece mentoría pagada: en la demo la declinó.

---

## 14. Señales para pausar

- No puede nombrar a nadie ni dar fecha para nombrarlo.
- Los usuarios nombrados no entran en la semana acordada y no responde a un recordatorio.
- Habla de estructura, porcentaje o exclusividad antes de que nadie haya usado la app.
- Pide más manuales cargados como condición previa a que alguien pruebe.
- Aparece un conflicto con su empleador que no puede resolver.
- Pide costos con insistencia sin aportar datos de mercado.

Con dos de estas: escenario C. Se resuelve por escrito la custodia del corpus y se sigue con Carlos, Venezuela y el registro MINVU. Sin drama y sin cerrar la puerta.

**Regla de cierre del Plan General, que no cambia por esta reunión:** ninguna decisión de producto, gasto, postulación, venta o fecha depende de Gonzalo. Los gates del 16 de septiembre, 2 de octubre y 2 de noviembre no se mueven por lo que pase el viernes.

---

## 15. Hoja de bolsillo

```
OBJETIVO ÚNICO: nombre + caso + fecha inicio + fecha revisión.
Sin eso no cerró. Todo lo demás es información.

APERTURA (su idea, con atribución)
"Me dijiste que lo valioso no era consultar el manual, sino que el
 historial de fallas por marca quedara en la empresa y no en el
 técnico, y que hubiera una base multimarca. Con tus manuales eso
 es lo que hay hoy. Quiero mostrártelo y saber si sigues pensando
 lo mismo."

DEMO 15 min, teléfono
 Biblioteca (180 docs, 6 marcas) -> él elige marca y pregunta x3
 -> foto de consola/tarjeta/plano (NO componente quemado)
 -> Schindler/Fermator: declara sin evidencia
 -> traza de sesión -> cupo por usuario (NUNCA en pesos)
 Decir yo primero: "esto no reemplaza el tester; el código puede
 decir puertas y ser el variador."

OBJECIONES -> RESPUESTA
 "el código miente"         -> cierto; el diagnóstico es del técnico
 "es la mitad de la pega"   -> la mitad que hoy hace ing. de campo
 "el quemado ya es la falla"-> no uso esa foto
 "ya tengo control+F"       -> la carpeta la tienes tú, no el técnico
                               en el foso; y son 6 marcas a la vez
 "falsa confianza"          -> cita página y declara los vacíos

CHATGPT (6)
 1 multicuenta/aislamiento  2 si no está lo dice + cita página
 3 traza auditable por técnico  4 calibra con uso real
 5 contexto acotado  6 cupo visible (sin pesos)
 Cierre: "pruébalo con una pregunta difícil, ahora"
 Prohibido: "garantizo la precisión", "no alucina"

PREGUNTAS (1,2,4,5,8 obligatorias)
 1 ¿Qué esperabas ver hoy? ¿Qué te haría decir sirve / no sirve?
 2 Escalada a ingeniería de campo: ¿cuántas/semana, quién?
 3 Cartera que rechazan por marca desconocida: ¿cuánta, qué falta?
 4 ¿Cómo te imaginas participando? ¿tiempo real en 30 días?
 5 ¿Vender a otras mantenedoras te complica con tu empresa?
 6 ¿Quién decide software y hasta qué monto sin comité?
 7 ¿% mantención vs correctivos/modernizaciones?
 8 CIERRE: 1-2 ingenieros, 2 semanas: ¿quiénes, qué caso, cuándo?
 (certificador) Cuando hacías los informes tú mismo, ¿cuánto se
  te iba escribiéndolos después de la visita?

CORPUS (sin monto)
 "Es lo más valioso que he recibido. Sin eso no tendría con qué
  probar nada real. Están aislados y no los he usado con nadie.
  ¿Se quedan solo ahí o pueden ser base para otros clientes?
  Y si fuera lo segundo, ¿qué te gustaría a cambio?"
 Si pregunta por qué no cargué todo: 6 marcas acordadas ~10 mil
 págs; quedan ~15 mil. Cuesta por página y no quise pasarme de
 lo acordado. Sin dólares, sin reclamo.

ACTIVACIÓN (sin número)
 "No es solo cargar manuales: usuarios por técnico, biblioteca
  aislada, y si quieres su propio dominio. Ya tengo un cliente
  así. Se cobra aparte porque es trabajo por empresa."

SI PREGUNTA PRECIO / MODELO
 1 "Tres formas: por técnico, por equipo, por informe. ¿Cuál
    acepta una mantenedora y en qué rango?"
 2 "No está decidido: estoy midiendo el costo, falta el de la voz."
 3 "Te lo digo en octubre, con el piloto encima."
 Puente: "el modelo lo define el piloto. Armemos la prueba."

VISIÓN (solo min 42-45, después del cierre)
 "Que el técnico deje el teléfono en el piso, pregunte hablando y
  la aplicación le conteste hablando y lo vaya guiando. Con
  guantes, poca luz, sin soltar la herramienta. Es hacia donde
  va Danebo."
 "Lo que me tiene indeciso es cuál de los tres módulos construyo
  primero. El piloto me lo dice."
 El piloto se hace con lo que existe hoy; la voz no es parte de él.
 Voz del certificador: mostrarla solo si pasó 5 recorridos limpios.
 Es rumbo, no oferta. NO prometer fechas ni alcance.

NO DECIR
 Precio, COGS, US$255, runway, CORFO, expansión regional,
 socio, equity, comisión, exclusividad, garantías absolutas.

CIERRE (en voz alta + escrito esa tarde)
 Usuarios ______   Caso ______
 Inicio ____  Revisión ____ (evitar 17-21 sep)
 Yo: acceso e instrucciones el ____.  Él: que usen.
 Éxito: 1 persona, 2 sesiones reales, sin mi ayuda, y me dice
 una consulta que sirvió y una que falló.

PAUSA SI
 no hay nombre ni fecha para el nombre / estructura antes de uso /
 "más manuales primero" como condición / conflicto laboral sin
 salida / pide costos sin dar datos.
```

---

## 16. Documentos relacionados

- [PLAN_GENERAL_2026-09-03.md](PLAN_GENERAL_2026-09-03.md) — estrategia padre, reglas fijas §0, señales de Gonzalo §9.2, custodia del corpus §9.3, escenarios §9.4, límite de rol sectorial §9.7, objeción ChatGPT §13
- [PLAN_SEPTIEMBRE_2026.md](PLAN_SEPTIEMBRE_2026.md) — alcance del mes, cortes y consecuencias §8
- [PRICING_Y_MERCADO_2026-08-07.md](PRICING_Y_MERCADO_2026-08-07.md) — unidades de cobro §5, por qué no por token §7, preguntas de mercado §8.2
- [SAAS_COST_MODEL_2026-06-12.md](SAAS_COST_MODEL_2026-06-12.md) — COGS y pisos de precio
- [INGESTA_PILOTO_GONZALO_2026-08-20.md](INGESTA_PILOTO_GONZALO_2026-08-20.md) — corpus, alcance, huecos y costo real
- [MATRIZ_DEMOS_PILOTOS_2026-08-07.md](MATRIZ_DEMOS_PILOTOS_2026-08-07.md) — telemetría de la demo del 6 de agosto
