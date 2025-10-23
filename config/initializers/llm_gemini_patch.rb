# frozen_string_literal: true

require "llm/providers/gemini"

module LLM
  class Gemini < LLM::Provider
    def complete(prompt, params = {})
      params = { role: :user, model: default_model }.merge!(params)
      params = [ params, format_schema(params), format_tools(params) ].inject({}, &:merge!).compact
      role, model, stream = [ :role, :model, :stream ].map { params.delete(_1) }
      action = stream ? "streamGenerateContent?key=#{@key}&alt=sse" : "generateContent?key=#{@key}"

      # It seems strange that there's no left operand in an expression using a ternary operator.
      # https://github.com/llmrb/llm/blob/d92c133f48accac5f15e3c5090b4e0d8ba41cdf5/lib/llm/providers/gemini.rb#L74
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

module LLM::Gemini::Response
  module Models
    include ::Enumerable
    def each(&)
      return enum_for(:each) unless block_given?
      models.each do
        it.id = it.name.delete_prefix("models/") if it.respond_to?(:name) && !it.respond_to?(:id)
        yield(it)
      end
    end

    def models
      body.models || []
    end
  end
end
