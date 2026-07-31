# RAG SEGURIDADES benchmark

Versioned 12-case regression benchmark for the `SEGURIDADES 1.1-1` corpus.
It is separate from the historical 16-case platform-lift benchmark.

## Preconditions

- The source PDF must exist as a tenant-scoped `KbDocument`.
- Its chunks must be synchronized in the configured Bedrock Knowledge Base.
- Set `RAG_SEGURIDADES_DOCUMENT_KEY` when the display name does not contain
  `SEGURIDADES`.
- Use `RAG_SEGURIDADES_ACCOUNT_ID` when the same key could exist in more than
  one account.

## Run

```bash
RAG_SEGURIDADES_DOCUMENT_KEY="uploads/.../seguridades.pdf" \
RAG_SEGURIDADES_ACCOUNT_ID=5 \
RAG_SEGURIDADES_OUTPUT=tmp/rag_seguridades_benchmark.json \
bin/rails runner script/rag_seguridades_benchmark.rb
```

This performs real Bedrock retrieval/generation calls. For every case it records:

- the separately retrieved chunks and retrieval trace;
- whether the runtime context contained a page image or only text;
- whether a visual description was present in the text;
- raw, internal-marker, and user-visible answers;
- the first empty stage (`retrieval`, `generation`, or `render`);
- citations, generation mode, and rubric evaluation.

The Retrieve API used by the current query path returns text chunks, not page-image
bytes, so `context_included_page_image` remains false unless the runtime contract
is deliberately changed.

## Re-evaluate an existing run

```bash
RAG_SEGURIDADES_INPUT=tmp/rag_seguridades_benchmark.json \
RAG_SEGURIDADES_EVALUATION_OUTPUT=tmp/rag_seguridades_evaluation.json \
bin/rails runner script/evaluate_rag_seguridades_benchmark.rb
```

Both scripts accept `RAG_SEGURIDADES_RUBRIC` to select a rubric file. Defaults:

- 12-case regression: `script/fixtures/rag_seguridades_rubric.json` (`seguridades-v3.2`)
- certified pilot 10q: `script/fixtures/rag_seguridades_pilot_10q.json` (`seguridades-pilot-v1.2`)
- generalization pilot 10q v2: `script/fixtures/rag_seguridades_pilot_10q_v2.json` (`seguridades-pilot-v2.1`)

```bash
RAG_SEGURIDADES_RUBRIC=script/fixtures/rag_seguridades_pilot_10q_v2.json \
RAG_SEGURIDADES_OUTPUT=tmp/rag_seguridades_pilot_v2.json \
bin/rails runner script/rag_seguridades_benchmark.rb
```

The default rubric for evaluate (when unset) is
`script/fixtures/rag_seguridades_rubric.json`. Each question declares:

- required claims;
- acceptable optional claims;
- penalized claims;
- severity and source pages.

The rubric also requires at least one real entry in the recorded `citations`
array for every case. A page number written by the model in answer prose does
not satisfy this requirement. Separately retrieved chunks are diagnostic
context only and cannot be used as retrospective attribution for a generated
answer.

Set `RAG_SEGURIDADES_CASE_IDS` (comma-separated case ids) on either script to
run or re-score a subset instead of all 12 cases; the filter also applies to the
rubric handed to the evaluator, so the cases left out are not counted as
failures.

Current rubric version is `seguridades-v3.2`. A pattern may only be relaxed with
a negative control proving the known-bad phrasing it guards still fails, and the
controls are locked as tests in
`test/services/rag/seguridades_rubric_calibration_test.rb` (offline, no Bedrock).
The current gate status and per-case results live in
[RAG_SEGURIDADES_STATUS.md](RAG_SEGURIDADES_STATUS.md).

## Replay fidelity gate for archived runs

Archived runs are replayed offline before any transform is scored. The gate asserts that the
recorded user-visible `answer` can be reproduced from the recorded `internal_answer`. Which
gate applies depends on when the artifact was produced.

| Artifacts | Fidelity baseline |
|---|---|
| Produced with `RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED` unset or `"false"` | `answer == AnswerSafetyProcessor.call(internal_answer, evidence: chunks)` (I0) |
| Produced with `RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED="true"` | `answer == CitationAttributionGuard.call(AnswerSafetyProcessor.call(internal_answer, …))` (I15) |

Replaying a flag-on artifact against I0 reports false mismatches. `tmp/d5_abstention_contract/`
predates the flag, so its baseline stays I0 and the guard is applied to it as a transform.

One documented exception: a structured-route turn whose citation gate replaced the answer records
an `internal_answer` from **before** that gate, so `AnswerSafetyProcessor` alone cannot reproduce
its `answer`. Reproducing it requires re-running the structured terminal gate.
`script/replay_d5_attribution_contract.rb` marks such rows `fidelity_strategy:
"structured_terminal_gate"` instead of `"answer_safety"`, per row, rather than relaxing the gate.

Both contract flags default to `"false"`. A run intended to be comparable against
`tmp/d5_abstention_contract/` must set `RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED="true"` and
`RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED="true"`, and must write to `tmp/pilot_gate/` so the
archived baseline is never overwritten. Full evidence:
[RAG_CITATION_ATTRIBUTION_CONTRACT_2026-07-30.md](RAG_CITATION_ATTRIBUTION_CONTRACT_2026-07-30.md).

## Visual enrichment gate

Do not add runtime vision calls from this benchmark. First complete the
`visual_text_audit` entries against the source PDF. If failures correlate with
confirmed visual-to-text gaps, enrich diagram-dense pages during ingestion and
re-run the same rubric. New chunk sidecars include `page_number`; existing
documents require re-ingestion before citations can show that metadata.
