class AddScheduleNoteToGames < ActiveRecord::Migration[8.1]
  def change
    add_column :games, :schedule_note, :string
    add_column :games, :rest_days, :integer
  end
end
