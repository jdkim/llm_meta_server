module AnonymousUsageGuard
  private

  def usage_policy
    @usage_policy ||= AnonymousUsagePolicy.new
  end

  def render_usage_rejection(error)
    Rails.logger.info({ event: "anonymous_rejected", code: error.code, status: error.status,
      subject: usage_policy.subject(request.remote_ip) }.to_json)
    response.headers["Retry-After"] = error.retry_after.to_s if error.retry_after
    render json: { error: error.code, message: error.message }, status: error.status
  end
end
