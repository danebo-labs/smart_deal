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
   ```

3. Guarda el archivo (en vim/nano: `:wq` o `Ctrl+X` luego `Y`)

### Opción 2: Variables de Entorno

```bash
export AWS_ACCESS_KEY_ID=your_access_key
export AWS_SECRET_ACCESS_KEY=your_secret_key
export AWS_REGION=us-east-1
```

### Opción 3: API Key (Bearer Token de Bedrock)

Si generaste una API key en la consola de Bedrock:

```bash
export AWS_BEARER_TOKEN_BEDROCK=tu_api_key_generada
export AWS_REGION=us-east-1
```

> **Importante:** Las llaves de Bedrock pueden expirar (por ejemplo, en 24 horas). Cuando caduquen, genera una nueva y actualiza la variable de entorno.

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

## Troubleshooting

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

