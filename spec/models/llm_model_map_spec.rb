require "rails_helper"

# Direct tests for the model-catalog switchboard. Every chat request runs
# through `fetch!`, and the vision/image-gen gating runs through the
# predicate methods, so the semantics here are load-bearing across the
# whole API surface.
#
# Two implementation details worth pinning:
#
#   * `llm_type: nil` defaults to "ollama" — that's how the anonymous
#     fallback path resolves models when no API key is bound.
#   * `fetch!` currently raises NoMethodError (not a typed error) when the
#     meta_id isn't in the map. That's a real fragility — see the comment
#     on the relevant example. Pinning the behavior here means any future
#     swap to a typed error (ModelNotFoundError) is intentional.
RSpec.describe LlmModelMap do
  describe ".fetch!" do
    it "returns the provider api_id for a known meta_id + llm_type" do
      expect(described_class.fetch!("gpt-5", llm_type: "openai")).to eq("gpt-5")
      expect(described_class.fetch!("claude-opus-4-7", llm_type: "anthropic")).to eq("claude-opus-4-7")
    end

    it "translates between meta_id (no dots) and the provider's api_id (with dots/colons)" do
      # qwen3-6-35b-fast in our catalog → "qwen3.6:35b-fast" sent to Ollama
      expect(described_class.fetch!("qwen3-6-35b-fast", llm_type: "ollama")).to eq("qwen3.6:35b-fast")
      expect(described_class.fetch!("gemini-2-5-pro", llm_type: "google")).to eq("gemini-2.5-pro")
    end

    it "defaults to the ollama family when llm_type is nil (anonymous fallback path)" do
      expect(described_class.fetch!("qwen3-6-35b-fast")).to eq("qwen3.6:35b-fast")
    end

    it "treats llm_type: 'ollama' the same as llm_type: nil" do
      expect(described_class.fetch!("qwen3-6-35b-fast", llm_type: "ollama"))
        .to eq(described_class.fetch!("qwen3-6-35b-fast"))
    end

    it "raises ModelNotFoundError for an unknown meta_id under a known llm_type" do
      expect { described_class.fetch!("not-a-model", llm_type: "openai") }
        .to raise_error(ModelNotFoundError, /not-a-model/)
    end

    it "raises ModelNotFoundError when meta_id exists but under a different llm_type" do
      # gpt-5 exists in the openai map; asking for it under anthropic should miss cleanly.
      expect { described_class.fetch!("gpt-5", llm_type: "anthropic") }
        .to raise_error(ModelNotFoundError, /gpt-5/)
    end

    it "raises ModelNotFoundError for an unknown llm_type" do
      expect { described_class.fetch!("gpt-5", llm_type: "bogus") }
        .to raise_error(ModelNotFoundError, /gpt-5/)
    end
  end

  describe ".available_models_for" do
    it "returns label/value plus capability flags for a known family" do
      openai = described_class.available_models_for("openai")
      gpt5 = openai.find { |m| m["value"] == "gpt-5" }

      expect(gpt5).to eq(
        "label" => "GPT-5",
        "value" => "gpt-5",
        "supports_vision" => true,
        "supports_tools" => true
      )
    end

    it "emits `kind` only for non-chat models so the frontend doesn't have to filter nils" do
      google = described_class.available_models_for("google")
      image_models, chat_models = google.partition { |m| m["value"].end_with?("-image") }
      expect(chat_models).to all(satisfy { |m| !m.key?("kind") })
      expect(image_models).to all(include("kind" => "image"))
    end

    it "supports_vision/_tools coerce to strict booleans (never nil)" do
      described_class.available_models_for("ollama").each do |m|
        %w[supports_vision supports_tools].each do |k|
          expect(m[k]).to satisfy { |v| v == true || v == false },
            "#{m['value']} has non-boolean #{k}: #{m[k].inspect}"
        end
      end
    end

    it "raises KeyError for an unknown family (Hash#fetch semantics)" do
      expect { described_class.available_models_for("bogus") }.to raise_error(KeyError)
    end
  end

  describe ".ollama_model?" do
    it "is true for any ollama api_id in the catalog" do
      # Pick the api_ids dynamically so this stays green across catalog edits.
      api_ids = LlmModelMap::MODEL_MAP.fetch("ollama").values.map { |m| m[:api_id] }
      api_ids.each do |id|
        expect(described_class.ollama_model?(id)).to be(true), "#{id} should be recognized"
      end
    end

    it "is false for an api_id from a different family" do
      expect(described_class.ollama_model?("gpt-5")).to be(false)
      expect(described_class.ollama_model?("claude-opus-4-7")).to be(false)
    end

    it "is false for an unknown id" do
      expect(described_class.ollama_model?("totally-fake")).to be(false)
    end

    it "is false for nil" do
      expect(described_class.ollama_model?(nil)).to be(false)
    end
  end

  describe ".image_model?" do
    it "is true when the model has kind: :image" do
      expect(described_class.image_model?("gemini-3-pro-image", llm_type: "google")).to be(true)
      expect(described_class.image_model?("gemini-2-5-flash-image", llm_type: "google")).to be(true)
    end

    it "is false for non-image models in the same family" do
      # Pick a non-image google model dynamically so this stays green
      # across catalog edits.
      non_image_google = LlmModelMap::MODEL_MAP.fetch("google")
                                                .reject { |_, info| info[:kind].to_s == "image" }
                                                .keys.first
      expect(described_class.image_model?(non_image_google, llm_type: "google")).to be(false)
    end

    it "is false for an unknown meta_id (does NOT raise — used in vision-gating before fetch!)" do
      expect(described_class.image_model?("not-a-model", llm_type: "google")).to be(false)
    end

    it "defaults to the ollama family when llm_type is nil" do
      # No ollama image model in the catalog, so this should always be false.
      expect(described_class.image_model?("qwen3-6-35b-fast")).to be(false)
    end
  end

  describe ".supports_vision?" do
    it "is true for explicitly vision-capable models" do
      expect(described_class.supports_vision?("gpt-5", llm_type: "openai")).to be(true)
      expect(described_class.supports_vision?("claude-opus-4-7", llm_type: "anthropic")).to be(true)
      expect(described_class.supports_vision?("qwen3-6-35b", llm_type: "ollama")).to be(true)
    end

    it "is false for an unknown meta_id (does NOT raise — vision-gating runs before fetch!)" do
      expect(described_class.supports_vision?("not-a-model", llm_type: "openai")).to be(false)
      expect(described_class.supports_vision?("not-a-model", llm_type: "ollama")).to be(false)
    end

    it "defaults to the ollama family when llm_type is nil" do
      expect(described_class.supports_vision?("qwen3-6-35b")).to be(true)
      # Unknown meta_id under the ollama default also returns false.
      expect(described_class.supports_vision?("not-a-model")).to be(false)
    end
  end

  describe ".supports_tools?" do
    it "is true for models flagged supports_tools: true" do
      expect(described_class.supports_tools?("gpt-5", llm_type: "openai")).to be(true)
      expect(described_class.supports_tools?("claude-sonnet-4-6", llm_type: "anthropic")).to be(true)
      expect(described_class.supports_tools?("gemini-2-5-pro", llm_type: "google")).to be(true)
    end

    it "is false for image-gen models and for unknown meta_ids" do
      expect(described_class.supports_tools?("gemini-2-5-flash-image", llm_type: "google")).to be(false)
      expect(described_class.supports_tools?("not-a-model", llm_type: "openai")).to be(false)
    end
  end

  describe ".defaults_for" do
    it "returns the catalog's per-model defaults block (symbol-keyed)" do
      defaults = described_class.defaults_for("qwen3-6-35b-fast", llm_type: "ollama")
      # qwen3.6 ignores the SYSTEM /no_think text directive, so the catalog
      # pins think: false as the per-request default for this tag. Plus the
      # Ollama-wide num_ctx: 32768 override.
      expect(defaults).to eq(think: false, options: { num_ctx: 32768 })
    end

    it "returns an empty hash when the model has no defaults declared" do
      # claude-haiku-4-5 has no defaults (Anthropic rejected adaptive
      # thinking on Haiku, so no thinking config is declared until a
      # working shape is confirmed).
      expect(described_class.defaults_for("claude-haiku-4-5", llm_type: "anthropic")).to eq({})
    end

    it "returns Ollama's num_ctx override for qwen3-6-35b (32K, was silently 2048)" do
      expect(described_class.defaults_for("qwen3-6-35b", llm_type: "ollama"))
        .to eq(options: { num_ctx: 32768 })
    end

    it "returns Ollama's num_ctx override for medgemma1-5-4b" do
      expect(described_class.defaults_for("medgemma1-5-4b", llm_type: "ollama"))
        .to eq(options: { num_ctx: 32768 })
    end

    it "returns an empty hash for an unknown meta_id (does NOT raise)" do
      expect(described_class.defaults_for("not-a-model", llm_type: "ollama")).to eq({})
    end

    it "defaults to the ollama family when llm_type is nil" do
      # Ollama models all set `options.num_ctx: 32768` in the catalog; qwen3-6-35b-fast
      # additionally has `think: false`. Assert both are present.
      out = described_class.defaults_for("qwen3-6-35b-fast")
      expect(out[:think]).to eq(false)
      expect(out.dig(:options, :num_ctx)).to eq(32768)
    end

    it "returns the per-model thinking shape for Claude Opus 4.7 and Sonnet 4.6 (adaptive)" do
      expect(described_class.defaults_for("claude-opus-4-7", llm_type: "anthropic"))
        .to eq(thinking: { type: "adaptive" })
      expect(described_class.defaults_for("claude-sonnet-4-6", llm_type: "anthropic"))
        .to eq(thinking: { type: "adaptive" })
    end
  end

  describe ".endpoint_for" do
    it "returns 'responses' for OpenAI reasoning models marked with endpoint: responses in the catalog" do
      expect(described_class.endpoint_for("gpt-5", llm_type: "openai")).to eq("responses")
      expect(described_class.endpoint_for("gpt-5-mini", llm_type: "openai")).to eq("responses")
    end

    it "defaults to 'chat_completions' for models without an explicit endpoint" do
      expect(described_class.endpoint_for("claude-opus-4-7", llm_type: "anthropic")).to eq("chat_completions")
      expect(described_class.endpoint_for("qwen3-6-35b-fast", llm_type: "ollama")).to eq("chat_completions")
    end

    it "returns 'chat_completions' for an unknown meta_id (safe default for the dispatch)" do
      expect(described_class.endpoint_for("not-a-model", llm_type: "openai")).to eq("chat_completions")
    end
  end

  describe "catalog integrity" do
    it "every entry has at least the keys :api_id and :display_name" do
      LlmModelMap::MODEL_MAP.each do |family, entries|
        entries.each do |meta_id, info|
          expect(info).to include(:api_id, :display_name),
            "#{family}/#{meta_id} is missing :api_id or :display_name"
          expect(info[:api_id]).to be_a(String).and(be_present)
          expect(info[:display_name]).to be_a(String).and(be_present)
        end
      end
    end

    it "every image-gen entry also has supports_vision: true (image models accept image input)" do
      LlmModelMap::MODEL_MAP.each_value do |entries|
        entries.each do |meta_id, info|
          next unless info[:kind] == :image
          expect(info[:supports_vision]).to be(true),
            "image model #{meta_id} must also have supports_vision: true"
        end
      end
    end
  end
end
