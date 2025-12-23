# Validación de Estrategia de Testing - Rails

**Fecha:** $(date)  
**Contexto:** Rails 7+, Ruby 3+, bajo coverage actual, dependencias AWS Bedrock  
**Objetivo:** Validar y ajustar plan de testing propuesto por Cline

---

## 1. Evaluación General del Plan de Cline

### ⚠ Ajustable

**Explicación:**

El plan de Cline identifica los componentes correctos pero tiene problemas de priorización y sobre-ingeniería:

**Fortalezas:**
- ✅ Identifica componentes críticos correctamente
- ✅ Reconoce necesidad de mocks para AWS
- ✅ Separa tests unitarios de integración

**Debilidades:**
- ❌ **Sobre-recomienda Capybara** - Tests de sistema son lentos y frágiles para endpoints API
- ❌ **Contract testing prematuro** - Complejo y bajo ROI para esta etapa
- ❌ **Falta priorización clara** - No indica qué hacer primero
- ❌ **No considera tests existentes** - Ya hay tests básicos que pueden mejorarse

---

## 2. Prioridad Real de Tipos de Tests

### Prioridad 1: Request Specs (Funcionales) 🔴 **ALTA**

**Justificación:**
- **Rápidos** - Más rápidos que Capybara (no requieren navegador)
- **Cubren flujos críticos** - Endpoints API son el corazón de la app
- **Detectan regresiones** - Cambios en controladores se detectan inmediatamente
- **Apropiados para APIs** - RagController y DocumentsController son endpoints JSON/Turbo Streams

**Cuándo usar:**
- Todos los controladores con endpoints HTTP
- Verificar autenticación, validaciones, respuestas JSON
- Manejo de errores en endpoints

**Ejemplo:**
```ruby
# test/controllers/rag_controller_test.rb
test "requires authentication" do
  post rag_ask_url, params: { question: "test" }
  assert_response :redirect # o :unauthorized según implementación
end

test "returns answer with citations" do
  sign_in users(:one)
  BedrockRagService.any_instance.stubs(:query).returns({
    answer: "Test answer",
    citations: [],
    session_id: "123"
  })
  
  post rag_ask_url, params: { question: "test" }, as: :json
  assert_response :success
  json = JSON.parse(@response.body)
  assert_equal "success", json["status"]
end
```

---

### Prioridad 2: Unit Tests con Mocks 🔵 **ALTA**

**Justificación:**
- **Aislados** - No dependen de servicios externos (AWS)
- **Rápidos** - Ejecutan en milisegundos
- **Permiten refactor seguro** - Cambios internos no rompen tests
- **Críticos para servicios** - BedrockRagService, BedrockClient tienen lógica compleja

**Cuándo usar:**
- Servicios con lógica de negocio
- Parsing de respuestas AWS
- Formateo de datos
- Validaciones internas

**Ejemplo:**
```ruby
# test/services/bedrock_rag_service_test.rb
test "formats citations correctly" do
  service = BedrockRagService.new
  # Mock AWS response
  # Test parsing logic
end
```

---

### Prioridad 3: Integration Tests (Capybara) 🟡 **MEDIA/BAJA**

**Justificación:**
- **Lentos** - Requieren navegador, más frágiles
- **Útiles para flujos completos** - Solo cuando request specs no son suficientes
- **Para este proyecto:** Solo si hay interacciones complejas frontend que no se pueden testear con request specs

**Cuándo usar:**
- Flujos completos usuario (subir PDF → ver resumen)
- Interacciones JavaScript complejas
- **NO usar para:** Endpoints API simples, validaciones básicas

**Recomendación:** Postergar hasta tener request specs y unit tests básicos

---

### Prioridad 4: Contract Testing 🟢 **BAJA (Postergar)**

**Justificación:**
- **Complejo** - Requiere setup de VCR, WebMock, o similar
- **Bajo ROI inicial** - AWS SDK ya valida contratos
- **Mejor después** - Cuando se tenga coverage básico

**Recomendación:** NO implementar ahora. AWS SDK ya maneja validación de contratos.

---

## 3. Validación por Componente

### 3.1. RagController

**Plan de Cline:** Tests de integración con Capybara + Request specs

**Evaluación:** ⚠️ **Ajustable**

**Tipo de test recomendado:** **Request specs (funcionales)**

**Motivo:**
- Es un endpoint API JSON simple
- No requiere interacciones complejas de navegador
- Capybara sería sobre-ingeniería

**Riesgo que cubre:**
- 🔴 **Alto:** Autenticación requerida
- 🔴 **Alto:** Validación de parámetros (question vacío)
- 🔴 **Alto:** Manejo de errores de BedrockRagService
- 🟡 **Medio:** Formato de respuesta JSON

**Nivel de prioridad:** 🔴 **ALTA**

**Tests mínimos necesarios:**
1. Requiere autenticación
2. Rechaza question vacío
3. Retorna respuesta exitosa con answer y citations
4. Maneja errores de BedrockRagService correctamente

**Cambios sugeridos:**
- ❌ Eliminar: Tests con Capybara
- ✅ Agregar: Request specs con mocks de BedrockRagService

---

### 3.2. DocumentsController

**Plan de Cline:** Tests de integración con Capybara

**Evaluación:** ⚠️ **Ajustable**

**Tipo de test recomendado:** **Request specs + Unit tests para lógica de PDF**

**Motivo:**
- Endpoint Turbo Stream (no JSON puro, pero testeable con request specs)
- Lógica de extracción de PDF puede testearse unitariamente
- Capybara solo si hay interacciones JS complejas (no parece ser el caso)

**Riesgo que cubre:**
- 🔴 **Alto:** Validación de tipo de archivo (solo PDF)
- 🔴 **Alto:** Manejo de PDFs corruptos/vacíos
- 🟡 **Medio:** Extracción de texto de PDF
- 🟡 **Medio:** Formato de Turbo Stream response
- 🟢 **Bajo:** Interacciones JavaScript (postergar)

**Nivel de prioridad:** 🔴 **ALTA**

**Tests mínimos necesarios:**
1. Requiere autenticación
2. Rechaza archivos no-PDF
3. Rechaza archivos vacíos
4. Procesa PDF válido y retorna Turbo Stream
5. Maneja errores de extracción de PDF

**Cambios sugeridos:**
- ❌ Eliminar: Capybara (por ahora)
- ✅ Agregar: Request specs para endpoint
- ✅ Agregar: Unit tests para `extract_text_from_pdf` (método privado, testear indirectamente)

---

### 3.3. BedrockRagService

**Plan de Cline:** Unit tests con mocks HTTParty + Contract testing

**Evaluación:** ⚠️ **Ajustable**

**Tipo de test recomendado:** **Unit tests con mocks de AWS SDK**

**Motivo:**
- No usa HTTParty, usa AWS SDK directamente
- Contract testing es prematuro
- Unit tests con mocks son suficientes

**Riesgo que cubre:**
- 🔴 **Alto:** Parsing de respuestas AWS (citations, answer)
- 🔴 **Alto:** Manejo de errores de AWS
- 🟡 **Medio:** Formateo de citations
- 🟡 **Medio:** Estimación de tokens
- 🟢 **Bajo:** Validación de configuración (puede postergarse)

**Nivel de prioridad:** 🔴 **ALTA**

**Tests mínimos necesarios:**
1. Query exitoso retorna answer y citations formateados
2. Maneja errores de AWS correctamente
3. Formatea citations con estructura correcta
4. Guarda BedrockQuery en BD correctamente

**Cambios sugeridos:**
- ❌ Eliminar: Contract testing (postergar)
- ❌ Eliminar: Mocks de HTTParty (no se usa)
- ✅ Agregar: Mocks de `Aws::BedrockAgentRuntime::Client`
- ✅ Agregar: Tests de parsing de respuestas complejas

---

### 3.4. BedrockClient

**Plan de Cline:** Unit tests con mocks HTTParty + Contract testing

**Evaluación:** ⚠️ **Ajustable**

**Tipo de test recomendado:** **Unit tests con mocks de AWS SDK**

**Motivo:**
- Similar a BedrockRagService
- No usa HTTParty
- Contract testing prematuro

**Riesgo que cubre:**
- 🟡 **Medio:** Formato de request a AWS
- 🟡 **Medio:** Parsing de respuesta
- 🟡 **Medio:** Manejo de errores
- 🟢 **Bajo:** Configuración de credenciales (puede postergarse)

**Nivel de prioridad:** 🟡 **MEDIA**

**Razón de prioridad media:**
- Ya se testea indirectamente a través de AiProvider y DocumentsController
- Lógica relativamente simple (wrapper de AWS SDK)
- Puede testearse después de componentes más críticos

**Tests mínimos necesarios:**
1. Genera request con formato correcto
2. Parsea respuesta correctamente
3. Maneja errores de AWS

**Cambios sugeridos:**
- ❌ Eliminar: Contract testing
- ❌ Eliminar: Mocks de HTTParty
- ✅ Agregar: Mocks de `Aws::BedrockRuntime::Client`
- ⏳ Postergar: Si otros tests cubren el comportamiento

---

### 3.5. AiProvider

**Plan de Cline:** No mencionado explícitamente

**Evaluación:** ⚠️ **Falta en plan**

**Tipo de test recomendado:** **Unit tests simples**

**Motivo:**
- Lógica muy simple (wrapper de BedrockClient)
- Pero es punto de integración importante

**Riesgo que cubre:**
- 🟡 **Medio:** Validación de provider (solo bedrock ahora)
- 🟡 **Medio:** Delegación correcta a BedrockClient
- 🟢 **Bajo:** Manejo de errores (delega a BedrockClient)

**Nivel de prioridad:** 🟡 **MEDIA/BAJA**

**Razón:**
- Lógica muy simple después de simplificación
- Se testea indirectamente a través de DocumentsController
- Puede postergarse

**Tests mínimos necesarios:**
1. Rechaza providers no-bedrock
2. Delega correctamente a BedrockClient

---

### 3.6. DailyMetricsJob

**Plan de Cline:** Tests de ejecución en diferentes horarios + Pruebas de reintento + Verificación de métricas

**Evaluación:** ⚠️ **Sobre-ingeniería**

**Tipo de test recomendado:** **Mejorar tests existentes + Edge cases básicos**

**Motivo:**
- Ya tiene tests básicos (enqueue, perform sin crash)
- Tests de "diferentes horarios" no aportan valor (usa Date, no hora)
- Pruebas de reintento son responsabilidad de ActiveJob, no del job

**Riesgo que cubre:**
- 🟡 **Medio:** Ejecución con diferentes fechas
- 🟢 **Bajo:** Reintentos (ActiveJob lo maneja)
- 🟢 **Bajo:** Horarios (no aplica)

**Nivel de prioridad:** 🟡 **MEDIA**

**Tests mínimos necesarios:**
1. ✅ Ya existe: Enqueue correcto
2. ✅ Ya existe: Perform sin crash
3. ⏳ Agregar: Verifica que llama SimpleMetricsService con fecha correcta
4. ⏳ Agregar: Maneja errores de SimpleMetricsService

**Cambios sugeridos:**
- ❌ Eliminar: Tests de "diferentes horarios" (no aplica)
- ❌ Eliminar: Tests de reintento (ActiveJob lo maneja)
- ✅ Mejorar: Agregar verificación de llamada a SimpleMetricsService
- ✅ Agregar: Test de manejo de errores

---

### 3.7. Users::SessionsController

**Plan de Cline:** Mencionado pero sin detalles

**Evaluación:** ⚠️ **Baja prioridad**

**Tipo de test recomendado:** **Request specs básicos (si Devise no los cubre)**

**Motivo:**
- Devise ya tiene tests propios
- Solo testear customizaciones si las hay

**Riesgo que cubre:**
- 🟢 **Bajo:** Solo si hay lógica customizada

**Nivel de prioridad:** 🟢 **BAJA**

**Recomendación:** Solo si hay lógica customizada en el controller. Devise ya está testeado.

---

## 4. Cambios Sugeridos al Plan

### 4.1. Qué Mover de Prioridad

**Subir prioridad:**
1. ✅ **RagController request specs** - Crítico, endpoint principal
2. ✅ **DocumentsController request specs** - Crítico, funcionalidad core
3. ✅ **BedrockRagService unit tests** - Lógica compleja de parsing

**Bajar prioridad:**
1. ⏳ **Capybara/system tests** - Postergar hasta tener request specs
2. ⏳ **Contract testing** - Postergar indefinidamente
3. ⏳ **BedrockClient unit tests** - Se testea indirectamente
4. ⏳ **AiProvider tests** - Lógica muy simple ahora

---

### 4.2. Qué Simplificar

**Eliminar:**
- ❌ Capybara para endpoints API (usar request specs)
- ❌ Contract testing (prematuro)
- ❌ Tests de "diferentes horarios" para DailyMetricsJob (no aplica)
- ❌ Tests de reintento manual (ActiveJob lo maneja)

**Simplificar:**
- ✅ Usar mocks de AWS SDK directamente (no HTTParty)
- ✅ Focus en happy path + errores críticos primero
- ✅ Postergar edge cases hasta tener coverage básico

---

### 4.3. Qué Eliminar o Postergar

**Eliminar ahora:**
- Contract testing
- Tests de horarios para jobs
- Tests de reintento manual

**Postergar:**
- Capybara/system tests (hasta tener request specs)
- Tests exhaustivos de BedrockClient (se testea indirectamente)
- Tests de AiProvider (muy simple después de simplificación)
- Edge cases complejos (hasta tener tests básicos)

---

## 5. Roadmap Mínimo de Testing

### Iteración 1: Tests Indispensables (Semana 1) 🔴

**Objetivo:** Cubrir flujos críticos que detecten regresiones

#### 1.1. RagController - Request Specs
```ruby
# test/controllers/rag_controller_test.rb
- Requiere autenticación
- Rechaza question vacío
- Retorna respuesta exitosa (mock BedrockRagService)
- Maneja errores de BedrockRagService
```

**Tiempo estimado:** 2-3 horas  
**Valor:** 🔴 **ALTO** - Endpoint crítico sin tests

#### 1.2. DocumentsController - Request Specs
```ruby
# test/controllers/documents_controller_test.rb
- Requiere autenticación
- Rechaza archivos no-PDF
- Rechaza archivos vacíos
- Procesa PDF válido (mock AiProvider)
- Maneja errores de extracción
```

**Tiempo estimado:** 3-4 horas  
**Valor:** 🔴 **ALTO** - Funcionalidad core sin tests

#### 1.3. BedrockRagService - Unit Tests Básicos
```ruby
# test/services/bedrock_rag_service_test.rb
- Query exitoso retorna estructura correcta (mock AWS)
- Formatea citations correctamente
- Maneja errores de AWS
- Guarda BedrockQuery en BD
```

**Tiempo estimado:** 4-5 horas  
**Valor:** 🔴 **ALTO** - Lógica compleja sin tests

**Total Iteración 1:** ~10-12 horas  
**Coverage esperado:** ~40-50% de código crítico

---

### Iteración 2: Mejoras y Edge Cases (Semana 2) 🟡

**Objetivo:** Mejorar tests existentes y agregar edge cases importantes

#### 2.1. Mejorar DailyMetricsJob
```ruby
# test/jobs/daily_metrics_job_test.rb
- Verifica llamada a SimpleMetricsService con fecha
- Maneja errores de SimpleMetricsService
- (Ya tiene: enqueue, perform sin crash)
```

**Tiempo estimado:** 1-2 horas

#### 2.2. BedrockRagService - Edge Cases
```ruby
# test/services/bedrock_rag_service_test.rb
- Sin citations en respuesta
- Respuesta vacía
- Diferentes formatos de citations
- Estimación de tokens
```

**Tiempo estimado:** 2-3 horas

#### 2.3. BedrockClient - Unit Tests (Opcional)
```ruby
# test/services/bedrock_client_test.rb
- Formato de request correcto
- Parsing de respuesta
- Manejo de errores
```

**Tiempo estimado:** 2-3 horas  
**Nota:** Puede postergarse si otros tests cubren el comportamiento

**Total Iteración 2:** ~5-8 horas  
**Coverage esperado:** ~60-70%

---

### Iteración 3: Opcional / Postergar 🟢

**Objetivo:** Tests adicionales que mejoran confianza pero no son críticos

#### 3.1. System Tests con Capybara (Solo si necesario)
```ruby
# test/system/
- Flujo completo: subir PDF → ver resumen
- Flujo completo: chat RAG
```

**Cuándo hacer:**
- Solo si hay interacciones JS complejas
- Después de tener request specs funcionando
- Si hay tiempo/budget disponible

**Tiempo estimado:** 4-6 horas

#### 3.2. AiProvider - Unit Tests
```ruby
# test/services/ai_provider_test.rb
- Rechaza providers no-bedrock
- Delega a BedrockClient
```

**Tiempo estimado:** 1 hora  
**Nota:** Muy simple, puede postergarse

#### 3.3. Contract Testing
**Recomendación:** NO hacer por ahora. AWS SDK ya valida contratos.

---

## 6. Resumen Ejecutivo

### Evaluación del Plan de Cline

**Estado:** ⚠️ **Ajustable**

**Problemas principales:**
1. Sobre-recomienda Capybara para endpoints API
2. Contract testing prematuro
3. Falta priorización clara
4. No considera tests existentes

**Ajustes recomendados:**
1. ✅ Priorizar Request Specs sobre Capybara
2. ✅ Eliminar contract testing del plan inicial
3. ✅ Enfocarse en Iteración 1 primero
4. ✅ Postergar system tests hasta tener coverage básico

### Prioridad de Tipos de Tests

1. 🔴 **Request Specs** - Rápidos, cubren endpoints críticos
2. 🔴 **Unit Tests con Mocks** - Aislados, permiten refactor seguro
3. 🟡 **System Tests** - Solo para flujos complejos, postergar
4. 🟢 **Contract Testing** - Postergar indefinidamente

### Roadmap Recomendado

**Iteración 1 (Crítico):**
- RagController request specs
- DocumentsController request specs  
- BedrockRagService unit tests básicos

**Iteración 2 (Mejoras):**
- Mejorar DailyMetricsJob
- Edge cases de BedrockRagService
- BedrockClient (opcional)

**Iteración 3 (Opcional):**
- System tests (solo si necesario)
- AiProvider tests
- Contract testing (NO hacer)

### Próximo Paso Inmediato

**Empezar con:** `test/controllers/rag_controller_test.rb` - Request specs básicos

**Razón:** Endpoint crítico sin tests, rápido de implementar, alto valor.

