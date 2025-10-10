class ModelNotFoundError < StandardError
  def initialize(model_name)
    super("Model not found: #{model_name}")
  end
end
