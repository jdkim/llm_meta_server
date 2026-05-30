require "rails_helper"

# Integration spec for the Google OAuth2 sign-in callback and sign-out flow.
# Drives Devise + OmniAuth with a mocked auth hash, so the real
# User.from_omniauth and the persistence/redirect branches all run.
#
# The interesting cases are:
#   * First sign-in creates a new User and signs them in.
#   * Returning user (same email) signs in without re-creating or rewriting
#     the existing record.
#   * A returning user with the SAME email but a DIFFERENT google_id keeps
#     the original google_id — `where(email:).first_or_create` only runs
#     the block on create. Documenting this behavior.
#   * Validation failure (e.g. blank email) doesn't persist and redirects
#     home with the model's error messages.
#   * The /users/auth/failure route surfaces a generic alert.
#   * Sign-out via DELETE /logout clears the session.
RSpec.describe "Users::OmniauthCallbacksController", type: :request do
  before do
    OmniAuth.config.test_mode = true
  end

  after do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  def stub_google_auth(email:, uid:)
    auth = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: uid,
      info: { email: email, name: "Test User" }
    )
    OmniAuth.config.mock_auth[:google_oauth2] = auth
    Rails.application.env_config["omniauth.auth"] = auth
  end

  describe "GET /users/auth/google_oauth2/callback" do
    it "creates a new User on first sign-in and redirects with a success notice" do
      stub_google_auth(email: "new@example.com", uid: "google-uid-new")

      expect {
        get "/users/auth/google_oauth2/callback"
      }.to change(User, :count).by(1)

      user = User.last
      expect(user.email).to eq("new@example.com")
      expect(user.google_id).to eq("google-uid-new")

      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(flash[:notice]).to match(/Successfully authenticated/i)
    end

    it "signs in a returning user without creating a duplicate row" do
      existing = User.create!(email: "ret@example.com", google_id: "google-uid-old")
      stub_google_auth(email: "ret@example.com", uid: "google-uid-old")

      expect {
        get "/users/auth/google_oauth2/callback"
      }.not_to change(User, :count)

      expect(response).to redirect_to(root_path)
      expect(User.find_by(email: "ret@example.com").id).to eq(existing.id)
    end

    it "does NOT rewrite google_id when the same email signs in with a different uid" do
      # Documents the current `first_or_create` behavior: the block only runs
      # on create, so the existing google_id is preserved as-is. If we ever
      # want to update on sign-in, this test will need to be flipped to
      # `to change` — and that change should be deliberate.
      existing = User.create!(email: "same@example.com", google_id: "google-uid-original")
      stub_google_auth(email: "same@example.com", uid: "google-uid-different")

      get "/users/auth/google_oauth2/callback"

      expect(existing.reload.google_id).to eq("google-uid-original")
      expect(response).to redirect_to(root_path)
    end

    it "redirects to root with the model errors when the user fails to persist" do
      stub_google_auth(email: "", uid: "google-uid-blank-email")

      expect {
        get "/users/auth/google_oauth2/callback"
      }.not_to change(User, :count)

      expect(response).to redirect_to(root_path)
      follow_redirect!
      # The validation errors include both Email and Google id (since both are required)
      expect(flash[:alert]).to include("Email")
    end
  end

  describe "GET /users/auth/failure" do
    it "redirects to root with a generic auth-failure alert" do
      OmniAuth.config.mock_auth[:google_oauth2] = :invalid_credentials
      get "/users/auth/google_oauth2/callback"

      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(flash[:alert]).to match(/Failed to authentication/i)
    end
  end

  describe "DELETE /logout" do
    include Devise::Test::IntegrationHelpers

    it "clears the session and redirects to root with a notice" do
      user = User.create!(email: "out@example.com", google_id: "g-out")
      sign_in user

      delete "/logout"

      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(flash[:notice]).to eq("You have successfully signed out.")
    end
  end
end
