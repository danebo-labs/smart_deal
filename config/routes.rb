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
  post 'dashboard/refresh',  to: 'dashboard#refresh'

  devise_for :users,
             controllers: {
               sessions: 'users/sessions',
               passwords: 'users/passwords',
               registrations: 'users/registrations'
             }
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get 'up' => 'rails/health#show', as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  resources :pinned_documents, only: %i[create destroy]

  # RAG endpoint for Knowledge Base queries
  post '/rag/ask', to: 'rag#ask'

  # post '/twilio/webhook', to: 'twilio#webhook'  # WA channel disabled for MVP
end
