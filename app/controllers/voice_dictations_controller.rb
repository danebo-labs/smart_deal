# frozen_string_literal: true

# A certifier's dictations (Fase 5 of
# docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md). Every action here is
# glue between the browser and the Fase 4 contracts — VoiceDictationIntake,
# VoiceDictationConfirmation, VoiceDictationRetry, the VoiceDictation state
# machine — and none of them decides anything those contracts don't already
# enforce.
#
# Three rules shape the surface:
#
#   * Upload-first (fixed rule 11): `create` is hit the moment recording stops,
#     before the certifier does anything else. The response is the dictation's
#     card in its current state, so a page reload shows the same thing.
#   * Nothing reaches the draft without the editable panel and an explicit
#     yes (fixed rule 3): `update` only autosaves the correction; `confirm` is
#     the single path to an InspectionFinding.
#   * Ownership on both axes (fixed rule 12): every lookup goes through
#     `owned_dictations`, so another account's or another colleague's dictation
#     404s exactly like a report does.
class VoiceDictationsController < ApplicationController
  include AuthenticationConcern
  include CertifierModuleGuard

  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  # The card in its current state, straight from the database. The broadcast
  # carries only a preview; this is where the full transcript comes from.
  def show
    @dictation = owned_dictations.find(params[:id])

    respond_to do |format|
      format.turbo_stream
      format.html do
        redirect_to certification_report_path(@dictation.certification_report_id, anchor: helpers.dom_id(@dictation))
      end
    end
  end

  # Upload-first. The browser posts the blob and the duration it measured;
  # intake deduplicates by content per report, so a retried upload from a
  # flaky connection returns the same dictation and bills nothing twice.
  def create
    report = owned_reports.find(params[:certification_report_id])
    upload = params[:audio]
    return head :unprocessable_entity if upload.blank?

    @dictation = VoiceDictationIntake.call(
      account_id: current_account.id,
      user_id: current_user.id,
      certification_report_id: report.id,
      binary: upload.read,
      content_type: upload.content_type.to_s.split(";").first.presence || "application/octet-stream",
      filename: upload.original_filename,
      duration_seconds: params[:duration_seconds].presence&.to_i
    )
    return head :unprocessable_entity if @dictation.nil?

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to certification_report_path(report, anchor: helpers.dom_id(@dictation)) }
    end
  end

  # Debounced autosave of the certifier's correction (fixed rule 11: a reload
  # never loses an edit). Writes transcript_edited and nothing else; refused
  # with 409 once the dictation left `transcribed`, which the browser shows as
  # "not saved" rather than retrying forever.
  def update
    dictation = owned_dictations.find(params[:id])
    saved = VoiceDictation.record_edit(id: dictation.id, text: edit_params[:transcript_edited].to_s)

    head(saved ? :no_content : :conflict)
  end

  # The explicit yes. The form carries the textarea's current text so a tap
  # inside the autosave debounce window still commits what the certifier sees;
  # a double tap is absorbed server-side (CAS + unique index) and lands on the
  # same finding, highlighted with its undo.
  def confirm
    dictation = owned_dictations.find(params[:id])
    text = edit_params[:transcript_edited]

    if text.present?
      VoiceDictation.record_edit(id: dictation.id, text: text)
    elsif !text.nil? && dictation.transcribed?
      # The certifier emptied the panel: confirming would silently fall back
      # to the raw transcript they just deleted.
      return redirect_to report_path_for(dictation), alert: t("certifier.dictation.alerts.empty")
    end

    finding = VoiceDictationConfirmation.call(dictation.reload, location: edit_params[:location])
    if finding
      flash[:highlight_finding_id] = finding.id
      redirect_to certification_report_path(finding.certification_report_id, anchor: helpers.dom_id(finding)),
                  notice: t("certifier.notices.dictation_confirmed")
    else
      redirect_to report_path_for(dictation), alert: t("certifier.dictation.alerts.not_confirmable")
    end
  end

  # Inline undo of the confirmation just made: the finding goes, the text
  # comes back to the panel to correct and confirm again — never re-record.
  def undo
    dictation = owned_dictations.find(params[:id])

    if VoiceDictationConfirmation.undo(dictation)
      redirect_to report_path_for(dictation), notice: t("certifier.notices.dictation_undone")
    else
      redirect_to report_path_for(dictation), alert: t("certifier.dictation.alerts.nothing_to_undo")
    end
  end

  # T5. Costs one new billed call, which is why it is a tap and never a timer.
  def retry
    dictation = owned_dictations.find(params[:id])

    if VoiceDictationRetry.call(dictation)
      redirect_to report_path_for(dictation), notice: t("certifier.notices.dictation_retried")
    else
      redirect_to report_path_for(dictation), alert: t("certifier.dictation.alerts.cannot_retry")
    end
  end

  # Discard a dictation the certifier does not want. A confirmed one is the
  # finding's trace and stays; the finding itself has its own delete.
  def destroy
    dictation = owned_dictations.find(params[:id])
    return redirect_to report_path_for(dictation), alert: t("certifier.dictation.alerts.cannot_discard") if dictation.confirmed?

    dictation.destroy!
    redirect_to report_path_for(dictation), notice: t("certifier.notices.dictation_discarded")
  end

  private

  def owned_reports
    CertificationReport.owned_by(account_id: current_account.id, user_id: current_user.id)
  end

  def owned_dictations
    VoiceDictation.owned_by(account_id: current_account.id, user_id: current_user.id)
  end

  def edit_params
    params.fetch(:voice_dictation, {}).permit(:transcript_edited, :location)
  end

  def report_path_for(dictation)
    certification_report_path(dictation.certification_report_id, anchor: helpers.dom_id(dictation))
  end

  def not_found
    head :not_found
  end
end
