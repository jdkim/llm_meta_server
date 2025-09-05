require "test_helper"

class LlmApiKeyTest < ActiveSupport::TestCase
  test "should create valid llm_api_key with required attributes" do
    user = User.create!(
      email: "test@example.com",
      google_id: 1
    )

    llm_api_key = LlmApiKey.new(
      uuid: SecureRandom.uuid,
      llm_type: "openai",
      encrypted_api_key: "encrypted_key_example",
      user: user
    )

    assert llm_api_key.valid?
    assert_equal user, llm_api_key.user
    assert_not_nil llm_api_key.uuid
    assert_equal "openai", llm_api_key.llm_type
    assert_equal "encrypted_key_example", llm_api_key.encrypted_api_key
  end

  test "should be invalid without required attributes" do
    llm_api_key = LlmApiKey.new

    assert_not llm_api_key.valid?
    assert_includes llm_api_key.errors[:uuid], "can't be blank"
    assert_includes llm_api_key.errors[:llm_type], "can't be blank"
    assert_includes llm_api_key.errors[:encrypted_api_key], "can't be blank"
  end

  test "should require unique uuid" do
    user = User.create!(
      email: "test2@example.com",
      google_id: 2
    )
    uuid = SecureRandom.uuid

    LlmApiKey.create!(
      uuid: uuid,
      llm_type: "openai",
      encrypted_api_key: "key1",
      user: user
    )

    duplicate = LlmApiKey.new(
      uuid: uuid,
      llm_type: "claude",
      encrypted_api_key: "key2",
      user: user
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:uuid], "has already been taken"
  end
end
