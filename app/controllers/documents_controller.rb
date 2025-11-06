class DocumentsController < ApplicationController
  before_action :authenticate_user!

  def create
    uploaded_file = params[:file]
    
    if uploaded_file.nil?
      render turbo_stream: turbo_stream.update("document_info", partial: "documents/error", locals: { message: "No file provided" })
      return
    end

    # Validar que sea un PDF
    unless uploaded_file.content_type == 'application/pdf' || uploaded_file.original_filename&.downcase&.end_with?('.pdf')
      render turbo_stream: turbo_stream.update("document_info", partial: "documents/error", locals: { message: "File must be a PDF" })
      return
    end

    begin
      # Extraer texto del PDF
      text = extract_text_from_pdf(uploaded_file)
      
      if text.strip.empty?
        render turbo_stream: turbo_stream.update("document_info", partial: "documents/error", locals: { message: "Could not extract text from PDF. The file might be empty or corrupted." })
        return
      end
      
      # Procesar con IA (placeholder por ahora)
      summary = analyze_text(text)
      
      # Actualizar ambas secciones con Turbo Streams
      # Usamos 'update' en lugar de 'replace' para preservar los turbo-frames
      render turbo_stream: [
        turbo_stream.update("document_info", partial: "documents/info", locals: { 
          filename: uploaded_file.original_filename,
          file_size: uploaded_file.size
        }),
        turbo_stream.update("ai_summary", partial: "documents/summary", locals: { 
          summary: summary 
        })
      ]
    rescue PDF::Reader::MalformedPDFError => e
      render turbo_stream: turbo_stream.update("document_info", partial: "documents/error", locals: { message: "Invalid PDF file: #{e.message}" })
    rescue => e
      Rails.logger.error "Error processing PDF: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render turbo_stream: turbo_stream.update("document_info", partial: "documents/error", locals: { message: "Error processing file: #{e.message}" })
    end
  end

  private

  def extract_text_from_pdf(file)
    require 'pdf-reader'
    
    # Crear un archivo temporal
    temp_file = Tempfile.new(['document', '.pdf'])
    temp_file.binmode
    temp_file.write(file.read)
    temp_file.rewind
    
    # Leer el PDF
    reader = PDF::Reader.new(temp_file.path)
    text = reader.pages.map(&:text).join(" ")
    
    # Limpiar archivo temporal
    temp_file.close
    temp_file.unlink
    
    text
  rescue => e
    raise "Error reading PDF: #{e.message}"
  end

  def analyze_text(text)
    # Placeholder: Por ahora retornamos texto hardcodeado
    # Cuando tengas la API key de OpenAI, descomenta el código de abajo
    
    # client = OpenAI::Client.new(api_key: ENV["OPENAI_API_KEY"])
    # response = client.chat(
    #   parameters: {
    #     model: "gpt-4o-mini",
    #     messages: [
    #       { role: "system", content: "You are an expert document analyst. Summarize and explain this document clearly." },
    #       { role: "user", content: "Analyze this document and summarize the main ideas:\n\n#{text}" }
    #     ]
    #   }
    # )
    # response.dig("choices", 0, "message", "content")
    
    # Placeholder response
    "This is a placeholder analysis of the document. The document contains #{text.length} characters. 
    
    Main points:
    • Document successfully processed
    • Ready to integrate with OpenAI API
    • Text extraction working correctly
    
    Once you configure your OPENAI_API_KEY, the AI will provide a detailed analysis of the document content."
  end
end

