class DocumentsController < ApplicationController
  before_action :authenticate_user!

  def create
    uploaded_file = params[:file]
    
    if uploaded_file.nil?
      render json: { error: "No file provided" }, status: :bad_request
      return
    end

    # Validar que sea un PDF
    unless uploaded_file.content_type == 'application/pdf' || uploaded_file.original_filename&.downcase&.end_with?('.pdf')
      render json: { error: "File must be a PDF" }, status: :bad_request
      return
    end

    begin
      # Extraer texto del PDF
      text = extract_text_from_pdf(uploaded_file)
      
      if text.strip.empty?
        render json: { error: "Could not extract text from PDF. The file might be empty or corrupted." }, status: :unprocessable_entity
        return
      end
      
      # Procesar con IA (placeholder por ahora)
      summary = analyze_text(text)
      
      render json: { 
        success: true, 
        summary: summary,
        filename: uploaded_file.original_filename,
        file_size: uploaded_file.size
      }
    rescue PDF::Reader::MalformedPDFError => e
      render json: { error: "Invalid PDF file: #{e.message}" }, status: :unprocessable_entity
    rescue => e
      Rails.logger.error "Error processing PDF: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: "Error processing file: #{e.message}" }, status: :unprocessable_entity
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

