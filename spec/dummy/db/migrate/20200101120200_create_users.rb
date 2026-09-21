class CreateUsers < ActiveRecord::Migration[7.0]
  def change
    create_table :users do |t|
      t.references :organisation, index: true, foreign_key: true
      t.string :first_name
      t.string :last_name
      t.string :other_names
      t.string :phone_number
      t.string :gender
      t.date :date_of_birth

      t.boolean :active, index: true, default: true

      t.timestamps
    end
  end
end
