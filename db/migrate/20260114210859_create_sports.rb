class CreateSports < ActiveRecord::Migration[8.1]
  def change
    create_table :sports do |t|
      t.string :name
      t.string :slug
      t.string :icon
      t.boolean :active
      t.integer :position

      t.timestamps
    end
  end
end
