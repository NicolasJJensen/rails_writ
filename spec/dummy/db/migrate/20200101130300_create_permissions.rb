class CreatePermissions < ActiveRecord::Migration[7.0]
  def change
    create_table :permissions do |t|
      t.references :role, index: true, null: false, foreign_key: true
      t.string :model, index: true, null: false
      t.string :action, null: false
      t.string :generated_signature

      t.timestamps
    end

    # Composite indexes for permission lookups
    add_index :permissions, [:action, :model]
    add_index :permissions, [:role_id, :action, :model]
  end
end
