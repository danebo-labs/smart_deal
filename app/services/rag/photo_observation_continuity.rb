# frozen_string_literal: true

module Rag
  # First matching rule wins. New image bytes never reach the reuse rules.
  # DEICTIC_RE is not used here and is not widened for these phrases.
  class PhotoObservationContinuity
    VISUAL_REREAD_RE = /\b(?:volve|volver|vuelve|revisa|revisar|mira|mirar|analiza|analizar)\b.{0,40}\b(?:otra vez|de nuevo|nuevamente)\b|\b(?:otra vez|de nuevo)\b.{0,40}\b(?:foto|imagen)\b/
    VISUAL_REFERENCE_RE = /\b(?:estos|estas|esos|esas)\s+(?:resortes|cables|bornes|terminales|contactos)\b|\bsegun la foto\b|\bla imagen que te mande\b|\blo que se ve ahi\b|\b(?:la|esa|esta)\s+(?:foto|imagen)\b/
    MISSING_PHOTO_MESSAGE = "No tengo una foto vigente en este caso. Seleccioná la foto anterior o volvé a enviarla."

    Decision = Struct.new(:action, :photo, keyword_init: true)

    class << self
      def decide(question:, images:, field_photo_id:, account:, session:)
        return Decision.new(action: :fresh_bytes, photo: nil) if Array(images).any?

        normalized = FollowupQueryRewriter.normalize_label(question)
        if field_photo_id.present?
          photo = owned_photo(account, field_photo_id)
          if photo
            action = visual_reread?(normalized) ? :reread : :reuse
            return Decision.new(action: action, photo: photo)
          end

          # An explicit id that is not this account's photo is not replaced
          # by active_photo.
          if visual_reference?(normalized) || visual_reread?(normalized)
            return Decision.new(action: :missing_photo, photo: nil)
          end

          return Decision.new(action: :passthrough, photo: nil)
        end

        return Decision.new(action: :passthrough, photo: nil) unless visual_reference?(normalized)
        return Decision.new(action: :missing_photo, photo: nil) unless session_matches_account?(session, account)

        photo = owned_photo(account, active_photo_id(session))
        if photo
          Decision.new(action: :reuse, photo: photo)
        else
          Decision.new(action: :missing_photo, photo: nil)
        end
      end

      def visual_reread?(normalized)
        VISUAL_REREAD_RE.match?(normalized.to_s)
      end

      def visual_reference?(normalized)
        VISUAL_REFERENCE_RE.match?(normalized.to_s)
      end

      private

      def owned_photo(account, id)
        return nil if account.nil? || id.blank?

        FieldPhoto.where(account_id: account.id).find_by(id: id)
      end

      def session_matches_account?(session, account)
        return false if account.nil?
        return true if session.nil? || !session.respond_to?(:account_id)

        session.account_id == account.id
      end

      def active_photo_id(session)
        return nil unless session.respond_to?(:active_episode)

        episode = ActiveEpisode.parse(session.active_episode, now: Time.current)
        return nil if episode.blank?

        episode.active_photo&.dig("field_photo_id")
      end
    end
  end
end
