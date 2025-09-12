require "test_helper"

class UserControllerTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(
      email: "test@example.com",
      google_id: "123456789"
    )
  end

  test "should redirect when not authenticated" do
    get "/user"
    # 未認証の場合は何らかのリダイレクトが発生することを確認
    assert_response :redirect
  end

  test "user model should be valid with required attributes" do
    assert @user.valid?
    assert_equal "test@example.com", @user.email
    assert_equal "123456789", @user.google_id
  end

  test "user model should validate presence of email and google_id" do
    user = User.new
    assert_not user.valid?
    assert_includes user.errors[:email], "can't be blank"
    assert_includes user.errors[:google_id], "can't be blank"
  end

  test "user should have llm_api_keys association" do
    assert_respond_to @user, :llm_api_keys
  end
end
