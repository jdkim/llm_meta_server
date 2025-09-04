require "test_helper"

class LlmTest < ActiveSupport::TestCase
  test "valid llm with name" do
    llm = Llm.new(name: "Test LLM")
    assert llm.valid?
  end

  test "invalid llm without name" do
    llm = Llm.new
    assert_not llm.valid?
    assert_includes llm.errors[:name], "can't be blank"
  end

  test "invalid llm with duplicate name" do
    Llm.create!(name: "Test LLM")
    llm = Llm.new(name: "Test LLM")
    assert_not llm.valid?
    assert_includes llm.errors[:name], "has already been taken"
  end
end
