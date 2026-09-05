require "rails_helper"

# OLLAMA_HOST is also the variable the `ollama` CLI reads. On the machine that
# hosts both, a developer exports it to aim the CLI at the shared instance —
# and dotenv never overwrites an existing variable, so that export silently
# outranked the app's own .env and sent AIbranch to the wrong server for an
# hour. The app therefore reads its own names first.
RSpec.describe OllamaEndpoint do
  def with_env(vars)
    allow(ENV).to receive(:[]).and_call_original
    vars.each { |k, v| allow(ENV).to receive(:[]).with(k).and_return(v) }
  end

  describe ".base_url" do
    it "prefers the app's own variables over the CLI's" do
      with_env("AIBRANCH_OLLAMA_HOST" => "172.18.8.61", "AIBRANCH_OLLAMA_PORT" => "61435",
               "OLLAMA_HOST" => "http://172.18.8.61:61434", "OLLAMA_PORT" => "61434")

      expect(described_class.base_url).to eq("http://172.18.8.61:61435")
    end

    it "falls back to the bare names, so existing deployments keep working" do
      with_env("AIBRANCH_OLLAMA_HOST" => nil, "AIBRANCH_OLLAMA_PORT" => nil,
               "OLLAMA_HOST" => "172.18.8.61", "OLLAMA_PORT" => "61434")

      expect(described_class.base_url).to eq("http://172.18.8.61:61434")
    end

    it "defaults to localhost when nothing is set" do
      with_env("AIBRANCH_OLLAMA_HOST" => nil, "AIBRANCH_OLLAMA_PORT" => nil,
               "OLLAMA_HOST" => nil, "OLLAMA_PORT" => nil)

      expect(described_class.base_url).to eq("http://127.0.0.1")
    end

    # The host is written three ways across this project's environments.
    it "accepts a host that already carries its port, without doubling it" do
      with_env("AIBRANCH_OLLAMA_HOST" => "172.18.8.61:61435", "AIBRANCH_OLLAMA_PORT" => "61435")

      expect(described_class.base_url).to eq("http://172.18.8.61:61435")
    end

    it "accepts a full URL and strips a trailing slash" do
      with_env("AIBRANCH_OLLAMA_HOST" => "http://172.18.8.61:61435/", "AIBRANCH_OLLAMA_PORT" => "61435")

      expect(described_class.base_url).to eq("http://172.18.8.61:61435")
    end
  end

  describe ".host / .port" do
    it "reports the app's own values when set" do
      with_env("AIBRANCH_OLLAMA_HOST" => "10.0.0.1", "AIBRANCH_OLLAMA_PORT" => "1234",
               "OLLAMA_HOST" => "shared", "OLLAMA_PORT" => "9999")

      expect(described_class.host).to eq("10.0.0.1")
      expect(described_class.port).to eq("1234")
    end
  end
end
