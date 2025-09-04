class CreateLlmModels < ActiveRecord::Migration[8.0]
  def change
    create_table :llm_models do |t|
      t.references :llm, null: false, foreign_key: true
      t.string :name, null: false

      t.timestamps
    end
  end
end
