# frozen_string_literal: true

module Rag
  # Ordered schematic tables can support adjacency without a prose sentence
  # stating the relation. Only use contiguous rows in an explicitly ordered
  # table and resolve an anaphoric level from the live episode.
  module CompanionSequence
    NEIGHBORS = /\b(?:a (?:sus|los) lados|vecin\w*|adyacente\w*|antes y despu[eé]s)\b/i
    SAME_LEVEL = /\b(?:del|de ese) mismo nivel\b/i
    LEVEL = /\bnivel\s+(\d+)\b/i
    TABLE = /\|\s*(?:posici[oó]n|orden)\s*\|[^\n]+\n[ \t]*\|[\s:|\-]+?\|[ \t]*\n((?:[ \t]*\|[ \t]*\d+[ \t]*\|[^\n|]+\|[ \t]*(?:\n|\z))+)/i
    ROW = /\|[ \t]*(\d+)[ \t]*\|[ \t]*([^\n|]+?)\s*\|/
    Match = Data.define(:number, :previous, :target, :following) do
      def answer
        "«#{target}» queda entre «#{previous}» y «#{following}» en el orden de la tabla [#{number}]."
      end

      def excerpt
        [ previous, target, following ].join(" → ")
      end
    end

    module_function

    def referent_context(question, episode)
      return unless question.to_s.match?(SAME_LEVEL)

      level = resolved_level(question, episode)
      "El nivel vigente para «del mismo nivel» es nivel #{level}." if level
    end

    def resolve(question:, episode:, sources:)
      return unless question.to_s.match?(NEIGHBORS)

      level = resolved_level(question, episode)
      return unless level

      label = FollowupQueryRewriter.normalize_label(question)
      candidates = sources.filter_map.with_index do |source, index|
        next unless CompanionTurnPublication.citable_source?(source)

        source.fetch("content").scan(TABLE).flatten.flat_map do |table|
          table.scan(ROW).each_cons(3).filter_map do |(left, previous), (position, target), (right, following)|
            target_level = target[LEVEL, 1]
            next unless target_level == level && left.to_i + 1 == position.to_i && position.to_i + 1 == right.to_i

            name = FollowupQueryRewriter.normalize_label(target.sub(LEVEL, ""))
            next if name.blank? || !label.match?(/\b#{Regexp.escape(name)}\b/)
            next unless [ previous, following ].all? { |item| item.split.size >= CompanionClaimBacking::MIN_BACKING_WORDS }

            Match.new(index + 1, previous, target, following)
          end
        end
      end.flatten.uniq { |match| [ match.previous, match.target, match.following ] }
      candidates.first if candidates.one?
    end

    def resolved_level(question, episode)
      explicit = question.to_s.scan(LEVEL).flatten.uniq
      return explicit.first if explicit.one?
      return unless explicit.empty? && question.to_s.match?(SAME_LEVEL)

      active = episode.is_a?(ActiveEpisode) ? episode : ActiveEpisode.parse(episode)
      levels = Array(active&.identifiers).select { |row| %w[user photo].include?(row["source"]) }
        .filter_map { |row| row["value"].to_s[LEVEL, 1] }.uniq
      levels.first if levels.one?
    end
  end
end
