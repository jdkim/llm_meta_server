namespace :anonymous_usage do
  desc "Stop/resume anonymous llm or mcp requests: KIND=llm ENABLED=false ACTOR=name REASON=incident"
  task set: :environment do
    enabled = ENV.fetch("ENABLED")
    abort "ENABLED must be true or false" unless %w[true false].include?(enabled)
    AnonymousUsagePolicy.set_enabled!(ENV.fetch("KIND"), enabled == "true",
      actor: ENV.fetch("ACTOR"), reason: ENV.fetch("REASON"))
    puts "Anonymous #{ENV.fetch('KIND')} enabled=#{enabled}"
  end
  desc "Release an uncertain reservation AFTER verifying upstream stopped: ID=... CONFIRMED_STOPPED=true ACTOR=... REASON=..."
  task reconcile: :environment do
    abort "Verify upstream termination and set CONFIRMED_STOPPED=true" unless ENV["CONFIRMED_STOPPED"] == "true"
    AnonymousUsagePolicy.reconcile!(ENV.fetch("ID"), actor: ENV.fetch("ACTOR"), reason: ENV.fetch("REASON"))
    puts "Reconciled anonymous reservation #{ENV.fetch('ID')}"
  end
end
