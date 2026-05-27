require "rails_helper"

# Tests for the Google Gemini image-generation service. Stubs the upstream
# generateContent HTTP call with WebMock so we exercise the real
# build_contents + response-parsing logic. The cases here lock in three
# fragile pieces of behavior:
#
#   1. The Nano Banana 2 / Pro thoughtSignature workaround: a SINGLE user
#      turn carrying the latest image, never replayed model turns.
#   2. Response parsing across the inlineData/inline_data and
#      mimeType/mime_type casing variants Gemini may emit.
#   3. Graceful fallback when Gemini returns text (refusal / clarification)
#      or empty content (finishReason) instead of an image.
RSpec.describe ImageGenerationService do
  let(:user) { User.create!(email: "u@example.com", google_id: "g-img") }
  let(:google_key) do
    user.llm_api_keys.create!(llm_type: "google", description: "personal",
                              encryptable_api_key: EncryptableApiKey.new(plain_api_key: "g-key"))
  end
  let(:openai_key) do
    user.llm_api_keys.create!(llm_type: "openai", description: "personal",
                              encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-openai"))
  end
  let(:model_id) { "gemini-3-pro-image-preview" }
  let(:endpoint) do
    %r{\Ahttps://generativelanguage\.googleapis\.com/v1beta/models/#{Regexp.escape(model_id)}:generateContent\?key=}
  end

  # Build a canonical Gemini generateContent JSON response shape.
  def gemini_response(parts:, finish_reason: "STOP")
    {
      candidates: [
        { content: { parts: parts, role: "model" }, finishReason: finish_reason }
      ]
    }
  end

  def stub_gemini(response_json:, status: 200)
    stub_request(:post, endpoint)
      .to_return(status: status, body: response_json.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  describe "provider routing" do
    it "raises for a non-google llm_api_key" do
      expect {
        described_class.generate!(model_id: model_id, prompt: "hi", llm_api_key: openai_key)
      }.to raise_error(ArgumentError, /not supported for provider/)
    end

    it "raises for a nil llm_api_key" do
      expect {
        described_class.generate!(model_id: model_id, prompt: "hi", llm_api_key: nil)
      }.to raise_error(ArgumentError, /not supported for provider/)
    end
  end

  describe "request shape" do
    it "sends a single user turn with responseModalities=[IMAGE,TEXT] for a text-only prompt" do
      stub_gemini(response_json: gemini_response(parts: [
        { inlineData: { mimeType: "image/png", data: "GENERATED" } }
      ]))

      described_class.generate!(model_id: model_id, prompt: "a red ball", llm_api_key: google_key)

      expect(WebMock).to have_requested(:post, endpoint).with { |req|
        body = JSON.parse(req.body)
        expect(body["generationConfig"]).to eq("responseModalities" => %w[IMAGE TEXT])
        expect(body["contents"].length).to eq(1)
        turn = body["contents"][0]
        expect(turn["role"]).to eq("user")
        expect(turn["parts"]).to eq([ { "text" => "a red ball" } ])
        true
      }
    end

    it "embeds the freshly attached image alongside the prompt in a single user turn" do
      stub_gemini(response_json: gemini_response(parts: [
        { inlineData: { mimeType: "image/png", data: "OUT" } }
      ]))

      described_class.generate!(
        model_id: model_id, prompt: "make it blue", llm_api_key: google_key,
        image: { mime: "image/png", data_b64: "INPUTBYTES" }
      )

      expect(WebMock).to have_requested(:post, endpoint).with { |req|
        body = JSON.parse(req.body)
        parts = body["contents"][0]["parts"]
        expect(parts.length).to eq(2)
        expect(parts[0]).to eq("inlineData" => { "mimeType" => "image/png", "data" => "INPUTBYTES" })
        expect(parts[1]).to eq("text" => "make it blue")
        true
      }
    end

    it "carries forward the most recent image from image_context when no fresh image is attached" do
      stub_gemini(response_json: gemini_response(parts: [
        { inlineData: { mimeType: "image/png", data: "OUT" } }
      ]))

      image_context = [
        { response: "earlier text, no image" },
        { response: "Here you go: ![](data:image/jpeg;base64,EARLIER)" },
        { response: "no image either" }
      ]

      described_class.generate!(
        model_id: model_id, prompt: "make it darker", llm_api_key: google_key,
        image_context: image_context
      )

      expect(WebMock).to have_requested(:post, endpoint).with { |req|
        body = JSON.parse(req.body)
        parts = body["contents"][0]["parts"]
        expect(parts[0]).to eq("inlineData" => { "mimeType" => "image/jpeg", "data" => "EARLIER" })
        expect(parts[1]).to eq("text" => "make it darker")
        # Only ONE user turn — never replayed model turns (thoughtSignature
        # workaround for Nano Banana 2 / Pro).
        expect(body["contents"].length).to eq(1)
        true
      }
    end

    it "prefers the freshly attached image over any image in image_context" do
      stub_gemini(response_json: gemini_response(parts: [
        { inlineData: { mimeType: "image/png", data: "OUT" } }
      ]))

      described_class.generate!(
        model_id: model_id, prompt: "tweak", llm_api_key: google_key,
        image_context: [ { response: "![](data:image/png;base64,OLD)" } ],
        image: { mime: "image/png", data_b64: "FRESH" }
      )

      expect(WebMock).to have_requested(:post, endpoint).with { |req|
        body = JSON.parse(req.body)
        expect(body["contents"][0]["parts"][0]).to eq(
          "inlineData" => { "mimeType" => "image/png", "data" => "FRESH" }
        )
        true
      }
    end

    it "passes the api_key in the URL query string" do
      stub_gemini(response_json: gemini_response(parts: [
        { inlineData: { mimeType: "image/png", data: "X" } }
      ]))

      described_class.generate!(model_id: model_id, prompt: "x", llm_api_key: google_key)

      expect(WebMock).to have_requested(:post, /key=g-key/)
    end
  end

  describe "response parsing — happy path" do
    it "returns a markdown image when the response contains an inlineData part" do
      stub_gemini(response_json: gemini_response(parts: [
        { inlineData: { mimeType: "image/png", data: "AAAA" } }
      ]))

      result = described_class.generate!(model_id: model_id, prompt: "hi", llm_api_key: google_key)
      expect(result).to eq("![](data:image/png;base64,AAAA)")
    end

    it "interleaves caption text before the image when both are present" do
      stub_gemini(response_json: gemini_response(parts: [
        { text: "Here is your ball:" },
        { inlineData: { mimeType: "image/jpeg", data: "BBBB" } }
      ]))

      result = described_class.generate!(model_id: model_id, prompt: "hi", llm_api_key: google_key)
      expect(result).to eq("Here is your ball:\n\n![](data:image/jpeg;base64,BBBB)")
    end

    it "accepts the snake_case inline_data / mime_type variants from Gemini" do
      stub_gemini(response_json: gemini_response(parts: [
        { inline_data: { mime_type: "image/webp", data: "CCCC" } }
      ]))

      result = described_class.generate!(model_id: model_id, prompt: "hi", llm_api_key: google_key)
      expect(result).to eq("![](data:image/webp;base64,CCCC)")
    end

    it "defaults to image/png when the inlineData omits a mime type" do
      stub_gemini(response_json: gemini_response(parts: [
        { inlineData: { data: "DDDD" } }
      ]))

      result = described_class.generate!(model_id: model_id, prompt: "hi", llm_api_key: google_key)
      expect(result).to eq("![](data:image/png;base64,DDDD)")
    end

    it "returns the text alone when Gemini answers with only text (refusal / clarification)" do
      stub_gemini(response_json: gemini_response(parts: [
        { text: "I can't generate that — please rephrase." }
      ]))

      result = described_class.generate!(model_id: model_id, prompt: "hi", llm_api_key: google_key)
      expect(result).to eq("I can't generate that — please rephrase.")
    end
  end

  describe "response parsing — error paths" do
    it "raises with the Gemini API error message on non-success HTTP" do
      stub_gemini(
        status: 400,
        response_json: { error: { message: "Invalid argument: image too large" } }
      )

      expect {
        described_class.generate!(model_id: model_id, prompt: "hi", llm_api_key: google_key)
      }.to raise_error(/Google API 400: Invalid argument: image too large/)
    end

    it "falls back to the HTTP status message when the error body isn't JSON" do
      stub_request(:post, endpoint).to_return(status: [ 500, "Internal Server Error" ], body: "<html>oops</html>")

      expect {
        described_class.generate!(model_id: model_id, prompt: "hi", llm_api_key: google_key)
      }.to raise_error(/Google API 500: Internal Server Error/)
    end

    it "raises with the finishReason when neither image nor text comes back" do
      stub_gemini(response_json: gemini_response(parts: [], finish_reason: "SAFETY"))

      expect {
        described_class.generate!(model_id: model_id, prompt: "hi", llm_api_key: google_key)
      }.to raise_error(/Gemini returned no image \(SAFETY\)/)
    end

    it "raises with the promptFeedback blockReason when neither image, text, nor finishReason is present" do
      stub_request(:post, endpoint).to_return(
        status: 200, body: { promptFeedback: { blockReason: "PROHIBITED_CONTENT" } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      expect {
        described_class.generate!(model_id: model_id, prompt: "hi", llm_api_key: google_key)
      }.to raise_error(/Gemini returned no image \(PROHIBITED_CONTENT\)/)
    end
  end
end
