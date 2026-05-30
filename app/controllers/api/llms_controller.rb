class Api::LlmsController < ApiController
  # Public catalog endpoint: returns at minimum the Ollama family even when
  # the caller is anonymous (the test_service guest path needs to render the
  # LLM picker for not-yet-signed-in users). With a valid bearer token the
  # response also includes the user's registered keys + favorites.
  def index
    render json: { llms: Llm.all_services_with_ollama(user: optional_current_user) }
  end

  private

  # Returns the resolved current_user when a valid bearer token is present,
  # nil otherwise. Swallows the same auth errors that ApiController's
  # rescue_from chain handles for protected endpoints.
  def optional_current_user
    current_user
  rescue ActionController::ParameterMissing,
         Google::Auth::IDTokens::VerificationError,
         Google::Auth::IDTokens::AudienceMismatchError,
         JWT::DecodeError,
         JWT::ExpiredSignature,
         ActiveRecord::RecordNotFound
    nil
  end
end
