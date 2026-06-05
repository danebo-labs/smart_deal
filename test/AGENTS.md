# Test Rules

## Framework

* Use Minitest only.
* Do not introduce RSpec.
* Test all behavioral changes.
* Test failure scenarios.
* Preserve existing behavior.
* Maintain idempotency guarantees.

## Style

* Prefer fast isolated tests.
* Prefer deterministic tests.
* Avoid excessive integration/system tests when a focused service/model/job test covers the behavior.
* Avoid unnecessary fixtures.
* Keep setup lightweight.

## Verification

* Run targeted tests for touched paths.
* Run the full suite when touching shared services, request flow, RAG orchestration, or test support.

