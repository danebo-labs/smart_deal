# Rastro sanitizado de producción — SEGURIDADES

**Fecha:** 2026-07-29
**Origen:** base de producción consultada en modo lectura mediante Kamal.
**Alcance:** cuenta, sesión, preguntas RAG, historial conservado y diagnósticos `Retrieve`.
**Privacidad:** se excluyen nombres, correo, tokens, credenciales y contenido ajeno a la batería.

## Estado verificado

- El despliegue de producción y el checkout local apuntaban al commit `7c5e9545f4fd1452104ae7ae788b2ac5361577af`.
- Documento fijado: `SEGURIDADES 1.1-1`.
- Knowledge Base: `Y7RZWMFJSR`.
- Data source: `PJ0N58DMHG`.
- Ruta de consultas observada: `rag_filtered`.
- Modelo de generación observado: Claude Haiku 4.5 mediante perfil global.
- La API del navegador disponible no expuso historial y no conservaba pestañas abiertas. Este rastro de base de datos es el sustituto verificable del recorrido de hoy.

## Recorrido funcional observado

| Consulta o acción | Resultado observado |
|---|---|
| Pregunta genérica por SPM | SPM está documentado en dos secciones con dos series distintas, por lo que desambiguar era correcto. El defecto fue que las tres opciones mostradas —SMART 001, MR08 y MICONIC LX— no contenían SPM. |
| Selección de SMART 001 | La búsqueda continuó en el contexto incorrecto. |
| Reformulaciones Carlos Silva/TRP50 | La respuesta declaró que el contexto no contenía SPM/TRP50, aunque el dato existe en la página 9 y en su chunk. |
| Pregunta genérica por LEDs de seguridades | Se mostraron enlaces/opciones sin exponer el hecho que justificaba cada uno. |
| Pregunta DL27 | Respuesta precisa: identificó SSH/serie de seguridad de hueco cerrada y se abstuvo de inventar cuándo se enciende. |
| Pregunta LED 12/19 | Se mostró desambiguación; al elegir NE300, respondió sobre esa placa y no llegó a MXL1. |
| Pregunta Elecmegon sin modelo | Se mostró desambiguación. Incluyó NE300 LBII, que no corresponde a Elecmegon, y dos variantes EM3000. |
| Selección EM3000 | Respondió que no había un LED dedicado en ese contexto, pero no presentó simultáneamente las alternativas documentadas EM2000/EM4000. |

## Diferencia frente a la batería canónica

El historial conservado incluye una repetición de DL27 y no permite identificar una corrida de EDEL-K3 equivalente a la pregunta canónica. La próxima medición debe ejecutar las diez preguntas exactamente como están escritas en el fixture v2.

## Diagnóstico de recuperación

| Caso | Rango de la página de respuesta en producción |
|---|---:|
| ALTIUS D8/D11 | 1 |
| TPR50 SPM | 10 |
| SR8P SPH | 1 |
| EM2000 | 3 |
| EM4000 V1 | 7 |
| EDEL-K3 | 1 |
| TOKIBAT DL27 | 1 |
| MXL1 LED 12/19 | >20; divisoria MXL1 en 3 |
| Thyssen Serie E | 6 |

Resumen:

- Contenido objetivo presente: 9/9 casos directos.
- `recall@3`: 5/9.
- `recall@10`: 8/9; `recall@20`: 8/9 (top 20 no mejora: MXL1 sigue >20).
- Precisión de opciones para SPM: 0/3.
- La falla de MXL1 demuestra pérdida de continuidad divisoria → página de contenido.
- La falla de EM4000 demuestra una normalización insuficiente de variantes con/sin espacio.

## Hallazgo de metadata

Se descargaron y auditaron 97 chunks de texto y sus sidecars. Los sidecars objetivo usan el contrato `field_records_v5` y repiten un `canonical_name` global de ALJO/ALTIUS en páginas de otros fabricantes/modelos. No aportan de forma consistente `section_identity`, `manufacturer`, `controller_model` ni `board_model`.

Los chunks contienen encabezados y alias más específicos que sus sidecars, por lo que el dato no está perdido; la recuperación no dispone de filtros estructurales confiables.

## Artefactos locales de auditoría

- PDF fuente: `/Users/lahirisan/Documents/Danebo/Danebo Elevator Rag Julio 2026/entrevosdtas /SEGURIDADES 1.1-1.pdf` (el nombre de la carpeta termina en espacio; sin él la ruta no resuelve).
- Texto extraído: `tmp/pdfs/seguridades_audit/source_layout.txt`
- Render de páginas verificadas: `tmp/pdfs/seguridades_audit/verified-pages-contact-sheet.png`
- Copia lectora de chunks/sidecars: `tmp/pdfs/seguridades_audit/production_chunks`

Estos artefactos están bajo `tmp/` y no forman parte del producto ni autorizan su publicación.
