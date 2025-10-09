require "llm"

class LlmStrategies::AnthropicStrategy
  def self.llm(encryptable_api_key)
    LLM.anthropic(key: encryptable_api_key.plain_api_key)
  end
end
