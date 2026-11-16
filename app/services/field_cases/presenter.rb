# frozen_string_literal: true

module FieldCases
  # Public shape of a case and a turn. The execution token, the input digest
  # and the lease stay on the row for the writer; a client reloads by id.
  module Presenter
    module_function

    def case_hash(record)
      {
        "id" => record.id,
        "episode_id" => record.episode_id,
        "mode" => record.mode,
        "title" => record.title,
        "opened_at" => record.opened_at&.iso8601,
        "last_activity_at" => record.last_activity_at&.iso8601,
        "state_revision" => record.state_revision,
        "last_sequence" => record.last_sequence,
        "schema_version" => record.schema_version,
        "document_focus" => record.document_focus,
        "technical_state" => record.technical_state
      }
    end

    def turn_hash(record)
      {
        "id" => record.id,
        "sequence" => record.sequence,
        "client_submission_id" => record.client_submission_id,
        "correlation_id" => record.correlation_id,
        "kind" => record.kind,
        "status" => record.status,
        "phase" => record.phase,
        "message" => record.message,
        "field_photo_id" => record.field_photo_id,
        "attachment" => record.attachment,
        "locale" => record.locale,
        "response" => record.response,
        "prompt_reply" => record.prompt_reply,
        "checkpoint" => record.checkpoint,
        "failure_stage" => record.failure_stage,
        "failure_code" => record.failure_code,
        "attempt" => record.attempt,
        "base_state_revision" => record.base_state_revision,
        "result_state_revision" => record.result_state_revision,
        "admitted_at" => record.admitted_at&.iso8601,
        "completed_at" => record.completed_at&.iso8601
      }
    end
  end
end
