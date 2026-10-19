class AddMaxInputTokensToLlmModels < ActiveRecord::Migration[8.0]
  # The hub knew a local model's window (the catalog's `options.num_ctx`) but
  # nothing about a hosted one, so `context_window` returned 0 and every
  # protection keyed to it switched off: no pre-flight check, no truncation
  # detection, and an overflow message that would have read "window of 0
  # tokens". A visitor saw the provider's own words instead — "Input length
  # (157358) exceeds model's maximum context length (131072)".
  #
  # The number is already in reach: PricingReference downloads LiteLLM's
  # model_prices_and_context_window.json, which carries max_input_tokens beside
  # the prices this column's neighbour already keeps.
  def change
    add_column :llm_models, :max_input_tokens, :integer
  end
end
