class CreatePermissionScopes < ActiveRecord::Migration[7.0]
  def change
    create_table :permission_scopes do |t|
      t.references :permission, null: false, foreign_key: true
      t.references :scope, null: false, foreign_key: true
      t.jsonb :arguments, default: {}, null: false

      t.timestamps
    end

    add_index :permission_scopes, [:permission_id, :scope_id], unique: true
  end
end
