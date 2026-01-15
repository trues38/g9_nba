class CreateReports < ActiveRecord::Migration[8.1]
  def change
    create_table :reports do |t|
      t.references :game, null: false, foreign_key: true
      t.string :title
      t.text :content
      t.string :pick
      t.string :confidence
      t.string :status
      t.datetime :published_at

      t.timestamps
    end
  end
end
