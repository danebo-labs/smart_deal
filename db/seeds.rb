# frozen_string_literal: true

# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

BUCKET = "multimodal-source-destination"

# KB catalog. JPEG rows use full s3:// URI as canonical s3_key; object path still matches S3 list via KbDocument.object_key_for_match.
KB_DOCUMENT_SEEDS = [
  {
    s3_key: "uploads/2026-03-27/Esquema SOPREL.pdf",
    display_name: "Foremcaro 6118/81 Electrical Schematic",
    aliases: [
      "Planta U150",
      "Esquema Eléctrico Elevador",
      "Colegio Santa Doroteia",
      "Foremcaro 6118/81",
      "Portas de Patamar",
      "Legacy Electromechanical Elevator",
      "Motor Drive Three-Phase Schematic",
      "Elevator Safety Chain Legacy Diagram"
    ]
  },
  {
    s3_key: "s3://#{BUCKET}/uploads/2026-03-27/wa_20260327_160921_0.jpeg",
    display_name: "Orona elevator controller PCB",
    aliases: [
      "Orona main controller board",
      "Orona CPU PCB",
      "Orona elevator processor board",
      "Orona controller printed circuit board",
      "Orona microprocessor main board",
      "Elevator controller PCB with battery backup",
      "Orona green controller PCB"
    ]
  },
  {
    s3_key: "s3://#{BUCKET}/uploads/2026-03-27/wa_20260327_174834_0.jpeg",
    display_name: "Purple circular PCB battery holder",
    aliases: [
      "LilyPad coin cell battery holder",
      "wearable electronics battery board",
      "CR2032 dual battery holder PCB"
    ]
  }
].freeze

# Merge legacy rows (plain object key or prior wrong metadata) into canonical s3_key + fields — avoids duplicate rows after URI change.
KB_DOCUMENT_REPAIRS = [
  {
    legacy_s3_keys: [
      "uploads/2026-03-27/wa_20260327_160921_0.jpeg",
      "s3://#{BUCKET}/uploads/2026-03-27/wa_20260327_160921_0.jpeg"
    ],
    s3_key: "s3://#{BUCKET}/uploads/2026-03-27/wa_20260327_160921_0.jpeg",
    display_name: "Orona elevator controller PCB",
    aliases: [
      "Orona main controller board",
      "Orona CPU PCB",
      "Orona elevator processor board",
      "Orona controller printed circuit board",
      "Orona microprocessor main board",
      "Elevator controller PCB with battery backup",
      "Orona green controller PCB"
    ]
  },
  {
    legacy_s3_keys: [
      "uploads/2026-03-27/wa_20260327_174834_0.jpeg",
      "s3://#{BUCKET}/uploads/2026-03-27/wa_20260327_174834_0.jpeg"
    ],
    s3_key: "s3://#{BUCKET}/uploads/2026-03-27/wa_20260327_174834_0.jpeg",
    display_name: "Purple circular PCB battery holder",
    aliases: [
      "LilyPad coin cell battery holder",
      "wearable electronics battery board",
      "CR2032 dual battery holder PCB"
    ]
  }
].freeze

KB_DOCUMENT_REPAIRS.each do |fix|
  kb = KbDocument.where(s3_key: fix[:legacy_s3_keys]).first
  next unless kb

  kb.update!(
    s3_key: fix[:s3_key],
    display_name: fix[:display_name],
    aliases: Array(fix[:aliases])
  )
end

# Always sync catalog fields so rows created earlier via ensure_for_s3_key! (aliases []) get filled in.
KB_DOCUMENT_SEEDS.each do |attrs|
  kb = KbDocument.find_or_initialize_by(s3_key: attrs[:s3_key])
  kb.update!(display_name: attrs[:display_name], aliases: Array(attrs[:aliases]))
end
