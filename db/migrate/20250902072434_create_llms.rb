class CreateLlms < ActiveRecord::Migration[8.0]
  def change
    create_table :llms do |t|

      t.string :name, null: false

      t.timestamps
    end
  end
end
