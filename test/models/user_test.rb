require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "valid user with email, google_id" do
    user = User.new(email: "test@example.com", google_id: 1)
    assert user.valid?
  end

  test "invalid user without email" do
    user = User.new(google_id: 1)
    assert_not user.valid?
    assert_includes user.errors[:email], "can't be blank"
  end

  test "invalid user without google_id" do
    user = User.new(email: "test@example.com")
    assert_not user.valid?
    assert_includes user.errors[:google_id], "can't be blank"
  end

  test "invalid user with duplicate email" do
    User.create!(email: "test@example.com", google_id: 1)
    user = User.new(email: "test@example.com", google_id: 2)
    assert_not user.valid?
    assert_includes user.errors[:email], "has already been taken"
  end

  test "invalid user with duplicate google_id" do
    User.create!(email: "test1@example.com", google_id: 1)
    user = User.new(email: "test2@example.com", google_id: 1)
    assert_not user.valid?
    assert_includes user.errors[:google_id], "has already been taken"
  end
end
