class Report < ApplicationRecord
  belongs_to :game

  validates :content, presence: true

  RESULTS = %w[pending win loss push].freeze
  PICK_TYPES = %w[spread total moneyline].freeze

  scope :published, -> { where(status: "published").order(published_at: :desc) }
  scope :draft, -> { where(status: "draft") }
  scope :recent, -> { order(created_at: :desc) }
  scope :free_reports, -> { where(free: true) }
  scope :premium_reports, -> { where(free: false) }

  # Result tracking scopes
  scope :with_result, -> { where.not(result: [nil, "pending"]) }
  scope :pending_result, -> { where(result: [nil, "pending"]) }
  scope :wins, -> { where(result: "win") }
  scope :losses, -> { where(result: "loss") }
  scope :pushes, -> { where(result: "push") }

  delegate :sport, to: :game

  def publish!
    update(status: "published", published_at: Time.current)
  end

  def published?
    status == "published"
  end

  def free?
    free == true
  end

  def premium?
    !free?
  end

  def confidence_stars
    confidence || "---"
  end

  # Result tracking methods
  def record_result!(result_value, home_score: nil, away_score: nil, note: nil)
    update!(
      result: result_value,
      result_recorded_at: Time.current,
      actual_home_score: home_score,
      actual_away_score: away_score,
      result_note: note
    )
  end

  def result_pending?
    result.nil? || result == "pending"
  end

  def result_recorded?
    !result_pending?
  end

  # Auto-calculate result based on scores (for spread/total)
  def calculate_result_from_scores(home_score, away_score)
    return nil unless pick_type.present? && pick_line.present?

    case pick_type
    when "spread"
      calculate_spread_result(home_score, away_score)
    when "total"
      calculate_total_result(home_score, away_score)
    when "moneyline"
      calculate_ml_result(home_score, away_score)
    end
  end

  # Class methods for stats
  class << self
    def stats(scope = all)
      records = scope.with_result
      total = records.count
      return empty_stats if total.zero?

      wins = records.wins.count
      losses = records.losses.count
      pushes = records.pushes.count

      # Calculate units (stake-weighted)
      units_won = records.wins.sum("COALESCE(stake, 1)")
      units_lost = records.losses.sum("COALESCE(stake, 1)")
      net_units = units_won - units_lost
      total_staked = records.sum("COALESCE(stake, 1)")

      {
        total: total,
        wins: wins,
        losses: losses,
        pushes: pushes,
        win_rate: (wins.to_f / [total - pushes, 1].max * 100).round(1),
        net_units: net_units.round(2),
        roi: total_staked.positive? ? ((net_units / total_staked) * 100).round(1) : 0.0
      }
    end

    def stats_by_pick_type(scope = all)
      PICK_TYPES.each_with_object({}) do |pick_type, hash|
        hash[pick_type] = stats(scope.where(pick_type: pick_type))
      end
    end

    def stats_by_consensus(scope = all)
      scope.with_result
           .group(:analyst_consensus)
           .pluck(:analyst_consensus)
           .compact
           .each_with_object({}) do |consensus, hash|
        hash[consensus] = stats(scope.where(analyst_consensus: consensus))
      end
    end

    def stats_by_month(scope = all)
      scope.with_result
           .group_by { |r| r.published_at&.strftime("%Y-%m") }
           .transform_values { |reports| stats(where(id: reports.map(&:id))) }
    end

    private

    def empty_stats
      { total: 0, wins: 0, losses: 0, pushes: 0, win_rate: 0.0, net_units: 0.0, roi: 0.0 }
    end
  end

  private

  def calculate_spread_result(home_score, away_score)
    margin = home_score - away_score
    # pick_side: "home" means betting home team, line is home spread
    adjusted_margin = pick_side == "home" ? margin + pick_line : -margin + pick_line

    if adjusted_margin > 0
      "win"
    elsif adjusted_margin < 0
      "loss"
    else
      "push"
    end
  end

  def calculate_total_result(home_score, away_score)
    total = home_score + away_score
    diff = total - pick_line

    if pick_side == "over"
      diff > 0 ? "win" : (diff < 0 ? "loss" : "push")
    else # under
      diff < 0 ? "win" : (diff > 0 ? "loss" : "push")
    end
  end

  def calculate_ml_result(home_score, away_score)
    home_won = home_score > away_score

    if pick_side == "home"
      home_won ? "win" : "loss"
    else
      home_won ? "loss" : "win"
    end
  end
end
