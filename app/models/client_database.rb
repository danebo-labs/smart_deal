# frozen_string_literal: true

# app/models/client_database.rb
#
# Abstract base class for connecting to the client's business database.
# Using a dedicated abstract class (instead of ActiveRecord::Base.establish_connection)
# ensures the secondary connection is isolated and does NOT interfere with the
# primary application database used by User, BedrockQuery, CostMetric, etc.
#
# Future multi-tenant note: When evolving to multi-tenant, this class can be
# parameterized to connect to different databases per tenant by overriding
# the connection configuration dynamically.
class ClientDatabase < ActiveRecord::Base # rubocop:disable Rails/ApplicationRecord -- intentionally not using ApplicationRecord to isolate connection pool
  self.abstract_class = true
  establish_connection :client_db
end
