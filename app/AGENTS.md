# Rails Application Rules

## Stack

* Rails 8.1+
* Ruby 3.4+
* PostgreSQL
* Hotwire
* Importmap
* Tailwind
* Solid Queue
* Solid Cable
* Solid Cache
* AWS Bedrock

## Architecture

* Keep controllers thin.
* Put service objects in `app/services`.
* Use query objects for retrieval, filtering, and non-trivial query composition.
* Keep models free from infrastructure SDK logic.
* Keep AWS SDK usage outside models.
* Prefer PORO services.
* Prefer explicit code over metaprogramming.

## Rails-Native First

* Prefer Rails-native patterns before external gems.
* Prefer Hotwire over SPA patterns.
* Prefer Solid Stack over Redis-based solutions.
* Avoid unnecessary abstractions.
* Avoid premature enterprise architecture.

## Performance

* Optimize hot request paths.
* Minimize database queries.
* Avoid N+1 queries.
* Prefer `pluck`, `select`, `exists?`, and `preload` where appropriate.
* Avoid unnecessary ActiveRecord instantiation.
* Avoid callback-heavy flows in latency-sensitive paths.
* Use jobs only for genuinely long-running work.
* Keep user-facing request cycles minimal.

