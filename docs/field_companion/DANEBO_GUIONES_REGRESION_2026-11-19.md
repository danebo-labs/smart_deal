# Guiones de regresión de Danebo

19 de noviembre de 2026

Los textos de entrada de los casos 22–29 se copiaron de `report.json` sin normalizar. Las respuestas esperadas especifican el sentido aceptable, con referencias locales al turno. La traza anterior sirve como evidencia histórica. La batería acepta otras formulaciones y traducciones que mantengan el significado, la procedencia, las condiciones y el alcance. El estado indicado se comprueba después de recargar el caso.

La evidencia histórica conserva los 47 turnos con lo publicado y lo que se guardó, incluidos los fallos. Archivo en el repositorio: `test/fixtures/files/field_companion/pilot_2026_11_19.json`.

| Cuenta | SHA-256 de `report.json` |
| --- | --- |
| danebo-legacy | `c618a0cb97efbb35fbb15c69f8b6920b564fd21008cd33a880d228b0426dce6e` |
| danebo-pilot-elevator | `12d5e3f2c3be3e8f8ca7b484f01f48c4ff6a44c6b37f5c9cc7565d2e20130911` |

Los reportes identifican `dcd56e5f448d709097604543065859529b637917` en los 47 turnos. Los rótulos de fotos proceden de la salida de visión capturada. Las fotos se identifican por su hash y su posición en el recorrido.

Los casos 22, 23, 25, 26, 27, 28 y 29 usan la secuencia real completa. La versión de campo de Elemont usa los turnos originales 1–5, 8 y 9. Los turnos originales 6 y 7 surgieron de la pregunta que atribuyó una acción y se mantienen como regresiones de reparación en el apéndice. Los guiones documentales de reapertura sin obstrucción, Chapa nivel y SM/SPC/SA conservan la versión propuesta y tienen estado esperado propio.


## Caso 22 · Fermator VF5+ · reapertura con obstrucción visible

`danebo-legacy` · episodio `ep_856541886d6aa932`

### T1

`query:81aebc69-c804-4924-979a-0d247b79c371`

**Consulta exacta**

> Estoy revisando un operador de puerta  Fermator VF5+ . La puerta se reabre sola durante el cierre . El LED está apagado y veo obstrucción

**Respuesta esperada**

Reportas reapertura durante el cierre, un LED apagado y una obstrucción visible. La obstrucción es una observación de terreno y su relación con la reapertura sigue abierta. Con el sistema alimentado, el manual orienta a los fusibles externos si el indicador apagado es STATUS [3]. ¿Cuál es el LED que viste apagado?

**Fuentes**

- [3] *Módulo electrónico VF5+ Fermator*, p. 13 en el export. «Comprobar si los fusibles externos se han quemado».

**Al recargar**

Síntoma y obstrucción del técnico. Pendiente identificar el LED. Sin causa establecida.

### T2

`query:0d28aac3-31d4-4a83-9042-73eb6c8c9a23`

**Consulta exacta**

> Corrijo, el LED está encendido. No apagado

**Respuesta esperada**

Queda corregido el dato: el LED está encendido. La revisión de obstrucción mecánica es parte de la rama de reapertura [5]. La luz de OBSTRUCCIÓN indica que se detecta un obstáculo [8]. ¿Qué indicador está encendido?

**Fuentes**

- [5] *Módulo electrónico VF5+ Fermator*, p. 12 en el export. «Comprobar que no hay una obstrucción mecánica en la puerta.».
- [8] *Módulo electrónico VF5+ Fermator*, p. 7 en el export. «Indicador LED y relé activado cuando se detecta un obstáculo que impide a la puerta cerrarse.».

**Al recargar**

Sustituir apagado por encendido. Obstrucción visible se mantiene. Pendiente identificar el indicador.

### T3

`query:2942f3d6-1651-408c-95ce-8f7f8fafdc34`

**Consulta exacta**

> Es el LEd de fotocelula. Revise y la fotocelula  no se activa durante el cierre

**Respuesta esperada**

El indicador encendido es el de FOTOCÉLULA y dices que las cápsulas no disparan durante el cierre. El mismo indicador responde a la fotocélula o a la entrada de reapertura [8]. ¿Sigue encendido cuando el paso entre las cápsulas está libre?

**Fuentes**

- [8] *Módulo electrónico VF5+ Fermator*, p. 7 en el export. «cuando la fotocélula o la entrada de re-apertura está activada».

**Al recargar**

LED de fotocélula encendido y fotocélula reportada inactiva durante el cierre. Pendiente la distinción entre las dos entradas.

### T4

`query:bd244663-31ef-4f3c-b731-048068309067`

**Consulta exacta**

> El LED de fotocelula está encendido , como identifico la entrada de re apertura ?

**Respuesta esperada**

El plano de señales identifica el borne 21 como entrada de reapertura y el 23 como la referencia de +12 V para esa entrada [12]. ¿Se distingue un cable o contacto entre ambos bornes? La descripción explica cómo está definida la entrada en el manual.

**Fuentes**

- [12] *Módulo electrónico VF5+ Fermator*, p. 7 en el export. «Para activar esta señal, se debe conectar la entrada re-apertura (21) con la entrada de +12V (23).».

**Al recargar**

Pendiente la observación del conexionado 21–23. Sin confirmación del estado lógico de #21.

### T5

`query:1bf4988a-4c10-432b-bd6c-54d690a0fd11`

**Consulta exacta**

> No, no veo un cable conectado entre los botones 21 y 23

**Respuesta esperada**

Anoto que no ves un cable entre 21 y 23. La observación visual queda registrada y el estado de la entrada de reapertura sigue sin verificar.

**Fuentes**

Reporte del técnico y estado del episodio.

**Al recargar**

Guardar ausencia de cable visible con atribución al técnico. Retirar la pregunta visual ya contestada. Mantener #21 sin verificar.

### T6

`query:0d569355-ad3b-4266-a29b-b130dac1b50e`

**Consulta exacta**

> Y si estuviera el cable entre esos bornes, que sigue revisar ?

**Respuesta esperada**

En el supuesto de que 21 estuviera conectado a 23, la señal de reapertura tiene prioridad sobre la orden de cierre. El manual la describe para un interruptor de cabina o una barrera externa [12]. ¿Hay alguno de esos dispositivos en la instalación?

**Fuentes**

- [12] *Módulo electrónico VF5+ Fermator*, p. 7 en el export. «La señal de re-apertura tiene prioridad sobre la señal cerrar. … Esta señal se usa para instalar el interruptor de la puerta de cabina o una barrera externa.».

**Al recargar**

Hipótesis separada del dato de cable no visible. Pendiente dispositivo externo.

### T7

`query:89f65647-5a2e-4d83-bc5b-d52fd6323d5e`

**Consulta exacta**

> No no hay interruptor

**Respuesta esperada**

Queda anotado que no hay interruptor. El estado de la barrera externa y de #21 sigue pendiente. La rama de reapertura pide revisar la fotocélula, la obstrucción y la sensibilidad de #54 [5]. El paso TEST está condicionado a que el problema persista después de esas comprobaciones [5]. ¿La puerta sigue reabriéndose tras revisar la obstrucción observada?

**Fuentes**

- [5] *Módulo electrónico VF5+ Fermator*, p. 12 en el export. «En caso que el problema persista, desconectar la fotocélula y volver a pulsar el botón de TEST.». El registro de recuperación indica p. 12. El bloque §8.2 comienza en la p. 12 del PDF y la condición de TEST continúa en la p. 13.

**Al recargar**

Solo interruptor descartado por reporte. #21, barrera y #54 sin resultado. No registrar TEST como indicado o ejecutado. Pendiente comprobar persistencia tras revisión.


## Caso 23 · Fermator VF5+ · apertura lenta

`danebo-legacy` · episodio `ep_622ef112361e4b5e`

### T1

`query:3e0d620b-5a82-4cb1-a04d-f2f1a29925dd`

**Consulta exacta**

> Estoy con un Fermator VF5+ . Después de un corte de alimentación , la puerta se abre muy despacio

**Respuesta esperada**

El manual describe que la puerta abre lentamente en la primera maniobra tras un fallo de alimentación para comprobar el paso libre [1]. ¿La lentitud ocurrió solo en esa primera apertura?

**Fuentes**

- [1] *Módulo electrónico VF5+ Fermator*, p. 8 en el export. «Las puertas se abrirán lentamente en la primera operación después de un fallo de alimentación para verificar el paso libre.».

**Al recargar**

Corte y apertura lenta son hechos del técnico. Pendiente si se limitó a primera apertura.

### T2

`query:f56b5133-7765-4bc6-b2ac-39f7935327fc`

**Consulta exacta**

> Si fue solo la primera vez

**Respuesta esperada**

Según confirmas, ocurrió solo en la primera apertura. Eso coincide con la comprobación de paso libre descrita tras un corte [1]. Si vuelve a abrir lentamente en otra maniobra, será un dato distinto para investigar.

**Fuentes**

- [1] *Módulo electrónico VF5+ Fermator*, p. 8 en el export. «Las puertas se abrirán lentamente en la primera operación después de un fallo de alimentación para verificar el paso libre.».

**Al recargar**

Respuesta enlazada a T1. Primera apertura confirmada y pendiente resuelto. Sin causa nueva ni observación de cierres posteriores que el técnico no mencionó.

### T3

`query:9ea8bcdd-a6b8-44e9-8b1a-0a3ad044da71`

**Consulta exacta**

> Hace falta algún auto ajuste ?

**Respuesta esperada**

Con lo que describiste del corte, no hace falta repetir el autoajuste. El manual lo contempla para configurar los parámetros por defecto o tras cambios como conectar o desconectar la fotocélula Fermator [1]. ¿Hubo alguno de esos cambios?

**Fuentes**

- [1] *Módulo electrónico VF5+ Fermator*, p. 8 en el export. «Solo es necesario realizar otra vez el autoajuste para la configuración de los parámetros por defecto o cuando se realicen cambios como la conexión o desconexión de la fotocélula Fermator.».

**Al recargar**

Mantener cerrado el dato de primera apertura. La única nueva pregunta admisible es si ocurrió un cambio de los descritos.


## Caso 24 · Elemont MH · cadena de seguridad en campo

`danebo-legacy` · episodio `ep_c031082a6fbc8106`

### T1

`query:46a0e212-7421-4c2f-832a-0d904a57957a`

**Consulta exacta**

> Estoy.en un montacargas Elemont MH  que no responde a las llamadas. No veo código de falla

**Respuesta esperada**

Dices que el montacargas no responde a las llamadas y no ves un código. El plano identifica H4 como piloto de falla de seguridad [4]. ¿La parada de emergencia está desenclavada?

**Fuentes**

- [4] *Elemont Montacargas Hidraulico Modelo MH*, p. 2 en el export. «Luz piloto, falla seguridad».

**Al recargar**

Pérdida de llamadas y ausencia de código visible atribuidas al técnico. Pendiente estado de la parada.

### T2

`query:9db624bf-f231-477d-97b0-1c8dff9c7954`

**Consulta exacta**

> La parada de emergencia está desenclavada

**Respuesta esperada**

Anoto que la parada de emergencia está desenclavada. El plano identifica H4 como piloto de falla de seguridad [4]. ¿H4 está encendido?

**Fuentes**

- [4] *Elemont Montacargas Hidraulico Modelo MH*, p. 2 en el export. «Luz piloto, falla seguridad».

**Al recargar**

Guardar el estado sin inventar cuál parada ni una maniobra. Pendiente H4.

### T3

`query:150292a7-f9e1-4d70-bfa8-2f699c3fe3c8`

**Consulta exacta**

> Si, H4 está encendido

**Respuesta esperada**

Reportas que H4 está encendido. Su designación en el plano orienta a la seguridad y todavía falta localizar el punto [4]. ¿K7 está energizado?

**Fuentes**

- [4] *Elemont Montacargas Hidraulico Modelo MH*, p. 2 en el export. «Luz piloto, falla seguridad».

**Al recargar**

H4 encendido. Pendiente K7. Causa abierta.

### T4

`query:98890154-9dce-4413-a614-1386ae3628ba`

**Consulta exacta**

> No está energizado

**Respuesta esperada**

K7 queda registrado como sin energizar. El plano vincula H4 con K5 y K7 [6] e identifica K5 como relé indicador de seguridad [4]. ¿K5 está energizado?

**Fuentes**

- [4] *Elemont Montacargas Hidraulico Modelo MH*, p. 2 en el export. «Relé plano 24VDC INDICADOR SEGURIDAD».
- [6] *Elemont Montacargas Hidraulico Modelo MH*, p. 1 en el export. «vinculado a K5 y K7».

**Al recargar**

Respuesta breve ligada a K7. Pendiente K5. H4 sigue como observación anterior.

### T5

`query:ce8ac964-303a-4613-b021-4fdf257f25e6`

**Consulta exacta**

> K5 no está energizada

**Respuesta esperada**

H4 estaba encendido y reportas K7 y K5 sin energizar. El plano distingue la parada sobre cabina y la parada del foso [9]. ¿Cuál de esas dos paradas está desenclavada?

**Fuentes**

- [6] *Elemont Montacargas Hidraulico Modelo MH*, p. 1 en el export. «vinculado a K5 y K7 … Vinculado a PET, RLP y Com 24VDC».
- [9] *Elemont Montacargas Hidraulico Modelo MH*, p. 5 en el export. «Parada emergencia sobre cabina … Parada emergencia foso».

**Al recargar**

K5 asociado a su pregunta. Pendiente identificar a cuál parada correspondía el estado indicado en T2.

### T6 · original T8

`query:895f24a8-aa2e-41f5-820b-68c7e0d6a872`

**Consulta exacta**

> Parada emergencia foso

**Respuesta esperada**

La parada desenclavada que identificas es la del foso. El plano muestra la cadena en serie entre Seg In y Seg Out y distingue la parada sobre cabina [14]. ¿La parada sobre cabina está enclavada o desenclavada?

**Fuentes**

- [14] *Elemont Montacargas Hidraulico Modelo MH*, p. 5 en el export. «Los componentes se conectan en serie … Parada emergencia sobre cabina».

**Al recargar**

Foso queda liberado con referencia a T2 y este turno. Pendiente exclusivamente el estado de la parada sobre cabina.

### T7 · original T9

`query:669af125-073e-4175-8e70-21d79136fa84`

**Consulta exacta**

> Desenclavada

**Respuesta esperada**

La parada sobre cabina queda registrada como desenclavada. La del foso ya estaba registrada. H4 estaba encendido y K5 y K7 sin energizar. El plano muestra una cadena en serie entre Seg In y Seg Out [15]. Esos estados de los pulsadores no verifican la continuidad eléctrica de toda la cadena.

**Fuentes**

- [15] *Elemont Montacargas Hidraulico Modelo MH*, p. 5 en el export. «Los componentes se conectan en serie entre los nodos Seg In y Seg Out».

**Al recargar**

La respuesta «Desenclavada» completa solo el pendiente de sobre cabina. Conservar dato previo del foso y causa sin confirmar. No abrir una pregunta sin referente.


## Caso 25 · Monarch NICE3000new · Err14

`danebo-legacy` · episodio `ep_124c05d4fa9c4ba5`

### T1

`query:02efc701-3b01-4598-8fe7-7b72690dc7e3`

**Consulta exacta**

> Estoy con un controlador Monarch3000new después de varias maniobras apareció Err14

**Respuesta esperada**

La tabla asocia Err14 al sobrecalentamiento del módulo y lista temperatura ambiente alta, ventilador dañado y filtro de aire bloqueado [1]. Con esta referencia, ¿qué observas en el filtro de aire? La placa y configuración instalada quedan por confirmar.

**Fuentes**

- [1] *Monarch nice 3000 fallas-1*, p. 8 en el export. «La temperatura ambiental es demasiado alta … El ventilador está dañado … El filtro de aire está bloqueado».

**Al recargar**

Guardar Err14 y su aparición tras varias maniobras. Pendiente observación del filtro. Identidad verificada solo al nivel que aportó el técnico.

### T2

`query:8aec6948-f54c-4139-8ade-6261936b7cfa`

**Consulta exacta**

> Medi 26 grados centígrados en el.ambiente junto al gabinete . Mire el filtro de afuera y está cubierto de polvo

**Respuesta esperada**

Mediste 26 °C en el ambiente junto al gabinete y viste polvo en el filtro. La fila de Err14 enumera filtro bloqueado e indica limpiarlo [1]. La tabla no aporta un umbral para interpretar tu temperatura ni un método de limpieza. Para la limpieza se necesita el procedimiento interno aprobado. ¿Ya se limpió el filtro?

**Fuentes**

- [1] *Monarch nice 3000 fallas-1*, p. 8 en el export. «El filtro de aire está bloqueado … Limpie el filtro de aire».

**Al recargar**

Medición literal de T2 y ubicación guardadas con procedencia técnica. Polvo registrado. Pendiente limpieza. Ningún umbral ni método inventado.

### T3

`query:555a1650-7974-4446-9cfc-80ec79bfb26a`

**Consulta exacta**

> Limpie el filtro pero sigo viendo el mismo error

**Respuesta esperada**

Según tu reporte, limpiaste el filtro y Err14 persiste. La tabla mantiene entre las causas un ventilador dañado y una temperatura ambiente alta [1]. Los 26 °C que mediste no tienen un umbral aplicable en la fila. ¿El ventilador gira cuando está funcionando el equipo?

**Fuentes**

- [1] *Monarch nice 3000 fallas-1*, p. 8 en el export. «El filtro de aire está bloqueado … El ventilador está dañado … La temperatura ambiental es demasiado alta».

**Al recargar**

Limpieza hecha y error persistente. Lectura anterior íntegra. Pendiente estado del ventilador, sin comprobación de enclavamiento.

### T4

`query:76ee983f-dbcb-4ba0-95fa-964ee64a3364`

**Consulta exacta**

> No entiendo, como debo seguir? Ya limpie el filtro

**Respuesta esperada**

Ya limpiaste el filtro y el error sigue. La siguiente observación es si gira el ventilador, porque la tabla enumera un ventilador dañado entre las causas de Err14 [1]. Los 26 °C junto al gabinete son tu medición y el manual no da un límite en esa fila. También menciona comprobar la distancia de instalación [1]. Aquí falta el valor requerido para esa distancia.

**Fuentes**

- [1] *Monarch nice 3000 fallas-1*, p. 8 en el export. «El ventilador está dañado … Sustituya el ventilador dañado … La temperatura ambiental es demasiado alta … Compruebe si la distancia de instalación del controlador cumple con el requisito».

**Al recargar**

Publicar la orientación con la cita válida y conservar la lectura. Mantener pendiente el ventilador, sin duplicar el chequeo. Causas de temperatura y distancia sin verificar.


## Caso 26 · CEA15+ · patín en campo

`danebo-legacy` · episodio `ep_b1d5bd5ba850281f`

### T1

`query:6929d612-9cb2-483c-ab4a-6db399ca05e5`

**Consulta exacta**

> La puerta de piso no traba . Hay patín retractil

**Respuesta esperada**

Dices que la puerta de piso no traba y que hay un patín retráctil. Para orientar la comprobación, ¿observas el patín extendido o retraído? El manual seleccionado queda como referencia hasta confirmar la placa y la configuración.

**Fuentes**

Reporte del técnico y estado del episodio.

**Al recargar**

Registrar no traba y patín reportado. Pendiente posición del patín. Identidad no confirmada.

### T2

`query:a1475729-ad72-4094-83b2-4bc3d98786dc`

**Consulta exacta**

> El patín retractil está retraido

**Respuesta esperada**

El patín está retraído según tu observación. En la combinación 2, el manual CEA15+ describe cabina automática y puerta de piso manual con doble contacto y traba por patín [6]. En el supuesto documentado, SA vale 1 cuando el patín está retraído [5]. ¿Tu instalación corresponde a esa combinación?

**Fuentes**

- [5] *manual-cea15p*, p. 27 en el export. «1 … SA es "1" si el patín retráctil está retirado».
- [6] *manual-cea15p*, p. 26 en el export. «Combinación 2: Puerta de cabina automática + Puerta de piso manual con doble contacto; contacto de traba por patín retráctil».

**Al recargar**

Patín retraído con procedencia del técnico. Pendiente combinación. SA sin verificar en campo y placa pendiente.

### T3

`query:d669cd55-c680-4814-8cd7-e5b16652ea13`

**Consulta exacta**

> Si corresponde a esa combinación

**Respuesta esperada**

Confirmas la combinación de puertas. El manual CEA15+ incluye los contactos de traba de piso en la serie SA para esa configuración [6]. La confirmación de la combinación deja pendiente la identidad del controlador y el estado real de SA. ¿Ves algún impedimento en el patín o en la zona de traba?

**Fuentes**

- [6] *manual-cea15p*, p. 26 en el export. «Los contactos de traba de las puertas de piso se incluyen en SA … si el patín retráctil está retirado».

**Al recargar**

Combinación confirmada por el técnico. SA y modelo pendientes. Pregunta por impedimento visible.

### T4

`query:a91fd0b4-48d8-4238-81be-99bde4be9376`

**Consulta exacta**

> Si están obstruido, lo removí y ya cierra bien

**Respuesta esperada**

Reportas que retiraste la obstrucción y la puerta ahora cierra bien. El resultado corresponde al cierre observado. La traba y el estado de SA quedan por verificar. La lógica de SA citada sigue siendo la referencia de la configuración del manual [5]. ¿En la prueba, quedó trabada la puerta de piso?

**Fuentes**

- [5] *manual-cea15p*, p. 27 en el export. «SA es "1" si el patín retráctil está retirado».

**Al recargar**

Impedimento retirado y cierre mejorado según el técnico. Traba y SA sin verificar, placa pendiente. Evitar repetir pregunta por obstrucción.


## Caso 27 · Thyssen MCINV4 · ruido y KP-VS

`danebo-pilot-elevator` · episodio `ep_c8911d4a5b2ac316`

### T1

`query:801e1b09-2ebd-4dee-b2c0-cb0ff478de32`

**Consulta exacta**

> Tenemos un Thyssen con un controlador MCINV4. Se escucha fuerte el motor de traccion durante el viaje

**Respuesta esperada**

Reportas ruido fuerte del motor durante el viaje. La sección 19.13 describe una disminución de KP-VS hasta el mínimo de 3,0 cuando el ruido audible es muy elevado [2]. El valor es el límite de esa rama. ¿El ruido es muy elevado?

**Fuentes**

- [2] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 18 en el export. «En caso de ruido audible muy elevado: disminuya el valor del parámetro "KP-VS", hasta el mínimo de [3,0]».

**Al recargar**

Conservar identidad y ruido fuerte. Mantener sin confirmar la condición «ruido muy elevado». Si la pregunta fue por la lectura actual, persistir ese pendiente sin dar la condición por confirmada. Sin ajuste ni tarjeta adicional de códigos de falla.

### T2

`query:132876b4-b557-4008-a739-d9dceae3984a`

**Consulta exacta**

> El parámetro de KP-VS es de 2,5

**Respuesta esperada**

La lectura de KP-VS que reportas es 2,5. Está por debajo del mínimo 3,0 de la rama para ruido audible muy elevado [2]. El dato no establece la causa. Falta confirmar la condición de ruido antes de considerar aplicable esa orientación.

**Fuentes**

- [2] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 18 en el export. «En caso de ruido audible muy elevado: disminuya el valor del parámetro "KP-VS", hasta el mínimo de [3,0]».

**Al recargar**

Conservar 2,5 como lectura de terreno, 3,0 como límite documental condicionado y la condición aún sin responder. No inferir un ajuste anterior.


## Caso 28 · Thyssen MCINV4 · EA y foto del esquema

`danebo-pilot-elevator` · episodio `ep_9da61692d0d77e0c`

### T1

`photo:c81f840e-72c0-4803-bce2-c4a0addd2561`

**Consulta exacta**

> Estoy revisando un equipo Thyssen Universal con MCINV4. El ascensor quedó detenido y el display marca EA

**Adjunto** · foto 57 · SHA-256 `4b530eaa355c3776f5b83915353d31177d553ba0853fa1772f9e914dc3fb6ee7`

**Respuesta esperada**

Reportas que el ascensor quedó detenido y que en el display aparece EA. En la imagen se ve un esquema de conectores con rótulos como P27 y P28. La imagen no muestra el display con EA. El manual describe EA como falla de señales y trata P28 en la rama condicionada a puerta abierta [1]. ¿Qué observaste en el cierre de la puerta al quedar detenido?

**Fuentes**

- [1] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 24 en el export. «Falha de sinais … Quando falha de P28 - porta aberta - revisar linha dos trincos».
- Visión de la foto adjunta del turno. Diagrama de plugueo del cuadro de comando. Rótulos legibles PLUGACAO DO Q. DE COMANDO · PV-1 · PV-2 · PV-3 · P27 · P28.

**Al recargar**

Identidad, detención y EA tienen procedencia técnica. Rótulos con procedencia visual. Estado de puerta pendiente.

### T2

`query:32e0076c-f337-48eb-b2cd-ac74293a2882`

**Consulta exacta**

> La puerta de cabina no termina de cerrar

**Respuesta esperada**

Reportas que la puerta de cabina no termina de cerrar. La p. 19 identifica una señal de puerta cerrada [1]. La rama de P28 en la tabla de EA tiene su propia condición de puerta abierta [3]. ¿El operador de cabina se mueve durante el intento y se detiene antes de cerrar, o no se mueve?

**Fuentes**

- [1] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 19 en el export. «ENTRADA DO SINAL DE PORTA FECHADA».
- [3] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 24 en el export. «Quando falha de P28 - porta aberta - revisar linha dos trincos».

**Al recargar**

Registrar síntoma de cabina desde T2. Pendiente movimiento del operador. No trasladar la rama de piso como hecho.

### T3

`query:d8b09c8e-0bdb-40ea-9b6a-0dd78ea58508`

**Consulta exacta**

> No se mueve

**Respuesta esperada**

Anoto que el operador no se mueve. El esquema identifica los puntos del freno y de las fases del operador [1]. Esa leyenda no establece por sí sola qué genera EA. ¿Se ve algún impedimento en el recorrido de la puerta de cabina?

**Fuentes**

- [1] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 19 en el export. «PONTO PARA LIGAR FRENO OPERADOR DE PORTA … PONTO P/ LIGAR FASES DO MOTOR OP. PORTA».

**Al recargar**

Vincular respuesta breve al operador. Pendiente impedimento visible. Causa no confirmada.

### T4

`query:c80b67e3-d99e-4a4e-892a-efc8f0db8218`

**Consulta exacta**

> El tronco no engancha, se ve desalineado

**Respuesta esperada**

Describes un enganche que no entra y se ve desalineado. El manual menciona la línea de trincos cuando falla P28 con puerta abierta [3]. El pasaje no describe cómo corregir la alineación. ¿Ya se corrigió la desalineación según el procedimiento de la empresa?

**Fuentes**

- [1] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 19 en el export. «ENTRADA DO SINAL DE PORTA DE PAV. (FECHADA)».
- [3] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 24 en el export. «Quando falha de P28 - porta aberta - revisar linha dos trincos».

**Al recargar**

Guardar la expresión literal del técnico y la desalineación como observación. Pendiente intervención. Sin atribuir una falla eléctrica.

### T5

`query:1d1cac0a-6bf9-4e54-9df5-d91f53e42c75`

**Consulta exacta**

> Alinea el tronco y la puerta ahora cierra bien, pero sigo viendo en el display EA

**Respuesta esperada**

Según tu reporte, se corrigió la alineación y la puerta cierra bien, pero el display sigue mostrando EA. P28 está documentado como punto de señal del contacto de enganche de la puerta de piso [5]. La rama de la tabla conserva su condición de puerta abierta [3]. ¿Se completa la maniobra y se confirma el cierre mientras aparece EA?

**Fuentes**

- [3] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 24 en el export. «Quando falha de P28 - porta aberta - revisar linha dos trincos».
- [5] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 9 en el export. «Ponto para ligar sinal do contato de engate do trinco, confirmando portas de pavimento fechada».

**Al recargar**

Intervención de alineación, cierre mejorado y EA persistente. Pendiente comprobación de la maniobra, con lectura distinta de lo documentado.

### T6

`query:c3f9e356-1a75-43c2-871b-6dd8657806ce`

**Consulta exacta**

> Si, la maniobra se completa. Pero sigue marcando EA el display. Tiene motor de operador . Con la puerta cerrada medi 0vcc en RA-53/p28

**Respuesta esperada**

Confirmas que la maniobra termina, EA persiste y mediste 0 Vcc en RA-53/P28 con la puerta cerrada. El manual identifica P28 como la señal que confirma el enganche de puertas de piso y muestra +110 Vcc [7]. ¿La lectura se tomó respecto de RA-94/A−, que figura en el plano como referencia de 0 V [6]?

**Fuentes**

- [6] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 10 en el export. «RA-94/ A- = 0 VOLT».
- [7] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 9 en el export. «RA-53 / P28 = +110 Vcc … Ponto para ligar sinal do contato de engate do trinco, confirmando portas de pavimento fechada».

**Al recargar**

Conservar 0 Vcc de terreno, +110 Vcc de referencia, presencia del motor y estado de maniobra. Pendiente referencia de la medición.

### T7

`query:8f1c2a36-b9f4-4803-8807-b88d44d21a9e`

**Consulta exacta**

> Por qué comprobaría RA-27/A2+?

**Respuesta esperada**

El manual describe A2+ como alimentación de los circuitos de seguridad y de los señalizadores de pozo [8]. Esa función es distinta de la señal de confirmación de cierre en P28. La correspondencia exacta de RA-27 con A2+ en tu cuadro y su relación con EA siguen abiertas.

**Fuentes**

- [8] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 10 en el export. «Ponto para ligar alimentação dos circuitos de segurança e sinalizadores de poço … +110 Vcc».

**Al recargar**

Mantener el pendiente sobre la referencia de P28. La pregunta del técnico no constituye medición ni confirmación de bornes.

### T8

`query:5e69467f-8520-4864-8a35-2993e104c567`

**Consulta exacta**

> Con la puerta cerrada y trabada, me da +110v entre RA-27/A2 y RA-94/A sigue.marcando EA

**Respuesta esperada**

Reportas +110 V entre RA-27/A2 y RA-94/A con la puerta cerrada y trabada, y EA sigue presente. Es una lectura de ese par, distinta de la de RA-53/P28 [14]. ¿Los 0 V de P28 se midieron respecto de RA-94/A− con la puerta cerrada y trabada?

**Fuentes**

- [10] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 10 en el export. «Ponto para ligar alimentação dos circuitos de segurança e sinalizadores de poço».
- [14] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 9 en el export. «RA-53 / P28 = +110 Vcc».

**Al recargar**

Persisten ambas lecturas con pares y condiciones separados. Pendiente referencia de la lectura en P28.

### T9

`query:bfe53518-6203-48ce-9348-c6b06314f55e`

**Consulta exacta**

> Si con la puerta trabada y cerrada

**Respuesta esperada**

Confirmas que la puerta estaba cerrada y trabada. La respuesta no especifica la referencia de los 0 V. P28 corresponde a la señal del contacto de enganche [19]. ¿Se observa algún impedimento en el contacto de enganche del trinco o en su línea?

**Fuentes**

- [3] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 24 en el export. «Quando falha de P28 - porta aberta - revisar linha dos trincos».
- [19] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 9 en el export. «RA-53 / P28 = +110 Vcc … Ponto para ligar sinal do contato de engate do trinco, confirmando portas de pavimento fechada».

**Al recargar**

Registro parcial de las condiciones de medición. RA-94/A− por confirmar. Pregunta en español, con el término original en la fuente.

### T10

`query:2a6fe084-0de1-4318-9b5a-999226abcf52`

**Consulta exacta**

> Si estaba  desalineado el trinco mecánico. El contacto eléctrico no lo tocaron . Las lecturas las tomaron después cuando la puerta ya cerraba y traba bien

**Respuesta esperada**

Anoto la cronología que aclaraste: el trinco mecánico estaba desalineado, el contacto eléctrico no se tocó en esa intervención y las lecturas fueron posteriores, con la puerta ya cerrada y trabada. RA-53/P28 es el punto de señal del contacto de enganche [22]. ¿El display sigue marcando EA?

**Fuentes**

- [3] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 24 en el export. «Quando falha de P28 - porta aberta - revisar linha dos trincos».
- [22] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 9 en el export. «RA-53 / P28 = +110 Vcc … Ponto para ligar sinal do contato de engate do trinco, confirmando portas de pavimento fechada».

**Al recargar**

Separar corrección mecánica y contacto eléctrico. Conservar las lecturas como posteriores, no asumir operación sobre el contacto. Pendiente EA actual.

### T11

`query:1fc228df-b56b-4f06-bf36-b992e2fe9376`

**Consulta exacta**

> Revise el.esquema del cuadro y confirme que el enganche  no cerraba eléctricamente, aunque el trinco trabaja. Después con la puerta cerrada  y trabada , P28  volvio a marcar +110 vcc y EA desapareció

**Respuesta esperada**

Comprobaste que el contacto de enganche no cerraba eléctricamente aunque el trinco trababa. Luego mediste +110 Vcc en P28 con la puerta cerrada y trabada, y reportaste que EA desapareció. P28 lleva la señal de ese contacto para confirmar el cierre de piso [24]. ¿En esa maniobra se completa el recorrido, actúa la confirmación de cierre y reaparece la falla?

**Fuentes**

- [24] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 9 en el export. «RA-53 / P28 = +110 Vcc … Ponto para ligar sinal do contato de engate do trinco, confirmando portas de pavimento fechada».

**Al recargar**

EA actual contestado. Guardar nuevo pendiente funcional visible y vincularlo a T12. Hallazgo eléctrico y recuperación posteriores, causa no demostrada.

### T12

`query:727a9594-15ad-4ac0-8bd0-422adb1c4c0a`

**Consulta exacta**

> Si confirmo que la maniobra se completa , el enclavamiento de puerta actúa cuando corresponde y el display sigue sin mostrar EA ni otra falla

**Respuesta esperada**

Queda cerrada la comprobación de esa maniobra: se completó, actuó el enclavamiento y el display siguió sin EA ni otra falla. Antes reportaste que el contacto de enganche no cerraba eléctricamente y que después P28 volvió a +110 Vcc con la puerta cerrada y trabada. El manual identifica P28 como la señal de confirmación de puertas de piso cerradas [26]. La relación causal y el detalle de la intervención eléctrica siguen sin confirmar.

**Fuentes**

- [26] *THYSSEN (Manual de Maniobra Universal con MCINV4)*, p. 9 en el export. «Ponto para ligar sinal do contato de engate do trinco, confirmando portas de pavimento fechada».

**Al recargar**

Respuesta de T12 completa el pendiente funcional. Conservar alcance de una maniobra, contacto, P28 y cronología. Sin ordenar más ciclos ni certificar puesta en servicio.


## Caso 29 · Otis · GECB reportado como GECGB, 0102 y dos fotos

`danebo-pilot-elevator` · episodio `ep_e0ba3094742cf8e3`

### T1

`photo:2337fc60-1305-4d73-abc9-ac54869a8304`

**Consulta exacta**

> Estoy revisando un OTis con GECGB . En el.piso 3 la puerta intenta cerrar y vuelve abrir , esto es lo que veo en la consola

**Adjunto** · foto 58 · SHA-256 `d70a62aefe5a7ffc568ab99e71f8a67cc8b669fd878a6229747514af2ee77c84`

**Respuesta esperada**

Reportas que la puerta del piso 3 intenta cerrar y vuelve a abrir. En la foto de la herramienta de servicio alcanzo a leer COR y CR. Son rótulos de la pantalla. ¿Qué evento aparece en el historial? El rótulo del controlador queda por confirmar.

**Fuentes**

- Visión de la foto adjunta del turno. Herramienta de servicio con teclado y pantalla. Rótulos legibles Ad*** COR CR ][][ · C> U00D00 D 1C · MODULE · FUNCTION.

**Al recargar**

Guardar GECGB tal como se escribió y la reapertura como reporte. Foto de consola conserva COR y CR. Aún no existe 0102 en el episodio ni un pasaje aplicable a GECB.

Criterio del runner (corrida 20261120T121417Z): Danebo pide el evento del historial o una lectura equivalente que el equipo muestra (código, mensaje, consola) y encamina el turno siguiente. Una pregunta sobre una variante del manual (puerta frontal o trasera) no equivale: su respuesta no acerca el caso a un evento verificado y el técnico no la contestó en T2 ni en T3.

Criterio del runner (corrida 20261120T141251Z), T2: el evento está respaldado si la cita lleva un extracto que lo dice o si la fuente que recibió el generador bajo ese número contiene la fila (`generator_sources`). El extracto de la cita solo existe cuando la respuesta cita textualmente; una paráfrasis citada como [1][2] sobre las p. 22 y 85, que contienen la fila 0102, está respaldada. T5: «Esta lectura se limita a la prueba que reportaste» cuenta como límite de alcance.

### T2

`query:c95624ac-41c7-4e85-8625-44bb9d452c51`

**Consulta exacta**

> En el historial de eventos aparece 0102 0pMode DTC.

**Respuesta esperada**

Reportas el evento 0102 DTC. La tabla de referencia describe una puerta que no cerró en el tiempo permitido y menciona DCL, DFC y DW [1]. La lectura de ese evento no identifica una señal perdida. Una pregunta que oriente el siguiente paso es opcional; no se exige DCL como primera comprobación.

**Fuentes**

- [1] *MANUAL DE AYUDA TÃ‰CNICA ( Act. Marzo 2010 ) (p124-245)*, p. 85 en el export. «La puerta no fue capaz de cerrar (perdido DCL,DFC ó DW) dentro del tiempo permitido.».

**Al recargar**

0102 como dato de historial aportado por el técnico. Sin mezclar I/O de LCB_II con GECB.

**Criterio corregido.** El texto anterior exigía «¿Se pudo verificar DCL con la puerta cerrada?». El manual fijado solo dice que la puerta no cerró en el tiempo permitido porque se perdió *alguna* de DCL, DFC o DW (p. 22 y p. 85 del tomo 124-245, p. 44 del tomo 1-123 para OTIS 2000). No indica cuál comprobar primero ni «con la puerta cerrada»: era una posibilidad del manual, no una comprobación. La rúbrica pide una explicación fiel y citada del 0102 y que ninguna señal sola figure como la perdida (`no_single_signal_named_as_lost`).

### T3

`photo:069ebf85-5025-4cd3-a1e9-87bdb14f41f8`

**Consulta exacta**

> Todavía no he confirmado el.estado de DCL, así se ve la guía en la puerta del.piso 3

**Adjunto** · foto 59 · SHA-256 `7f04c1ccd48465cb8f0a23336f57705388b4e5818a0c29e12fa935eef231ccb6`

**Respuesta esperada**

DCL sigue sin verificar. En la segunda foto se aprecia la guía del umbral con residuos. Esa imagen aporta un indicio mecánico y no muestra el estado de las señales. ¿La hoja llega al cierre completo o se detiene antes?

**Fuentes**

- Visión de la foto adjunta del turno. Guía de umbral de puerta.

**Al recargar**

Conservar las dos fotos y su orden, con la guía como observación visual activa. DCL sin resultado. Pendiente dónde se detiene la hoja.

Criterio del runner: Danebo avanza desde la foto y el relato con una pregunta sobre la hoja, la guía o lo que la traba (`advances_from_photo_and_report`) y no repite como si nada la pregunta abierta que el técnico no contestó.

### T4

`query:3d7e1e93-00dc-4136-8502-480ff2d7ffae`

**Consulta exacta**

> Se detiene antes

**Respuesta esperada**

Confirmas que la hoja se detiene antes de cerrar. Eso concuerda con el significado del 0102 [1]. La guía con residuos sigue siendo una observación de la foto, y la relación causal queda abierta. ¿Ves algún punto concreto donde se trabe o roce la hoja en el umbral?

**Fuentes**

- [1] *MANUAL DE AYUDA TÃ‰CNICA ( Act. Marzo 2010 ) (p124-245)*, p. 85 en el export. «La puerta no fue capaz de cerrar (perdido DCL,DFC ó DW) dentro del tiempo permitido.».

**Al recargar**

Respuesta breve ligada a posición de cierre. Mantener 0102, foto y DCL pendiente. Pregunta por impedimento mecánico.

DCL se lee del registro persistido: es el check «no verificado» que el técnico declaró en T3, no una observación (`event_and_dcl_kept` acepta observación o check).

### T5

`query:f921b63a-1707-4e97-b6c2-a4d3881d23c9`

**Consulta exacta**

> La hoja se trababa antes de completar el cierre . Encontré residuos en la guía y los retire . Después la puerta cerró por completo y el 0102 no.volvio a registrarse durante la.prueba . No llegamos a verificar DCL ni DFC

**Respuesta esperada**

Se evalúa por significado y procedencia, no por una frase ni por un número de cita fijo. La respuesta aprobada:

- Separa hallazgo (la hoja se trababa antes de cerrar), intervención (retiró residuos de la guía) y resultado (después cerró por completo y el 0102 no volvió a registrarse durante la prueba). Es una sola prueba.
- Reconoce los residuos como la explicación más probable de que la hoja se trabara. Es lectura de Danebo, sin `[n]`, y no instrucción del fabricante. No los da por causa confirmada del 0102 ni certifica la puesta en servicio.
- Limita a esa maniobra lo que la respuesta afirma del resultado (cierre completo, el 0102 sin reaparecer), en la misma oración, en otra afirmación del mismo párrafo o en un párrafo propio de alcance («Alcance: el resultado vale para una prueba…»). Una mención de «la prueba» solo dentro de una pregunta no lo limita. «Limpieza», «retiro» o «residuos» son equivalentes mientras conserven el significado.
- Puede cerrar el intercambio sin pregunta. Si pregunta algo, es una comprobación distinta que una fuente de este turno respalda, no repetir la misma prueba.
- Conserva DCL y DFC como no verificados, tal como los declaró el técnico. No vuelve a pedir DCL.
- Puede sugerir observar DFC si el técnico hace otra maniobra, con respaldo del manual: DFC indica puertas completamente cerradas (Cadena de seguridad cerrada). La sugerencia es opcional. Si la hace con cita, el pasaje citado dice eso; da igual el número `[n]` y el tomo del manual cargado. Si cita la tabla de DFC, conserva el límite de aplicabilidad (la referencia no confirma la placa ni el controlador del caso): `dfc_table_limited_to_the_case_controller`.

**Fuentes**

- Opcional, solo si hay sugerencia: *MANUAL DE AYUDA TÃ‰CNICA ( Act. Marzo 2010 ) (p1-123)*, p. 121 en el export, «Puertas completamente cerradas (Cadena de seguridad cerrada)». En el export original figura como `[21]`; en el replay en vivo, como `[9]`. Ambos son el mismo pasaje.

**Al recargar**

- La comprobación que estaba abierta antes de T5 no queda esperando. Se lee del estado real del caso, sin fijar su identificador: su parte queda en `partial`, `complete` o `unknown`, o el técnico siguió con el caso y esa pregunta ya no es la pendiente.
- Hallazgo, intervención y resultado como observaciones del técnico de este turno.
- Un registro «no verificado» que cubra DCL y DFC (en una fila o en dos). Se conserva aunque el intérprete resuma el resultado en vez de copiarlo: con `FIELD_CHECK_OUTCOME` encendida solo se descarta el resultado no literal y se guarda la declaración.
- `targets: []` aprueba si T5 no abre una pregunta pendiente. La rúbrica anterior exigía el pendiente DFC y queda reemplazada.
- Si T5 sí abre una pregunta pendiente y la sostiene con una cita, el target conserva el documento correcto: `document_key` del manual citado, `filename` del pasaje y `page` citada, aunque la cita esté en el párrafo de la comprobación y la pregunta en el siguiente. Un pendiente con cita y `targets: []` no aprueba. Un pendiente sin cita detrás puede llevar `targets: []`.
- Ninguna pregunta nueva por DCL.

### T6

`query:342940ea-2b8d-45b5-aadb-c841b5f25b7a`

**Consulta exacta**

> Confirmo en la maniobra del piso 3 , la puerta completo el cierre , el LED DFC se encendió y se mantuvo encendido al quedar cerrada , el 0102 no volvió a aparecer durante la prueba. No verifique DCL

**Respuesta esperada**

Se evalúa por significado y procedencia. La respuesta aprobada:

- Vincula la lectura de DFC con la conversación anterior: es el resultado de la maniobra del piso 3 que T5 dejó sin verificar, no un tema nuevo.
- Registra el resultado de esa maniobra: la puerta completó el cierre, DFC se encendió y permaneció encendido, y el 0102 no volvió durante la prueba. Lo limita a esa maniobra y no certifica la puesta en servicio.
- Si cita DFC, el pasaje dice puertas completamente cerradas (Cadena de seguridad cerrada), con el número y el tomo que correspondan.
- Conserva DCL como no verificado, como lo declaró el técnico en este turno, y no vuelve a preguntar por DCL.
- No presenta los residuos como causa establecida del 0102.
- No abre otra comprobación automáticamente.
- Si cita la tabla de DFC, conserva el límite de aplicabilidad al controlador del caso.
- Si la publicación añade la pregunta por el rótulo del controlador, esa pregunta tiene una razón en el turno (controlador sin resolver, ninguna pregunta documentada abierta, pregunta nunca mostrada) y queda guardada como pendiente de tipo `controller`: una pregunta mostrada y no guardada no es aceptable (`published_question_is_the_pending`).

**Fuentes**

- *MANUAL DE AYUDA TÃ‰CNICA ( Act. Marzo 2010 ) (p1-123)*, p. 121 en el export, «Puertas completamente cerradas (Cadena de seguridad cerrada)». Figura como `[21]` en el export, como `[9]` en el replay de la ronda 4 y como `[12]` en la corrida 20261120T121417Z.

**Al recargar**

- La maniobra queda registrada con sus lecturas como observaciones de este turno, sin perder las de T1–T5.
- Si T5 abrió el pendiente DFC, queda cerrado: la parte en `complete` y sin pregunta pendiente. Si T5 no abrió pendiente, el hilo se conserva por el registro «no verificado» de DFC de T5, y T6 no abre una pregunta DFC nueva.
- DCL sigue como no verificado en el estado, con el registro de T6 o con los de T3 y T5 si el intérprete no lo repite, nunca como `done`, y no figura en ninguna pregunta del turno. Si el modelo lo pregunta de nuevo sin razón nueva, la publicación descarta la pregunta y no queda pendiente.
- Al terminar T6 no queda esperando ninguna pregunta que nadie vio. Si la publicación mostró la pregunta por el rótulo, es el único pendiente (`type: controller`). Antes de la corrección, esa pregunta se mostraba y no se guardaba: el estado de T6 (3945 de 4096 bytes) no admitía la pregunta con sus extractos de historial y `install_pending!` devolvía `pending_overflow`.

**Límite conocido.** El registro «No llegamos a verificar DCL ni DFC» de T5 sigue en el estado tras T6, porque cubre las dos cosas y DCL sigue sin verificar. Que DFC ya se leyó consta en las observaciones de T6 y no en un cierre de esa fila.

### Revisión de procedencia · corrida 20261120T121417Z

Qué parte de cada respuesta esperada sale del manual fijado, de la foto o del técnico, o es inferencia o pregunta de Danebo. Tomos: A = «MANUAL DE AYUDA TÃ‰CNICA ( Act. Marzo 2010 )» p1-123; B = p124-245. Páginas del export.

| Turno | Del manual | De la foto o del técnico | Inferencia o pregunta de Danebo | Estado |
|---|---|---|---|---|
| T1 | A p. 42 (OTIS 2000): LRD (I/O 607), DOS (I/O 605), DCL (I/O 894) y ^DCL (I/O 695, puertas traseras), en tablas separadas para frontal y trasera; A p. 49 (guía PAX) nombra DOS. No dice qué falla produce la reapertura. | Reapertura en el piso 3; rótulos COR, CR de la consola; GECGB tal como se escribió. | Pedir el evento del historial. | Evento del historial: razonable (el síntoma solo no identifica señal). Variante frontal o trasera: no sustituye. |
| T2 | B p. 22 («al desaparecer alguna de las señales DCL, DFC o DW», parámetros DCL (694), RDCL (695), DOOR, REAR DTC-T); B p. 85 («perdido DCL,DFC ó DW»); A p. 44 (OCSS, OTIS 2000). | El técnico lee 0102 en el historial. | Que la reapertura es compatible con el 0102. | «Verificar DCL con la puerta cerrada» no está en las páginas disponibles: criterio corregido. Asignar DCL a puerta delantera y RDCL a trasera no está en la fila: se rechaza. |
| T3 | A p. 42: DCL I/O 894, ^DCL I/O 695 (variante trasera). | DCL sin verificar (relato); guía inferior degradada (foto, no del técnico). | Pregunta por la hoja o la guía. | Razonable pedir un dato nuevo; no repetir la pregunta abierta. |
| T4 | B p. 85 (significado del 0102). A p. 49 solo para el operador PAX: «Comprobar ajustes mecánicos de la puerta». | «Se detiene antes». | La pregunta por un impedimento mecánico nace de la foto y del relato; el manual solo la respalda para PAX. | Pregunta razonable como aclaración; no se exige como paso del manual. |
| T5 | B p. 22 o p. 85 para el 0102. A p. 121, tabla de LED: «DFC ● Puertas completamente cerradas (Cadena de seguridad cerrada)». B p. 121 (NE300, «Señal DFC cortada») es otra sección y otro controlador. | Hallazgo, intervención y resultado de la maniobra; DCL y DFC sin verificar. | Residuos como explicación más probable; sugerencia opcional de observar DFC. | La sugerencia es opcional y solo se respalda con la tabla de LED con su límite de aplicabilidad. |
| T6 | A p. 121 (tabla de LED, DFC). | La lectura de DFC y el cierre completo; DCL sin verificar. | La pregunta por el rótulo (regla del controlador sin resolver). | Corregido: se guarda como pendiente. |

**Indeterminado, y qué falta.**

- Compatibilidad de GECGB (o GECB) con el contenido de las páginas citadas. Los dos tomos están en `config/document_identities.yml` sin marca ni designador y sin confirmar. «GECB» y «TCBC/GECB» aparecen solo como alias de búsqueda del chunk de B p. 85, no en su cuerpo. Falta una página del manual que nombre el controlador del caso; los alias del índice ayudan a encontrar el pasaje, no prueban que aplique.
- Página completa de B p. 85, B p. 22 y A p. 121. De cada una solo hay en las capturas los chunks que `Retrieve` devolvió (B p. 85: `chunk_p85_2`; B p. 22: `chunk_p22_1` y `chunk_p22_2`; A p. 121: `chunk_p121_2`). No hay encabezado de sección de B p. 85 ni de A p. 121 en el cuerpo, solo en alias. Falta el PDF o los chunks restantes de cada página.
- Si alguna página fijada pide «verificar DCL con la puerta cerrada»: no se halló en ningún chunk disponible; no se puede descartar fuera de ellos.

## Apéndice · reparaciones conservadas del caso 24

Estos dos mensajes históricos siguen disponibles como pruebas separadas de recuperación cuando aparece la confusión inicial.

### T6

`query:8e2e23f1-01e8-4458-a936-fc535a03658b`

**Consulta exacta**

> A qué te refieres con desenclavastes ?

**Respuesta esperada**

Me refiero al estado del pulsador de emergencia. Desenclavada significa que está en la posición liberada. El plano identifica una parada sobre cabina y otra en el foso [11]. ¿Cuál está desenclavada?

**Fuentes**

- [11] *Elemont Montacargas Hidraulico Modelo MH*, p. 5 en el export. «Parada emergencia sobre cabina».

**Al recargar**

Mantener pendiente la ubicación. Ningún cambio de estado ni intervención inferida.

### T7

`query:9f1c9cda-d4f8-4477-a687-c0982806ccfe`

**Consulta exacta**

> Desenclave K5

**Respuesta esperada**

K5 es un relé indicador de seguridad [4]. Los pulsadores de emergencia son la parada sobre cabina y la del foso [13]. ¿Cuál de esas dos paradas está desenclavada?

**Fuentes**

- [4] *Elemont Montacargas Hidraulico Modelo MH*, p. 2 en el export. «Luz piloto, falla seguridad».
- [13] *Elemont Montacargas Hidraulico Modelo MH*, p. 5 en el export. «Parada emergencia sobre cabina … Parada emergencia foso».

**Al recargar**

Conservar el mensaje sobre K5 como reporte del técnico y distinguirlo de las dos paradas. Pendiente la ubicación.


## Guiones documentales conservados

Estas entradas corresponden a la versión propuesta del documento de revisión. Los exports del 19 de noviembre no contienen esas secuencias completas.

## 1. Fermator VF5+ · La puerta se reabre durante el cierre

**Manual:** *Módulo electrónico VF5+ Fermator*, pp. 7 y 12 del PDF. La sección 8.2 de la p. 12 trata la puerta que se reabre sola. En la misma página, la comprobación de #21 figura en el bloque de puerta que no cierra. La conexión de #21 se describe en la sección «21.- Re-apertura». La pregunta genérica «¿Qué sigue?» es prescindible en la versión aprobada.


### T1

**Técnico:** Estoy revisando un operador de puerta Fermator VF5+. La puerta se reabre sola durante el cierre. El LED está apagado y no veo obstrucción.

**Danebo esperado:** Para una puerta que se reabre sola, el manual indica revisar la sensibilidad del potenciómetro de fuerza de reapertura, #54, comprobar el estado de la fotocélula y verificar si hay obstrucción mecánica [1]. Que no veas una obstrucción es una observación visual. ¿Llegaste a comprobar si la fotocélula se activa durante el cierre?

**[1] VF5+, p. 12, §8.2.** «Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)» y «Comprobar que la fotocélula no esté activada».

**Al recargar**

Reapertura durante el cierre, LED apagado sin identificar y sin obstrucción visible como observación. Fotocélula pendiente.

### T2

**Técnico:** Corrijo un dato: el LED está encendido, no apagado.

**Danebo esperado:** Queda corregido: el LED está encendido. Si es el indicador de fotocélula, el manual lo asocia tanto con la fotocélula como con la entrada de reapertura [1]. ¿Qué LED está encendido: Fotocélula, Obstrucción u otro?

**[1] VF5+, p. 7.** «Indicador LED y relé activado cuando la fotocélula o la entrada de re-apertura está activada».

**Al recargar**

LED encendido reemplaza al apagado. Indicador específico por identificar.

### T3

**Técnico:** Es el LED de Fotocélula. Revisé y la fotocélula no se activa durante el cierre.

**Danebo esperado:** El LED de Fotocélula está encendido y reportas que la fotocélula no se activa. La entrada de reapertura puede explicar el indicador según la p. 7 [1]. El manual también contempla comprobar el estado de la señal #21 en el bloque de puerta que no cierra [2]. ¿Sabes si la señal #21 está activa? El ajuste de #54 y la comprobación mecánica siguen sin resultado.

**[1] VF5+, p. 7.** Indicador compartido por fotocélula y entrada de reapertura.

**[2] VF5+, p. 12.** «Comprobar si la señal de re-apertura (#21) está activada». La cita pertenece a un bloque distinto de §8.2.

**Al recargar**

LED de fotocélula identificado y encendido, sin disparo reportado. #21, #54 y obstrucción mecánica sin confirmar.

### T4

**Técnico:** No sé identificar el estado de la entrada #21 ni puedo comprobar el contacto entre #21 y #23 con el acceso que tengo. ¿Qué dato nos falta?

**Danebo esperado:** Queda pendiente el estado de #21. El manual identifica esa señal como entrada de reapertura y la vincula con el LED de Fotocélula [1]. Con los datos actuales, la causa sigue abierta. Para compartir el caso con quien pueda verificarlo, tenemos reapertura durante el cierre, LED de Fotocélula encendido y fotocélula reportada como inactiva. También queda pendiente aclarar si hay una obstrucción mecánica y qué se encontró al revisar #54 [2].

**[1] VF5+, p. 7, «21.- Re-apertura» e indicadores.** Función de la entrada y alcance del indicador.

**[2] VF5+, p. 12, §8.2.** Comprobaciones de #54 y obstrucción mecánica.

**Al recargar**

Verificación de #21 inaccesible con el alcance reportado. Conservar pendientes la causa y el estado real de #21. No duplicar la solicitud inaccesible.

## 3. Elemont MH · Corregir la referencia del plano

**Manual:** *Elemont Montacargas Hidráulico Modelo MH*, pp. 1, 5 y 6 del PDF. Los trayectos y números de posición se tomaron de la tabla de lectura añadida al plano en el índice.


### T1

**Técnico:** Estoy con un montacargas Elemont MH que no responde a las llamadas. No veo código de falla.

**Danebo esperado:** El plano muestra conexiones y borneras, pero en los pasajes disponibles no aparece un procedimiento que identifique la causa de que el montacargas no responda a las llamadas. Si quieres revisar un circuito puntual, dime qué rótulo estás siguiendo en el plano [1].

**[1] Elemont MH, p. 1.** La fuente indica que la asignación de terminales «debe verificarse físicamente en campo». El límite sobre el diagnóstico surge del alcance de los pasajes disponibles.

**Al recargar**

No responde a llamadas y no hay código visible según el técnico. Mantener identidad declarada y diagnóstico abierto.

### T2

**Técnico:** En el plano, ¿el trazo de Chapa nivel 2 se une a PasCom 24 V donde lo cruza?

**Danebo esperado:** La lectura del plano indica que Chapa nivel 2 cruza PasCom 24 V con un puente semicircular y sin punto de unión. La unión con PasCom 24 V figura en el lado de Sp2 [1].

**[1] Elemont MH, p. 5, tabla de recorridos.** «Cruza PasCom 24V con un puente semicircular sin punto de unión» y «El trazo del lado Sp2 tiene punto de unión con PasCom 24V».

**Al recargar**

Chapa nivel 2 como referente del plano. La continuidad física sigue sin comprobar.

### T3

**Técnico:** Me equivoqué: la referencia que estoy mirando es Chapa nivel 3, no Chapa nivel 2.

**Danebo esperado:** Queda corregida a Chapa nivel 3. En ese recorrido, el trazo pasa por Dp3 y cruza PasCom 24 V sin punto de unión. La unión con PasCom 24 V figura del lado de Sp3 [1].

**[1] Elemont MH, p. 5, tabla de recorridos.** Trayecto por Dp3 y «El trazo del lado Sp3 tiene punto de unión con PasCom 24V».

**Al recargar**

Reemplazar nivel 2 por nivel 3 como referente vigente. Conservar la corrección.

### T4

**Técnico:** ¿Y dónde está Seguridad Puerta del mismo nivel y qué tiene a sus lados en la línea?

**Danebo esperado:** Para el nivel 3, la tabla ubica Seguridad Puerta nivel 3 entre Seguridad Puerta nivel 4 y Seguridad Puerta nivel 2. Su posición en esa tabla es 7. Es un orden de lectura de la cadena en el plano; los números de posición no están impresos en el esquema [1].

**[1] Elemont MH, p. 5, tabla de cadena en serie.** Niveles 4, 3 y 2 en las posiciones 6, 7 y 8 de la transcripción.

**Al recargar**

Vincular «del mismo nivel» a nivel 3. Mantener la vecindad documental 4 → 3 → 2 y la posición 7 como índice de tabla.

### T5

**Técnico:** No sé identificar en el equipo cuál es la Chapa nivel 3. ¿Con lo que tenemos puedes decirme qué reemplazar?

**Danebo esperado:** El plano identifica el terminal Chapa nivel 3 y lo lista como «Chapa/selector de nivel 3» [1, 2]. Eso permite ubicar la referencia en el dibujo. Falta identificar el componente instalado y confirmar una falla en campo antes de recomendar un repuesto.

**[1] Elemont MH, p. 5.** El recorrido termina en el terminal Chapa nivel 3.

**[2] Elemont MH, p. 6.** «Chapa/selector de nivel 3».

**Al recargar**

No identificado físicamente el componente. Referencia en el plano disponible. Sin pieza confirmada para reemplazo.

## 5. CEA15+ · Serie de puertas, referencia con identidad pendiente

**Manual:** `manual-cea15p.pdf`. Usar como consulta documental hasta confirmación de placa y configuración. El informe de producción sitúa el ejemplo de contactos en p. 24. Un replay lo muestra como p. 25, y un fixture posterior tiene otro número de chunk. Para fijar una referencia, verificar el encabezado y la condición del ejemplo contra el PDF del despliegue.


### T1

**Técnico:** La puerta de piso no traba. Hay patín retráctil. ¿Qué tiene que cumplirse para que la seguridad automática SA quede en 1?

**Danebo esperado:** En el manual CEA hay dos ramas. Cuando hay contactos que se normalizan por acción del patín, SA incluye esos contactos. Cuando no los hay, el manual remite SA a SPC [1]. Para saber si esa referencia corresponde a tu instalación, ¿qué modelo dice el rótulo del controlador?

**[1] manual-cea15p, p. 24 en la corrida de producción.** Definición y condición de SA.

**Al recargar**

Patín y puerta que no traba son reportes. Identidad del controlador y aplicabilidad pendientes.

### T2

**Técnico:** ¿Qué son los terminales SM, SPC y SA en la serie de seguridad de puertas?

**Danebo esperado:** En la referencia CEA, SM corresponde a Seguridad Manual. SPC corresponde a Seguridad de Puertas Cerradas y contempla el cierre por operador cuando existe ese tipo de puerta. SA corresponde a Seguridad Automática y contempla los contactos que actúan con el patín cuando esa configuración los lleva [1]. La asignación de cada contacto depende de la combinación de puertas.

**[1] manual-cea15p, apartado «Sistema de seguridad — SM, SPC y SA».** Reportado en p. 24 de la prueba de producción y p. 22 del replay posterior.

**Al recargar**

Conservar SM, SPC y SA como definiciones documentales. Mantener identidad pendiente.

### T3

**Técnico:** Si mido un terminal de la serie de seguridad, ¿qué tensión es un 1 y qué tensión es un 0?

**Danebo esperado:** Para las entradas que describe ese manual, 24 Vcc corresponde al nivel lógico 1 y 0 Vcc al nivel lógico 0 [1]. Son las referencias del manual CEA para ese sistema.

**[1] manual-cea15p, p. 22.** Condición de nivel lógico para 24 Vcc y 0 Vcc.

**Al recargar**

Valores de referencia documental. Sin registrar una medición de 0 Vcc ni 24 Vcc del técnico.

### T4

**Técnico:** No hay contactos que cierren por el patín retráctil. ¿Cómo se conecta SA?

**Danebo esperado:** El manual describe SA referida a SPC en la configuración donde no hay contactos que actúen por el patín [1]. Esa es la rama documental que corresponde al supuesto que acabas de indicar. Su aplicación en el equipo depende de confirmar el modelo y el esquema de la instalación.

**[1] manual-cea15p, p. 24, condición de ausencia de contactos del patín.** Conservar la condición al citar.

**Al recargar**

Escenario sin contactos accionados por patín. SA referida a SPC solo bajo esa condición. Identidad pendiente.

### T5

**Técnico:** La puerta de cabina es manual y la de piso es manual, con doble contacto y traba por patín. ¿Qué contactos van en SM y cuáles en SA?

**Danebo esperado:** El ejemplo de cabina manual y puerta de piso manual con doble contacto y traba por patín sitúa en SM el contacto de cabina cerrada y los precierres de piso, y en SA los contactos de traba de piso. El ejemplo también describe SPC referido a SM [1]. Antes dijiste que no había contactos que actuaran por el patín. Falta confirmar cuál de esas dos configuraciones describe tu equipo.

**[1] manual-cea15p, ejemplo «Puerta de cabina manual + Puerta de piso manual con doble contacto; contacto de traba por patín retráctil».** P. 24 en el informe de producción y p. 25 en el replay.

**Al recargar**

Conservar como hipótesis separadas las configuraciones incompatibles de T4 y T5. Pendiente cuál describe el equipo.

### T6

**Técnico:** La bobina del patín retráctil mete interferencia. ¿Qué indica el manual para ese caso?

**Danebo esperado:** Para interferencia por la bobina, el manual describe un supresor de arco. La referencia al rectificador de rueda libre responde a otro propósito, relacionado con el retardo de caída [1]. La selección para el equipo requiere confirmar el esquema y las características de la bobina.

**[1] manual-cea15p, pp. 19–20.** Pasajes de supresión de interferencia y rueda libre.

**Al recargar**

Reporte de interferencia atribuido al técnico. El supresor y la rueda libre son referencias con propósitos distintos.

### T7

**Técnico:** ¿El contacto del operador de puerta automática entra en la serie SM?

**Danebo esperado:** En la definición CEA, SM excluye los contactos que se normalizan por acción del operador de puerta automática [1]. Eso responde a la definición de SM. La asignación concreta depende de la configuración de puertas del esquema aplicable.

**[1] manual-cea15p, p. 23, definición de SM.** La fuente indica «NO incluye» respecto a los contactos del operador automático.

**Al recargar**

SM excluye contactos que se normalizan por el operador automático en la definición. No guardar un esquema ni una medición confirmada para este equipo.
