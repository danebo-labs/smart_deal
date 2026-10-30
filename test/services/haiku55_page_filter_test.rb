# frozen_string_literal: true

require "test_helper"
require "stringio"

class Haiku55PageFilterTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  Page = Struct.new(:number, :binary, :text, :byte_size, keyword_init: true)

  class Reply
    def initialize(text)
      @content = [ OpenStruct.new(type: "text", text: text) ]
      @usage = OpenStruct.new(input_tokens: 10, output_tokens: 20)
    end

    attr_reader :content, :usage

    def stop_reason
      "end_turn"
    end
  end

  class RecordingClient
    attr_reader :calls

    def initialize(bodies)
      @bodies = bodies.dup
      @calls = []
    end

    def messages
      self
    end

    def create(**kwargs)
      @calls << kwargs
      body = @bodies.shift
      raise body if body.is_a?(Exception)

      Reply.new(body || pages_json(kwargs, true))
    end

    private

    def pages_json(kwargs, keep)
      numbers = page_numbers(kwargs)
      JSON.generate("pages" => numbers.map { |number| { "page" => number, "keep" => keep, "reason" => "technical" } })
    end

    def page_numbers(kwargs)
      Array(kwargs.dig(:messages, 0, :content)).filter_map do |block|
        block[:text][/Page (\d+):/, 1]&.to_i if block[:type].to_s == "text"
      end
    end
  end

  class FakeRenderer
    attr_reader :calls, :max_inflight

    def initialize(fail_on: [])
      @fail_on = fail_on
      @calls = []
      @mutex = Mutex.new
      @inflight = 0
      @max_inflight = 0
    end

    def render(page, directory)
      raise "render down" if @fail_on.include?(page.number)

      @mutex.synchronize do
        @inflight += 1
        @max_inflight = [ @max_inflight, @inflight ].max
      end
      sleep 0.02
      path = File.join(directory, format("visual-%04d.pdf", page.number))
      File.binwrite(path, "VISUAL-PAGE-#{page.number}")
      @mutex.synchronize { @calls << page.number }
      path
    ensure
      @mutex.synchronize { @inflight -= 1 if @inflight.positive? }
    end
  end

  setup do
    @flag = ENV["HAIKU55_PAGE_FILTER"]
    ENV.delete("HAIKU55_PAGE_FILTER")
  end

  teardown do
    if @flag.nil?
      ENV.delete("HAIKU55_PAGE_FILTER")
    else
      ENV["HAIKU55_PAGE_FILTER"] = @flag
    end
    Thread.current[:selective_page_renderer] = nil
  end

  test "the flag is off and the batch request stays on haiku 4.5" do
    pages = pdf_pages([ { text: prose }, { text: prose } ])
    renderer = FakeRenderer.new
    client = RecordingClient.new([ nil ])

    with_renderer(renderer) do
      without_tracking do |jobs|
        result = PageRelevanceFilter.filter_pages(pages: pages, filename: "off.pdf", haiku_client: client)

        assert_equal false, Haiku55PageFilterFlag.enabled?
        assert_empty renderer.calls
        assert_equal [ PageRelevanceFilter::HAIKU_MODEL ], client.calls.pluck(:model)
        assert_nil client.calls.first[:output_config]
        assert_nil client.calls.first[:thinking]
        assert_equal %i[max_tokens messages model system], client.calls.first.keys.sort
        assert_equal [ PageRelevanceFilter::HAIKU_TRACKING_MODEL_ID ], jobs
        assert_equal pages.map(&:binary), decoded_documents(client.calls.first)
        assert_equal false, result[1][:force_opus]
        assert_equal false, result[2][:force_opus]
      end
    end
  end

  test "text pages are visual copies and an adequate scan stays the original" do
    pages = pdf_pages([ { text: prose }, { image: true } ])
    before = pages.to_h { |page| [ page.number, Digest::SHA256.hexdigest(page.binary) ] }
    renderer = FakeRenderer.new
    client = RecordingClient.new([ nil ])

    with_flag do
      with_renderer(renderer) do
        without_tracking do |jobs|
          result = PageRelevanceFilter.filter_pages(pages: pages, filename: "mixto.pdf", haiku_client: client)
          documents = decoded_documents(client.calls.first)

          assert_equal [ 1 ], renderer.calls
          assert_equal Haiku55PageFilterFlag::MODEL, client.calls.first[:model]
          assert_equal({ effort: "low" }, client.calls.first[:output_config])
          assert_equal({ type: "disabled" }, client.calls.first[:thinking])
          assert_equal PageRelevanceFilter::BatchFilter::HAIKU_BATCH_SYSTEM, client.calls.first[:system]
          assert_equal "VISUAL-PAGE-1", documents[0]
          assert_equal pages[1].binary, documents[1]
          assert_not_includes documents[0], "borne conexion"
          assert_equal before, pages.to_h { |page| [ page.number, Digest::SHA256.hexdigest(page.binary) ] }
          assert_equal false, result[1][:force_opus]
          assert_equal true, result[2][:force_opus]
          assert_equal [ Haiku55PageFilterFlag::TRACKING_MODEL_ID ], jobs
          assert_empty temp_dirs
        end
      end
    end
  end

  test "a mixed page is visual and thin text on a dense image stays a scan" do
    pages = pdf_pages([
      { text: prose, image: true },
      { text: "Nota", image: true }
    ])

    mixed = SelectivePageRepresentation.decide(pages[0].binary)
    thin = SelectivePageRepresentation.decide(pages[1].binary)

    assert_equal :mixed_text, mixed.kind
    assert_equal :visual, mixed.representation
    assert_equal :adequate_scan, thin.kind
    assert_equal false, PageRelevanceFilter.scanned_dense?(pages[0].binary)
    assert_equal true, PageRelevanceFilter.scanned_dense?(pages[1].binary)
  end

  test "the safety guard reads the original text while haiku receives the visual copy" do
    pages = pdf_pages([
      { text: Array.new(2) { "Authorized personnel must lock out the drive before service. Do not restart until the fault is corrected." } },
      { text: prose }
    ])
    client = RecordingClient.new([ JSON.generate("pages" => [
      { "page" => 1, "keep" => false, "reason" => "preface" },
      { "page" => 2, "keep" => true, "reason" => "technical" }
    ]) ])

    with_flag do
      with_renderer(FakeRenderer.new) do
        without_tracking do
          result = PageRelevanceFilter.filter_pages(pages: pages, filename: "guarda.pdf", haiku_client: client)

          assert_equal "VISUAL-PAGE-1", decoded_documents(client.calls.first)[0]
          assert_equal true, result[1][:keep]
          assert_equal :safety_action_guard, result[1][:reason]
          assert_equal false, result[1][:force_opus]
          assert_equal true, result[2][:keep]
        end
      end
    end
  end

  test "a render failure keeps the page and still classifies the scan from the original" do
    pages = pdf_pages([ { text: prose }, { image: true } ])
    renderer = FakeRenderer.new(fail_on: [ 1 ])
    client = RecordingClient.new([ nil ])

    with_flag do
      with_renderer(renderer) do
        without_tracking do
          result = PageRelevanceFilter.filter_pages(pages: pages, filename: "fallo.pdf", haiku_client: client)

          assert_empty renderer.calls
          assert_equal [ 2 ], page_numbers(client.calls.first)
          assert_equal pages[1].binary, decoded_documents(client.calls.first).first
          assert_equal :visual_render_failed, result[1][:reason]
          assert_equal true, result[1][:keep]
          assert_equal false, result[1][:force_opus]
          assert_equal true, result[2][:keep]
          assert_equal true, result[2][:force_opus]
          assert_empty temp_dirs
        end
      end
    end
  end

  test "an api error keeps the window without turning on opus" do
    pages = pdf_pages([ { text: prose }, { image: true } ])
    client = RecordingClient.new([ StandardError.new("api down") ])

    with_flag do
      with_renderer(FakeRenderer.new) do
        without_tracking do
          result = PageRelevanceFilter.filter_pages(pages: pages, filename: "api.pdf", haiku_client: client)

          assert_equal 1, client.calls.size
          assert_equal :haiku_batch_error_fallback, result[1][:reason]
          assert_equal :haiku_batch_error_fallback, result[2][:reason]
          assert_not result[2][:force_opus]
          assert_empty temp_dirs
        end
      end
    end
  end

  test "malformed json retries once and a second failure keeps the pages" do
    pages = pdf_pages([ { text: prose }, { text: prose } ])
    client = RecordingClient.new([ "{", "{" ])

    with_flag do
      with_renderer(FakeRenderer.new) do
        without_tracking do
          result = PageRelevanceFilter.filter_pages(pages: pages, filename: "json.pdf", haiku_client: client)

          assert_equal 2, client.calls.size
          assert_equal client.calls.first[:max_tokens] * 2, client.calls.last[:max_tokens]
          assert_equal [ Haiku55PageFilterFlag::MODEL ], client.calls.pluck(:model).uniq
          assert_equal :haiku_batch_error_fallback, result[1][:reason]
          assert_equal true, result[1][:keep]
        end
      end
    end
  end

  test "twenty one visual pages use two windows and at most two renders at once" do
    pages = pdf_pages(Array.new(21) { { text: prose } })
    renderer = FakeRenderer.new
    client = RecordingClient.new([ nil, nil ])

    with_flag do
      with_renderer(renderer) do
        without_tracking do
          PageRelevanceFilter.filter_pages(pages: pages, filename: "ventanas.pdf", haiku_client: client)

          assert_equal [ (1..20).to_a, [ 21 ] ], client.calls.map { |call| page_numbers(call) }
          assert_equal (1..21).to_a, renderer.calls.sort
          assert_operator renderer.max_inflight, :<=, SelectivePageRepresentation::CONCURRENCY
          assert_operator renderer.max_inflight, :>=, 2
        end
      end
    end
  end

  test "a one page document stays on haiku 4.5 and is not rasterized" do
    pages = pdf_pages([ { text: "revisar el contactor del cuadro de maniobra y el rele" } ])
    renderer = FakeRenderer.new
    client = RecordingClient.new([ JSON.generate("keep" => true, "reason" => "technical") ])

    with_flag do
      with_renderer(renderer) do
        without_tracking do |jobs|
          result = PageRelevanceFilter.filter_pages(pages: pages, filename: "una.pdf", haiku_client: client)

          assert_empty renderer.calls
          assert_equal [ PageRelevanceFilter::HAIKU_MODEL ], client.calls.pluck(:model)
          assert_nil client.calls.first[:output_config]
          assert_equal [ PageRelevanceFilter::HAIKU_TRACKING_MODEL_ID ], jobs
          assert_equal true, result[1][:keep]
        end
      end
    end
  end

  test "an unreadable page and a blank page stay original" do
    assert_equal :analysis_error, SelectivePageRepresentation.decide("not a pdf").kind
    blank = pdf_pages([ {} ]).first
    assert_equal :no_text, SelectivePageRepresentation.decide(blank.binary).kind
  end

  test "a raised caller still deletes the temporary copies" do
    pages = pdf_pages([ { text: prose } ])
    before = temp_dirs

    assert_raises(RuntimeError) do
      with_renderer(FakeRenderer.new) do
        SelectivePageRepresentation.call(pages) { raise "boom" }
      end
    end
    assert_equal before, temp_dirs
  end

  test "libvips writes an image only copy at 200 dpi" do
    page = pdf_pages([ { text: prose } ]).first
    Dir.mktmpdir do |directory|
      path = SelectivePageRepresentation::Renderer.new.render(page, directory)
      raw = File.binread(path)
      image = Vips::Image.pdfload_buffer(raw, page: 0, dpi: SelectivePageRepresentation::DPI)

      assert_equal "", PageRelevanceFilter.extract_page_text(raw)
      assert_in_delta 1654, image.width, 4
      assert_in_delta 2339, image.height, 4
      assert_not_equal Digest::SHA256.hexdigest(page.binary), Digest::SHA256.hexdigest(raw)
    end
  end

  private

  def prose
    Array.new(8) { "borne conexion del contactor y del rele" }
  end

  def pdf_pages(specs)
    directory = Dir.mktmpdir("haiku55-src-")
    document = HexaPDF::Document.new
    png_path = nil
    specs.each do |spec|
      page = document.pages.add
      canvas = page.canvas
      Array(spec[:text]).each_with_index do |line, line_index|
        canvas.font("Helvetica", size: 11)
        canvas.text(line.to_s, at: [ 36, 800 - (line_index * 14) ])
      end
      next unless spec[:image]

      png_path ||= File.join(directory, "full.png").tap do |png|
        File.binwrite(png, Vips::Image.black(1000, 1000).write_to_buffer(".png"))
      end
      image = document.images.add(png_path)
      box = page.box(:media)
      canvas.image(image, at: [ 0, 0 ], width: box.width, height: box.height)
    end
    io = StringIO.new
    document.write(io, validate: false)
    pages = []
    PdfPageSplitterService.new(io.string).each_page do |number, binary|
      pages << Page.new(
        number: number,
        binary: binary,
        text: PageRelevanceFilter.extract_page_text(binary),
        byte_size: binary.bytesize
      )
    end
    pages
  ensure
    FileUtils.remove_entry(directory) if directory
  end

  def with_flag
    ENV["HAIKU55_PAGE_FILTER"] = "1"
    yield
  ensure
    ENV.delete("HAIKU55_PAGE_FILTER")
  end

  def with_renderer(renderer)
    previous = Thread.current[:selective_page_renderer]
    Thread.current[:selective_page_renderer] = renderer
    yield
  ensure
    Thread.current[:selective_page_renderer] = previous
  end

  def without_tracking
    calls = []
    original = TrackBedrockQueryJob.method(:perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**kwargs| calls << kwargs[:model_id] }
    yield calls
  ensure
    TrackBedrockQueryJob.define_singleton_method(:perform_later, original) if original
  end

  def decoded_documents(call)
    Array(call.dig(:messages, 0, :content)).filter_map do |block|
      next unless block[:type].to_s == "document"

      Base64.strict_decode64(block.dig(:source, :data).to_s)
    end
  end

  def page_numbers(call)
    Array(call.dig(:messages, 0, :content)).filter_map do |block|
      block[:text][/Page (\d+):/, 1]&.to_i if block[:type].to_s == "text"
    end
  end

  def temp_dirs
    Dir.children(Dir.tmpdir).grep(/\Adanebo-haiku55-page-/).sort
  end
end
