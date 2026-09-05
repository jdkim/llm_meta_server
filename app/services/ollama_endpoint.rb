# frozen_string_literal: true

# Where this application's Ollama lives.
#
# Reads AIBRANCH_OLLAMA_* in preference to the bare OLLAMA_* names, because
# OLLAMA_HOST is also the variable the `ollama` CLI reads. On the machine that
# hosts both, a developer's shell exports OLLAMA_HOST to point the CLI at the
# *shared* instance — and since dotenv never overwrites an existing variable,
# that export silently outranked the app's own .env and sent AIbranch to the
# wrong server. The failure was invisible: the .env said one thing, the app
# did another.
#
# The bare names remain as a fallback so existing deployments keep working.
class OllamaEndpoint
  DEFAULT_HOST = "127.0.0.1"
  DEFAULT_PORT = "11434"

  def self.host
    ENV["AIBRANCH_OLLAMA_HOST"].presence || ENV["OLLAMA_HOST"].presence
  end

  def self.port
    ENV["AIBRANCH_OLLAMA_PORT"].presence || ENV["OLLAMA_PORT"].presence
  end

  # Base URL for direct HTTP calls (the /api/tags model check).
  #
  # The host is written three different ways across this project's own
  # environments — a bare host, a host:port, and a full URL — so all three
  # have to resolve to the same place. Appending the port unconditionally
  # produced "…:61434:61434", which is not a valid URI.
  def self.base_url
    raw = host.presence || DEFAULT_HOST
    raw = "http://#{raw}" unless raw.start_with?("http")
    raw = raw.chomp("/")

    raw.match?(/:\d+\z/) || port.blank? ? raw : "#{raw}:#{port}"
  end
end
