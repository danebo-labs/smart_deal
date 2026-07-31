# Pilot Capture Template — sesión de demo RAG SEGURIDADES

## Metadatos de sesión
- **Fecha:** [YYYY-MM-DD]
- **Hora de inicio:** [HH:MM]
- **Duración (min):** 
- **Técnico:** [Nombre]
- **Modelo de placa testeado:** [ej: Sistel Twister, ARCA II, TPR50, etc.]
- **Condición de inicio:** [nuevo usuario / usuario experimentado / con historial en el KB]

---

## Por pregunta técnica

### Pregunta 1: [texto literal]
**Contexto:** [qué motivó la pregunta en el campo]

- **Utilidad:** ☐ Útil · ☐ Parcialmente útil · ☐ No útil
- **Corrección técnica:** ☐ Sí (claims centrales correctos) · ☐ No (especificar abajo)
- **Soporte de cita verificado contra logs:** ☐ Sí · ☐ No
- **Detalles técnicos / hallazgos:**
  ```
  [especificar si la respuesta faltó información, fue precisa, 
   o si observó trasplante/confusión entre placas]
  ```
- **¿Incidente?** ☐ Sí · ☐ No → **Clase:** ☐ Crítico · ☐ Alto · ☐ Medio
  - Descripción: 

### Pregunta 2: [texto literal]
[Repetir estructura anterior]

[Continuar para cada pregunta — incluir al menos 5–8 preguntas]

---

## Insight de valor por sesión

**Dolor observado:**
[Ej: "El técnico consultaba 3 documentos en papel para saber qué serie de puertas mira en la placa X"]

**Solución actual (línea base):**
[Ej: "Busca página X del PDF, luego página Y del catálogo de repuestos; ~4–5 min por consulta"]

**Resultado observado con la app:**
[Ej: "La app le dio la respuesta en 30 seg y le sugirió verificar página 89 del documento — coincidió con lo que veía en campo"]

**Evidencia:**
[Ej: "El técnico confirmó que la serie que le recomendó la app era la correcta; evitó un servicio técnico innecesario"]

---

## Señal comercial

Después de esta sesión, el resultado es:

- ☐ **Continuar:** el valor observado justifica seguir demostrando
- ☐ **Referir:** el feedback sugiere pivotar a otro grupo o caso de uso
- ☐ **Autorizar:** está listo para rollout limitado / prueba piloto formal
- ☐ **Pagar:** el técnico / empresa quiere acceso de pago inmediato
- ☐ **Pedir siguiente paso:** especificar qué es (capacitación, integración, datos, etc.)

**Notas:**

---

## Tiempo del método actual (línea base manual)

Para las 2–3 búsquedas típicas en papel / catálogos:

| Búsqueda | Tiempo (min:seg) | Documento/proceso |
|---|---|---|
| [ej: serie de puertas en Twister] | 3:45 | PDF + catálogo |
| [ej: LED en tabla EM 1000] | 2:20 | PDF tabla |
| [ej: ambigüedad verificada] | 5:10 | múltiples PDFs |
| **Promedio** | **3:45** | — |

---

## Observaciones no-estructuradas

[Ej: "El técnico preguntó 2 veces por cosas ya respondidas — sugiere que la UI podría recordar historial visual. La abstención en la pregunta #4 fue sorpresiva, porque el documento sí tiene la info (revisé después en el KB)."]

---

## Anexo: Métricas automáticas

Ejecutar después de la sesión:
```bash
kamal app logs -f 2>&1 | grep -E 'PILOT_USAGE|RAG_QUALITY' > tmp/pilot.log
PILOT_USAGE_LOG=tmp/pilot.log bin/rails runner script/pilot_metrics_export.rb 2026-07-31
```

**Extraer de `technical_and_cost.evidence_route_summary`:**
- Total de queries: 
- Abstención rate: 
- Ambigüedades detectadas: 
- Latencia promedio (generación): 

**Extraer de `repeat_usage`:**
- ¿Hubo repetición de preguntas?: 
- ¿Reformulación después de abstención?: 

**Archivar el log completo en:** `tmp/pilot_baseline_[YYYYMMDD]_[technician].log`
