class GameResult < ApplicationRecord
  belongs_to :game

  scope :with_spread_result, -> { where.not(spread_result: nil) }
  scope :with_total_result, -> { where.not(total_result: nil) }
  scope :home_covered, -> { where(spread_result: 'home_covered') }
  scope :away_covered, -> { where(spread_result: 'away_covered') }
  scope :over, -> { where(total_result: 'over') }
  scope :under, -> { where(total_result: 'under') }

  # Calculate ATS/OU records for a team
  def self.ats_record_for_team(team_abbr)
    home_games = joins(:game).where(games: { home_abbr: team_abbr }).with_spread_result
    away_games = joins(:game).where(games: { away_abbr: team_abbr }).with_spread_result

    wins = home_games.home_covered.count + away_games.away_covered.count
    losses = home_games.away_covered.count + away_games.home_covered.count
    pushes = home_games.where(spread_result: 'push').count + away_games.where(spread_result: 'push').count

    { wins: wins, losses: losses, pushes: pushes, record: "#{wins}-#{losses}-#{pushes}" }
  end

  def self.ou_record_for_team(team_abbr)
    games = joins(:game).where("games.home_abbr = ? OR games.away_abbr = ?", team_abbr, team_abbr)
                       .with_total_result

    overs = games.over.count
    unders = games.under.count
    pushes = games.where(total_result: 'push').count

    { overs: overs, unders: unders, pushes: pushes, record: "#{overs}-#{unders}-#{pushes}" }
  end

  # Capture pre-game lines from current game data
  def capture_lines!
    return if lines_captured_at.present?

    self.opening_spread ||= game.home_spread
    self.closing_spread = game.home_spread
    self.opening_total ||= game.total_line
    self.closing_total = game.total_line
    self.lines_captured_at = Time.current
    save!
  end

  # Calculate result after game finishes
  def calculate_result!
    return unless game.home_score.present? && game.away_score.present?
    return if result_captured_at.present?

    self.home_score = game.home_score
    self.away_score = game.away_score
    self.margin = home_score - away_score

    # ATS calculation (using closing spread)
    if closing_spread.present?
      adjusted_margin = margin + closing_spread  # Home score + spread
      self.spread_result = if adjusted_margin > 0
        'home_covered'
      elsif adjusted_margin < 0
        'away_covered'
      else
        'push'
      end
      self.spread_covered_home = (spread_result == 'home_covered')
    end

    # O/U calculation
    if closing_total.present?
      total_points = home_score + away_score
      self.total_result = if total_points > closing_total
        'over'
      elsif total_points < closing_total
        'under'
      else
        'push'
      end
      self.total_over = (total_result == 'over')
    end

    self.result_captured_at = Time.current
    save!
  end
end
