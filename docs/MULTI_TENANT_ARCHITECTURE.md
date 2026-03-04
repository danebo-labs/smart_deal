# Multi-Tenant Architecture

## Overview

This document describes the architecture for converting the application from single-tenant (environment variable configuration) to multi-tenant (database-driven per-tenant configuration).

## Current Architecture (Single Tenant)

### Configuration via Environment Variables

```ruby
# .env
BEDROCK_MODEL_ID=us.anthropic.claude-3-5-haiku-20241022-v1:0
BEDROCK_KNOWLEDGE_BASE_ID=AMFSKKPEZN
BEDROCK_DATA_SOURCE_ID=<data_source_id>  # Use multimodal data source (e.g. CBXXGAKRZ3) for JPEG/PNG support
```

### Limitations
- All users share the same Knowledge Base
- Single AWS account configuration
- No cost isolation between customers
- Cannot offer different service tiers

## Multi-Tenant Architecture (Future)

### Goals
- Per-tenant Knowledge Base isolation
- Configurable models per tenant
- Cost tracking and quotas per tenant
- Different service tiers (Basic, Pro, Enterprise)
- Multiple AWS accounts support

## Database Schema

### 1. Tenants Table

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_tenants.rb
class CreateTenants < ActiveRecord::Migration[8.0]
  def change
    create_table :tenants do |t|
      t.string :name, null: false
      t.string :subdomain, null: false, index: { unique: true }
      t.string :slug, null: false, index: { unique: true }
      t.string :status, default: 'active' # active, suspended, cancelled
      t.string :tier, default: 'basic' # basic, pro, enterprise
      t.jsonb :settings, default: {}
      
      t.timestamps
    end
  end
end
```

### 2. Bedrock Configurations Table

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_bedrock_configs.rb
class CreateBedrockConfigs < ActiveRecord::Migration[8.0]
  def change
    create_table :bedrock_configs do |t|
      t.references :tenant, null: false, foreign_key: true, index: { unique: true }
      
      # AWS Credentials (encrypted)
      t.string :aws_access_key_id
      t.string :aws_secret_access_key
      t.string :aws_region, default: 'us-east-1'
      
      # Bedrock Configuration
      t.string :knowledge_base_id, null: false
      t.string :data_source_id
      t.string :s3_bucket
      
      # Model Configuration
      t.string :default_model_id, default: 'us.anthropic.claude-3-5-haiku-20241022-v1:0'
      t.string :vision_model_id, default: 'us.anthropic.claude-3-5-sonnet-20241022-v2:0'
      t.string :embedding_model_id, default: 'amazon.titan-embed-text-v1'
      
      # Limits & Quotas
      t.integer :monthly_token_limit # null = unlimited
      t.integer :tokens_used_this_month, default: 0
      t.decimal :max_cost_per_query, precision: 10, scale: 6
      
      # Feature Flags
      t.boolean :multimodal_enabled, default: true
      t.boolean :sql_generation_enabled, default: false
      t.boolean :whatsapp_enabled, default: false
      
      t.timestamps
    end
  end
end
```

### 3. Update Users Table

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_tenant_to_users.rb
class AddTenantToUsers < ActiveRecord::Migration[8.0]
  def change
    add_reference :users, :tenant, null: false, foreign_key: true, index: true
    add_column :users, :role, :string, default: 'member' # admin, member, viewer
  end
end
```

### 4. Query Logs Table (Per Tenant)

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_tenant_to_bedrock_queries.rb
class AddTenantToBedrockQueries < ActiveRecord::Migration[8.0]
  def change
    add_reference :bedrock_queries, :tenant, null: false, foreign_key: true, index: true
  end
end
```

## Models

### Tenant Model

```ruby
# app/models/tenant.rb
class Tenant < ApplicationRecord
  has_one :bedrock_config, dependent: :destroy
  has_many :users, dependent: :restrict_with_error
  has_many :bedrock_queries, dependent: :destroy
  
  validates :name, presence: true
  validates :subdomain, presence: true, uniqueness: true, 
            format: { with: /\A[a-z0-9-]+\z/i }
  validates :slug, presence: true, uniqueness: true
  validates :status, inclusion: { in: %w[active suspended cancelled] }
  validates :tier, inclusion: { in: %w[basic pro enterprise] }
  
  before_validation :generate_slug, if: -> { slug.blank? }
  after_create :create_default_bedrock_config
  
  scope :active, -> { where(status: 'active') }
  
  def active?
    status == 'active'
  end
  
  def quota_exceeded?
    return false if bedrock_config.monthly_token_limit.nil?
    bedrock_config.tokens_used_this_month >= bedrock_config.monthly_token_limit
  end
  
  private
  
  def generate_slug
    self.slug = name.parameterize
  end
  
  def create_default_bedrock_config
    create_bedrock_config!
  end
end
```

### BedrockConfig Model

```ruby
# app/models/bedrock_config.rb
class BedrockConfig < ApplicationRecord
  belongs_to :tenant
  
  validates :knowledge_base_id, presence: true
  validates :aws_region, presence: true
  
  # Encrypt sensitive fields
  encrypts :aws_access_key_id
  encrypts :aws_secret_access_key
  
  def reset_monthly_usage!
    update!(tokens_used_this_month: 0)
  end
  
  def increment_token_usage!(input_tokens, output_tokens)
    increment!(:tokens_used_this_month, input_tokens + output_tokens)
  end
  
  def within_quota?
    monthly_token_limit.nil? || tokens_used_this_month < monthly_token_limit
  end
end
```

### User Model Updates

```ruby
# app/models/user.rb
class User < ApplicationRecord
  belongs_to :tenant
  
  validates :role, inclusion: { in: %w[admin member viewer] }
  
  def admin?
    role == 'admin'
  end
  
  def can_configure_tenant?
    admin?
  end
end
```

## Tenant Identification Strategies

### Option 1: Subdomain-based (Recommended)

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  around_action :set_current_tenant
  
  private
  
  def set_current_tenant
    tenant = identify_tenant
    
    if tenant.nil?
      render plain: 'Tenant not found', status: :not_found
      return
    end
    
    unless tenant.active?
      render plain: 'Account suspended', status: :forbidden
      return
    end
    
    Current.tenant = tenant
    yield
  ensure
    Current.tenant = nil
  end
  
  def identify_tenant
    # Subdomain: acme.smartdeal.com -> 'acme'
    subdomain = request.subdomain
    return nil if subdomain.blank? || subdomain == 'www'
    
    Tenant.active.find_by(subdomain: subdomain)
  end
end
```

### Option 2: User-based

```ruby
def identify_tenant
  current_user&.tenant
end
```

### Option 3: Header-based (API)

```ruby
def identify_tenant
  tenant_id = request.headers['X-Tenant-ID']
  Tenant.active.find_by(id: tenant_id)
end
```

## Service Layer Updates

### BedrockRagService with Tenant Support

```ruby
# app/services/bedrock_rag_service.rb
class BedrockRagService
  include AwsClientInitializer
  
  def initialize(tenant:, model_id: nil)
    @tenant = tenant
    @config = tenant.bedrock_config
    
    raise MissingKnowledgeBaseError, 'Tenant has no Bedrock configuration' unless @config
    
    # Use tenant-specific AWS credentials
    client_options = build_aws_client_options(
      region: @config.aws_region,
      access_key_id: @config.aws_access_key_id,
      secret_access_key: @config.aws_secret_access_key
    )
    
    @region = @config.aws_region
    @client = Aws::BedrockAgentRuntime::Client.new(client_options)
    @knowledge_base_id = @config.knowledge_base_id
    @citation_processor = Bedrock::CitationProcessor.new
    
    # Use tenant's default model or override
    @model_ref = model_id.presence || @config.default_model_id
    
    Rails.logger.info("BedrockRagService initialized for tenant #{@tenant.name} - KB: #{@knowledge_base_id}, Model: #{@model_ref}")
  end
  
  def query(question, session_id: nil, custom_config: {})
    # Check quota before processing
    raise QuotaExceededError, 'Monthly token limit exceeded' if @tenant.quota_exceeded?
    
    # ... existing query logic ...
    
    # Track usage after successful query
    track_usage(response)
    
    # ... return result ...
  end
  
  private
  
  def track_usage(response)
    # Extract token counts from response metadata
    input_tokens = response.metadata[:input_tokens] || 0
    output_tokens = response.metadata[:output_tokens] || 0
    
    @config.increment_token_usage!(input_tokens, output_tokens)
  end
end
```

### Controller Updates

```ruby
# app/controllers/rag_controller.rb
class RagController < ApplicationController
  include AuthenticationConcern
  include RagQueryConcern
  
  def ask
    tenant = Current.tenant
    
    # Check feature flags
    unless tenant.bedrock_config.multimodal_enabled?
      return render json: { error: 'Multimodal queries not enabled' }, status: :forbidden
    end
    
    images = extract_images_from_params
    documents = extract_documents_from_params
    model_id = resolve_model_id(params[:model])
    
    # Pass tenant to service
    result = execute_rag_query(
      params[:question],
      tenant: tenant,
      images: images,
      documents: documents,
      model_id: model_id
    )
    
    # ... render response ...
  end
end
```

## Tenant-Aware Queries

```ruby
# app/models/bedrock_query.rb
class BedrockQuery < ApplicationRecord
  belongs_to :tenant
  
  scope :for_tenant, ->(tenant) { where(tenant: tenant) }
  scope :this_month, -> { where('created_at >= ?', Time.current.beginning_of_month) }
end

# Usage in controllers
@queries = BedrockQuery.for_tenant(Current.tenant).this_month
```

## Admin Dashboard

### Tenant Management

```ruby
# app/controllers/admin/tenants_controller.rb
module Admin
  class TenantsController < AdminController
    def index
      @tenants = Tenant.includes(:bedrock_config).all
    end
    
    def show
      @tenant = Tenant.find(params[:id])
      @usage = {
        tokens_used: @tenant.bedrock_config.tokens_used_this_month,
        token_limit: @tenant.bedrock_config.monthly_token_limit,
        queries_this_month: @tenant.bedrock_queries.this_month.count
      }
    end
    
    def suspend
      @tenant = Tenant.find(params[:id])
      @tenant.update!(status: 'suspended')
      redirect_to admin_tenant_path(@tenant), notice: 'Tenant suspended'
    end
  end
end
```

## Billing Integration

### Track Costs Per Tenant

```ruby
# app/services/billing_service.rb
class BillingService
  def calculate_monthly_cost(tenant)
    queries = tenant.bedrock_queries.this_month
    
    total_cost = queries.sum(&:cost)
    
    {
      total_cost: total_cost,
      query_count: queries.count,
      average_cost_per_query: total_cost / queries.count.to_f
    }
  end
  
  def generate_invoice(tenant, month:)
    # Generate invoice for the tenant
    # Integrate with Stripe, PayPal, etc.
  end
end
```

## Scheduled Jobs

### Reset Monthly Usage

```ruby
# app/jobs/reset_monthly_usage_job.rb
class ResetMonthlyUsageJob < ApplicationJob
  queue_as :default
  
  def perform
    BedrockConfig.find_each do |config|
      config.reset_monthly_usage!
      Rails.logger.info("Reset usage for tenant #{config.tenant.name}")
    end
  end
end

# config/schedule.rb (using whenever gem or good_job cron)
# Run on the 1st of every month at midnight
schedule :reset_monthly_usage, cron: '0 0 1 * *' do
  ResetMonthlyUsageJob.perform_later
end
```

## Migration Path

### Phase 1: Preparation
1. Add tenant tables and associations
2. Create default tenant for existing data
3. Update all models to include tenant reference

### Phase 2: Service Layer Updates
1. Update BedrockRagService to accept tenant parameter
2. Add tenant identification middleware
3. Implement quota checking

### Phase 3: UI Updates
1. Tenant settings page
2. Usage dashboard per tenant
3. Admin panel for tenant management

### Phase 4: Testing & Rollout
1. Test with 2-3 pilot tenants
2. Monitor performance and costs
3. Gradual rollout to all customers

## Security Considerations

### Data Isolation
- All queries must filter by `tenant_id`
- Use `default_scope` with caution (can hide bugs)
- Audit all ActiveRecord queries for tenant filtering

### Credential Management
- Encrypt AWS credentials at rest
- Use Rails encrypted credentials or AWS Secrets Manager
- Rotate credentials regularly

### Access Control
- Implement row-level security
- Users can only access their tenant's data
- Admins have cross-tenant access (audit logged)

## Performance Considerations

### Database Indexes
```ruby
add_index :bedrock_queries, [:tenant_id, :created_at]
add_index :users, :tenant_id
```

### Caching
```ruby
# Cache tenant config
Rails.cache.fetch("tenant:#{tenant.id}:config", expires_in: 5.minutes) do
  tenant.bedrock_config
end
```

### Connection Pooling
- Consider separate connection pools per tenant
- For high-volume tenants, dedicated database instances

## Monitoring & Observability

### Metrics to Track
- Queries per tenant per day
- Tokens used per tenant
- Cost per tenant
- Error rates per tenant
- Response times per tenant

### Alerts
- Tenant approaching quota limit (90%)
- Unusual query patterns
- High error rates for specific tenant
- Cost anomalies

## Example: Complete Request Flow

```ruby
# 1. Request comes in: https://acme.smartdeal.com/rag/ask
# 2. ApplicationController identifies tenant by subdomain 'acme'
# 3. Current.tenant = Tenant.find_by(subdomain: 'acme')
# 4. RagController validates tenant is active and within quota
# 5. BedrockRagService.new(tenant: Current.tenant, model_id: params[:model])
# 6. Service uses tenant's AWS credentials and Knowledge Base
# 7. Response generated and token usage tracked
# 8. BedrockConfig.increment_token_usage!(input, output)
# 9. Response returned to user
```

## References

- [Apartment gem](https://github.com/influitive/apartment) - Database multi-tenancy
- [ActsAsTenant gem](https://github.com/ErwinM/acts_as_tenant) - Simple tenant scoping
- [AWS Multi-tenancy](https://docs.aws.amazon.com/wellarchitected/latest/saas-lens/multi-tenancy.html)
