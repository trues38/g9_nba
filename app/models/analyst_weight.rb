# frozen_string_literal: true

# AnalystWeight - 5인 분석가 가중치 관리
#
# 백테스트 결과를 기반으로 각 분석가의 신뢰도와 가중치를 저장
#
# signal_type:
#   - main: 메인 시그널 (CONTRARIAN)
#   - secondary: 보조 시그널 (SYSTEM)
#   - reverse: 역지표 (SHARP, MOMENTUM)
#   - neutral: 중립/정보용 (SCOUT)
#
class AnalystWeight < ApplicationRecord
  ANALYSTS = %w[SHARP SCOUT CONTRARIAN MOMENTUM SYSTEM].freeze
  SIGNAL_TYPES = %w[main secondary reverse neutral].freeze

  validates :analyst_name, presence: true, uniqueness: true, inclusion: { in: ANALYSTS }
  validates :signal_type, inclusion: { in: SIGNAL_TYPES }, allow_nil: true
  validates :accuracy, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :weight, numericality: true, allow_nil: true

  scope :main_signals, -> { where(signal_type: 'main') }
  scope :secondary_signals, -> { where(signal_type: 'secondary') }
  scope :reverse_signals, -> { where(signal_type: 'reverse') }

  # Calculate weighted score for a pick
  # picks: { 'CONTRARIAN' => 'HOME', 'SHARP' => 'AWAY', ... }
  def self.calculate_weighted_score(picks)
    score = { 'HOME' => 0.0, 'AWAY' => 0.0 }

    all.each do |aw|
      pick = picks[aw.analyst_name]
      next unless pick && aw.weight

      # Reverse indicators: if SHARP says HOME, we count AWAY
      if aw.signal_type == 'reverse'
        opposite = pick == 'HOME' ? 'AWAY' : 'HOME'
        score[opposite] += aw.weight.abs
      else
        score[pick] += aw.weight
      end
    end

    score
  end

  # Get recommendation based on weighted scores
  def self.get_recommendation(picks)
    scores = calculate_weighted_score(picks)
    diff = scores['HOME'] - scores['AWAY']

    {
      scores: scores,
      diff: diff.round(2),
      recommendation: diff > 0.5 ? 'HOME' : (diff < -0.5 ? 'AWAY' : 'PASS'),
      confidence: diff.abs > 1.5 ? 'HIGH' : (diff.abs > 0.8 ? 'MEDIUM' : 'LOW')
    }
  end

  # Update from backtest results
  def self.update_from_backtest(results)
    results.each do |analyst_name, data|
      aw = find_or_initialize_by(analyst_name: analyst_name)
      aw.accuracy = data[:accuracy]
      aw.sample_size = data[:sample_size]
      aw.last_backtest_date = Date.current

      # Auto-calculate weight based on accuracy
      aw.weight = case data[:accuracy]
                  when 0.6.. then 1.0
                  when 0.55..0.6 then 0.7
                  when 0.5..0.55 then 0.3
                  when 0.45..0.5 then -0.3
                  else -0.5
                  end

      aw.signal_type = case aw.weight
                       when 0.8.. then 'main'
                       when 0.5..0.8 then 'secondary'
                       when -0.5..0.5 then 'neutral'
                       else 'reverse'
                       end

      aw.save!
    end
  end
end
