class CreateCreditTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :credit_transactions do |t|
      t.references :user, null: false, foreign_key: true
      t.references :granted_by, foreign_key: { to_table: :users }
      t.string :kind, null: false
      t.integer :amount_cents, null: false
      t.string :note
      t.string :model
      t.timestamps
    end

    add_index :credit_transactions, [ :user_id, :created_at ]
    add_index :credit_transactions, :kind
  end
end
