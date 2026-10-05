namespace :anonymous_usage do
  desc "Stop/resume anonymous llm or mcp requests: KIND=llm ENABLED=false ACTOR=name REASON=incident"
  task set: :environment do
    enabled = ENV.fetch("ENABLED")
    abort "ENABLED must be true or false" unless %w[true false].include?(enabled)
    AnonymousUsagePolicy.set_enabled!(ENV.fetch("KIND"), enabled == "true",
      actor: ENV.fetch("ACTOR"), reason: ENV.fetch("REASON"))
    puts "Anonymous #{ENV.fetch('KIND')} enabled=#{enabled}"
  end
end
