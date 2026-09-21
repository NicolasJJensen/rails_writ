class CreatePermissionConditions < ActiveRecord::Migration[7.0]
  def change
    create_table :permission_conditions do |t|
      t.references :permission, null: false, foreign_key: true
      t.references :condition, null: false, foreign_key: true
      t.jsonb :arguments, default: {}, null: false

      t.timestamps
    end

    add_index :permission_conditions, [:permission_id, :condition_id], unique: true
  end
end
