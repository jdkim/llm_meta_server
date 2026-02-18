# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

puts "Starting seed data creation..."

# Create LLMs and their models based on LlmModelMap
llm_configs = {
  "OpenAI" => { models: LlmModelMap::MODEL_MAP_OPENAI, family: "openai" },
  "Anthropic" => { models: LlmModelMap::MODEL_MAP_ANTHROPIC, family: "anthropic" },
  "Google" => { models: LlmModelMap::MODEL_MAP_GOOGLE, family: "google" },
  "Ollama" => { models: LlmModelMap::MODEL_MAP_OLLAMA, family: "ollama" }
}

llm_configs.each do |llm_name, config|
  model_map = config[:models]
  # Create or find LLM platform
  llm = Llm.find_or_create_by!(name: llm_name) do |l|
    l.family = config[:family]
    puts "  Creating LLM platform: #{llm_name}"
  end
  # Ensure family is set for existing records
  llm.update!(family: config[:family]) if llm.family != config[:family]
  puts "  ✓ LLM platform: #{llm_name} (ID: #{llm.id})"

  # Create models for this LLM platform
  model_map.each do |meta_id, model_info|
    model = llm.llm_models.find_or_create_by!(name: meta_id) do
      puts "    Creating model: #{model_info[:display_name]} (#{meta_id})"
    end

    # Update display_name and api_id if they've changed
    if model.display_name != model_info[:display_name] || model.api_id != model_info[:api_id]
      model.update!(
        display_name: model_info[:display_name],
        api_id: model_info[:api_id]
      )
    end

    puts "    ✓ Model: #{model_info[:display_name]} (API ID: #{model_info[:api_id]})"
  end

  puts ""
end

puts "Seed data creation completed!"
puts "Summary:"
puts "  Total LLM platforms: #{Llm.count}"
puts "  Total models: #{LlmModel.count}"
