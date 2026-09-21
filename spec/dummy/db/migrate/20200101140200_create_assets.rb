class CreateAssets < ActiveRecord::Migration[7.0]
  def change
    create_table :assets do |t|
      t.references :organisation, index: true
      t.references :location, index: true
      t.string :name
      t.text :description
      t.integer :status, default: 0, null: false
      t.boolean :archived
      t.date :purchase_date
      t.datetime :last_service
      t.interval :service_frequency

      t.timestamps
    end
  end
end
