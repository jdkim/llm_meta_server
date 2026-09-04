require "rails_helper"

# CatalogExporter closes the loop the database move opened: the catalog is
# curated in the admin UI, and this writes the checked-in snapshot back out.
# The contract that matters is that its output survives a trip through
# CatalogSeeder unchanged — otherwise a "Reset from YAML" silently mutates
# the catalog it was supposed to restore.
RSpec.describe CatalogExporter do
  let(:path) { Rails.root.join("tmp", "catalog_exporter_spec.yml") }

  after { File.delete(path) if File.exist?(path) }

  def build_catalog!
    openai = Llm.find_or_create_by!(family: "openai") { |l| l.name = "Openai" }
    openai.llm_models.create!(
      name: "zeta-1", api_id: "zeta.1", display_name: "Zeta One",
      supports_vision: true, supports_tools: true, responses_only: true,
      endpoint: "responses", released_on: Date.new(2026, 7, 9),
      defaults: { "reasoning" => { "summary" => "auto" } },
      pricing: { "input" => 4.0, "output" => 20.0, "reviewed_at" => "2026-09-04", "verified" => false },
      notes: "Why this model is configured this way.\nSecond line.", position: 0
    )
    openai.llm_models.create!(
      name: "zeta-image", api_id: "zeta.image", display_name: "Zeta Image",
      kind: "image", pricing: { "per_image" => 0.0336 }, position: 1
    )
    openai
  end

  describe ".render" do
    before { build_catalog! }

    it "round-trips through CatalogSeeder without changing a single field" do
      before_state = LlmModel.includes(:llm).map do |m|
        [ m.llm.family, m.name, m.api_id, m.display_name, m.supports_vision, m.supports_tools,
          m.responses_only, m.kind, m.endpoint, m.defaults, m.pricing, m.notes, m.released_on ]
      end.sort_by { |row| row[0, 2] }

      File.write(path, described_class.render)
      LlmModel.delete_all
      CatalogSeeder.call(path: path)

      after_state = LlmModel.includes(:llm).map do |m|
        [ m.llm.family, m.name, m.api_id, m.display_name, m.supports_vision, m.supports_tools,
          m.responses_only, m.kind, m.endpoint, m.defaults, m.pricing, m.notes, m.released_on ]
      end.sort_by { |row| row[0, 2] }

      expect(after_state).to eq(before_state)
    end

    it "re-emits notes as the comment block CatalogSeeder reads back" do
      yaml = described_class.render

      expect(yaml).to include("  # Why this model is configured this way.\n  # Second line.\n  zeta-1:")
      expect(CatalogSeeder.extract_notes(yaml)[[ "openai", "zeta-1" ]])
        .to eq("Why this model is configured this way.\nSecond line.")
    end

    it "carries release dates, which the YAML used to drop on the floor" do
      expect(described_class.render).to include("released_on: 2026-07-09")

      File.write(path, described_class.render)
      LlmModel.delete_all
      CatalogSeeder.call(path: path)

      expect(LlmModel.find_by(name: "zeta-1").released_on).to eq(Date.new(2026, 7, 9))
    end

    it "orders chat models before image models, most expensive first" do
      yaml = described_class.render
      expect(yaml.index("zeta-1:")).to be < yaml.index("zeta-image:")
    end

    it "omits false flags and empty blocks rather than writing noise" do
      yaml = described_class.render

      expect(yaml).to include("  zeta-image:\n    api_id: zeta.image")
      expect(yaml).not_to include("supports_vision: false")
      expect(yaml).not_to include("defaults: {}")
    end

    it "leaves dates unquoted so they parse back as dates" do
      expect(described_class.render).to include("reviewed_at: 2026-09-04")
      expect(described_class.render).not_to include('reviewed_at: "2026-09-04"')
    end

    it "excludes hidden models — the snapshot is what users can actually pick" do
      LlmModel.find_by(name: "zeta-image").update!(active: false)

      expect(described_class.render).not_to include("zeta-image:")
    end

    it "produces a file CatalogSeeder can bootstrap an empty catalog from" do
      # Counts the whole seeded catalog, not just this spec's two models —
      # the export is of everything active, which is the point of a bootstrap.
      expected = LlmModel.active.count

      File.write(path, described_class.render)
      LlmModel.delete_all

      stats = CatalogSeeder.call(path: path)

      expect(stats[:created]).to eq(expected)
      expect(LlmModel.count).to eq(expected)
    end
  end

  describe ".scalar (private-ish: the quoting rule)" do
    # Nothing else pins this. If the rule is loosened, a display_name holding
    # ": " emits unquoted and the snapshot reparses into different data — or
    # fails to parse — which would surface only during a restore.
    {
      "GPT-5: Pro"        => '"GPT-5: Pro"',      # colon-space starts a mapping
      "3.5 Turbo"         => '"3.5 Turbo"',       # leading digit reads as a number
      "yes"               => '"yes"',             # YAML 1.1 boolean
      "  padded"          => '"  padded"',        # leading whitespace is lost bare
      "a # b"             => '"a # b"',           # starts a comment
      "trailing:"         => '"trailing:"',       # trailing colon starts a key
      ""                  => '""',                # empty would vanish
      "o3-mini"           => "o3-mini",           # safe, stays bare
      "Nano Banana (Pro)" => "Nano Banana (Pro)", # parens are safe in YAML
      "2026-09-04"        => "2026-09-04"         # bare, so it parses back as a Date
    }.each do |input, expected|
      it "renders #{input.inspect} as #{expected}" do
        expect(described_class.scalar(input)).to eq(expected)
      end
    end

    it "round-trips a hostile display_name through YAML unchanged" do
      llm = Llm.find_or_create_by!(family: "openai") { |l| l.name = "Openai" }
      llm.llm_models.create!(name: "hostile-1", api_id: "hostile.1",
                             display_name: "GPT-5: Pro", pricing: { "input" => 1.0, "output" => 2.0 })

      parsed = YAML.safe_load(described_class.render, permitted_classes: [ Symbol, Date ])

      expect(parsed.dig("openai", "hostile-1", "display_name")).to eq("GPT-5: Pro")
    end
  end

  describe "idempotence" do
    before { build_catalog! }

    it "a second export of the same catalog is byte-identical" do
      first = described_class.render

      File.write(path, first)
      LlmModel.delete_all
      CatalogSeeder.call(path: path)

      expect(described_class.render).to eq(first)
    end
  end

  describe ".call" do
    before { build_catalog! }

    it "writes to the given path and returns it" do
      expect(described_class.call(path: path)).to eq(path)
      expect(File.read(path)).to include("GENERATED FILE, do not hand-edit")
    end

    it "defaults to the catalog path — and refuses it when that is the suite's fixture" do
      expect { described_class.call }
        .to raise_error(described_class::ProtectedPath, /#{Regexp.escape(CatalogSeeder.catalog_path.to_s)}/)
    end

    it "leaves the pinned fixture untouched when it refuses" do
      before_bytes = File.read(CatalogSeeder.catalog_path)

      expect { described_class.call }.to raise_error(described_class::ProtectedPath)

      expect(File.read(CatalogSeeder.catalog_path)).to eq(before_bytes)
    end
  end
end
