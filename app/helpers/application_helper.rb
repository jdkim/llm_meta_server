module ApplicationHelper
  # The app's manually-bumped semantic version, sourced from the VERSION
  # file at the repo root. See config/initializers/app_version.rb.
  def app_version
    AppVersion::CURRENT
  end
end
