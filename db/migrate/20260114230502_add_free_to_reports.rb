class AddFreeToReports < ActiveRecord::Migration[8.1]
  def change
    add_column :reports, :free, :boolean, default: false
  end
end
