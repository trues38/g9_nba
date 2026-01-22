# frozen_string_literal: true

class WeaknessPrediction < ApplicationRecord
  belongs_to :game

  # Trigger types - Schedule based
  SCHEDULE_TRIGGERS = %w[B2B 3IN4 REST_DISADVANTAGE LONG_ROAD_TRIP HOME_STAND_END].freeze

  # Trigger types - Matchup based
  MATCHUP_TRIGGERS = %w[BAD_MATCHUP_OFFENSE BAD_MATCHUP_DEFENSE PACE_MISMATCH_SLOW PACE_MISMATCH_FAST].freeze

  # All trigger types
  TRIGGER_TYPES = (SCHEDULE_TRIGGERS + MATCHUP_TRIGGERS).freeze

  # Predicted outcomes
  OUTCOMES = %w[LOSS UNDER COVER_FAIL].freeze

  validates :team, presence: true
  validates :trigger_type, presence: true, inclusion: { in: TRIGGER_TYPES }

  scope :evaluated, -> { where.not(evaluated_at: nil) }
  scope :unevaluated, -> { where(evaluated_at: nil) }
  scope :hits, -> { where(hit: true) }
  scope :misses, -> { where(hit: false) }
  scope :by_trigger, ->(type) { where(trigger_type: type) }
  scope :by_team, ->(team) { where(team: team) }

  class << self
    # Load advanced team stats from cache
    def load_advanced_stats
      cache_path = Rails.root.join("tmp", "team_advanced_stats.json")
      return {} unless File.exist?(cache_path)

      JSON.parse(File.read(cache_path))
    rescue JSON::ParserError
      {}
    end

    # Detect and create predictions for upcoming games
    def detect_triggers_for_game(game)
      predictions = []
      advanced_stats = load_advanced_stats

      # Check home team triggers (schedule + matchup)
      home_triggers = detect_team_triggers(game, :home)
      home_triggers += detect_matchup_triggers(game, :home, advanced_stats)
      home_triggers.each do |trigger|
        predictions << create_prediction(game, game.home_team, trigger)
      end

      # Check away team triggers (schedule + matchup)
      away_triggers = detect_team_triggers(game, :away)
      away_triggers += detect_matchup_triggers(game, :away, advanced_stats)
      away_triggers.each do |trigger|
        predictions << create_prediction(game, game.away_team, trigger)
      end

      predictions.compact
    end

    # Detect schedule-based triggers (B2B, 3in4, etc.)
    def detect_team_triggers(game, side)
      triggers = []
      edge_field = side == :home ? :home_edge : :away_edge
      edge_value = game.send(edge_field)

      return triggers unless edge_value.present?

      # Parse edge value (e.g., "B2B", "3in4", "REST-1")
      if edge_value.include?("B2B")
        triggers << {
          type: "B2B",
          detail: "2nd game of back-to-back",
          confidence: 0.65,
          predicted_outcome: "COVER_FAIL"
        }
      end

      if edge_value.include?("3in4") || edge_value.include?("3IN4")
        triggers << {
          type: "3IN4",
          detail: "3rd game in 4 days",
          confidence: 0.60,
          predicted_outcome: "COVER_FAIL"
        }
      end

      # Check rest disadvantage
      if edge_value.match?(/REST-?\d+/)
        rest_diff = edge_value.scan(/REST-?(\d+)/).flatten.first&.to_i || 0
        if rest_diff >= 2
          triggers << {
            type: "REST_DISADVANTAGE",
            detail: "#{rest_diff} fewer rest days",
            confidence: 0.55,
            predicted_outcome: "COVER_FAIL"
          }
        end
      end

      triggers
    end

    # Detect matchup-based triggers using advanced stats
    def detect_matchup_triggers(game, side, advanced_stats)
      triggers = []
      return triggers if advanced_stats.empty?

      team_abbr = side == :home ? game.home_abbr : game.away_abbr
      opp_abbr = side == :home ? game.away_abbr : game.home_abbr

      team_stats = advanced_stats[team_abbr]
      opp_stats = advanced_stats[opp_abbr]

      return triggers unless team_stats && opp_stats

      # BAD_MATCHUP_OFFENSE: Weak offense (rank > 20) vs elite defense (rank <= 5)
      if (team_stats["off_rank"] || 15) > 20 && (opp_stats["def_rank"] || 15) <= 5
        triggers << {
          type: "BAD_MATCHUP_OFFENSE",
          detail: "Weak OFF (##{team_stats['off_rank']}) vs Elite DEF (##{opp_stats['def_rank']} #{opp_abbr})",
          confidence: 0.60,
          predicted_outcome: "COVER_FAIL"
        }
      end

      # BAD_MATCHUP_DEFENSE: Weak defense (rank > 20) vs elite offense (rank <= 5)
      if (team_stats["def_rank"] || 15) > 20 && (opp_stats["off_rank"] || 15) <= 5
        triggers << {
          type: "BAD_MATCHUP_DEFENSE",
          detail: "Weak DEF (##{team_stats['def_rank']}) vs Elite OFF (##{opp_stats['off_rank']} #{opp_abbr})",
          confidence: 0.58,
          predicted_outcome: "COVER_FAIL"
        }
      end

      # PACE_MISMATCH: Slow team (rank > 25) vs fast team (rank <= 5) - tempo disadvantage
      team_pace_rank = team_stats["pace_rank"] || 15
      opp_pace_rank = opp_stats["pace_rank"] || 15

      if team_pace_rank > 25 && opp_pace_rank <= 5
        triggers << {
          type: "PACE_MISMATCH_SLOW",
          detail: "Slow pace (##{team_pace_rank}) vs Fast (##{opp_pace_rank} #{opp_abbr})",
          confidence: 0.55,
          predicted_outcome: "COVER_FAIL"
        }
      end

      if team_pace_rank <= 5 && opp_pace_rank > 25
        triggers << {
          type: "PACE_MISMATCH_FAST",
          detail: "Fast pace (##{team_pace_rank}) vs Slow (##{opp_pace_rank} #{opp_abbr})",
          confidence: 0.52,
          predicted_outcome: "UNDER"
        }
      end

      triggers
    end

    # Create prediction record
    def create_prediction(game, team, trigger)
      find_or_create_by(
        game: game,
        team: team,
        trigger_type: trigger[:type]
      ) do |pred|
        pred.trigger_detail = trigger[:detail]
        pred.confidence = trigger[:confidence]
        pred.predicted_outcome = trigger[:predicted_outcome]
        pred.triggered_at = Time.current
        pred.source = "Rails"
      end
    end

    # Evaluate predictions after game ends
    def evaluate_game_predictions(game)
      return unless game.finished?

      predictions = where(game: game, evaluated_at: nil)
      return if predictions.empty?

      game_result = GameResult.find_by(game: game)
      return unless game_result

      predictions.each do |pred|
        pred.evaluate_outcome(game_result)
      end
    end

    # Calculate hit rate by trigger type
    def hit_rate_by_trigger(trigger_type, min_samples: 10)
      preds = evaluated.by_trigger(trigger_type)
      return nil if preds.count < min_samples

      {
        trigger_type: trigger_type,
        total: preds.count,
        hits: preds.hits.count,
        misses: preds.misses.count,
        hit_rate: (preds.hits.count.to_f / preds.count * 100).round(1)
      }
    end

    # Calculate hit rate by team
    def hit_rate_by_team(team, min_samples: 5)
      preds = evaluated.by_team(team)
      return nil if preds.count < min_samples

      {
        team: team,
        total: preds.count,
        hits: preds.hits.count,
        hit_rate: (preds.hits.count.to_f / preds.count * 100).round(1),
        by_trigger: TRIGGER_TYPES.map { |t|
          trigger_preds = preds.by_trigger(t)
          next nil if trigger_preds.empty?
          { trigger: t, count: trigger_preds.count, hit_rate: trigger_hit_rate(trigger_preds) }
        }.compact
      }
    end

    # Overall statistics
    def statistics
      evaluated_preds = evaluated

      {
        total_predictions: count,
        evaluated: evaluated_preds.count,
        unevaluated: unevaluated.count,
        overall_hit_rate: evaluated_preds.any? ?
          (evaluated_preds.hits.count.to_f / evaluated_preds.count * 100).round(1) : 0,
        by_trigger: TRIGGER_TYPES.map { |t| hit_rate_by_trigger(t) }.compact
      }
    end

    private

    def trigger_hit_rate(preds)
      return 0 if preds.empty?
      (preds.hits.count.to_f / preds.count * 100).round(1)
    end
  end

  # Instance method: Evaluate outcome
  def evaluate_outcome(game_result)
    return if evaluated_at.present?

    # Determine if prediction hit
    self.actual_outcome = determine_actual_outcome(game_result)
    self.hit = (actual_outcome == predicted_outcome)
    self.evaluated_at = Time.current
    save!
  end

  private

  def determine_actual_outcome(result)
    # Check if the team with trigger failed to cover
    is_home = (game.home_team == team || game.home_abbr == team)

    case result.spread_result
    when "home_covered"
      is_home ? "COVERED" : "COVER_FAIL"
    when "away_covered"
      is_home ? "COVER_FAIL" : "COVERED"
    when "push"
      "PUSH"
    else
      "UNKNOWN"
    end
  end
end
