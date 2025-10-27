
class LlmModelMap
  MODEL_MAP_OPENAI = {
    # OpenAI Models
    "gpt-4o" => "gpt-4o",
    "gpt-4o-mini" => "gpt-4o-mini",
    "gpt-4-turbo" => "gpt-4-turbo",
    "gpt-3-5-turbo" => "gpt-3.5-turbo",
    "gpt-3-5-turbo-16k" => "gpt-3.5-turbo-16k"
  }
  MODEL_MAP_ANTHROPIC = {
    # Anthropic Models
    "claude-opus-4-20250514" => "claude-opus-4-20250514",
    "claude-opus-4-1-20250513" => "claude-opus-4-1-20250513",
    "claude-sonnet-4-20250514" => "claude-sonnet-4-20250514",
    "claude-sonnet-4-5-20250929" => "claude-sonnet-4-5-20250929",
    "claude-3-5-sonnet-20241022" => "claude-3-5-sonnet-20241022",
    "claude-3-5-sonnet-20240620" =>  "claude-3-5-sonnet-20240620",
    "claude-3-5-haiku-20241022" => "claude-3-5-haiku-20241022",
    "claude-3-opus-20240229" => "claude-3-opus-20240229",
    "claude-3-sonnet-20240229" => "claude-3-sonnet-20240229",
    "claude-3-haiku-20240307" => "claude-3-haiku-20240307"
  }
  MODEL_MAP_GOOGLE = {
    # Google Gemini Models
    "gemini-2-5-pro" => "models/gemini-2.5-pro",
    "gemini-2-5-flash" => "models/gemini-2.5-flash",
    "gemini-2-5-flash-lite" => "models/gemini-2.5-flash-lite",
    "gemini-2-0-flash" => "models/gemini-2.0-flash",
    "gemini-2-0-flash-lite" => "models/gemini-2.0-flash-lite"
  }
  MODEL_MAP_OLLAMA = {
    # Ollama Models
    # :
  }

  MODEL_MAP = {
    "openai" => MODEL_MAP_OPENAI,
    "anthropic" => MODEL_MAP_ANTHROPIC,
    "google" => MODEL_MAP_GOOGLE,
    "ollama" => MODEL_MAP_OLLAMA
  }

  def self.fetch!(llm_type, meta_id) = MODEL_MAP.fetch(llm_type).fetch meta_id
end
