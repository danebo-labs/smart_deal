# Performance Constraints

Production priorities:

* Low end-user latency
* Minimal Bedrock round trips
* Minimal DB queries
* Minimal orchestration complexity

Preferred patterns:

* Direct execution paths
* Single-pass retrieval/generation
* Metadata filtering before semantic search
* Async only for long-running operations

Avoid:

* Excessive orchestration
* Multi-step retrieval chains
* Callback-heavy flows
* Polling-heavy architectures
* Excessive Turbo broadcasts
