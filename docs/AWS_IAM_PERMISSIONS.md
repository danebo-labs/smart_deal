# AWS IAM Permissions for Bedrock Knowledge Base

## Overview
El rol IAM `BedrockKnowledgeBaseRole-chat-bot` necesita permisos específicos para invocar los modelos de Bedrock usados en la aplicación.

## 🚀 Quick Setup Guide

### Step 1: Access IAM Console
1. Go to AWS Console: https://console.aws.amazon.com/iam/
2. Navigate to: **IAM → Roles**
3. Search for: `BedrockKnowledgeBaseRole-chat-bot`
4. Click on the role name

### Step 2: Add Permissions
1. Click the **Permissions** tab
2. Click **Add permissions** → **Create inline policy**
3. Click the **JSON** tab
4. Copy the policy from `docs/bedrock-iam-policy.json` (see below)
5. Paste into the JSON editor
6. Click **Review policy**
7. Name: `BedrockModelInvokePermissions`
8. Click **Create policy**

### Step 3: Verify
- The role should now show the new inline policy
- All models listed in `MODELS_MAP` will have invoke permissions

## Modelos Permitidos

La aplicación usa los siguientes modelos que deben tener permisos `bedrock:InvokeModel`:

### Modelos Principales
- **Default Model (Haiku)**: `us.anthropic.claude-3-5-haiku-20241022-v1:0`
- **Vision Model (Sonnet v2)**: `us.anthropic.claude-3-5-sonnet-20241022-v2:0`

### Modelos Seleccionables en UI
- `global.anthropic.claude-sonnet-4-5-20250929-v1:0` - Claude Sonnet 4.5 (Global)
- `global.anthropic.claude-haiku-4-5-20251001-v1:0` - Claude Haiku 4.5 (Global)
- `global.anthropic.claude-opus-4-5-20251101-v1:0` - Claude Opus 4.5 (Global)
- `us.anthropic.claude-sonnet-4-5-20250929-v1:0` - Claude Sonnet 4.5 (US)
- `us.anthropic.claude-haiku-4-5-20251001-v1:0` - Claude Haiku 4.5 (US)
- `us.anthropic.claude-opus-4-5-20251101-v1:0` - Claude Opus 4.5 (US)
- `anthropic.claude-3-7-sonnet-20250219-v1:0` - Claude 3.7 Sonnet
- `anthropic.claude-3-5-sonnet-20241022-v2:0` - Claude 3.5 Sonnet v2

## Política IAM Recomendada

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BedrockInvokeModelPermissions",
      "Effect": "Allow",
      "Action": "bedrock:InvokeModel",
      "Resource": [
        "arn:aws:bedrock:us-east-1::foundation-model/us.anthropic.claude-3-5-haiku-20241022-v1:0",
        "arn:aws:bedrock:us-east-1::foundation-model/us.anthropic.claude-3-5-sonnet-20241022-v2:0",
        "arn:aws:bedrock:us-east-1::foundation-model/global.anthropic.claude-sonnet-4-5-20250929-v1:0",
        "arn:aws:bedrock:us-east-1::foundation-model/global.anthropic.claude-haiku-4-5-20251001-v1:0",
        "arn:aws:bedrock:us-east-1::foundation-model/global.anthropic.claude-opus-4-5-20251101-v1:0",
        "arn:aws:bedrock:us-east-1::foundation-model/us.anthropic.claude-sonnet-4-5-20250929-v1:0",
        "arn:aws:bedrock:us-east-1::foundation-model/us.anthropic.claude-haiku-4-5-20251001-v1:0",
        "arn:aws:bedrock:us-east-1::foundation-model/us.anthropic.claude-opus-4-5-20251101-v1:0",
        "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-7-sonnet-20250219-v1:0",
        "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0"
      ]
    }
  ]
}
```

## Pasos para Actualizar Permisos

1. **Ir a IAM Console en AWS**
   - Navigate to: IAM → Roles → `BedrockKnowledgeBaseRole-chat-bot`

2. **Agregar/Actualizar la Política**
   - Click en "Add permissions" → "Attach policies" o editar la política existente
   - Si la política es inline, click "Edit policy" y pega el JSON de arriba

3. **Verificar Permisos**
   - Asegúrate de que la política incluya `bedrock:InvokeModel` para todos los modelos listados
   - También verifica que tenga permisos para S3, CloudWatch, etc. según sea necesario

## Errores Comunes

### Error: "User is not authorized to perform: bedrock:InvokeModel"
```
Knowledge base role arn:aws:iam::935142957735:role/BedrockKnowledgeBaseRole-chat-bot 
is not able to call the specified model
```

**Solución**: Agregar el modelo específico a la política IAM usando el ARN correcto.

### Modelo Deprecado
El modelo `anthropic.claude-3-5-sonnet-20240620-v1:0` está deprecado y **NO debe usarse**. 
Ha sido removido de la lista de modelos seleccionables en la UI.

## Configuración del Knowledge Base

El modelo usado por el Knowledge Base para ingestion se configura en AWS Console:
- Bedrock → Knowledge bases → [Tu KB] → Data sources → Model settings

Asegúrate de que el modelo configurado allí esté incluido en la política IAM.

## Security Best Practices

✅ **Recomendado**: Especificar cada modelo individualmente (como en el JSON de arriba)
❌ **No recomendado**: Usar wildcard `arn:aws:bedrock:*:*:foundation-model/*` (demasiado permisivo)

Limitar permisos solo a los modelos necesarios reduce el riesgo de seguridad.
