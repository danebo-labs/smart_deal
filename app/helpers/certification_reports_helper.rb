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
end
