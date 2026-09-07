# Danebo — Plan de Septiembre 2026 (validación de uso)

**Estado: ACTIVO — documento operativo del mes.** Agosto está cerrado ([PLAN_AGOSTO_2026-08-07.md](PLAN_AGOSTO_2026-08-07.md)).
**Ventana:** jueves 3 de septiembre → viernes 2 de octubre de 2026.
**Construcción efectiva:** lunes 7 de septiembre → viernes 2 de octubre.
**Convención:** se planifican días hábiles; los fines de semana no cuentan como capacidad.
**Documento padre:** [PLAN_GENERAL_2026-09-03.md](PLAN_GENERAL_2026-09-03.md).
**Documento anterior:** [PLAN_AGOSTO_2026-08-07.md](PLAN_AGOSTO_2026-08-07.md), cerrado el 3 de septiembre.

La prioridad del ciclo es demostrar que el circuito mínimo de voz y borrador resuelve una tarea real. El mes no se evalúa por cantidad de funcionalidades terminadas.

---

## 0. Decisión de foco

Danebo avanza como proyecto founder-solo. Ninguna fecha, gasto ni entregable presupone horas, usuarios, ventas o contactos aportados por Gonzalo.

El único frente activo de construcción es el circuito compartido:

> audio → transcripción visible y editable → confirmación → borrador persistente → cierre y reapertura → revisión simple

La secuencia de validación es:

1. La empresa de los hermanos en Venezuela prueba la **mecánica y el uso** con un informe correctivo real.
2. Carlos Schwartz valida el **encaje del flujo certificador chileno** y ayuda a llevarlo a una inspección real.
3. Un piloto chileno prueba uso repetido y una condición de compra.
4. Una oferta aceptada y dinero cobrado prueban demanda comercial.

Venezuela no valida mercado, precio ni regulación chilena. Carlos no se trata como comprador ni como representante de una empresa hasta comprobarlo. Gonzalo puede acelerar una actividad si reaparece, pero no altera esta secuencia.

---

## 1. Estado de partida al 3 de septiembre

### 1.1 Hechos comprobados

| Hecho | Implicación |
|---|---|
| Existe un MVP funcional del asistente documental y se han realizado ocho entrevistas | La capacidad técnica y el problema documental tienen evidencia; la compra aún no |
| Carlos Schwartz sugirió aplicar voz al trabajo de certificadores | Justifica una prueba de flujo, no demuestra mercado |
| La empresa de los hermanos puede probar el mismo mecanismo con su informe correctivo | Hay acceso de bajo riesgo a validación de uso |
| Gonzalo propuso explorar una asociación y luego entregó aproximadamente 2,88 GB | Hubo interés explícito y un aporte concreto |
| Se procesaron 180 PDF, 10.442 páginas y seis marcas, con USD 255,21 de gasto real | La ingesta está ejecutada; no se vuelve a gastar para justificar la relación |
| Credenciales y pedido de correos se enviaron el 26 de agosto; al corte no hay respuesta ni uso confirmado | La disponibilidad operativa no está demostrada |
| El 3 de septiembre se retomó el almuerzo; al corte no hay respuesta | No existe siguiente paso acordado; el silencio tampoco prueba rechazo |
| Jesús usó la app y no obtuvo respuestas útiles antes de aportar nuevos manuales | Existe una señal de precisión que debe registrarse, sin desviar el mes |

### 1.2 Hipótesis activas

- Un usuario de campo preferirá dictar a escribir cuando la transcripción sea visible y corregible.
- Poder cerrar y recuperar el borrador reduce el costo de interrupciones y mala conectividad.
- El mecanismo común puede servir tanto a un informe correctivo como a un informe de certificación, aunque sus formatos y reglas sean distintos.
- Un certificador valorará suficientemente el flujo como para repetirlo y luego considerar pagar.

Ninguna hipótesis se convierte en hecho porque una persona elogie la idea.

### 1.3 Pendientes externos

- Carlos: informe anonimizado o ejemplo equivalente, mapa de su proceso, fecha de una inspección y usuario del piloto.
- Venezuela: trabajo real sobre el cual usar el circuito y fecha de devolución.
- Gonzalo: cualquier respuesta, permiso de reutilización del corpus y disponibilidad concreta. No bloquea.
- Caja: confirmar cargos bancarios exactos y abono efectivo de la AFC.

---

## 2. Alcance mínimo que sí se construye

### 2.1 Obligatorio para el piloto

1. Grabar audio desde la web o cargar una grabación.
2. Mostrar la transcripción antes de convertirla en hallazgo.
3. Permitir corregir el texto y exigir confirmación del usuario.
4. Guardar el hallazgo en un borrador persistente asociado a su cuenta.
5. Cerrar y reabrir sin perder audio, transcripción ni texto confirmado.
6. Mostrar una revisión simple de los hallazgos acumulados.
7. Registrar costo, duración, latencia, correcciones y errores del procesamiento.
8. Mantener aislamiento por cuenta, trazabilidad y el aviso de que Danebo no sustituye inspección, medición, criterio profesional ni procedimientos de seguridad.

### 2.2 Deliberadamente fuera del alcance

- Informe final en PDF o Word.
- Estructura completa de ocho ítems de certificación.
- Clasificación automática de gravedad o cumplimiento.
- Decisión de aprobación o rechazo de un equipo.
- Integración normativa exhaustiva.
- Flujo hands-free del mantenedor.
- Nuevo corpus, más marcas o uso de la biblioteca de Gonzalo con terceros.
- Módulo para administradores u otro sector.

Estos elementos se reconsideran solo después de uso real. El exportable no es necesario para saber si dictar, corregir y recuperar un borrador resuelve el problema.

---

## 3. Plan ejecutable

### 3.1 Jueves 3 y viernes 4 de septiembre

- Separar en caja el corte aproximado de septiembre y provisionar el de octubre.
- Confirmar el alcance mínimo anterior y convertir cada paso en criterio verificable.
- Preparar para Carlos un pedido concreto: informe anonimizado, conversación de proceso y fecha real.
- Acordar con los hermanos un trabajo real para la primera prueba; no usar una demo preparada.
- No volver a contactar a Gonzalo para pedir reunión.

### 3.2 Lunes 7 a viernes 11 de septiembre

- Implementar el modelo mínimo de borrador: cuenta, trabajo, hallazgo, texto confirmado y estado.
- Implementar guardado, cierre y reapertura antes de automatizar estructura.
- Probar manualmente interrupción y recuperación.
- Realizar la conversación de flujo con Carlos si acepta; documentar proceso actual, artefacto, tiempo y errores.
- Dejar preparado el guion de prueba de Venezuela.
- Registrar el caso de Jesús como fallo de precisión separado; corregir solo si bloquea un usuario activo.

**Entregable:** borrador persistente demostrable con texto manual y material/fecha de al menos un validador.

### 3.3 Lunes 14 a miércoles 16 de septiembre

- Integrar grabación o carga de audio.
- Mostrar la transcripción editable y exigir confirmación.
- Unir el texto confirmado al borrador persistente.
- Medir un recorrido completo con audio de prueba realista.
- Ejecutar el corte del 16 de septiembre de la sección 8.

**Entregable:** circuito mínimo extremo a extremo, aunque la interfaz sea austera.

### 3.4 Jueves 17 a lunes 21 de septiembre

Fiestas Patrias reduce la disponibilidad externa. No se planifican respuestas de Carlos, Gonzalo, técnicos o prospectos.

- Corregir pérdida de datos, errores de reintento y problemas de cuenta.
- Instrumentar costo, minutos, latencia y correcciones.
- Ensayar pérdida de conexión sin construir una arquitectura offline completa.
- Preparar una versión utilizable desde teléfono.

### 3.5 Martes 22 a viernes 25 de septiembre

- Ejecutar el primer uso con la empresa de los hermanos sobre un informe correctivo real.
- Observar sin guiar cada paso que el usuario no entienda.
- Corregir únicamente los bloqueos del circuito mínimo.
- Pedir un segundo uso o continuación del mismo trabajo para distinguir novedad de repetición.
- Mostrar a Carlos el flujo con su propio material, si lo entregó, y fijar una inspección o prueba real.

### 3.6 Lunes 28 de septiembre a viernes 2 de octubre

- Repetir la prueba de Venezuela y cerrar su registro.
- Revisar con Carlos u otro certificador qué campos faltan para una prueba real.
- Medir COGS de voz por audio y por recorrido.
- Preparar una oferta de piloto chileno con alcance, usuario, fecha, devolución y condición de compra.
- Tomar el gate de 30 días el 2 de octubre.

No se usa esta semana para completar PDF, ocho secciones o reglas normativas si falta uso real.

---

## 4. Validación independiente de Gonzalo

### 4.1 Venezuela: laboratorio de uso

**Perfil:** técnico o responsable que hoy produce el informe correctivo y pueda usar el flujo en un trabajo real.

**Oferta:** uso gratuito del circuito mínimo para documentar un caso verdadero, sin migración ni promesa comercial.

**Compromiso pedido:**

- aportar un trabajo real;
- intentar completarlo sin asistencia continua;
- recuperar el borrador después de cerrar o interrumpir;
- corregir la transcripción cuando sea necesario;
- repetir o continuar el uso;
- participar en una devolución breve con ejemplos concretos.

**Puede validar:** comprensión, fricción, correcciones, persistencia, recuperación, ruido y repetición.

**No puede validar:** demanda chilena, formato de certificación, precio, comprador ni expansión a Venezuela.

### 4.2 Carlos: flujo certificador chileno

**Perfil prioritario:** certificador que personalmente inspecciona o redacta y que pueda describir cómo se transforma una observación de terreno en informe. Idealmente participa también quien aprueba herramientas.

**Oferta:** adaptar el circuito mínimo a un caso real y reducir escritura o retrabajo. La primera actividad es validación de flujo, no una venta presumida.

**Compromiso pedido:**

- entregar un informe anonimizado o un ejemplo fiel;
- recorrer el proceso actual y estimar su tiempo;
- identificar una inspección real;
- nombrar a la persona que usará Danebo;
- fijar una sesión posterior para revisar el resultado;
- indicar quién decidiría una compra si la prueba funciona.

Si al 16 de septiembre Carlos no puede aportar material ni fecha, se contacta uno a uno a otros certificadores del registro MINVU hasta conseguir ese compromiso. La adquisición no depende de una introducción de Gonzalo.

### 4.3 De prueba a pago

1. Conversación: confirma lenguaje y proceso.
2. Material + fecha: demuestra interés operativo.
3. Primer uso real: demuestra utilidad puntual.
4. Segundo uso: demuestra repetición inicial.
5. Oferta con precio, unidad, aprobador y fecha: prueba intención de compra.
6. Dinero cobrado: prueba ingreso.

No se llama “piloto” a una cuenta creada sin uso ni “cliente” a quien aceptó una conversación.

### 4.4 Track opcional de Gonzalo

| Escenario | Conducta en septiembre |
|---|---|
| Sigue pendiente | Se asume capacidad cero y no se insiste por una reunión |
| Colabora de forma limitada | Se pide una sola contribución con objetivo, usuario, fecha y devolución |
| No se concreta | Se resuelve por escrito retención, licencia o borrado del corpus y el plan continúa igual |

La biblioteca está en custodia y aislada. No es un activo reutilizable con terceros sin autorización escrita. El costo de indexación no crea deuda ni obliga a mantener la relación.

Si Gonzalo reabre el canal, primero se aclaran disponibilidad, conflicto con su empleador, permiso sobre el corpus y aporte de los siguientes 30 días. No se negocian acciones ni exclusividad en septiembre.

---

## 5. Evidencia y medición

Para cada recorrido real se registra:

| Variable | Evidencia |
|---|---|
| Finalización | El usuario produjo un borrador útil o abandonó |
| Tiempo | Inicio, fin y comparación con su método actual, declarada por el usuario |
| Correcciones | Cambios necesarios para que la transcripción represente lo dicho |
| Recuperación | Pudo cerrar, reabrir y continuar sin pérdida |
| Ayuda | Pasos que requirieron intervención de Lahiri |
| Repetición | Hubo un segundo trabajo o continuación voluntaria |
| Costo | Minutos de audio, costo de transcripción, generación e infraestructura atribuible |
| Resultado | Qué parte usó en su informe y cuál descartó |
| Compra | Precio, responsable y fecha de decisión, solo en piloto chileno |

La lectura es cualitativa y trazable; no se inventan porcentajes con uno o dos usuarios. Un fallo observado se documenta con contexto. Una preferencia declarada no reemplaza el comportamiento.

---

## 6. Precio y adquisición

Durante septiembre se construye una **hipótesis de precio por informe**, no un precio definitivo. Se basa en:

- costo medido del recorrido;
- tiempo y retrabajo del flujo actual del certificador;
- frecuencia esperada de informes;
- soporte requerido;
- responsable de aprobación.

Los datos de agosto sobre equipos por técnico, cartera de mantenedoras y margen de correctivos no se extrapolan al certificador. Sirven para el producto documental de mantenedores y quedan fuera de esta cotización.

La primera prueba con Carlos puede ser gratuita si entrega material, uso real y devolución. La siguiente propuesta debe explicitar precio o condición pagada; continuar gratis sin un nuevo aprendizaje no produce evidencia comercial.

Adquisición sin Gonzalo:

1. Carlos como primera conversación por contexto existente.
2. Otro certificador del registro MINVU si no hay material y fecha.
3. Contacto directo centrado en quien redacta el informe, seguido por quien aprueba gasto.
4. Oferta concreta de una inspección, no una demo genérica.

No se ejecuta en paralelo una campaña de mantenedoras. El asistente documental queda operativo, pero solo recibe trabajo nuevo ante un piloto con usuario, fecha y decisor.

---

## 7. Runway y límites de gasto

Autoridad financiera: [Plan General](PLAN_GENERAL_2026-09-03.md), sección 6, corte del 5 de septiembre.

- Liquidez actual en cuentas corrientes, después de pagar el primer corte del viaje: CLP 51.117.941.
- AFC pendiente: CLP 2.800.000; no cuenta hasta ser abonada.
- Última obligación del viaje: USD 3.800 en octubre, provisionados como CLP 3.610.000 a CLP 950/USD.
- Gasto ordinario restante de septiembre: CLP 2.000.000.
- Burn mensual: CLP 3.200.000.
- Reserva intocable: CLP 19.200.000, equivalente a seis meses.
- Caja libre desde el 1 de octubre: CLP 26.307.941 sin AFC, equivalente a 8,22 meses; con AFC, CLP 29.107.941 y 9,10 meses.

Límites del mes:

- cero compra de corpus;
- cero contrataciones;
- cero herramientas para funciones fuera del circuito mínimo;
- infraestructura existente y consumo de voz solo contra pruebas registradas;
- cualquier nuevo gasto se anota antes de ejecutarlo con la evidencia que pretende comprar;
- la reserva no financia el piloto.

En septiembre se prepara la alternativa de ingreso remunerado. Se activa el 2 de noviembre si falta la evidencia definida en la sección 8.

---

## 8. Cortes y consecuencias

| Fecha | Evidencia requerida | Consecuencia si falta |
|---|---|---|
| **16 de septiembre** | Borrador persistente y circuito de transcripción confirmable; Venezuela o Carlos/otro certificador aporta material o fecha | Congelar estructura vertical y exportación; dedicar el resto del ciclo al circuito reutilizable y a conseguir una prueba real |
| **2 de octubre — 30 días** | Uso real en Venezuela, COGS/error medido y Carlos u otro certificador revisó el flujo o fijó piloto | No construir PDF, automatización normativa ni ocho secciones; buscar otro certificador y revisar el dolor antes de invertir más |
| **2 de noviembre — 60 días** | Pago, piloto pagado o uso repetido con precio/condición de compra, aprobador y fecha | Activar trabajo remunerado, pasar Danebo a tiempo parcial y detener gasto discrecional |

Gonzalo no es un requisito de ningún corte.

---

## 9. Lo que no se hace en septiembre

- Esperar a Gonzalo o perseguir una reunión.
- Reutilizar su biblioteca con Carlos, Venezuela u otro tercero.
- Diseñar una sociedad, negociar equity o asumir representación de ATLAGICH.
- Completar el producto certificador antes de ver uso.
- Confundir el informe correctivo venezolano con el informe regulatorio chileno.
- Tratar a Carlos como comprador sin identificar al decisor.
- Abrir el módulo de administradores, otro sector o consultoría de entrega durante el ciclo.
- Postular a fondos o contar subsidios, inversión o ventas no comprometidas en el runway.
- Declarar éxito por demos, elogios, mensajes o documentos recibidos.
- Relajar evidencia, trazabilidad o avisos de seguridad para acelerar.

---

## 10. Criterio de éxito del ciclo

Al 2 de octubre el ciclo es exitoso si existe:

1. un recorrido completo de audio a borrador recuperable;
2. una transcripción que el usuario puede ver, corregir y confirmar;
3. al menos un uso real en Venezuela con registro de fricción y recuperación;
4. revisión del flujo por Carlos u otro certificador, o una fecha concreta de piloto chileno;
5. costo y errores de voz documentados;
6. una decisión explícita sobre qué no construir;
7. tarjetas provisionadas y reserva intacta.

Un exportable, ocho secciones completas o actividad de Gonzalo no forman parte del criterio de éxito. El resultado comercial se evalúa después: uso no es compra y factura no es dinero disponible para remunerar al fundador.
