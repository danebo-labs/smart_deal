# Configuración de AWS Bedrock

## Requisitos

1. **Credenciales AWS**: Necesitas `access_key_id` y `secret_access_key` de AWS **o** un API Key (Bearer Token) generado en la consola de Bedrock
2. **Región**: `us-east-1` (configurada por defecto)
3. **Inference Profile**: `us.anthropic.claude-3-5-haiku-20241022-v1:0` (perfil administrado por Bedrock para Claude 3.5 Haiku)

## Configuración de Credenciales

### Opción 1: Rails Credentials (Recomendado)

1. Ejecuta:
   ```bash
   bin/rails credentials:edit
   ```

2. Agrega la siguiente configuración:
   ```yaml
   aws:
     access_key_id: YOUR_AWS_ACCESS_KEY_ID
     secret_access_key: YOUR_AWS_SECRET_ACCESS_KEY
     region: us-east-1
     bedrock_bearer_token: YOUR_AWS_BEDROCK_BEARER_TOKEN (opcional)
     bedrock_model_id: us.anthropic.claude-3-5-haiku-20241022-v1:0

   bedrock:
     knowledge_base_id: YOUR_KNOWLEDGE_BASE_ID
     data_source_id: YOUR_DATA_SOURCE_ID (opcional)
   ```

3. Guarda el archivo (en vim/nano: `:wq` o `Ctrl+X` luego `Y`)

### Opción 2: Variables de Entorno

```bash
export AWS_ACCESS_KEY_ID=your_access_key
export AWS_SECRET_ACCESS_KEY=your_secret_key
export AWS_REGION=us-east-1
export BEDROCK_KNOWLEDGE_BASE_ID=your_kb_id
export BEDROCK_DATA_SOURCE_ID=your_data_source_id  # Opcional, usa el preferido si está disponible
```

### Opción 3: API Key (Bearer Token de Bedrock)

Si generaste una API key en la consola de Bedrock:

```bash
export AWS_BEARER_TOKEN_BEDROCK=tu_api_key_generada
export AWS_REGION=us-east-1
```

> **Importante:** Las llaves de Bedrock pueden expirar (por ejemplo, en 24 horas). Cuando caduquen, genera una nueva y actualiza la variable de entorno.

## Configuración del Knowledge Base

El sistema usa AWS Bedrock Knowledge Base para RAG (Retrieval-Augmented Generation).

### Variables Requeridas

```bash
BEDROCK_KNOWLEDGE_BASE_ID=your_kb_id          # Requerido (ej: AMFSKKPEZN)
BEDROCK_DATA_SOURCE_ID=your_data_source_id    # Opcional, recomendado si hay varios
KNOWLEDGE_BASE_S3_BUCKET=your-bucket-name     # Bucket del data source del KB
```

### RAG retrieve_and_generate (opcional)

Parámetros de retrieval y generación. Valores por defecto optimizados para dominios safety-critical (ej. ascensores). En multi-tenant, cada tenant puede sobreescribir vía `bedrock_config.rag_config`.

| Variable | Default | Descripción |
|----------|---------|-------------|
| `BEDROCK_RAG_NUMBER_OF_RESULTS` | 15 | Chunks recuperados antes del reranking |
| `BEDROCK_RAG_SEARCH_TYPE` | HYBRID | HYBRID (semántico + keyword) o SEMANTIC |
| `BEDROCK_RAG_GENERATION_TEMPERATURE` | 0.0 | Determinismo en la respuesta (0 = máximo) |
| `BEDROCK_RAG_GENERATION_MAX_TOKENS` | 3000 | Máximo tokens de salida |
| `BEDROCK_RAG_ORCHESTRATION_TEMPERATURE` | 0.0 | Determinismo en query decomposition |
| `BEDROCK_RAG_ORCHESTRATION_MAX_TOKENS` | 2048 | Máximo tokens para orquestación |

```bash
# Ejemplo (opcional; los defaults ya son seguros)
BEDROCK_RAG_NUMBER_OF_RESULTS=15
BEDROCK_RAG_SEARCH_TYPE=HYBRID
BEDROCK_RAG_GENERATION_TEMPERATURE=0.0
BEDROCK_RAG_ORCHESTRATION_TEMPERATURE=0.0
```

**Nota sobre el data source actual**: No tiene inclusion prefix configurado; Bedrock indexa todo el bucket. Los documentos se suben en `uploads/{fecha}/{archivo}`.

### Selección de Data Source

- Si configuras `BEDROCK_DATA_SOURCE_ID`, el sistema verificará que existe en la lista de data sources disponibles y lo usará.
- Si no existe o no está configurado, usará el primer data source disponible.
- **Para subir imágenes (JPEG/PNG)**: usa un data source con parser multimodal (Bedrock Data Automation o Foundation Model). Lista los data sources con `bin/rails kb:status` y configura el ID del que soporte multimodal.
- **Sin inclusion prefix**: El data source actual no tiene inclusion prefix configurado; Bedrock indexa todo el bucket. Los documentos se suben bajo `uploads/{fecha}/{archivo}`.
- Para ver los data sources disponibles, ejecuta:

```bash
bin/rails kb:status
```

Este comando mostrará:
- El Knowledge Base ID actual
- El Data Source ID preferido (si está configurado)
- Todos los data sources disponibles con sus detalles

### Modelo de Embeddings (Embedding Model)

El modelo de embeddings se configura **en AWS al crear el Knowledge Base**, no en la app. La variable `BEDROCK_EMBEDDING_MODEL_ID` en `.env` es solo **para mostrar en la UI**; no afecta al funcionamiento del KB.

Para ver qué embedding model usa tu Knowledge Base (desde AWS):

```bash
bin/rails kb:embedding_model
```

Requiere permiso IAM `bedrock:GetKnowledgeBase` en el ARN del Knowledge Base.

**Nota importante**: No se puede cambiar el embedding model de un KB ya creado. `embeddingModelArn` es inmutable. Para usar otro modelo (ej. Cohere en lugar de Titan), hay que crear un nuevo Knowledge Base con ese modelo y re-indexar los documentos. Los embeddings existentes no se sobrescriben porque cada modelo genera vectores con dimensiones distintas.

### Modelo Vision (para imágenes en el chat)

El **vision model** es el LLM que analiza **imágenes que el usuario adjunta** en el chat (ej. "¿qué hay en esta foto?"). Es distinto del embedding model:

| Concepto        | Uso                                                      | Configuración                          |
|-----------------|----------------------------------------------------------|----------------------------------------|
| **Embedding**   | Convierte texto a vectores para búsqueda semántica en KB | AWS al crear el KB (Titan, Cohere…)    |
| **Vision**      | Procesa imágenes adjuntas en el chat (multimodal)       | `BEDROCK_VISION_MODEL_ID` en `.env`    |

Haiku no soporta imágenes; cuando el usuario adjunta una foto y el modelo por defecto es Haiku, la app usa automáticamente el vision model. Configuración opcional:

```bash
BEDROCK_VISION_MODEL_ID=global.anthropic.claude-sonnet-4-6
```

## Configuración del Proveedor de IA

**Nota:** Actualmente solo AWS Bedrock está soportado. Los otros proveedores (OpenAI, Anthropic, GEIA) fueron removidos por falta de uso.

### Variable de Entorno AI_PROVIDER

Por defecto se usa Bedrock:

```bash
# AWS Bedrock (único proveedor disponible)
export AI_PROVIDER=bedrock
```

### En Rails Credentials

También puedes configurarlo en `bin/rails credentials:edit`:

```yaml
aws:
  access_key_id: YOUR_ACCESS_KEY
  secret_access_key: YOUR_SECRET_KEY
  region: us-east-1
  bedrock_bearer_token: YOUR_BEDROCK_BEARER_TOKEN (si aplicable)
  bedrock_model_id: us.anthropic.claude-3-5-haiku-20241022-v1:0

bedrock:
  knowledge_base_id: YOUR_KNOWLEDGE_BASE_ID
  data_source_id: YOUR_DATA_SOURCE_ID (opcional)

# Configuración del proveedor de IA (solo bedrock disponible)
ai_provider: bedrock
```

## Probar la Integración

### 1. Subir un Documento PDF

Ve a `http://localhost:3000` y sube un PDF. El sistema procesará el documento con Bedrock automáticamente.

### 2. Endpoint REST API para RAG (Knowledge Base)

Puedes consultar la Knowledge Base directamente:

```bash
curl -X POST http://localhost:3000/rag/ask \
  -H "Content-Type: application/json" \
  -H "Cookie: [tu_cookie_de_sesion]" \
  -d '{
    "question": "¿Qué es S3?"
  }'
```

**Nota:** El endpoint `/ai/ask` fue removido. Para procesar documentos, usa la interfaz web o el endpoint `/documents/process`.

## Estructura de Servicios

La aplicación usa los siguientes servicios:

- `app/services/bedrock_client.rb` - Cliente de AWS Bedrock
- `app/services/bedrock_rag_service.rb` - Servicio RAG para consultas a Knowledge Base
- `app/services/ai_provider.rb` - Facade que usa BedrockClient (solo Bedrock disponible)

## Verificación

1. Verifica que las credenciales estén configuradas:
   ```bash
   bin/rails runner "puts Rails.application.credentials.dig(:aws, :access_key_id) ? 'OK' : 'NOT CONFIGURED'"
   ```

2. Verifica el proveedor activo:
   ```bash
   bin/rails runner "puts ENV.fetch('AI_PROVIDER', 'bedrock')"
   ```

3. Reinicia el servidor Rails después de cambiar las credenciales:
   ```bash
   bin/dev
   ```

## Permisos IAM para el Usuario de la Aplicación

Las credenciales AWS que usa la app (ej: `bedrock-integration-user`) necesitan estos permisos para RAG:

| Acción | Recurso | Motivo |
|--------|---------|--------|
| `bedrock:RetrieveAndGenerate` | Knowledge Base | Consultar el Knowledge Base vía API |
| `bedrock:Retrieve` | Knowledge Base | Búsqueda vectorial (usado internamente por RetrieveAndGenerate) |
| `bedrock:Rerank` | Modelo Cohere | Reranking de resultados (configurado en el servicio) |
| `bedrock:InvokeModel` | Foundation models | Generar respuestas con Claude |
| `bedrock:GetKnowledgeBase` | Knowledge Base | Opcional: para `bin/rails kb:embedding_model` |

**Política mínima para el usuario IAM** (reemplaza `YOUR_ACCOUNT_ID` y `YOUR_KB_ID`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "RetrieveAndRetrieveAndGenerate",
      "Effect": "Allow",
      "Action": [
        "bedrock:Retrieve",
        "bedrock:RetrieveAndGenerate",
        "bedrock:GetKnowledgeBase"
      ],
      "Resource": "arn:aws:bedrock:us-east-1:YOUR_ACCOUNT_ID:knowledge-base/YOUR_KB_ID"
    },
    {
      "Sid": "Rerank",
      "Effect": "Allow",
      "Action": "bedrock:Rerank",
      "Resource": "arn:aws:bedrock:us-east-1::foundation-model/cohere.rerank-v3-5:0"
    },
    {
      "Sid": "InvokeModel",
      "Effect": "Allow",
      "Action": "bedrock:InvokeModel",
      "Resource": [
        "arn:aws:bedrock:us-east-1::foundation-model/us.anthropic.claude-3-5-haiku-20241022-v1:0",
        "arn:aws:bedrock:us-east-1::foundation-model/us.anthropic.claude-haiku-4-5-20251001-v1:0",
        "arn:aws:bedrock:us-east-1::foundation-model/*"
      ]
    }
  ]
}
```

Para varios Knowledge Bases: `arn:aws:bedrock:us-east-1:YOUR_ACCOUNT_ID:knowledge-base/*`

Ver `docs/bedrock-app-user-iam-policy.json` para una política completa lista para adjuntar.

## Troubleshooting

### Error: "is not authorized to perform: bedrock:RetrieveAndGenerate" o "bedrock:Retrieve"
- El usuario IAM (ej: `bedrock-integration-user`) no tiene `bedrock:RetrieveAndGenerate` ni `bedrock:Retrieve`.
- **Solución**: Añade la política de la sección "Permisos IAM para el Usuario de la Aplicación" al usuario en IAM → Users → [tu usuario] → Add permissions → Create inline policy.

### Error: "is not authorized to perform: bedrock:GetKnowledgeBase"
- Aparece al ejecutar `bin/rails kb:embedding_model`.
- **Solución**: Añade `bedrock:GetKnowledgeBase` al statement del Knowledge Base en la política IAM (ver tabla de permisos arriba).

### Error: "Unknown AI provider"
- Solo `bedrock` está disponible. Verifica que `AI_PROVIDER` sea `bedrock` o esté sin configurar (usa bedrock por defecto)

### Error: "Bedrock error: AccessDeniedException"
- Verifica que tus credenciales AWS tengan permisos para Bedrock
- Verifica que el modelo esté habilitado en tu región AWS

### Error: "Bedrock error: ... inference profile"
- Verifica que `BEDROCK_MODEL_ID` apunte a un inference profile válido. Por defecto usamos `us.anthropic.claude-3-5-haiku-20241022-v1:0` (Haiku en us-east-1)
- Si trabajas en otra región, consulta la consola de Bedrock en **Cross-region inference** para obtener el profile correcto.

### Error: "API key not configured"
- Verifica que las credenciales estén en Rails credentials o variables de entorno
- Reinicia el servidor después de configurar las credenciales

