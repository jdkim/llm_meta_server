
class LlmModelMap
  MODEL_MAP = {
    # OpenAI Models
    "gpt-4o" => "gpt-4o",
    "gpt-4o-mini" => "gpt-4o-mini",
    "gpt-4-turbo" => "gpt-4-turbo",
    "gpt-3-5-turbo" => "gpt-3.5-turbo",
    "gpt-3-5-turbo-16k" => "gpt-3.5-turbo-16k",

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
    "claude-3-haiku-20240307" => "claude-3-haiku-20240307",

    # Google Gemini Models
    "gemini-2-5-pro" => "models/gemini-2.5-pro",
    "gemini-2-5-flash" => "models/gemini-2.5-flash",
    "gemini-2-5-flash-lite" => "models/gemini-2.5-flash-lite",
    "gemini-2-0-flash" => "models/gemini-2.0-flash",
    "gemini-2-0-flash-lite" => "models/gemini-2.0-flash-lite"

    # Ollama Models
    # :
  }

  def self.fetch!(meta_id) = MODEL_MAP.fetch meta_id
end
