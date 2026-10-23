# frozen_string_literal: true

module Rag
  # Lexical match between a reported field act and a documentary step.
  # It does not decide that two phrasings are the same operation. When it
  # cannot show the same acts and the same component, it does not attribute
  # execution.
  #
  # Each family is a closed verb prefix plus an obligatory ending. The finite
  # endings are the ones in CompanionPlanCheck::OPERATION, so a noun such as
  # "regulación" or "mediciones" is not an act. The participle endings ado/ada
  # are added because that finite list misses "comprobado", and the pending
  # check required by the plan would otherwise not see the verb. They are not
  # applied to apag/encend: "apagado" and "encendido" are state adjectives in
  # these reports, not the act of switching the equipment.
  class ReportedOperation
    ACTS = {
      "check" => %w[comprob verific revis mir observ control asegur cheque],
      "disconnect" => %w[desconect],
      "connect" => %w[conect],
      "press" => %w[puls presion apret],
      "adjust" => %w[ajust gir regul calibr],
      "measure" => %w[med mid],
      "clean" => %w[limpi],
      "replace" => %w[cambi reemplaz sustitu],
      "restart" => %w[reinici apag encend]
    }.freeze
    FINITE = /\A(?:ar|er|ir|aste|iste|a|e|i|as|es|alo|elo|arlo|erlo|irlo|ando|iendo|ala|ela)\z/
    PARTICIPLE = /\A(?:ado|ados|ada|adas)\z/
    NEGATION_WORD = /\A(?:no|ni|nunca|sin|tampoco|ningun[oa]?)\z/

    Act = Data.define(:family, :negated)
    Parsed = Data.define(:acts, :component)

    def self.parse(text)
      words = CompanionPlanCheck.words(text)
      verb_at = {}
      words.each_with_index do |word, index|
        family = family_of(word)
        verb_at[index] = family if family
      end
      acts = verb_at.map do |index, family|
        Act.new(family: family, negated: negated_at?(words, index))
      end
      Parsed.new(acts: acts, component: component_of(words, verb_at.keys))
    end

    def self.family_of(word)
      ACTS.each do |family, prefixes|
        prefixes.each do |prefix|
          next unless word.start_with?(prefix)

          rest = word[prefix.length..]
          next if rest.empty?
          return family if rest.match?(FINITE)
          return family if family != "restart" && rest.match?(PARTICIPLE)
        end
      end
      nil
    end

    # The act closest to the subject, looking only at the words before it.
    def self.family_before(sentence, subject)
      haystack = sentence.to_s
      needle = subject.to_s.strip
      return nil if needle.empty?

      index = haystack.downcase.index(needle.downcase)
      return nil if index.nil?

      family = nil
      CompanionPlanCheck.words(haystack[0...index]).each do |word|
        found = family_of(word)
        family = found if found
      end
      family
    end

    def self.correspondence(report_text:, result:, status:, statement_text:)
      report = parse(report_text)
      step = parse(statement_text)
      shared = report.component & step.component
      return :none if shared.empty?

      selected = selected_acts(report.acts, status)
      step_acts = step.acts.reject(&:negated).map(&:family).uniq
      reported = selected.to_set
      required = step_acts.to_set
      if status.to_s == "not_done"
        return (reported & required).any? ? :pending : :related
      end
      if required.any? && required.subset?(reported)
        return :complete unless required == Set["check"]

        predicate = step.component - shared
        return :complete if predicate.empty? || predicate.intersect?(parse(report_text).component | parse(result.to_s).component)

        return :related
      end
      return :partial if (reported & required).any?

      :related
    end

    # [families, component] so two rows replace each other only when both match.
    # A stored row without operation is the check family.
    def self.key(subject, operation)
      families = Array(operation).map(&:to_s) & ACTS.keys
      families = [ "check" ] if families.empty?
      [ families.sort, parse(subject.to_s).component.to_a.sort ]
    end

    def self.negated_at?(words, index)
      words[[ index - 3, 0 ].max...index].any? { |word| word.match?(NEGATION_WORD) }
    end
    private_class_method :negated_at?

    def self.selected_acts(acts, status)
      return [ "check" ] if acts.empty?

      chosen = status.to_s == "not_done" ? acts.select(&:negated) : acts.reject(&:negated)
      chosen.map(&:family).uniq
    end
    private_class_method :selected_acts

    def self.component_of(words, verb_indexes)
      skipped = verb_indexes.to_set
      words.each_with_index.filter_map do |word, index|
        next if skipped.include?(index)
        next if CompanionPlanCheck::CONNECTORS.include?(word)
        next if CompanionPlanCheck::PERCEPTION.include?(word)

        stem = CompanionPlanCheck.stem(word)
        next if CompanionPlanRender::GENERIC_STEMS.include?(stem)

        stem
      end.to_set
    end
    private_class_method :component_of
  end
end
