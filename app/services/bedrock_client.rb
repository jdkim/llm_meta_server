# frozen_string_literal: true

# Amazon Bedrock, reached through its OpenAI-compatible Chat Completions
# endpoint.
#
# A subclass rather than a new provider because bedrock-runtime speaks the
# OpenAI wire format, so everything llm.rb already does for OpenAI — streaming,
# tool calls, message shaping — applies unchanged. Only two things differ: the
# host carries the region, and the OpenAI surface is served under /openai/v1
# rather than /v1.
#
# AUTH IS A BEDROCK API KEY (a bearer token), NOT SigV4. The OpenAI-compatible
# Chat Completions path accepts only the API key, and that is also what keeps
# this to a subclass: SigV4 would mean aws-sdk-bedrockruntime and the Converse
# API — a different message format, a different streaming path, and a provider
# written from scratch. The key is an ordinary bearer credential, so it stores
# as an LlmApiKey row encrypted through the existing KMS path, exactly like an
# OpenAI or Anthropic key.
#
# Region defaults to the one the app already uses for KMS (AWS_REGION), so a
# deployment keeps its prompts and its encrypted keys in the same jurisdiction
# without a second setting. BEDROCK_REGION overrides it if inference should go
# somewhere other than where KMS lives.
class BedrockClient < LLM::OpenAI
  DEFAULT_REGION = "ap-northeast-1"

  def self.region
    ENV["BEDROCK_REGION"].presence || ENV["AWS_REGION"].presence || DEFAULT_REGION
  end

  def self.host
    "bedrock-runtime.#{region}.amazonaws.com"
  end

  def initialize(**)
    # LLM::OpenAI#initialize does `super(host: HOST, **)`; the splat is applied
    # after the literal, so the host passed here wins.
    super(host: self.class.host, **)
  end

  private

  # bedrock-runtime serves the OpenAI surface under /openai/v1. (bedrock-mantle
  # uses a bare /v1 and different model ids — a separate endpoint, not this one.)
  def completions_path
    "/openai/v1/chat/completions"
  end
end
