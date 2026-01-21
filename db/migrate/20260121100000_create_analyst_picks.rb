class CreateAnalystPicks < ActiveRecord::Migration[7.1]
  def change
    create_table :analyst_picks do |t|
      t.references :report, null: false, foreign_key: true
      t.string :analyst_name, null: false  # SHARP, SCOUT, CONTRARIAN, MOMENTUM, SYSTEM
      t.string :pick_side, null: false     # HOME, AWAY
      t.string :confidence                  # HIGH, MEDIUM, LOW (optional)
      t.text :rationale                     # 분석 근거 (optional)

      # Result tracking (populated after game)
      t.boolean :correct                    # true if pick matched actual result
      t.datetime :evaluated_at              # when result was evaluated

      t.timestamps
    end

    add_index :analyst_picks, [:report_id, :analyst_name], unique: true
    add_index :analyst_picks, :analyst_name
    add_index :analyst_picks, :correct
  end
end
