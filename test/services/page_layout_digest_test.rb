require "test_helper"

class PageLayoutDigestTest < ActiveSupport::TestCase
  test "renders nil when there is nothing to say" do
    assert_nil PageLayoutDigest.render({ words: [], images: [] }, [])
  end

  test "renders the image inventory (size_class + bbox) when under the token cap" do
    layout = { images: [
      { name: "Im1", width: 100, height: 80, bbox: [ 1, 2, 3, 4 ], size_class: :small }
    ] }

    digest = PageLayoutDigest.render(layout, [])

    assert_includes digest, "Im1"
    assert_includes digest, "small"
    assert_includes digest, "[1, 2, 3, 4]"
  end

  test "renders resolved edges with their labels' bboxes, not a dump of every word" do
    layout = {
      words: [
        { text: "LIMITADOR", bbox: [ 1, 2, 3, 4 ] },
        { text: "CONECTOR AI", bbox: [ 5, 6, 7, 8 ] },
        { text: "UNRELATED LABEL", bbox: [ 9, 9, 9, 9 ] }
      ],
      images: []
    }
    edges = [ { from: "LIMITADOR", to: "CONECTOR AI", method: :leader_line, evidence: "polilínea…" } ]

    digest = PageLayoutDigest.render(layout, edges)

    assert_includes digest, "LIMITADOR -> CONECTOR AI"
    assert_includes digest, "[1, 2, 3, 4]"
    assert_includes digest, "[5, 6, 7, 8]"
    assert_not_includes digest, "UNRELATED LABEL"
  end

  test "returns nil when the digest would exceed the 400-token cap" do
    huge_images = Array.new(200) do |i|
      { name: "Im#{i}", width: 10, height: 10, bbox: [ i, i, i + 1, i + 1 ], size_class: :small }
    end

    digest = PageLayoutDigest.render({ images: huge_images }, [])

    assert_nil digest
  end

  test "stays under the cap for a realistic page (~12 edges, per the plan's own budget)" do
    edges = Array.new(12) do |i|
      { from: "LABEL#{i}", to: "CONECTOR#{i % 2}", method: :leader_line, evidence: "short evidence #{i}" }
    end
    words = edges.flat_map { |e| [ e[:from], e[:to] ] }.uniq.map { |t| { text: t, bbox: [ 0, 0, 1, 1 ] } }

    digest = PageLayoutDigest.render({ words: words, images: [] }, edges)

    assert digest.present?
  end
end
