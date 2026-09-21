class CreateScopes < ActiveRecord::Migration[7.0]
  def change
    create_table :scopes do |t|
      t.string :model, null: false
      t.string :name, null: false

      t.timestamps
    end

    add_index :scopes, [:model, :name], unique: true
  end
end
