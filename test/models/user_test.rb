require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "valid user with email" do
    user = User.new(email: "test@example.com")
    assert user.valid?
  end

  test "invalid user without email" do
    user = User.new
    assert_not user.valid?
    assert_includes user.errors[:email], "can't be blank"
  end

  test "invalid user with duplicate email" do
    User.create!(email: "test@example.com")
    user = User.new(email: "test@example.com")
    assert_not user.valid?
    assert_includes user.errors[:email], "has already been taken"
  end
end
