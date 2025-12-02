class LlmApiKeyRequiredError < StandardError
  def initialize(model_id)
    super("LLM API key is required for paid model: #{model_id}")
  end
end

