# frozen_string_literal: true

module LLM
  require "llm/provider"
  class Gemini < LLM::Provider
    require "llm/providers/gemini"

    def initialize(**)
      super(host: HOST, **)
    end

    def complete(prompt, params = {})
      params = { role: :user, model: default_model }.merge!(params)
      params = [ params, format_schema(params), format_tools(params) ].inject({}, &:merge!).compact
      role, model, stream = [ :role, :model, :stream ].map { params.delete(_1) }
      action = stream ? "streamGenerateContent?key=#{@key}&alt=sse" : "generateContent?key=#{@key}"

      # It seems strange that there's no left operand in an expression using a ternary operator.
      model = model.respond_to?(:id) ? model.id : model

      path = [ "/v1beta/models/#{model}", action ].join(":")
      req  = Net::HTTP::Post.new(path, headers)
      messages = [ *(params.delete(:messages) || []), LLM::Message.new(role, prompt) ]
      body = JSON.dump({ contents: format(messages) }.merge!(params))
      set_body_stream(req, StringIO.new(body))
      res = execute(request: req, stream:)
      LLM::Response.new(res)
                   .extend(LLM::Gemini::Response::Completion)
                   .extend(Module.new { define_method(:__tools__) { tools } })
    end
  end
end
