# frozen_string_literal: true

# AnalystPick - 분석가별 개별 픽 저장
#
# RALPH 시스템의 핵심: 각 분석가의 픽을 저장하고 결과를 추적
#
class AnalystPick < ApplicationRecord
  belongs_to :report

  ANALYSTS = AnalystWeight::ANALYSTS
  PICK_SIDES = %w[HOME AWAY].freeze

  validates :analyst_name, presence: true, inclusion: { in: ANALYSTS }
  validates :pick_side, presence: true, inclusion: { in: PICK_SIDES }
  validates :analyst_name, uniqueness: { scope: :report_id }

  scope :by_analyst, ->(name) { where(analyst_name: name) }
  scope :evaluated, -> { where.not(correct: nil) }
  scope :pending_evaluation, -> { where(correct: nil) }
  scope :correct_picks, -> { where(correct: true) }
  scope :incorrect_picks, -> { where(correct: false) }

  # Record picks from report generation
  def self.record_picks(report, picks_hash)
    picks_hash.each do |analyst_name, pick_data|
      next unless ANALYSTS.include?(analyst_name)

      pick_side = pick_data.is_a?(Hash) ? pick_data[:side] : pick_data
      confidence = pick_data.is_a?(Hash) ? pick_data[:confidence] : nil
      rationale = pick_data.is_a?(Hash) ? pick_data[:rationale] : nil

      find_or_create_by!(report: report, analyst_name: analyst_name) do |ap|
        ap.pick_side = pick_side.to_s.upcase
        ap.confidence = confidence
        ap.rationale = rationale
      end
    end
  end

  # Evaluate picks after game result is known
  def self.evaluate_for_report(report)
    return unless report.result_recorded?

    # Determine winning side from report result
    winning_side = determine_winning_side(report)
    return unless winning_side

    report.analyst_picks.pending_evaluation.find_each do |pick|
      pick.update!(
        correct: pick.pick_side == winning_side,
        evaluated_at: Time.current
      )
    end
  end

  # Calculate accuracy for an analyst over a date range
  def self.accuracy_for_analyst(analyst_name, start_date: nil, end_date: nil)
    scope = by_analyst(analyst_name).evaluated

    if start_date || end_date
      scope = scope.joins(:report)
      scope = scope.where('reports.published_at >= ?', start_date) if start_date
      scope = scope.where('reports.published_at <= ?', end_date) if end_date
    end

    total = scope.count
    return nil if total.zero?

    correct = scope.correct_picks.count
    {
      analyst_name: analyst_name,
      correct: correct,
      total: total,
      accuracy: (correct.to_f / total).round(3),
      period: { start_date: start_date, end_date: end_date }
    }
  end

  # Calculate accuracy for all analysts
  def self.accuracy_all(start_date: nil, end_date: nil)
    ANALYSTS.each_with_object({}) do |analyst, hash|
      result = accuracy_for_analyst(analyst, start_date: start_date, end_date: end_date)
      hash[analyst] = result if result
    end
  end

  private_class_method def self.determine_winning_side(report)
    case report.result
    when 'win'
      report.pick_side&.upcase
    when 'loss'
      report.pick_side&.upcase == 'HOME' ? 'AWAY' : 'HOME'
    else
      nil  # push or pending
    end
  end
end
