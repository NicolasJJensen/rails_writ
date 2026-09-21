class CreateJoinTableServiceIndustriesUsers < ActiveRecord::Migration[7.0]
  def change
    create_join_table :service_industries, :users do |t|
      # t.index [:service_industry_id, :user_id]
      t.index [:user_id, :service_industry_id], name: 'index_SI_U_on_U_id_and_SI_id'
    end

    add_foreign_key :service_industries_users, :service_industries
    add_foreign_key :service_industries_users, :users
  end
end
