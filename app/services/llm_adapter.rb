require "llm"
class LlmAdapter
  def self.call(llm_type, encryptable_api_key, model_name, prompt)
    llm = select_llm llm_type, encryptable_api_key
    model_id = model_id(llm, model_name)

    bot  = LLM::Bot.new(llm, model: model_id)
    messages = bot.chat do |_prompt|
      _prompt.user prompt
    end

    messages.map { _1.content }.join("\n")
  end

  private

  def self.model_id(llm, model_name)
    model = llm.models.all.find { |m| m.id == model_name }
    raise ModelNotFoundError.new(model_name) unless model

    model.id
  end

  def self.select_llm(llm_type, encryptable_api_key)
    case llm_type
    when "ollama"
      LlmStrategies::OllamaStrategy.llm encryptable_api_key
    when "openai"
      LlmStrategies::OpenaiStrategy.llm encryptable_api_key
    when "anthropic"
      LlmStrategies::AnthropicStrategy.llm encryptable_api_key
    when "google"
      LlmStrategies::GoogleStrategy.llm encryptable_api_key
    else
      raise NotSupportedLlmError.new(llm_type)
    end
  end
end
