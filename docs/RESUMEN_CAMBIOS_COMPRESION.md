# Resumen de Cambios - Compresión de Imágenes y Configuración de Modelos

> **Historical implementation summary.** Current setup and IAM guidance live in
> [BEDROCK_SETUP.md](../BEDROCK_SETUP.md), [IMAGE_COMPRESSION.md](IMAGE_COMPRESSION.md),
> and `docs/bedrock-iam-policy.json`.

> **Documento histórico.** Las comparaciones de costo aquí registran el
> experimento original y no son pricing vigente. Fuente financiera actual:
> [SAAS_COST_MODEL_2026-06-12.md](SAAS_COST_MODEL_2026-06-12.md).

## Cambios Implementados

### 1. ✅ Service Object: `ImageCompressionService`
**Ubicación**: `app/services/image_compression_service.rb`

Servicio que comprime imágenes automáticamente antes de enviarlas a Bedrock:
- Redimensiona a máximo 1024x1024 pixels
- Convierte a JPEG con 80% de calidad
- Omite compresión para imágenes < 500KB
- Valida que no exceda el límite de 10MB
- Logs detallados de compresión
- **Tests**: ✅ Todos pasando

### 2. ✅ RagController Actualizado
**Ubicación**: `app/controllers/rag_controller.rb`

Métodos modificados:
- `extract_images_from_params`: Ahora llama a `compress_images`
- `compress_images`: Nuevo método que aplica compresión automática

### 3. ✅ BedrockClient - Modelo Deprecado Removido
**Ubicación**: `app/services/bedrock_client.rb`

- ❌ Removido: `anthropic.claude-3-5-sonnet-20240620-v1:0` (deprecado)
- ✅ Mantenidos: Solo modelos actuales en `MODELS_MAP`

### 4. ✅ Documentación Completa

#### `README.md` - Sección Nueva: "Model Configuration"
- Lista completa de modelos disponibles
- Tabla comparativa (costo, velocidad, precisión)
- Instrucciones para cambiar modelos
- Guía de permisos IAM
- Información sobre compresión de imágenes
- Referencia a arquitectura multi-tenant

#### Referencia IAM actual
- Configuración y errores: `BEDROCK_SETUP.md`
- Política del repositorio: `docs/bedrock-iam-policy.json`

#### `docs/bedrock-iam-policy.json` - Nuevo
- Política IAM lista para copiar/pegar en AWS Console
- Solo modelos usados en la aplicación
- Siguiendo principle of least privilege

#### `docs/IMAGE_COMPRESSION.md` - Nuevo
- Descripción del problema y solución
- Límites de Bedrock
- Guía de uso y performance

#### `docs/MULTI_TENANT_ARCHITECTURE.md` - Nuevo
- Diseño completo para multi-tenant
- Database schema propuesto
- Service layer updates
- Tenant identification strategies
- Security y performance considerations
- Migration path

#### `docs/RESUMEN_CAMBIOS_COMPRESION.md` - Este archivo actualizado

### 5. ✅ `.env.sample` Actualizado
- Comentarios explicativos para cada modelo
- Lista de modelos alternativos para testing
- Recomendaciones de uso (haiku/sonnet/opus)
- Variables de entorno documentadas

### 6. ✅ `.gitignore` Actualizado
- Agregado: `meeting*.txt` para ignorar notas personales

## Requisitos del Sistema

### ✅ libvips instalado
```bash
brew install vips
vips --version  # 8.18.0
```

## Configuración de Modelos (100% Configurable)

### Variables de Entorno
```bash
# Modelo principal para generación
BEDROCK_MODEL_ID=us.anthropic.claude-3-5-haiku-20241022-v1:0

# Modelo para imágenes (multimodal)
BEDROCK_VISION_MODEL_ID=us.anthropic.claude-3-5-sonnet-20241022-v2:0
```

### Modelos Disponibles

| Modelo | Costo (1K tokens) | Velocidad | Precisión | Uso |
|--------|-------------------|-----------|-----------|-----|
| Haiku 4.5 | $0.0008/$0.004 | ⚡⚡⚡ | ⭐⭐⭐ | Alto volumen |
| Sonnet 4.5 | $0.003/$0.015 | ⚡⚡ | ⭐⭐⭐⭐⭐ | Recomendado |
| Opus 4.5 | $0.015/$0.075 | ⚡ | ⭐⭐⭐⭐⭐⭐ | Máxima calidad |

### Profiles: Global vs US Regional
- **Global**: Mejor throughput, misma precio (recomendado para producción)
- **US Regional**: Data residency en US (compliance)

## Permisos IAM - Acción Requerida ⚠️

El rol `BedrockKnowledgeBaseRole-chat-bot` necesita permisos para 10 modelos.

### Pasos Rápidos:

1. **AWS Console** → IAM → Roles → `BedrockKnowledgeBaseRole-chat-bot`
2. **Add permissions** → Create inline policy → JSON tab
3. **Copiar** el contenido de `docs/bedrock-iam-policy.json`
4. **Nombre**: `BedrockModelInvokePermissions`
5. **Crear policy**

Ver guía actual: `BEDROCK_SETUP.md`.

## Logs Esperados

### Imagen Pequeña (<500KB)
```
ImageCompressionService: Skipping compression (size: 340316 bytes)
```

### Imagen Grande (>500KB)
```
ImageCompressionService: Compressed 5242880 -> 524288 bytes (90.0% reduction)
```

### Modelo Usado
```
BedrockRagService initialized - Model ID: us.anthropic.claude-3-5-haiku-20241022-v1:0
```

## Pruebas para Hacer

### 1. Probar Compresión de Imágenes
- Subir imagen pequeña (<500KB) → debe omitir compresión
- Subir imagen grande (>500KB) → debe comprimir y mostrar % reducción

### 2. Probar Diferentes Modelos
```bash
# Editar .env
BEDROCK_MODEL_ID=us.anthropic.claude-sonnet-4-5-20250929-v1:0

# Reiniciar
bin/dev

# Hacer query y ver logs
```

### 3. Probar Selector de UI
- Seleccionar modelo diferente en dropdown
- Hacer query
- Verificar en logs qué modelo se usó

## Arquitectura Multi-Tenant (Futuro)

Documento completo en `docs/MULTI_TENANT_ARCHITECTURE.md` incluye:
- Topología SaaS compartida
- Aislamiento lógico obligatorio mediante `account_id`
- Prefijos S3 por cuenta y un único Data Source compartido
- Filtros Bedrock por cuenta
- Aislamiento de jobs, cachés, streams y métricas
- Opción comercial de aislamiento físico

### Key Features Propuestos:
- ✅ Infraestructura estándar compartida para mantener costos comerciales viables
- ✅ Un Knowledge Base, Data Source y Aurora/pgvector compartidos
- ✅ Metadata y filtros `account_id` obligatorios
- ✅ Amazon S3 Vectors dedicado solo para clientes que contraten aislamiento
- ✅ Quotas y límites configurables
- ✅ Cost tracking per tenant
- ✅ Feature flags por tenant
- ✅ Diferentes service tiers (Basic, Pro, Enterprise)

## Archivos Nuevos

```
app/services/image_compression_service.rb
test/services/image_compression_service_test.rb
BEDROCK_SETUP.md
docs/IMAGE_COMPRESSION.md
docs/MULTI_TENANT_ARCHITECTURE.md
docs/RESUMEN_CAMBIOS_COMPRESION.md (este archivo)
docs/bedrock-iam-policy.json
```

## Archivos Modificados

```
.env.sample (modelos documentados)
.gitignore (meeting notes)
README.md (sección "Model Configuration")
app/controllers/rag_controller.rb (compresión)
app/services/bedrock_client.rb (modelo deprecado removido)
```

## Estado: ✅ Implementación Completa

### Completado
- ✅ Compresión de imágenes funcionando
- ✅ Tests pasando
- ✅ Modelo deprecado removido
- ✅ Documentación completa
- ✅ README actualizado
- ✅ Arquitectura multi-tenant diseñada

### Pendiente (Manual)
- ⚠️ Actualizar permisos IAM en AWS Console
- ⚠️ Probar con imágenes grandes por UI
- ⚠️ Probar diferentes modelos
- ⚠️ Verificar modelo del Knowledge Base en AWS (no debe ser el deprecado)

## Próximos Pasos Recomendados

1. **Actualizar IAM** (crítico)
2. **Probar compresión** con imagen >500KB
3. **Experimentar con modelos**:
   - Semana 1: Baseline con Haiku (costo)
   - Semana 2: Evaluar Sonnet (precisión vs costo)
   - Decisión: ¿Vale la pena 3-4x más caro?
4. **Considerar Global profiles** para producción
5. **Planificar multi-tenancy** si es necesario

## Referencias

- AWS Bedrock Pricing: https://aws.amazon.com/bedrock/pricing/
- Claude Models Comparison: https://docs.anthropic.com/claude/docs/models-overview
- Image Processing Gem: https://github.com/janko/image_processing
