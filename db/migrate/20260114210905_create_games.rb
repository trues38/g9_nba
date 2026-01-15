class CreateGames < ActiveRecord::Migration[8.1]
  def change
    create_table :games do |t|
      t.references :sport, null: false, foreign_key: true
      t.string :external_id
      t.string :home_team
      t.string :away_team
      t.string :home_abbr
      t.string :away_abbr
      t.datetime :game_date
      t.string :venue
      t.string :status

      t.timestamps
    end
  end
end
