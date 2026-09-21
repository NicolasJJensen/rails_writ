class CreateOrganisations < ActiveRecord::Migration[7.0]
  def change
    create_table :organisations do |t|
      t.string :name
      t.string :abn, index: { unique: true }

      t.timestamps
    end
  end
end
