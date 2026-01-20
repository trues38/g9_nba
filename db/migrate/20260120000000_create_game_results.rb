class CreateGameResults < ActiveRecord::Migration[8.0]
  def change
    create_table :game_results do |t|
      t.references :game, null: false, foreign_key: true

      # Scores
      t.integer :home_score
      t.integer :away_score
      t.integer :margin  # home_score - away_score

      # Pre-game lines (captured BEFORE game starts)
      t.decimal :opening_spread, precision: 4, scale: 1  # Home team spread
      t.decimal :closing_spread, precision: 4, scale: 1
      t.decimal :opening_total, precision: 5, scale: 1
      t.decimal :closing_total, precision: 5, scale: 1

      # Results (calculated AFTER game ends)
      t.string :spread_result    # home_covered, away_covered, push
      t.string :total_result     # over, under, push
      t.boolean :spread_covered_home  # true if home covered
      t.boolean :total_over           # true if over hit

      # Metadata
      t.datetime :lines_captured_at   # When we stored the pre-game lines
      t.datetime :result_captured_at  # When we stored the final result

      t.timestamps
    end

    add_index :game_results, :spread_result
    add_index :game_results, :total_result
    add_index :game_results, :lines_captured_at
  end
end
