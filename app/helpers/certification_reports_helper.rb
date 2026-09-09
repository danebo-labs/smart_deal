# frozen_string_literal: true

module CertificationReportsHelper
  STATUS_BADGE_CLASSES = {
    "en_progreso"    => "bg-[hsl(48,96%,89%)] text-[hsl(32,81%,29%)]",
    "listo_revision" => "bg-[hsl(217,91%,93%)] text-[hsl(217,91%,35%)]",
    "enviado"        => "bg-[hsl(142,71%,90%)] text-[hsl(142,71%,29%)]"
  }.freeze

  def certifier_status_badge_class(status)
    STATUS_BADGE_CLASSES.fetch(status.to_s, "bg-[hsl(215,20%,93%)] text-[hsl(215,20%,42%)]")
  end

  # "1:07" — the same m:ss the recording indicator counts in, so the card a
  # certifier sees after reopening matches what they saw while recording.
  def certifier_audio_duration(seconds)
    total = seconds.to_i
    format("%d:%02d", total / 60, total % 60)
  end
end
