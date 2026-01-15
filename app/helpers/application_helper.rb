module ApplicationHelper
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
end
