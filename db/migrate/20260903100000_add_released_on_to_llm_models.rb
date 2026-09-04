# Release date per catalog model.
#
# Useful for judging how current the catalog is, and for ordering a picker by
# recency rather than by whenever someone happened to add the row.
#
# Providers expose it unevenly: OpenAI's list-models returns `created` and
# Anthropic returns `created_at`, but Google's returns no date at all.
# OpenRouter publishes a `created` timestamp for nearly everything, so it
# fills the gap. Nullable, and editable by hand for the rest.
class AddReleasedOnToLlmModels < ActiveRecord::Migration[8.0]
  def change
    add_column :llm_models, :released_on, :date
  end
end
