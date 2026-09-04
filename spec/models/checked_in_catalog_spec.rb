require "rails_helper"

# The suite seeds from spec/support/test_catalog.yml, not from the real
# catalog, so nothing else here would notice if config/llm_models.yml were
# malformed — and that file is what production reseeds from. This is the guard
# that keeps it honest: it must parse, and every entry it describes must be a
# valid LlmModel.
RSpec.describe "the checked-in catalog" do
  let(:path) { CatalogSeeder::CATALOG_PATH }
  let(:raw)  { YAML.safe_load_file(path, permitted_classes: [ Symbol, Date ]) }

  it "parses and describes at least one model per provider" do
    expect(raw).to be_a(Hash)
    expect(raw).not_to be_empty
    raw.each { |family, models| expect(models).not_to(be_empty, "#{family} has no models") }
  end

  it "describes only models that would save" do
    invalid = []

    raw.each do |family, models|
      llm = Llm.find_or_initialize_by(family: family) { |l| l.name = family.capitalize }

      models.each do |meta_id, attrs|
        record = LlmModel.new(
          llm: llm,
          name: meta_id,
          api_id: attrs["api_id"],
          display_name: attrs["display_name"],
          supports_vision: attrs["supports_vision"] == true,
          supports_tools: attrs["supports_tools"] == true,
          responses_only: attrs["responses_only"] == true,
          kind: attrs["kind"].presence,
          endpoint: attrs["endpoint"].presence,
          defaults: attrs["defaults"] || {},
          pricing: CatalogSeeder.stringify_dates(attrs["pricing"] || {})
        )
        # The uniqueness check would hit the seeded test catalog, which is a
        # different set of models; only the attribute validations matter here.
        record.valid?
        errors = record.errors.reject { |e| e.attribute == :name && e.type == :taken }
        invalid << "#{family}/#{meta_id}: #{errors.map(&:full_message).join(', ')}" if errors.any?
      end
    end

    expect(invalid).to be_empty, "invalid entries in #{path}:\n  #{invalid.join("\n  ")}"
  end

  it "gives every chargeable model a price" do
    unpriced = raw.except("ollama").flat_map do |family, models|
      models.reject { |_, a| a["kind"] == "image" }
            .reject { |_, a| a.dig("pricing", "input").to_f.positive? && a.dig("pricing", "output").to_f.positive? }
            .keys.map { |id| "#{family}/#{id}" }
    end

    expect(unpriced).to be_empty, "unpriced chargeable models: #{unpriced.join(', ')}"
  end
end
