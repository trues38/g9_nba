class CreateInsights < ActiveRecord::Migration[8.1]
  def change
    create_table :insights do |t|
      t.references :sport, null: false, foreign_key: true
      t.string :title
      t.text :content
      t.string :category
      t.string :tags
      t.string :status
      t.datetime :published_at

      t.timestamps
    end
  end
end
