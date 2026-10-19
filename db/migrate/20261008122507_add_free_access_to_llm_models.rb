# Whether a model may be used WITHOUT a user-supplied API key.
#
# Until now that was synonymous with "is an Ollama model", because Ollama needs
# no credential. Selected hosted models (gpt-oss on Bedrock) should also be
# free to the caller, paid for by a server-owned key — so the access question
# gets its own flag rather than continuing to ride on the provider.
#
# Deliberately separate from `active`: active means "offered in the picker",
# this means "no key required to call it".
class AddFreeAccessToLlmModels < ActiveRecord::Migration[8.0]
  def change
    add_column :llm_models, :free_access, :boolean, default: false, null: false
  end
end
