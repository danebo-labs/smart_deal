# frozen_string_literal: true

Rails.application.routes.draw do
  mount ActionCable.server => "/cable"

  unless Rails.env.test?
    mount MissionControl::Jobs::Engine, at: '/jobs'
  end

  root 'home#index'

  get  'home/metrics',        to: 'home#metrics'
  get  'home/documents',      to: 'home#documents'
  get  'home/documents_page', to: 'home#documents_page'
  get  'dashboard',          to: 'dashboard#index'
  get  'dashboard/metrics',  to: 'dashboard#metrics'
  # Query-volume view for the demo — guarded by ENV["ACTIVITY_DASHBOARD_ENABLED"]
  # (see ActivityController). No `$`/tokens: pure counts from BedrockQuery.
  get  'actividad',          to: 'activity#index', as: :activity

  devise_for :users,
             controllers: {
               sessions: 'users/sessions',
               passwords: 'users/passwords'
             },
             skip: [ :registrations ]
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get 'up' => 'rails/health#show', as: :rails_health_check

  get 'locale/:locale', to: 'locales#switch', as: :switch_locale, constraints: { locale: /es|en/ }

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  resources :pinned_documents, only: %i[create destroy]
  resources :field_photos, only: %i[show]
  # resources :bulk_uploads, only: %i[new create show]  # T-31: disabled for pilot

  # Certifier module (Fase 2) — guarded by ENV["CERTIFIER_MODULE_ENABLED"]
  # (CertifierModuleGuard on every controller, nav entry gated in the layout).
  resources :certification_reports do
    # Fase 1B: read-only review of the whole draft, in the exact order fixed by
    # the plan. A GET, never generates or changes state.
    member do
      get :export
    end
    resources :inspection_findings, only: %i[create]
    # Fase 5: audio is uploaded against the report the moment recording stops.
    resources :voice_dictations, only: %i[create]
    # Fase 1A: the elevators of this draft. Created with just their visible
    # label; the optional technical characteristics are revealed on edit.
    resources :report_equipments, only: %i[create]
  end
  resources :inspection_findings, only: %i[edit update destroy]
  resources :report_equipments, only: %i[edit update destroy]

  # Fase 1A: the company's issuer identity — one per account, configured once
  # (fixed rule 14). Singular resource: there is nothing to list.
  resource :certifier_settings, only: %i[show update] do
    get    :logo,  action: :logo,          as: :logo
    delete :logo,  action: :destroy_logo
  end
  # Fase 5: the dictation's own lifecycle — refresh (show), autosave (update),
  # the explicit yes (confirm), its inline reversal (undo), the human retry of
  # a failed one (retry) and discarding it (destroy). Flat, not under the chat.
  resources :voice_dictations, only: %i[show update destroy] do
    member do
      post :confirm
      post :undo
      post :retry
    end
  end

  # RAG endpoint for Knowledge Base queries
  post '/rag/ask', to: 'rag#ask'

  # post '/twilio/webhook', to: 'twilio#webhook'  # WA channel disabled for MVP
end
