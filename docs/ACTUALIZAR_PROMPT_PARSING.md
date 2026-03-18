# Actualizar el Prompt de Parsing del Data Source (Bedrock Knowledge Base)

Este documento describe cómo actualizar el prompt utilizado en la estrategia de parsing (`BEDROCK_FOUNDATION_MODEL`) del data source de un Knowledge Base de AWS Bedrock.

## Requisitos previos

- AWS CLI configurado con credenciales válidas
- `jq` instalado (`brew install jq`)
- Knowledge Base ID y Data Source ID (ver `bin/rails kb:status`)

## IDs de referencia (actuales)

| Recurso      | ID           |
|-------------|--------------|
| Knowledge Base | `VBB72VKABV` |
| Data Source    | `OWRPGSX6XK` |

## Límite crítico: 10,000 caracteres

El campo `parsingPromptText` tiene un **máximo de 10,000 caracteres**. Si el archivo excede ese límite, la API devolverá error.

Verificar el conteo:

```bash
wc -m master_prompt.txt
```

Debe ser ≤ 10,000. Si excede, reducir el contenido del prompt antes de continuar.

---

## Paso 1: Crear el archivo template JSON

Crea `update-datasource.json` en la raíz del proyecto con la configuración completa del data source. **Importante:** el `chunkingConfiguration` es inmutable; debe coincidir exactamente con el actual.

```json
{
  "name": "knowledge-base-quick-start-hi85x-data-source",
  "dataSourceConfiguration": {
    "type": "S3",
    "s3Configuration": {
      "bucketArn": "arn:aws:s3:::multimodal-source-destination"
    }
  },
  "vectorIngestionConfiguration": {
    "chunkingConfiguration": {
      "chunkingStrategy": "HIERARCHICAL",
      "hierarchicalChunkingConfiguration": {
        "levelConfigurations": [
          { "maxTokens": 1200 },
          { "maxTokens": 256 }
        ],
        "overlapTokens": 40
      }
    },
    "parsingConfiguration": {
      "parsingStrategy": "BEDROCK_FOUNDATION_MODEL",
      "bedrockFoundationModelConfiguration": {
        "modelArn": "arn:aws:bedrock:us-east-1:935142957735:inference-profile/global.anthropic.claude-opus-4-6-v1",
        "parsingPrompt": {
          "parsingPromptText": "__PROMPT_CONTENT__"
        }
      }
    }
  }
}
```

> **Nota:** Si el nombre del data source, bucket o chunking cambió, obtén la configuración actual con:
> ```bash
> aws bedrock-agent get-data-source \
>   --knowledge-base-id VBB72VKABV \
>   --data-source-id OWRPGSX6XK \
>   --region us-east-1
> ```

---

## Paso 2: Ejecutar el script para generar el payload e invocar la API

Guarda este script como `bin/update-parsing-prompt.sh` (o ejecútalo inline):

```bash
#!/usr/bin/env bash
set -euo pipefail

KB_ID="VBB72VKABV"
DS_ID="OWRPGSX6XK"
PROMPT_FILE="master_prompt.txt"
TEMPLATE_FILE="update-datasource.json"
OUTPUT_FILE="/tmp/update-datasource-filled.json"

# Verificar longitud (límite: 10000 caracteres)
CHAR_COUNT=$(wc -m < "$PROMPT_FILE")
if [ "$CHAR_COUNT" -gt 10000 ]; then
  echo "ERROR: El prompt tiene $CHAR_COUNT caracteres. Límite es 10,000."
  exit 1
fi

PROMPT_CONTENT=$(cat "$PROMPT_FILE")
ESCAPED_PROMPT=$(echo "$PROMPT_CONTENT" | jq -Rs .)

jq --argjson prompt "$ESCAPED_PROMPT" \
  '.vectorIngestionConfiguration.parsingConfiguration.bedrockFoundationModelConfiguration.parsingPrompt.parsingPromptText = $prompt' \
  "$TEMPLATE_FILE" > "$OUTPUT_FILE"

echo "Payload generado en $OUTPUT_FILE"

# Actualizar el data source (sin pager para evitar tener que pulsar 'q')
AWS_PAGER="" aws bedrock-agent update-data-source \
  --knowledge-base-id "$KB_ID" \
  --data-source-id "$DS_ID" \
  --cli-input-json "file://$OUTPUT_FILE" \
  --region us-east-1
```

Ejecutar desde la raíz del proyecto:

```bash
chmod +x bin/update-parsing-prompt.sh
./bin/update-parsing-prompt.sh
```

---

## Paso 3: Iniciar el ingestion job

Tras actualizar el prompt, los documentos existentes **no** se re-parsean automáticamente. Hay que lanzar un ingestion job:

```bash
AWS_PAGER="" aws bedrock-agent start-ingestion-job \
  --knowledge-base-id VBB72VKABV \
  --data-source-id OWRPGSX6XK \
  --region us-east-1
```

Alternativa usando el rake task (si está configurado):

```bash
bin/rails kb:sync
```

---

## Paso 4: Monitorear el ingestion job

```bash
AWS_PAGER="" aws bedrock-agent list-ingestion-jobs \
  --knowledge-base-id VBB72VKABV \
  --data-source-id OWRPGSX6XK \
  --region us-east-1
```

Estados: `STARTING` → `IN_PROGRESS` → `COMPLETE`. Cuando esté `COMPLETE`, el nuevo prompt ya está aplicado a todos los documentos.

---

## Verificación opcional

Confirmar que el prompt se actualizó correctamente:

```bash
AWS_PAGER="" aws bedrock-agent get-data-source \
  --knowledge-base-id VBB72VKABV \
  --data-source-id OWRPGSX6XK \
  --region us-east-1 \
  --query 'dataSource.vectorIngestionConfiguration.parsingConfiguration.bedrockFoundationModelConfiguration.parsingPrompt.parsingPromptText' \
  --output text | head -c 500
```

---

## Troubleshooting

| Problema | Solución |
|----------|----------|
| `ValidationException` en update | Verificar que `chunkingConfiguration` coincida exactamente con el actual. No se puede modificar tras la creación. |
| Prompt excede 10,000 caracteres | Reducir el contenido de `master_prompt.txt` manteniendo las reglas de seguridad y anti-hallucination. |
| `AWS_PROFILE_REGION: parameter not set` | Aviso del plugin aws de Oh My Zsh. Añadir `export AWS_PROFILE_REGION="${AWS_REGION:-us-east-1}"` en `~/.zshrc`. |
| Salida en pager (hay que pulsar `q`) | Usar `AWS_PAGER=""` antes del comando o configurar `cli_pager =` en `~/.aws/config`. |

---

## Referencias

- [UpdateDataSource - AWS Bedrock API](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_UpdateDataSource.html)
- `BEDROCK_SETUP.md` — Configuración general de Bedrock
- `master_prompt.txt` — Archivo fuente del prompt de parsing
