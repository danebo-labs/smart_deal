# frozen_string_literal: true

# "Retorno directo" from the report's review page (Fase 1B, shared contract
# point 2): saving an edit opened from /certification_reports/:id/export comes
# straight back to that page instead of the report's own show page.
#
# The only accepted signal is the literal token "export" in params[:return_to]
# — never a URL. This can never become an open redirect: the destination is
# always this app's own export_certification_report_path, built from the
# already-authorized report, with an optional anchor to the section just
# edited.
module CertifierExportRedirect
  extend ActiveSupport::Concern
  include ActionView::RecordIdentifier

  private

  def export_return_path(report, anchor: nil)
    return nil unless params[:return_to] == "export"

    export_certification_report_path(report, anchor: anchor)
  end
end
