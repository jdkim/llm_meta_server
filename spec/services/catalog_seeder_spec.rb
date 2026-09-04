require "rails_helper"

# CatalogSeeder is the production cutover path: it moves config/llm_models.yml
# into the database, and prod boots with an empty catalog if it never runs.
# It also has to carry the YAML's comments across — those record why entries
# look the way they do, and a plain YAML.load drops them silently.
RSpec.describe CatalogSeeder do
  let(:path) { Rails.root.join("tmp", "catalog_seeder_spec.yml") }

  let(:yaml) do
    <<~YML
      testprov:
        # Why this model is configured the way it is.
        # Second line of the same note.
        alpha-1:
          api_id: alpha.1
          display_name: Alpha One
          supports_vision: true
          supports_tools: true
          endpoint: responses
          responses_only: true
          defaults:
            think: false
            options:
              num_ctx: 4096
          pricing:
            input: 1.5
            output: 6.0
            reviewed_at: 2026-07-21
        beta-2:
          api_id: beta.2
          display_name: Beta Two
          # A note that lives inside the model's own block.
          pricing:
            input: 0.5
            output: 2.0
    YML
  end

  before { File.write(path, yaml) }
  after  { FileUtils.rm_f(path) }

  def model(name) = LlmModel.joins(:llm).find_by(llms: { family: "testprov" }, name: name)

  describe ".call" do
    it "creates the provider and its models" do
      stats = described_class.call(path: path)

      expect(stats[:created]).to eq(2)
      expect(Llm.find_by(family: "testprov")).to be_present
      expect(model("alpha-1").api_id).to eq("alpha.1")
    end

    it "carries every catalog field across, not just the names" do
      described_class.call(path: path)
      m = model("alpha-1")

      expect(m.supports_vision).to be(true)
      expect(m.supports_tools).to be(true)
      expect(m.responses_only).to be(true)
      expect(m.endpoint).to eq("responses")
      expect(m.defaults).to eq("think" => false, "options" => { "num_ctx" => 4096 })
    end

    it "stores reviewed_at as a string so it round-trips through jsonb" do
      described_class.call(path: path)

      # YAML parses an unquoted date into a Date, which jsonb would not
      # return in the same shape.
      expect(model("alpha-1").pricing["reviewed_at"]).to eq("2026-07-21")
    end

    it "keeps the file's ordering, so the picker is not reordered arbitrarily" do
      described_class.call(path: path)

      expect(model("alpha-1").position).to eq(0)
      expect(model("beta-2").position).to eq(1)
    end
  end

  describe "comment extraction" do
    it "captures the comment block above a model" do
      described_class.call(path: path)

      expect(model("alpha-1").notes).to include("Why this model is configured")
      expect(model("alpha-1").notes).to include("Second line of the same note")
    end

    it "captures comments inside a model's own block" do
      described_class.call(path: path)

      expect(model("beta-2").notes).to include("lives inside the model's own block")
    end

    it "leaves notes nil for a model with no comments" do
      File.write(path, "testprov:\n  plain-1:\n    api_id: plain.1\n    display_name: Plain\n    pricing:\n      input: 1.0\n      output: 2.0\n")
      described_class.call(path: path)

      expect(model("plain-1").notes).to be_nil
    end
  end

  describe "idempotence" do
    it "updates in place on a second run rather than duplicating" do
      described_class.call(path: path)
      id = model("alpha-1").id

      stats = described_class.call(path: path)

      expect(stats[:created]).to eq(0)
      expect(stats[:updated]).to eq(2)
      expect(model("alpha-1").id).to eq(id)
    end

    it "keeps the meta_id stable, so favourites and routes keep resolving" do
      described_class.call(path: path)
      described_class.call(path: path)

      expect(LlmModel.joins(:llm).where(llms: { family: "testprov" }).pluck(:name))
        .to contain_exactly("alpha-1", "beta-2")
    end

    it "applies edited values from the file" do
      described_class.call(path: path)
      File.write(path, yaml.sub("input: 1.5", "input: 9.9"))

      described_class.call(path: path)

      expect(model("alpha-1").pricing["input"]).to eq(9.9)
    end
  end

  describe "pruning" do
    it "removes models the file no longer lists when asked" do
      described_class.call(path: path)
      File.write(path, yaml.sub(/^  beta-2:.*\z/m, ""))

      stats = described_class.call(path: path, prune: true)

      expect(stats[:pruned]).to eq(1)
      expect(model("beta-2")).to be_nil
      expect(model("alpha-1")).to be_present
    end

    it "leaves them alone by default — the UI reseed must not delete silently" do
      described_class.call(path: path)
      File.write(path, yaml.sub(/^  beta-2:.*\z/m, ""))

      described_class.call(path: path)

      expect(model("beta-2")).to be_present
    end
  end

  it "makes the seeded catalog visible through LlmModelMap" do
    described_class.call(path: path)
    LlmModelMap.reload!

    expect(LlmModelMap.catalog.dig("testprov", "alpha-1", :api_id)).to eq("alpha.1")
  end
end
