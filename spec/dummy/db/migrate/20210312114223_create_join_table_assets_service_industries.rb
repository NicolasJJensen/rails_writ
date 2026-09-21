class CreateJoinTableAssetsServiceIndustries < ActiveRecord::Migration[7.0]
  def change
    create_join_table :assets, :service_industries do |t|
      # t.index [:service_industry_id, :asset_id]
      t.index [:asset_id, :service_industry_id], name: 'index_A_SI_on_A_id_and_SI_id'
    end

    add_foreign_key :assets_service_industries, :assets
    add_foreign_key :assets_service_industries, :service_industries
  end
end
