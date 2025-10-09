class NotSupportedLlmError < StandardError
  def initialize(llm_type)
    super("Unsupported LLM type: #{llm_type}")
  end
end
