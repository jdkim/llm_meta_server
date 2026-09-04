# frozen_string_literal: true

# Writes config/llm_models.yml from the live `llm_models` table.
#
# The catalog moved into the database (see CatalogSeeder), which left the YAML
# as a snapshot rather than a source. Snapshots go stale: twice in one session
# the file disagreed with production, which quietly turns the admin UI's
# "Reset from YAML" into a way to resurrect models someone had just retired.
# Exporting closes that loop — curate in the UI, then regenerate the file.
#
# The output is meant to round-trip through CatalogSeeder unchanged, comments
# included: each model's `notes` are re-emitted as the comment block above its
# key, which is exactly where extract_notes looks for them.
class CatalogExporter
  HEADER = <<~YML
    # LLM catalog snapshot — GENERATED FILE, do not hand-edit.
    #
    # The live catalog is the `llm_models` table, curated at /admin/models.
    # This file is a checked-in snapshot of it, used to
    #   * bootstrap a deployment whose catalog table is still empty, and
    #   * roll back, via "Reset from YAML" in the admin UI.
    #
    # Regenerate it after curating models, so the snapshot stays honest:
    #   bin/rails models:export
    #
    # Comments above a model are its `notes` column; edit them in the admin UI
    # rather than here, or the next export will overwrite them.
    #
    # Schema per entry:
    #   meta_id:                     # URL-safe ID (no dots/colons). Used in URLs + favorites.
    #     api_id:         <string>   # Real provider model ID (with dots/colons).
    #     display_name:   <string>   # UI label.
    #     supports_vision: <bool>    # Omitted when false.
    #     supports_tools:  <bool>    # Omitted when false.
    #     responses_only:  <bool>    # Omitted when false. Model exists only on OpenAI's Responses API.
    #     kind:           <string>   # `image` for image-generation models.
    #     endpoint:       <string>   # `responses` routes OpenAI through llm.responses.create.
    #     released_on:    <date>     # Provider's release date, when known.
    #     defaults:       <hash>     # Per-request kwargs merged UNDER user params.
    #     pricing:                   # REQUIRED for chargeable models (not ollama, not kind: image).
    #       input:      <float>      # USD per 1M input tokens.
    #       output:     <float>      # USD per 1M output tokens.
    #       per_image:  <float>      # USD per image, for kind: image.
    #       reviewed_at: <YYYY-MM-DD> # When these values were last checked.
    #
    # Validate with: bin/rails models:validate
  YML

  # Providers in the order the file has always listed them; anything new sorts
  # after these, alphabetically, rather than by insertion accident.
  FAMILY_ORDER  = %w[openai anthropic google ollama].freeze
  PRICING_ORDER = %w[input output per_image reviewed_at source verified].freeze

  # Raised rather than overwriting the catalog the suite itself seeds from.
  class ProtectedPath < StandardError; end

  def self.call(path: CatalogSeeder.catalog_path)
    guard_suite_catalog!(path)
    File.write(path, render)
    path
  end

  # In the test environment CatalogSeeder.catalog_path is the pinned fixture
  # every example is seeded from (spec/support/test_catalog.yml). Exporting
  # onto it would replace that fixture with whatever the test database held at
  # the time, silently changing what the whole suite sees — and it would show
  # up only as a puzzling git diff. Specs must pass an explicit path.
  def self.guard_suite_catalog!(path)
    return unless Rails.env.test?
    return unless path.to_s == Rails.configuration.x.catalog_path.to_s

    raise ProtectedPath,
          "refusing to export onto the suite's pinned catalog (#{path}) — pass an explicit path"
  end

  def self.render
    out = [ HEADER.rstrip, "" ]

    families.each do |llm|
      models = LlmModel.catalog_order(llm.llm_models.select(&:active?))
      next if models.empty?

      out << "#{llm.family}:"
      models.each { |model| out.concat(render_model(model)) }
      out << ""
    end

    out.join("\n").rstrip + "\n"
  end

  def self.families
    Llm.includes(:llm_models).to_a.sort_by do |llm|
      [ FAMILY_ORDER.index(llm.family) || FAMILY_ORDER.size, llm.family.to_s ]
    end
  end

  def self.render_model(model)
    lines = model.notes.to_s.split("\n").map { |note| note.empty? ? "  #" : "  # #{note}" }

    lines << "  #{model.name}:"
    lines << "    api_id: #{scalar(model.api_id)}"
    lines << "    display_name: #{scalar(model.display_name)}"
    lines << "    supports_vision: true" if model.supports_vision?
    lines << "    supports_tools: true"  if model.supports_tools?
    lines << "    responses_only: true"  if model.responses_only?
    lines << "    kind: #{scalar(model.kind)}"             if model.kind.present?
    lines << "    endpoint: #{scalar(model.endpoint)}"     if model.endpoint.present?
    lines << "    released_on: #{model.released_on.iso8601}" if model.released_on.present?

    if model.defaults.present?
      lines << "    defaults:"
      lines << emit(model.defaults, 3)
    end

    if model.pricing.present?
      lines << "    pricing:"
      keys = (PRICING_ORDER & model.pricing.keys) + (model.pricing.keys - PRICING_ORDER)
      keys.each { |key| lines << "      #{key}: #{fmt(model.pricing[key])}" }
    end

    lines
  end

  # Nested hashes (defaults:) at an arbitrary depth.
  def self.emit(value, indent)
    pad = "  " * indent
    value.map do |key, val|
      val.is_a?(Hash) && val.any? ? "#{pad}#{key}:\n#{emit(val, indent + 1)}" : "#{pad}#{key}: #{fmt(val)}"
    end.join("\n")
  end

  def self.fmt(value)
    case value
    when Float            then value == value.round(2) ? format("%.2f", value) : value.to_s
    when true, false, Integer then value.to_s
    when nil              then "~"
    else scalar(value)
    end
  end

  # Quote only when YAML would otherwise misread the string. Dates are left
  # bare so they parse back as Date, which is what CatalogSeeder expects.
  def self.scalar(value)
    string = value.to_s
    return string if string.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    risky = string.empty? ||
            string.match?(/\A[\s>|*&!%@`\[\]{},"']/) ||
            string.match?(/:\s/) || string.end_with?(":") ||
            string.match?(/\A(true|false|null|yes|no|on|off|~)\z/i) ||
            string.match?(/\A-?\d/) || string.include?(" #")
    risky ? string.inspect : string
  end
end
