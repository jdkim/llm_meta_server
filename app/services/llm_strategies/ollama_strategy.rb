require "llm"

class LlmStrategies::OllamaStrategy
  def self.llm(encryptable_api_key)
    LLM.ollama(key: encryptable_api_key.plain_api_key)
  end
end
