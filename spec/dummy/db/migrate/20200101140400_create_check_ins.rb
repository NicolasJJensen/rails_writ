class CreateCheckIns < ActiveRecord::Migration[7.0]
  def change
    create_table :check_ins do |t|
      t.references :user, index: true
      t.references :location, index: true
      t.datetime :start
      t.datetime :finish

      t.timestamps
    end
  end
end
