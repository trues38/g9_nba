class AddPerformanceIndexes < ActiveRecord::Migration[8.1]
  def change
    # Games indexes for frequent queries
    add_index :games, :game_date
    add_index :games, :home_abbr
    add_index :games, :away_abbr
    add_index :games, :status
    add_index :games, :external_id, unique: true
    add_index :games, [:sport_id, :game_date]
    add_index :games, [:home_abbr, :away_abbr, :game_date]

    # Reports indexes
    add_index :reports, :status
    add_index :reports, :published_at
    add_index :reports, :free
    add_index :reports, [:game_id, :status]

    # Insights indexes
    add_index :insights, :status
    add_index :insights, :published_at
    add_index :insights, [:sport_id, :status]
  end
end
