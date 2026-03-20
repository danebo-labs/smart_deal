#!/usr/bin/env bash
# Actualiza el prompt de parsing del data source de Bedrock Knowledge Base.
# El promot va en el archivo docs/master_prompt.txt
# para ejecutar bin/update-parsing-prompt.sh 

set -euo pipefail

KB_ID="VBB72VKABV"
DS_ID="OWRPGSX6XK"
PROMPT_FILE="docs/master_prompt.txt"
TEMPLATE_FILE="update-datasource.json"
OUTPUT_FILE="/tmp/update-datasource-filled.json"

cd "$(dirname "$0")/.." || exit 1

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: No se encuentra $PROMPT_FILE"
  exit 1
fi

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "ERROR: No se encuentra $TEMPLATE_FILE"
  exit 1
fi

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

AWS_PAGER="" aws bedrock-agent update-data-source \
  --knowledge-base-id "$KB_ID" \
  --data-source-id "$DS_ID" \
  --cli-input-json "file://$OUTPUT_FILE" \
  --region us-east-1

echo "✓ Data source actualizado. Ejecuta: bin/rails kb:sync (o start-ingestion-job) para re-ingestar documentos."
