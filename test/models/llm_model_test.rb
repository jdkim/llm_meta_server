require "test_helper"

class LlmModelTest < ActiveSupport::TestCase
  test "valid with name" do
    llm = Llm.create!(name: "Test LLM")
    llm_model = LlmModel.new(name: "Test Model", llm: llm)
    assert llm_model.valid?
  end

  test "invalid without name" do
    llm = Llm.create!(name: "Test LLM")
    llm_model = LlmModel.new(name: nil, llm: llm)
    assert_not llm_model.valid?
  end

  test "invalid without llm" do
    llm_model = LlmModel.new(name: "Test Model")
    assert_not llm_model.valid?
  end

  test "belongs to llm" do
    llm = Llm.create!(name: "Test LLM")
    llm_model = LlmModel.create!(name: "Test Model", llm: llm)
    assert_equal llm, llm_model.llm
  end
end
