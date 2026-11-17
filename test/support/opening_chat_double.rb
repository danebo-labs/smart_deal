# frozen_string_literal: true

# Answers /rag/ask without a model. Absent answer calls the real pipeline.
module OpeningChatDouble
  class << self
    attr_accessor :answer, :calls

    def install!
      RagController.prepend(self) unless RagController.ancestors.include?(self)
      self.calls = 0
    end
  end

  def execute_rag_query(question, **)
    return super if OpeningChatDouble.answer.nil?

    OpeningChatDouble.calls += 1
    RagQueryConcern::RagResult.new(
      success?: true,
      answer: "#{OpeningChatDouble.answer} #{question}",
      citations: [],
      retrieved_citations: [],
      doc_refs: [],
      session_id: "local-opening",
      response_locale: :es,
      generation_mode: "opening_double",
      effective_question: question
    )
  end
end
