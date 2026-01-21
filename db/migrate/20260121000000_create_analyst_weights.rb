class CreateAnalystWeights < ActiveRecord::Migration[7.1]
  def change
    create_table :analyst_weights do |t|
      t.string :analyst_name, null: false  # SHARP, SCOUT, CONTRARIAN, MOMENTUM, SYSTEM
      t.decimal :accuracy, precision: 5, scale: 3  # 0.619 = 61.9%
      t.decimal :weight, precision: 4, scale: 2    # 1.0, 0.7, -0.5 etc
      t.string :signal_type  # main, secondary, reverse
      t.integer :sample_size  # backtest sample count
      t.date :last_backtest_date
      t.text :notes

      t.timestamps
    end

    add_index :analyst_weights, :analyst_name, unique: true

    # Seed initial data from backtest results
    reversible do |dir|
      dir.up do
        execute <<-SQL
          INSERT INTO analyst_weights (analyst_name, accuracy, weight, signal_type, sample_size, last_backtest_date, notes, created_at, updated_at)
          VALUES
            ('CONTRARIAN', 0.619, 1.0, 'main', 500, '2026-01-21', 'Best performer - main signal', datetime('now'), datetime('now')),
            ('SYSTEM', 0.555, 0.7, 'secondary', 500, '2026-01-21', 'Secondary signal', datetime('now'), datetime('now')),
            ('SHARP', 0.401, -0.5, 'reverse', 500, '2026-01-21', 'Use as reverse indicator', datetime('now'), datetime('now')),
            ('MOMENTUM', 0.452, -0.3, 'reverse', 500, '2026-01-21', 'Use as reverse indicator', datetime('now'), datetime('now')),
            ('SCOUT', 0.500, 0.0, 'neutral', 500, '2026-01-21', 'Neutral - informational only', datetime('now'), datetime('now'));
        SQL
      end
    end
  end
end
