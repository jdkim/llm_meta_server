require "llm"

class LlmStrategies::GoogleStrategy
  def self.llm(encryptable_api_key)
    LLM.gemini(key: encryptable_api_key.plain_api_key)
  end
end
