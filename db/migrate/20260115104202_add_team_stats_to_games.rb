class AddTeamStatsToGames < ActiveRecord::Migration[8.1]
  def change
    add_column :games, :home_record, :string
    add_column :games, :away_record, :string
    add_column :games, :home_home_record, :string
    add_column :games, :away_road_record, :string
    add_column :games, :h2h_summary, :string
  end
end
