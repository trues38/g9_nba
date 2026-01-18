module ApplicationHelper
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
end
