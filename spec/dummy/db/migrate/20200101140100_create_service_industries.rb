class CreateServiceIndustries < ActiveRecord::Migration[7.0]
  def change
    create_table :service_industries do |t|
      t.references :organisation, index: true
      t.string :name
      t.text :description

      t.timestamps
    end
  end
end
