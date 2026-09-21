class CreateJoinTableRolesUsers < ActiveRecord::Migration[7.0]
  def change
    create_join_table :roles, :users do |t|
      t.index [:user_id, :role_id], unique: true
      t.index [:role_id, :user_id]
    end

    add_foreign_key :roles_users, :roles
    add_foreign_key :roles_users, :users
  end
end
