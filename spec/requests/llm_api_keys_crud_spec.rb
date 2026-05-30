require "rails_helper"

# Integration spec for the web-facing LlmApiKey CRUD endpoints. The encryption
# lifecycle is the load-bearing concern: the controller must hand the raw
# plaintext to ApiKeyEncrypter and only ever persist ciphertext. These
# specs exercise the controller + model + EncryptableApiKey + (stubbed)
# encrypter together.
#
# The KMS stub in rails_helper is a round-trip Base64 encoder so we can
# verify that the value on disk is NOT the plaintext. We also intercept
# `ApiKeyEncrypter#encrypt` to count calls and capture the input.
RSpec.describe "LlmApiKey CRUD (web)", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { User.create!(email: "u@example.com", google_id: "g-crud") }
  let(:base_path) { "/user/#{user.id}/llm_api_keys" }

  before { sign_in user }

  describe "POST create" do
    it "encrypts the plaintext through ApiKeyEncrypter and never stores it raw" do
      encryptor_inputs = []
      allow_any_instance_of(ApiKeyEncrypter).to receive(:encrypt) do |_, plain|
        encryptor_inputs << plain
        Base64.encode64(plain.to_s)
      end

      post base_path, params: {
        llm_api_key: { llm_type: "openai", api_key: "sk-supersecret", description: "personal" }
      }

      expect(response).to redirect_to(base_path)
      follow_redirect!
      expect(response.body).to include("API key has been added successfully")

      key = user.llm_api_keys.last
      expect(key.llm_type).to eq("openai")
      expect(key.description).to eq("personal")
      # The plaintext was handed to the encryptor exactly once...
      expect(encryptor_inputs).to eq([ "sk-supersecret" ])
      # ...and what's on the row is the ciphertext, not the plaintext.
      expect(key.encrypted_api_key).not_to include("sk-supersecret")
      expect(key.encrypted_api_key).to eq(Base64.encode64("sk-supersecret"))
    end

    it "rejects a blank api_key with an alert and does not create a row" do
      expect {
        post base_path, params: {
          llm_api_key: { llm_type: "openai", api_key: "", description: "x" }
        }
      }.not_to change(user.llm_api_keys, :count)

      follow_redirect!
      expect(response.body).to include("API Key can&#39;t blank.")
    end

    it "rejects an unsupported llm_type with a record-invalid alert" do
      expect {
        post base_path, params: {
          llm_api_key: { llm_type: "bogus", api_key: "sk-x", description: "x" }
        }
      }.not_to change(user.llm_api_keys, :count)

      follow_redirect!
      expect(response.body).to match(/Failed to add API key.*bogus is not a supported LLM type/)
    end

    it "alerts when llm_api_key params are missing entirely" do
      post base_path, params: {}
      follow_redirect!
      expect(response.body).to include("Please enter LLM type and API key")
    end
  end

  describe "PATCH update" do
    let!(:existing_key) do
      user.llm_api_keys.create!(llm_type: "openai", description: "old",
                                encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-old"))
    end

    it "updates description only without re-encrypting (api_key omitted)" do
      encrypt_call_count = 0
      allow_any_instance_of(ApiKeyEncrypter).to receive(:encrypt) do |_, plain|
        encrypt_call_count += 1
        Base64.encode64(plain.to_s)
      end

      original_ciphertext = existing_key.encrypted_api_key

      patch "#{base_path}/#{existing_key.id}", params: {
        llm_api_key: { llm_type: "openai", api_key: "", description: "new description" }
      }

      follow_redirect!
      expect(response.body).to include("Description of API key has been updated successfully")
      expect(existing_key.reload.description).to eq("new description")
      expect(existing_key.encrypted_api_key).to eq(original_ciphertext)
      expect(encrypt_call_count).to eq(0)
    end

    it "re-encrypts and replaces the ciphertext when api_key is supplied" do
      encryptor_inputs = []
      allow_any_instance_of(ApiKeyEncrypter).to receive(:encrypt) do |_, plain|
        encryptor_inputs << plain
        Base64.encode64(plain.to_s)
      end

      patch "#{base_path}/#{existing_key.id}", params: {
        llm_api_key: { llm_type: "openai", api_key: "sk-new", description: "old" }
      }

      follow_redirect!
      expect(response.body).to include("API key has been updated successfully")
      expect(existing_key.reload.encrypted_api_key).to eq(Base64.encode64("sk-new"))
      expect(encryptor_inputs).to eq([ "sk-new" ])
    end

    it "reports both updates when api_key and description change together" do
      patch "#{base_path}/#{existing_key.id}", params: {
        llm_api_key: { llm_type: "openai", api_key: "sk-both", description: "renamed" }
      }
      follow_redirect!
      expect(response.body).to include("API key and description have been updated successfully")
    end

    it "alerts when neither api_key nor description changed" do
      patch "#{base_path}/#{existing_key.id}", params: {
        llm_api_key: { llm_type: "openai", api_key: "", description: "old" }
      }
      follow_redirect!
      expect(response.body).to include("Please enter a new API key or description")
    end

    it "isolates users: A cannot touch B's key" do
      other_user = User.create!(email: "o@example.com", google_id: "g-other")
      other_key = other_user.llm_api_keys.create!(
        llm_type: "openai", description: "theirs",
        encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-theirs")
      )

      patch "#{base_path}/#{other_key.id}", params: {
        llm_api_key: { llm_type: "openai", api_key: "sk-hijack", description: "stolen" }
      }

      # The controller's `llm_api_key` helper rescues ActiveRecord::RecordNotFound
      # and redirects to user_path with an error notice — verify the foreign
      # record was NOT modified regardless of the redirect target.
      expect(other_key.reload.description).to eq("theirs")
      expect(other_key.encrypted_api_key).to eq(Base64.encode64("sk-theirs"))
    end
  end

  describe "DELETE destroy" do
    let!(:existing_key) do
      user.llm_api_keys.create!(llm_type: "anthropic", description: "to-delete",
                                encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-rm"))
    end

    it "removes the row and confirms via flash notice" do
      expect {
        delete "#{base_path}/#{existing_key.id}"
      }.to change(user.llm_api_keys, :count).by(-1)

      follow_redirect!
      expect(response.body).to include("anthropic")
      expect(response.body).to include("to-delete")
      expect(response.body).to include("API key has been deleted successfully")
    end

    it "isolates users: A cannot delete B's key" do
      other_user = User.create!(email: "o@example.com", google_id: "g-other")
      other_key = other_user.llm_api_keys.create!(
        llm_type: "openai", description: "theirs",
        encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-theirs")
      )

      expect {
        delete "#{base_path}/#{other_key.id}"
      }.not_to change(other_user.llm_api_keys, :count)
    end
  end
end
