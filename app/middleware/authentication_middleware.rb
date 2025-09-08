
class AuthenticationMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    request = ActionDispatch::Request.new env

    # API routes request JWT authentication
    if api_route? request
      auth_result = authenticate_api_request request

      if auth_result[:success]
        # Set current user in the environment for downstream use
        env["authenticated_user"] = auth_result[:user]
        env["jwt_payload"] = auth_result[:payload]
      else
        return unauthorized_response auth_result[:error]
      end
    end

    @app.call(env)
  end

  private

  def api_route?(request)
    request.path.start_with?("/api/")
  end

  def authenticate_api_request(request)
    # Try to internal JWT authentication
    internal_auth_result = verify_internal_jwt request
    return internal_auth_result if internal_auth_result[:success]

    # Fallback to exte4rnal JWT authentication
    external_auth_result = verify_external_jwt request
    return external_auth_result if external_auth_result[:success]

    {
      success: false,
      error: "Unauthorized",
      status: 401
    }
  end

  def verify_internal_jwt(request)
    token = extract_internal_jwt_token request
    return { success: false, error: "No internal token" } unless token

    begin
      decoded_token = JWT.decode token,
                                 internal_jwt_secret,
                                 true,
                                 {
                                    algorithm: "HS256",
                                    verify_iat: true,
                                    verify_exp: true
                                 }

      payload = decoded_token.first

      validate_internal_jwt_payload payload

      user = get_user_from_internal_jwt payload

      {
        success: true,
        user: user,
        payload: payload,
        auth_type: "internal_jwt"
      }
    rescue JWT::ExpiredSignature
      { success: false, error: "Token has expired", status: 401 }
    rescue JWT::InvalidSignature
      { success: false, error: "Invalid token signature", status: 401 }
    rescue JWT::InvalidIssuerError
      { success: false, error: "Invalid token issuer", status: 401 }
    rescue JWT::InvalidAudError
      { success: false, error: "Invalid token audience", status: 401 }
    rescue JWT::DecodeError => e
      { success: false, error: "Invalid token: #{e.message}", status: 401 }
    rescue StandardError => e
      { success: false, error: "Authentication error: #{e.message}", status: 401 }
    end
  end

  def verify_external_jwt(request)
    token = extract_external_jwt_token request
    return { success: false, error: "No user token" } unless token

    begin
      decoded_token = JWT.decode token,
                                 external_jwt_secret,
                                 true,
                                 {
                                    algorithm: "HS256",
                                    verify_iat: true,
                                    verify_exp: true
                                 }

      payload = decoded_token.first

      validate_external_jwt_payload payload

      user = User.find_by(id: payload["user_id"])
      return { success: false, error: "User not found", status: 404 } unless user

      unless user.email == payload["email"]
        return { success: false, error: "Token email does not match user", status: 401 }
      end

      {
        success: true,
        user: user,
        payload: payload,
        auth_type: "external_jwt"
      }
    rescue JWT::ExpiredSignature
      { success: false, error: "Token has expired", status: 401 }
    rescue JWT::DecodeError => e
      { success: false, error: "Invalid token: #{e.message}", status: 401 }
    rescue StandardError => e
      { success: false, error: "Authentication error: #{e.message}", status: 500 }
    end
  end

  def extract_internal_jwt_token(request)
    auth_header = request.get_header "HTTP_X_INTERNAL_AUTHORIZATION"

    if auth_header&.start_with?("Bearer ")
      return auth_header.gsub(/Bearer\s+/, "")
    end

    auth_header = request.get_header "HTTP_AUTHORIZATION"

    if auth_header&.start_with?("Bearer ")
      token = auth_header.gsub(/Bearer\s+/, "")

      begin
        payload = JWT.decode(token, internal_jwt_secret, false)[0]
        return token if payload["type"]&.include?("internal") || payload["type"]&.include?("service")
      rescue JWT::DecodeError => e
        # return nil
      end
    end

    nil
  end

  def extract_external_jwt_token(request)
    auth_header = request.get_header "HTTP_X_INTERNAL_AUTHORIZATION"

    if auth_header&.start_with?("Bearer ")
      token = auth_header.gsub(/Bearer\s+/, "")

      begin
        payload = JWT.decode(token, external_jwt_secret, false)[0]
        return token unless payload["type"]&.include?("internal") || payload["type"]&.include?("service")
      rescue JWT::DecodeError => e
        # return nil
      end
    end

    nil
  end

  def validate_internal_jwt_payload(payload)
    required_field = %w[iss aud type]
    missing_fields = required_fields.select { |field| payload[field].blank? }

    if missing_fields.any?
      raise JWT::InvalidPayload, "Missing required fields: #{missing_fields.join(', ')}"
    end

    expected_issuer = ENV["INTERNAL_ISSUER"] || "annotation_canvas"
    unless payload["iss"] == expected_issuer
      raise JWT::InvalidIssuerError, "Invalid issuer: #{payload["iss"]}"
    end

    expected_audience = ENV["INTERNAL_AUDIENCE"] || "llm_api_call_meta_server"
    unless payload["aud"] == expected_audience
      raise JWT::InvalidAudError, "Invalid audience: #{payload["aud"]}"
    end

    unless %w[internal_system service_to_service].include?(payload["type"])
      raise JWT::InvalidPayload, "Invalid token type: #{payload["type"]}"
    end

    if payload["service"].present?
      allowed_services = %w[annotaion_canvas llm_api_call_meta_server]
      unless allowed_services.include?(payload["service"])
        raise JWT::InvalidPayload, "Unauthorized service type: #{payload["service"]}"
      end
    end
  end

  def validate_external_jwt_payload(payload)
    required_fields = %w[user_id email]
    missing_fields = required_fields.select { |field| payload[field].blank? }

    if missing_fields.any?
      raise JWT::InvalidPayload, "Missing required fields: #{missing_fields.join(', ')}"
    end
  end

  def get_user_from_internal_jwt(payload)
    case payload["type"]
    when "internal_system"
      return User.find_by(id: payload["user_id"]) if payload["user_id"].present?
    when "service_to_service"
      return nil
    end

    nil
  end

  def internal_jwt_secret
    Rails.application.secret_key_base
  end

  def external_jwt_secret
    Rails.application.secret_key_base
  end

  def unauthorized_response(error_message)
    [
      401,
      { "Content-Type" => "application/json" },
      [ { error: error_message }.to_json ]
    ]
  end
end
