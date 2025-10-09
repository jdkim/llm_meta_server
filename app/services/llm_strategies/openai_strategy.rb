require "llm"

class LlmStrategies::OpenaiStrategy
  def self.llm(encryptable_api_key)
    LLM.openai(key: encryptable_api_key.plain_api_key)
  end
end
