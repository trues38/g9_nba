class AddSpreadToGames < ActiveRecord::Migration[8.1]
  def change
    add_column :games, :home_spread, :decimal
    add_column :games, :total_line, :decimal
    add_column :games, :away_spread, :decimal
  end
end
