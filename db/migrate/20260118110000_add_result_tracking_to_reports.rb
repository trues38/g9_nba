class AddResultTrackingToReports < ActiveRecord::Migration[8.1]
  def change
    # Result tracking
    add_column :reports, :result, :string  # win, loss, push, pending
    add_column :reports, :result_recorded_at, :datetime
    add_column :reports, :result_note, :text  # 내부 메모 (분석 회고용)

    # Pick details for accurate tracking
    add_column :reports, :pick_type, :string  # spread, total, moneyline
    add_column :reports, :pick_line, :decimal  # e.g., -7.5, 220.5
    add_column :reports, :pick_side, :string  # home, away, over, under
    add_column :reports, :stake, :decimal, default: 1.0  # units

    # Actual game results
    add_column :reports, :actual_home_score, :integer
    add_column :reports, :actual_away_score, :integer

    # Analyst attribution (for per-analyst stats)
    add_column :reports, :analyst_consensus, :string  # e.g., "5/5", "4/5", "3/5"

    add_index :reports, :result
    add_index :reports, :pick_type
    add_index :reports, [:result, :pick_type]
  end
end
