namespace :backtest do
  desc "Fetch all 2025-26 season games with scores for backtest"
  task fetch_season: :environment do
    require 'net/http'
    require 'json'

    puts "Fetching 2025-26 NBA season games..."

    # Season runs from Oct 2025 to Apr 2026
    # We'll fetch month by month
    all_games = []

    months = [
      ["202510", "October 2025"],
      ["202511", "November 2025"],
      ["202512", "December 2025"],
      ["202601", "January 2026"]
    ]

    months.each do |month_code, month_name|
      puts "Fetching #{month_name}..."

      # Fetch each day of the month
      start_date = Date.parse("#{month_code}01")
      end_date = start_date.end_of_month
      end_date = Date.today - 1.day if end_date >= Date.today

      (start_date..end_date).each do |date|
        date_str = date.strftime("%Y%m%d")
        uri = URI("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates=#{date_str}")

        begin
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
          http.read_timeout = 10

          response = http.get(uri.request_uri)
          data = JSON.parse(response.body)

          events = data["events"] || []
          events.each do |event|
            comp = event["competitions"]&.first
            next unless comp

            status = comp.dig("status", "type", "name")
            next unless status == "STATUS_FINAL"

            home = comp["competitors"].find { |c| c["homeAway"] == "home" }
            away = comp["competitors"].find { |c| c["homeAway"] == "away" }

            # Get spread from odds if available
            spread = nil
            odds = comp["odds"]&.first
            if odds
              spread = odds["spread"]&.to_f
            end

            game_data = {
              date: date,
              home_team: home.dig("team", "displayName"),
              away_team: away.dig("team", "displayName"),
              home_score: home["score"].to_i,
              away_score: away["score"].to_i,
              spread: spread,  # negative = home favored
              total: (home["score"].to_i + away["score"].to_i)
            }

            all_games << game_data
          end

          print "."
          sleep 0.1  # Rate limiting
        rescue => e
          puts "\nError on #{date}: #{e.message}"
        end
      end
      puts ""
    end

    # Save to file
    output_path = Rails.root.join("tmp", "backtest_games.json")
    File.write(output_path, JSON.pretty_generate(all_games))

    puts "\nSaved #{all_games.count} games to #{output_path}"

    # Show sample
    puts "\nSample games:"
    all_games.last(5).each do |g|
      puts "  #{g[:date]}: #{g[:away_team]} #{g[:away_score]} @ #{g[:home_team]} #{g[:home_score]} (spread: #{g[:spread]})"
    end
  end

  desc "Build team stats history for backtest"
  task build_stats: :environment do
    games_path = Rails.root.join("tmp", "backtest_games.json")
    unless File.exist?(games_path)
      puts "Run 'rake backtest:fetch_season' first"
      exit 1
    end

    games = JSON.parse(File.read(games_path), symbolize_names: true)
    games.sort_by! { |g| g[:date] }

    puts "Building rolling stats for #{games.count} games..."

    # Track team stats over time
    team_stats = Hash.new { |h, k| h[k] = { games: [], wins: 0, losses: 0, ats_wins: 0, ats_losses: 0, points_for: [], points_against: [] } }

    enriched_games = []

    games.each_with_index do |game, idx|
      home = game[:home_team]
      away = game[:away_team]

      # Calculate pre-game stats (what we'd know before this game)
      home_stats = calculate_pregame_stats(team_stats[home])
      away_stats = calculate_pregame_stats(team_stats[away])

      # Check schedule factors
      home_b2b = check_b2b(team_stats[home][:games], game[:date])
      away_b2b = check_b2b(team_stats[away][:games], game[:date])
      home_rest = days_rest(team_stats[home][:games], game[:date])
      away_rest = days_rest(team_stats[away][:games], game[:date])

      # Enrich game with pre-game context
      enriched = game.merge({
        home_record: "#{home_stats[:wins]}-#{home_stats[:losses]}",
        away_record: "#{away_stats[:wins]}-#{away_stats[:losses]}",
        home_ats: "#{home_stats[:ats_wins]}-#{home_stats[:ats_losses]}",
        away_ats: "#{away_stats[:ats_wins]}-#{away_stats[:ats_losses]}",
        home_last5_ats: home_stats[:last5_ats],
        away_last5_ats: away_stats[:last5_ats],
        home_ppg: home_stats[:ppg],
        away_ppg: away_stats[:ppg],
        home_papg: home_stats[:papg],
        away_papg: away_stats[:papg],
        home_streak: home_stats[:streak],
        away_streak: away_stats[:streak],
        home_b2b: home_b2b,
        away_b2b: away_b2b,
        home_rest: home_rest,
        away_rest: away_rest
      })

      enriched_games << enriched

      # Now update stats with this game's result
      margin = game[:home_score] - game[:away_score]
      spread = game[:spread] || 0

      # Home team
      team_stats[home][:games] << { date: game[:date], opponent: away, home: true, pf: game[:home_score], pa: game[:away_score], margin: margin, spread: spread }
      team_stats[home][:points_for] << game[:home_score]
      team_stats[home][:points_against] << game[:away_score]
      if margin > 0
        team_stats[home][:wins] += 1
      else
        team_stats[home][:losses] += 1
      end
      # ATS: home covers if margin > -spread (spread is negative for home favorite)
      if spread != 0 && margin > -spread
        team_stats[home][:ats_wins] += 1
      elsif spread != 0
        team_stats[home][:ats_losses] += 1
      end

      # Away team
      team_stats[away][:games] << { date: game[:date], opponent: home, home: false, pf: game[:away_score], pa: game[:home_score], margin: -margin, spread: -spread }
      team_stats[away][:points_for] << game[:away_score]
      team_stats[away][:points_against] << game[:home_score]
      if margin < 0
        team_stats[away][:wins] += 1
      else
        team_stats[away][:losses] += 1
      end
      if spread != 0 && -margin > spread
        team_stats[away][:ats_wins] += 1
      elsif spread != 0
        team_stats[away][:ats_losses] += 1
      end

      print "." if idx % 50 == 0
    end

    puts ""

    # Save enriched games
    output_path = Rails.root.join("tmp", "backtest_enriched.json")
    File.write(output_path, JSON.pretty_generate(enriched_games))

    puts "Saved #{enriched_games.count} enriched games to #{output_path}"
  end

  desc "Run backtest with all analysts"
  task run: :environment do
    games_path = Rails.root.join("tmp", "backtest_enriched.json")
    unless File.exist?(games_path)
      puts "Run 'rake backtest:build_stats' first"
      exit 1
    end

    games = JSON.parse(File.read(games_path), symbolize_names: true)

    # Skip first 2 weeks (not enough data)
    games = games.select { |g| Date.parse(g[:date].to_s) >= Date.parse("2025-11-01") }

    puts "Running backtest on #{games.count} games..."
    puts "=" * 60

    # Analyst results tracking
    analysts = {
      sharp: { spread_w: 0, spread_l: 0, spread_pass: 0, ou_w: 0, ou_l: 0, ou_pass: 0 },
      scout: { spread_w: 0, spread_l: 0, spread_pass: 0, ou_w: 0, ou_l: 0, ou_pass: 0 },
      contrarian: { spread_w: 0, spread_l: 0, spread_pass: 0, ou_w: 0, ou_l: 0, ou_pass: 0 },
      momentum: { spread_w: 0, spread_l: 0, spread_pass: 0, ou_w: 0, ou_l: 0, ou_pass: 0 },
      system: { spread_w: 0, spread_l: 0, spread_pass: 0, ou_w: 0, ou_l: 0, ou_pass: 0 }
    }

    games.each do |game|
      next unless game[:spread] && game[:spread] != 0

      margin = game[:home_score] - game[:away_score]
      spread = game[:spread]
      total = game[:total]

      # SHARP: Point differential based
      sharp_pick = sharp_analyze(game)
      record_result(analysts[:sharp], sharp_pick, margin, spread, total, game)

      # SCOUT: Efficiency matchup
      scout_pick = scout_analyze(game)
      record_result(analysts[:scout], scout_pick, margin, spread, total, game)

      # CONTRARIAN: Fade cold teams, back cold teams
      contrarian_pick = contrarian_analyze(game)
      record_result(analysts[:contrarian], contrarian_pick, margin, spread, total, game)

      # MOMENTUM: Recent ATS form
      momentum_pick = momentum_analyze(game)
      record_result(analysts[:momentum], momentum_pick, margin, spread, total, game)

      # SYSTEM: Schedule-based
      system_pick = system_analyze(game)
      record_result(analysts[:system], system_pick, margin, spread, total, game)
    end

    # Print results
    puts "\n" + "=" * 60
    puts "BACKTEST RESULTS"
    puts "=" * 60

    puts "\n📊 SPREAD PERFORMANCE:"
    analysts.each do |name, stats|
      total = stats[:spread_w] + stats[:spread_l]
      next if total == 0
      pct = (stats[:spread_w].to_f / total * 100).round(1)
      emoji = pct >= 53 ? "✅" : (pct >= 50 ? "➖" : "❌")
      puts "#{emoji} #{name.to_s.upcase.ljust(12)} #{stats[:spread_w]}-#{stats[:spread_l]} (#{pct}%) | Pass: #{stats[:spread_pass]}"
    end

    puts "\n📊 O/U PERFORMANCE:"
    analysts.each do |name, stats|
      total = stats[:ou_w] + stats[:ou_l]
      next if total == 0
      pct = (stats[:ou_w].to_f / total * 100).round(1)
      emoji = pct >= 53 ? "✅" : (pct >= 50 ? "➖" : "❌")
      puts "#{emoji} #{name.to_s.upcase.ljust(12)} #{stats[:ou_w]}-#{stats[:ou_l]} (#{pct}%) | Pass: #{stats[:ou_pass]}"
    end

    # Save results
    output_path = Rails.root.join("tmp", "backtest_results.json")
    File.write(output_path, JSON.pretty_generate(analysts))
    puts "\nResults saved to #{output_path}"
  end

  private

  def calculate_pregame_stats(stats)
    games = stats[:games]
    return { wins: 0, losses: 0, ats_wins: 0, ats_losses: 0, last5_ats: 0, ppg: 0, papg: 0, streak: 0 } if games.empty?

    last5 = games.last(5)
    last5_ats = last5.count { |g| g[:margin] > -g[:spread] }

    # Calculate streak
    streak = 0
    games.reverse.each do |g|
      if g[:margin] > 0
        break if streak < 0
        streak += 1
      else
        break if streak > 0
        streak -= 1
      end
    end

    {
      wins: stats[:wins],
      losses: stats[:losses],
      ats_wins: stats[:ats_wins],
      ats_losses: stats[:ats_losses],
      last5_ats: last5_ats,
      ppg: (stats[:points_for].sum.to_f / stats[:points_for].count).round(1),
      papg: (stats[:points_against].sum.to_f / stats[:points_against].count).round(1),
      streak: streak
    }
  end

  def check_b2b(games, date)
    return false if games.empty?
    last_game = games.last
    (Date.parse(date.to_s) - Date.parse(last_game[:date].to_s)).to_i == 1
  end

  def days_rest(games, date)
    return 7 if games.empty?
    (Date.parse(date.to_s) - Date.parse(games.last[:date].to_s)).to_i
  end

  # SHARP: Based on point differential and efficiency
  def sharp_analyze(game)
    home_diff = (game[:home_ppg] || 0) - (game[:home_papg] || 0)
    away_diff = (game[:away_ppg] || 0) - (game[:away_papg] || 0)

    expected_margin = home_diff - away_diff + 3  # Home court ~3 points
    spread = game[:spread] || 0

    edge = expected_margin - (-spread)  # spread is negative for home fav

    spread_pick = nil
    if edge > 3
      spread_pick = :home
    elsif edge < -3
      spread_pick = :away
    end

    # O/U: Based on pace (ppg)
    expected_total = (game[:home_ppg] || 110) + (game[:away_ppg] || 110)
    ou_line = expected_total  # Rough estimate if no line

    ou_pick = nil
    if game[:home_ppg] && game[:away_ppg]
      if expected_total > 225
        ou_pick = :over
      elsif expected_total < 215
        ou_pick = :under
      end
    end

    { spread: spread_pick, ou: ou_pick }
  end

  # SCOUT: Matchup based (simplified - offensive vs defensive efficiency)
  def scout_analyze(game)
    # Home offense vs Away defense
    home_off = game[:home_ppg] || 110
    away_def = game[:away_papg] || 110

    # Away offense vs Home defense
    away_off = game[:away_ppg] || 110
    home_def = game[:home_papg] || 110

    home_expected = (home_off + away_def) / 2
    away_expected = (away_off + home_def) / 2

    matchup_edge = home_expected - away_expected + 3

    spread_pick = nil
    if matchup_edge > 4
      spread_pick = :home
    elsif matchup_edge < -4
      spread_pick = :away
    end

    # O/U based on defensive matchup
    total_expected = home_expected + away_expected
    ou_pick = nil
    if home_def < 108 && away_def < 108  # Both good defenses
      ou_pick = :under
    elsif home_def > 115 && away_def > 115  # Both bad defenses
      ou_pick = :over
    end

    { spread: spread_pick, ou: ou_pick }
  end

  # CONTRARIAN: Fade public (approximated by betting against streaks)
  def contrarian_analyze(game)
    home_streak = game[:home_streak] || 0
    away_streak = game[:away_streak] || 0

    spread_pick = nil
    # Fade teams on big win streaks (public loves them)
    if home_streak >= 4
      spread_pick = :away
    elsif away_streak >= 4
      spread_pick = :home
    # Back teams on losing streaks (public hates them)
    elsif home_streak <= -3
      spread_pick = :home
    elsif away_streak <= -3
      spread_pick = :away
    end

    # O/U: Contrarian on totals - if both scoring a lot, go under
    ou_pick = nil
    if (game[:home_ppg] || 0) > 115 && (game[:away_ppg] || 0) > 115
      ou_pick = :under  # Public will bet over
    elsif (game[:home_ppg] || 0) < 105 && (game[:away_ppg] || 0) < 105
      ou_pick = :over  # Public will bet under
    end

    { spread: spread_pick, ou: ou_pick }
  end

  # MOMENTUM: Recent ATS performance
  def momentum_analyze(game)
    home_ats = game[:home_last5_ats] || 0
    away_ats = game[:away_last5_ats] || 0

    spread_pick = nil
    if home_ats >= 4 && away_ats <= 1
      spread_pick = :home
    elsif away_ats >= 4 && home_ats <= 1
      spread_pick = :away
    elsif home_ats >= 4
      spread_pick = :home
    elsif away_ats >= 4
      spread_pick = :away
    end

    # O/U: Teams on hot streaks tend to score more
    ou_pick = nil
    home_streak = game[:home_streak] || 0
    away_streak = game[:away_streak] || 0
    if home_streak >= 3 && away_streak >= 3
      ou_pick = :over
    elsif home_streak <= -3 && away_streak <= -3
      ou_pick = :under
    end

    { spread: spread_pick, ou: ou_pick }
  end

  # SYSTEM: Schedule-based rules
  def system_analyze(game)
    home_b2b = game[:home_b2b]
    away_b2b = game[:away_b2b]
    home_rest = game[:home_rest] || 2
    away_rest = game[:away_rest] || 2

    spread_pick = nil

    # B2B disadvantage
    if away_b2b && !home_b2b
      spread_pick = :home
    elsif home_b2b && !away_b2b
      spread_pick = :away
    end

    # Rest advantage (3+ days vs 1 day)
    if spread_pick.nil?
      if home_rest >= 3 && away_rest <= 1
        spread_pick = :home
      elsif away_rest >= 3 && home_rest <= 1
        spread_pick = :away
      end
    end

    # O/U: B2B teams tend to score less
    ou_pick = nil
    if home_b2b || away_b2b
      ou_pick = :under
    elsif home_rest >= 3 && away_rest >= 3
      ou_pick = :over  # Well rested = more energy
    end

    { spread: spread_pick, ou: ou_pick }
  end

  def record_result(analyst, picks, margin, spread, total, game)
    # Spread result
    if picks[:spread]
      home_covered = margin > -spread
      if picks[:spread] == :home
        if home_covered
          analyst[:spread_w] += 1
        else
          analyst[:spread_l] += 1
        end
      else  # away
        if home_covered
          analyst[:spread_l] += 1
        else
          analyst[:spread_w] += 1
        end
      end
    else
      analyst[:spread_pass] += 1
    end

    # O/U result (estimate line as 220 if not available)
    ou_line = 220
    if picks[:ou]
      if picks[:ou] == :over
        if total > ou_line
          analyst[:ou_w] += 1
        else
          analyst[:ou_l] += 1
        end
      else  # under
        if total < ou_line
          analyst[:ou_w] += 1
        else
          analyst[:ou_l] += 1
        end
      end
    else
      analyst[:ou_pass] += 1
    end
  end
end
