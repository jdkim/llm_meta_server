require "test_helper"

class UserControllerTest < ActionDispatch::IntegrationTest

  test "should redirect when not authenticated" do
    get "/profile"
    # Verify that some redirect occurs when not authenticated
    assert_response :redirect
  end
end
