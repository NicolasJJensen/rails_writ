class AddDefaultRoleToOrganisation < ActiveRecord::Migration[7.0]
  def change
    add_reference :organisations, :default_role, foreign_key: { to_table: :roles, deferrable: :deferred }
  end
end
