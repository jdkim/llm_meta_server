# frozen_string_literal: true

# Generates a paste-ready config/llm_models.yml entry for a model the provider
# reports but the catalog does not yet carry.
#
# Adding a model by hand means getting meta_id, display_name, the supports_*
# flags and the pricing block all right at once; a wrong guess is not caught
# until someone actually selects the model (see gpt-5.5-pro, which was hand
# written with supports_tools but no way to route tools). Scaffolding the
# mechanical parts leaves exactly one genuinely manual step: the two prices,
# which no provider exposes over an API.
class ModelCatalogScaffold
  PRICING_URLS = {
    "openai"    => "https://openai.com/api/pricing",
    "anthropic" => "https://www.anthropic.com/pricing#api",
    "google"    => "https://ai.google.dev/pricing"
  }.freeze

  # meta_id must be URL-safe: it appears in routes and favorites. The catalog
  # convention is the api_id with dots and colons flattened to dashes
  # (gpt-5.5-pro -> gpt-5-5-pro, qwen3.6:35b-fast -> qwen3-6-35b-fast).
  def self.meta_id_for(api_id)
    api_id.to_s.gsub(/[.:]/, "-")
  end

  ACRONYMS = { "gpt" => "GPT", "ai" => "AI" }.freeze

  # Combines the name derived from the api_id with the provider's own, which
  # is often a marketing name carrying no model identity ("Nano Banana 2
  # Lite"). The catalog convention is to keep both — "Gemini 3 Pro Image
  # (Nano Banana Pro)" — so a reader can tell which model it is *and*
  # recognise what the provider calls it.
  def self.display_name_with_provider(api_id, provider_name)
    derived = display_name_for(api_id)
    return derived if provider_name.blank?
    return derived if derived.casecmp?(provider_name.to_s.strip)
    return provider_name.to_s.strip if derived.casecmp?(provider_name.to_s.strip.delete("()"))

    "#{derived} (#{provider_name.to_s.strip})"
  end

  def self.display_name_for(api_id)
    api_id.to_s.split(/[-_]/).map { |part|
      ACRONYMS[part.downcase] || (part.match?(/\d/) ? part : part.capitalize)
    }.join(" ")
  end

  # Returns the YAML block as a String, indented to sit under the provider key.
  def self.entry_for(api_id, provider:, vision: true, tools: true, today: Date.today)
    meta_id = meta_id_for(api_id)
    lines = []
    lines << "  #{meta_id}:"
    lines << "    api_id: #{api_id}"
    lines << "    display_name: #{display_name_for(api_id)}"
    lines << "    supports_vision: #{vision}"
    lines << "    supports_tools: #{tools}"
    lines << "    # TODO verify both prices against #{PRICING_URLS[provider.to_s] || 'the provider pricing page'}"
    lines << "    # then run: bin/rails models:validate"
    lines << "    pricing:"
    lines << "      input: 0.00"
    lines << "      output: 0.00"
    lines << "      reviewed_at: #{today.iso8601}"
    lines.join("\n") + "\n"
  end
end
