require "llm"
class LlmAdapter
  def initialize(llm_type, encryptable_api_key)
    @llm_strategy = select_strategy llm_type
    @encryptable_api_key = encryptable_api_key
  end

  def call(model_name, prompt)
    llm = @llm_strategy.llm

    model_id = model_id(llm, model_name)
    bot  = LLM::Bot.new(llm, model: model_id)
    messages = bot.chat do |_prompt|
      _prompt.user prompt
    end

    messages.map { _1.content }.join("\n")
  end

  private

  def model_id(llm, model_name)
    model = llm.models.all.find { |m| m.id == model_name }
    raise ModelNotFoundError.new(model_name) unless model

    model.id
  end

  def select_strategy(llm_type)
    case llm_type
    when "ollama"
      LlmStrategies::OllamaStrategy.llm @encryptable_api_key
    when "openai"
      LlmStrategies::OpenaiStrategy.llm @encryptable_api_key
    when "anthropic"
      LlmStrategies::AnthropicStrategy.llm @encryptable_api_key
    when "google"
      LlmStrategies::GoogleStrategy.llm @encryptable_api_key
    else
      raise NotSupportedLlmError.new(llm_type)
    end
  end
end
