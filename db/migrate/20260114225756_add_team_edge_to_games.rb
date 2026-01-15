class AddTeamEdgeToGames < ActiveRecord::Migration[8.1]
  def change
    add_column :games, :home_edge, :string
    add_column :games, :away_edge, :string
  end
end
