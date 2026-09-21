class CreateRoles < ActiveRecord::Migration[7.0]
  def change
    create_table :roles do |t|
      t.references :organisation, index: true, null: false, foreign_key: true
      t.string :name, null: false
      t.string :description
      t.string :color
      t.jsonb :accessible_fields, default: {}, null: false
      t.jsonb :generated_fields, default: {}, null: false

      t.timestamps
    end

    add_index :roles, [:organisation_id, :name], unique: true
    add_index :roles, :name, unique: true, where: "organisation_id IS NULL",
              name: "index_roles_on_name_when_global"
  end
end
