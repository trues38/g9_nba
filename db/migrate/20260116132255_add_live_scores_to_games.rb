class AddLiveScoresToGames < ActiveRecord::Migration[8.1]
  def change
    add_column :games, :home_score, :integer
    add_column :games, :away_score, :integer
    add_column :games, :period, :integer
    add_column :games, :clock, :string
    add_column :games, :home_linescores, :text
    add_column :games, :away_linescores, :text
  end
end
