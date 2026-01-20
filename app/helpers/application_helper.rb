module ApplicationHelper
  # Confidence gradient for report cards (1-5 scale)
  def confidence_gradient(level)
    case level.to_i
    when 5
      "from-green-600 to-green-500"
    when 4
      "from-blue-600 to-blue-500"
    when 3
      "from-yellow-600 to-yellow-500"
    when 2
      "from-orange-600 to-orange-500"
    else
      "from-gray-600 to-gray-500"
    end
  end

  # Alias for markdown helper (used in report views)
  def render_markdown(text)
    markdown(text)
  end

  def markdown(text)
    return "" if text.blank?

    renderer = Redcarpet::Render::HTML.new(
      hard_wrap: true,
      link_attributes: { target: "_blank", rel: "noopener" }
    )
    markdown = Redcarpet::Markdown.new(
      renderer,
      autolink: true,
      tables: true,
      fenced_code_blocks: true,
      strikethrough: true,
      underline: true,
      highlight: true
    )
    markdown.render(text).html_safe
  end

  def injuries_for_team(team_abbr)
    @injuries_cache ||= load_injuries_cache
    @injuries_cache[team_abbr] || []
  end

  def key_injuries_for_team(team_abbr)
    injuries = injuries_for_team(team_abbr)
    # Filter to Out/Doubtful only
    injuries.select { |i| i["status"]&.match?(/Out|Doubtful/i) }
  end

  def lineup_for_team(team_abbr)
    @lineups_cache ||= load_lineups_cache
    @lineups_cache[team_abbr] || []
  end

  # Returns: :upcoming, :live, :finished
  def game_status(game)
    # Trust ESPN status for live/finished
    case game.status&.downcase
    when "live"
      return :live
    when "finished"
      return :finished
    end

    # Time-based estimation for scheduled/unknown
    now = Time.current.in_time_zone("Asia/Seoul")
    game_time = game.game_date.in_time_zone("Asia/Seoul")
    game_end_estimate = game_time + 2.5.hours

    if now < game_time
      :upcoming
    elsif now >= game_time && now < game_end_estimate
      :live
    else
      :finished
    end
  end

  private

  def load_injuries_cache
    cache_path = Rails.root.join("tmp", "injuries.json")
    return {} unless File.exist?(cache_path)

    JSON.parse(File.read(cache_path))
  rescue JSON::ParserError
    {}
  end

  def load_lineups_cache
    cache_path = Rails.root.join("tmp", "lineups.json")
    return {} unless File.exist?(cache_path)

    JSON.parse(File.read(cache_path))
  rescue JSON::ParserError
    {}
  end

  def load_trends_cache
    cache_path = Rails.root.join("tmp", "team_trends.json")
    return {} unless File.exist?(cache_path)

    JSON.parse(File.read(cache_path))
  rescue JSON::ParserError
    {}
  end

  def load_players_cache
    cache_path = Rails.root.join("tmp", "players.json")
    return {} unless File.exist?(cache_path)

    JSON.parse(File.read(cache_path))
  rescue JSON::ParserError
    {}
  end

  def load_rosters_cache
    cache_path = Rails.root.join("tmp", "rosters.json")
    return {} unless File.exist?(cache_path)

    JSON.parse(File.read(cache_path))
  rescue JSON::ParserError
    {}
  end

  # Get team trends data
  def trends_for_team(team_abbr)
    @trends_cache ||= load_trends_cache
    @trends_cache[team_abbr] || {}
  end

  # Format team trend summary for display
  def team_trend_summary(team_abbr)
    data = trends_for_team(team_abbr)
    return nil if data.empty?

    {
      record: data["record"],
      streak: data["current_streak"] || data["streak"],
      last_10: data["last_10"],
      home: data["home_record"],
      away: data["away_record"],
      ppg: data["ppg"],
      opp_ppg: data["opp_ppg"],
      recent_ppg: data["recent_ppg"],
      scoring_trend: data["scoring_trend_dir"],
      ats_record: data.dig("ats", "record"),
      ats_last_5: data["ats_last_5"],
      ou_record: data.dig("ou", "record"),
      ou_last_5: data["ou_last_5"],
      recent_games: data["recent_games"]&.first(5) || []
    }
  end

  # Get player's current team (from roster data)
  def player_team(player_name)
    @players_cache ||= load_players_cache
    @players_cache[player_name]
  end

  # Get team roster
  def roster_for_team(team_abbr)
    @rosters_cache ||= load_rosters_cache
    @rosters_cache[team_abbr] || {}
  end

  # Get key players for a team (starters/stars)
  def key_players_for_team(team_abbr)
    roster = roster_for_team(team_abbr)
    roster["players"]&.first(8) || []
  end

  # Get matchup analysis data for two teams
  def matchup_trends(home_abbr, away_abbr)
    home = trends_for_team(home_abbr)
    away = trends_for_team(away_abbr)

    return nil if home.empty? || away.empty?

    {
      home: {
        abbr: home_abbr,
        record: home["record"],
        home_record: home["home_record"],
        streak: home["current_streak"],
        ppg: home["ppg"],
        recent_ppg: home["recent_ppg"],
        trend: home["scoring_trend_dir"],
        ats: home.dig("ats", "record"),
        ats_l5: home["ats_last_5"],
        ou: home.dig("ou", "record"),
        ou_l5: home["ou_last_5"],
        form: home["recent_games"]&.first(5)&.map { |g| g["result"] }&.join || ""
      },
      away: {
        abbr: away_abbr,
        record: away["record"],
        away_record: away["away_record"],
        streak: away["current_streak"],
        ppg: away["ppg"],
        recent_ppg: away["recent_ppg"],
        trend: away["scoring_trend_dir"],
        ats: away.dig("ats", "record"),
        ats_l5: away["ats_last_5"],
        ou: away.dig("ou", "record"),
        ou_l5: away["ou_last_5"],
        form: away["recent_games"]&.first(5)&.map { |g| g["result"] }&.join || ""
      }
    }
  end
end
