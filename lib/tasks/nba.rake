namespace :nba do
  desc "Import NBA 2025-26 season schedule from NBA API"
  task import_schedule: :environment do
    require 'net/http'
    require 'json'

    puts "Fetching NBA 2025-26 schedule..."

    uri = URI("https://cdn.nba.com/static/json/staticData/scheduleLeagueV2.json")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE

    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    response = http.request(request)
    data = JSON.parse(response.body)

    sport = Sport.find_or_create_by!(slug: "basketball") do |s|
      s.name = "Basketball"
      s.active = true
    end

    team_names = {
      "ATL" => "Atlanta Hawks", "BOS" => "Boston Celtics", "BKN" => "Brooklyn Nets",
      "CHA" => "Charlotte Hornets", "CHI" => "Chicago Bulls", "CLE" => "Cleveland Cavaliers",
      "DAL" => "Dallas Mavericks", "DEN" => "Denver Nuggets", "DET" => "Detroit Pistons",
      "GSW" => "Golden State Warriors", "HOU" => "Houston Rockets", "IND" => "Indiana Pacers",
      "LAC" => "LA Clippers", "LAL" => "Los Angeles Lakers", "MEM" => "Memphis Grizzlies",
      "MIA" => "Miami Heat", "MIL" => "Milwaukee Bucks", "MIN" => "Minnesota Timberwolves",
      "NOP" => "New Orleans Pelicans", "NYK" => "New York Knicks", "OKC" => "Oklahoma City Thunder",
      "ORL" => "Orlando Magic", "PHI" => "Philadelphia 76ers", "PHX" => "Phoenix Suns",
      "POR" => "Portland Trail Blazers", "SAC" => "Sacramento Kings", "SAS" => "San Antonio Spurs",
      "TOR" => "Toronto Raptors", "UTA" => "Utah Jazz", "WAS" => "Washington Wizards"
    }

    game_dates = data.dig("leagueSchedule", "gameDates") || []
    season = data.dig("leagueSchedule", "seasonYear")
    puts "Found #{game_dates.count} game dates for season #{season}"

    imported = 0
    skipped = 0

    game_dates.each do |game_date|
      games = game_date["games"] || []

      games.each do |game|
        game_id = game["gameId"]
        home_abbr = game.dig("homeTeam", "teamTricode")
        away_abbr = game.dig("awayTeam", "teamTricode")
        game_time = game["gameDateTimeUTC"]
        arena = game["arenaName"]

        next unless home_abbr && away_abbr && game_time

        begin
          parsed_time = Time.parse(game_time)
        rescue
          next
        end

        existing = Game.find_by(external_id: game_id)
        if existing
          skipped += 1
          next
        end

        Game.create!(
          sport: sport,
          external_id: game_id,
          home_team: team_names[home_abbr] || home_abbr,
          away_team: team_names[away_abbr] || away_abbr,
          home_abbr: home_abbr,
          away_abbr: away_abbr,
          game_date: parsed_time,
          venue: arena.presence || "TBD",
          status: "Scheduled"
        )
        imported += 1
        print "." if imported % 50 == 0
      end
    end

    puts "\nImported #{imported} games, skipped #{skipped} existing"
    puts "Total games: #{Game.where(sport: sport).count}"
  end

  desc "Calculate schedule edge - which team has B2B/3in4"
  task calculate_edge: :environment do
    puts "Calculating team-specific schedule edge..."

    sport = Sport.find_by(slug: "basketball")
    unless sport
      puts "Run nba:import_schedule first."
      exit
    end

    # Reset all edge data
    Game.where(sport: sport).update_all(home_edge: nil, away_edge: nil, schedule_note: nil)

    teams = Game.where(sport: sport).pluck(:home_abbr).uniq.compact
    puts "Processing #{teams.count} teams..."

    teams.each do |team|
      games = Game.where(sport: sport)
                  .where("home_abbr = ? OR away_abbr = ?", team, team)
                  .order(:game_date)
                  .to_a

      games.each_with_index do |game, index|
        next if index == 0

        is_home = game.home_abbr == team
        prev_game = games[index - 1]
        days_rest = (game.game_date.to_date - prev_game.game_date.to_date).to_i

        edges = []

        # B2B detection
        if days_rest == 1
          edges << "B2B"
        end

        # 3-in-4 detection
        if index >= 2
          third_prev = games[index - 2]
          span = (game.game_date.to_date - third_prev.game_date.to_date).to_i
          if span <= 3 && !edges.include?("B2B")
            edges << "3in4"
          end
        end

        next if edges.empty?

        edge_str = edges.join(" ")

        if is_home
          current = game.home_edge
          game.update(home_edge: current ? "#{current} #{edge_str}".strip : edge_str)
        else
          current = game.away_edge
          game.update(away_edge: current ? "#{current} #{edge_str}".strip : edge_str)
        end
      end

      print "."
    end

    # Update schedule_note for filtering
    Game.where(sport: sport).where.not(home_edge: [nil, ""]).or(
      Game.where(sport: sport).where.not(away_edge: [nil, ""])
    ).find_each do |game|
      notes = []
      notes << "home:#{game.home_edge}" if game.home_edge.present?
      notes << "away:#{game.away_edge}" if game.away_edge.present?
      game.update(schedule_note: notes.join(" "))
    end

    puts "\nDone!"

    # Stats
    home_b2b = Game.where(sport: sport).where("home_edge LIKE ?", "%B2B%").count
    away_b2b = Game.where(sport: sport).where("away_edge LIKE ?", "%B2B%").count
    puts "Home team B2B: #{home_b2b}"
    puts "Away team B2B: #{away_b2b}"
  end

  desc "Fetch spreads and totals from ESPN API for upcoming games"
  task fetch_odds: :environment do
    require 'net/http'
    require 'json'

    puts "Fetching odds from ESPN..."

    sport = Sport.find_by(slug: "basketball")
    unless sport
      puts "Run nba:import_schedule first."
      exit
    end

    # Fetch for next 7 days
    updated = 0
    (0..6).each do |day_offset|
      date = (Date.current + day_offset).strftime("%Y%m%d")
      uri = URI("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates=#{date}")

      begin
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "Mozilla/5.0"
        response = http.request(request)
        data = JSON.parse(response.body)
      rescue => e
        puts "Error fetching #{date}: #{e.message}"
        next
      end

      events = data["events"] || []
      events.each do |event|
        competition = event["competitions"]&.first
        next unless competition

        # Get teams
        home_team = competition["competitors"]&.find { |c| c["homeAway"] == "home" }
        away_team = competition["competitors"]&.find { |c| c["homeAway"] == "away" }
        next unless home_team && away_team

        home_abbr = home_team.dig("team", "abbreviation")
        away_abbr = away_team.dig("team", "abbreviation")

        # Find matching game in our DB
        game_date = Time.parse(event["date"]).in_time_zone("Asia/Seoul").to_date
        game = Game.where(sport: sport)
                   .where(home_abbr: home_abbr, away_abbr: away_abbr)
                   .where("DATE(game_date) = ?", game_date)
                   .first

        next unless game

        # Extract odds
        odds = competition["odds"]&.first
        if odds
          spread_detail = odds["details"] # e.g., "LAL -3.5"
          over_under = odds["overUnder"]

          # Parse spread - format is "TEAM -X.X" or "TEAM +X.X"
          if spread_detail.present?
            parts = spread_detail.split(" ")
            if parts.length == 2
              fav_team = parts[0]
              spread_value = parts[1].to_f

              if fav_team == home_abbr
                game.home_spread = spread_value
                game.away_spread = -spread_value
              elsif fav_team == away_abbr
                game.away_spread = spread_value
                game.home_spread = -spread_value
              end
            end
          end

          game.total_line = over_under if over_under.present?
          game.save!
          updated += 1
          print "."
        end
      end
    end

    puts "\nUpdated #{updated} games with odds data"
  end

  desc "Fetch injury report from ESPN"
  task fetch_injuries: :environment do
    require 'net/http'
    require 'json'

    puts "Fetching injury report from ESPN..."

    uri = URI("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/injuries")

    begin
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "Mozilla/5.0"
      response = http.request(request)
      data = JSON.parse(response.body)
    rescue => e
      puts "Error: #{e.message}"
      exit
    end

    # Store in cache file for quick access
    injuries_by_team = {}

    team_abbrs = {
      "Atlanta Hawks" => "ATL", "Boston Celtics" => "BOS", "Brooklyn Nets" => "BKN",
      "Charlotte Hornets" => "CHA", "Chicago Bulls" => "CHI", "Cleveland Cavaliers" => "CLE",
      "Dallas Mavericks" => "DAL", "Denver Nuggets" => "DEN", "Detroit Pistons" => "DET",
      "Golden State Warriors" => "GSW", "Houston Rockets" => "HOU", "Indiana Pacers" => "IND",
      "LA Clippers" => "LAC", "Los Angeles Lakers" => "LAL", "Memphis Grizzlies" => "MEM",
      "Miami Heat" => "MIA", "Milwaukee Bucks" => "MIL", "Minnesota Timberwolves" => "MIN",
      "New Orleans Pelicans" => "NOP", "New York Knicks" => "NYK", "Oklahoma City Thunder" => "OKC",
      "Orlando Magic" => "ORL", "Philadelphia 76ers" => "PHI", "Phoenix Suns" => "PHX",
      "Portland Trail Blazers" => "POR", "Sacramento Kings" => "SAC", "San Antonio Spurs" => "SAS",
      "Toronto Raptors" => "TOR", "Utah Jazz" => "UTA", "Washington Wizards" => "WAS"
    }

    data["injuries"]&.each do |team_data|
      team_name = team_data["displayName"]
      team_abbr = team_abbrs[team_name] || team_name[0..2].upcase

      injuries_by_team[team_abbr] = team_data["injuries"]&.map do |injury|
        {
          player: injury.dig("athlete", "displayName"),
          position: injury.dig("athlete", "position", "abbreviation"),
          status: injury["status"],
          details: injury["shortComment"] || injury["longComment"]
        }
      end || []
    end

    # Save to tmp for view access
    cache_path = Rails.root.join("tmp", "injuries.json")
    File.write(cache_path, JSON.pretty_generate(injuries_by_team))

    total_injured = injuries_by_team.values.flatten.count
    puts "Cached #{total_injured} injuries for #{injuries_by_team.keys.count} teams"
    puts "Saved to #{cache_path}"
  end

  desc "Fetch projected lineups from BasketballMonster"
  task fetch_lineups: :environment do
    require 'net/http'
    require 'nokogiri'

    puts "Fetching projected lineups from BasketballMonster..."

    uri = URI("https://basketballmonster.com/nbalineups.aspx")

    begin
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      http.read_timeout = 30
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
      response = http.request(request)
      html = response.body
    rescue => e
      puts "Error fetching lineups: #{e.message}"
      exit
    end

    doc = Nokogiri::HTML(html)
    lineups_by_team = {}

    # Team abbreviation mapping (BasketballMonster uses some different abbrs)
    team_map = {
      "PHO" => "PHX", "SA" => "SAS", "NO" => "NOP", "NY" => "NYK", "GS" => "GSW"
    }

    positions = %w[PG SG SF PF C]

    # Each table.datatable represents one game
    doc.css("table.datatable").each do |game_table|
      rows = game_table.css("tr")
      next if rows.length < 3

      # Row 1: header with team names (e.g., " | MEM | @ ORL") - uses th elements
      header_row = rows[1]
      cells = header_row.css("td, th")
      next if cells.length < 3

      away_abbr = cells[1].text.strip.upcase
      home_text = cells[2].text.strip.upcase
      home_abbr = home_text.gsub(/^@\s*/, "")

      # Apply abbreviation mapping
      away_abbr = team_map[away_abbr] || away_abbr
      home_abbr = team_map[home_abbr] || home_abbr

      lineups_by_team[away_abbr] ||= []
      lineups_by_team[home_abbr] ||= []

      # Rows 2-6: PG, SG, SF, PF, C
      positions.each_with_index do |pos, idx|
        row = rows[idx + 2]
        next unless row

        cells = row.css("td")
        next if cells.length < 3

        # Away player (column 1)
        away_cell = cells[1]
        away_player = away_cell.at_css("a")&.text&.strip
        away_status = nil
        if away_cell.text.include?("Off Inj")
          away_status = "OUT"
        elsif away_cell.text.match?(/\bQ\b/)
          away_status = "Q"
        elsif away_cell.text.match?(/\bP\b/)
          away_status = "P"
        elsif away_cell.text.match?(/\bGTD\b/i)
          away_status = "GTD"
        end

        if away_player.present?
          lineups_by_team[away_abbr] << {
            "name" => away_player,
            "position" => pos,
            "status" => away_status
          }
        end

        # Home player (column 2)
        home_cell = cells[2]
        home_player = home_cell.at_css("a")&.text&.strip
        home_status = nil
        if home_cell.text.include?("Off Inj")
          home_status = "OUT"
        elsif home_cell.text.match?(/\bQ\b/)
          home_status = "Q"
        elsif home_cell.text.match?(/\bP\b/)
          home_status = "P"
        elsif home_cell.text.match?(/\bGTD\b/i)
          home_status = "GTD"
        end

        if home_player.present?
          lineups_by_team[home_abbr] << {
            "name" => home_player,
            "position" => pos,
            "status" => home_status
          }
        end
      end
    end

    # Save to tmp
    cache_path = Rails.root.join("tmp", "lineups.json")

    if lineups_by_team.any?
      File.write(cache_path, JSON.pretty_generate(lineups_by_team))
      puts "Cached lineups for #{lineups_by_team.keys.count} teams playing today"
      lineups_by_team.each do |team, players|
        starters = players.map { |p| "#{p['position']}:#{p['name']}#{p['status'] ? "(#{p['status']})" : ""}" }.join(", ")
        puts "  #{team}: #{starters}"
      end
    else
      puts "Warning: No lineups parsed. Page structure may have changed."
    end

    puts "Saved to #{cache_path}"
  end

  desc "Fetch team records and H2H from ESPN"
  task fetch_team_stats: :environment do
    require 'net/http'
    require 'json'

    puts "Fetching team records from ESPN..."

    sport = Sport.find_by(slug: "basketball")
    unless sport
      puts "Sport not found"
      exit
    end

    updated = 0

    # Fetch for next 7 days
    (0..6).each do |day_offset|
      date = (Date.current + day_offset).strftime("%Y%m%d")
      uri = URI("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates=#{date}")

      begin
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "Mozilla/5.0"
        response = http.request(request)
        data = JSON.parse(response.body)
      rescue => e
        puts "Error fetching #{date}: #{e.message}"
        next
      end

      events = data["events"] || []
      events.each do |event|
        competition = event["competitions"]&.first
        next unless competition

        home_comp = competition["competitors"]&.find { |c| c["homeAway"] == "home" }
        away_comp = competition["competitors"]&.find { |c| c["homeAway"] == "away" }
        next unless home_comp && away_comp

        home_abbr = home_comp.dig("team", "abbreviation")
        away_abbr = away_comp.dig("team", "abbreviation")

        # Find matching game
        game_date = Time.parse(event["date"]).in_time_zone("Asia/Seoul").to_date
        game = Game.where(sport: sport)
                   .where(home_abbr: home_abbr, away_abbr: away_abbr)
                   .where("DATE(game_date) = ?", game_date)
                   .first
        next unless game

        # Extract records
        home_records = home_comp["records"] || []
        away_records = away_comp["records"] || []

        home_overall = home_records.find { |r| r["type"] == "total" }&.dig("summary")
        home_home = home_records.find { |r| r["type"] == "home" }&.dig("summary")
        away_overall = away_records.find { |r| r["type"] == "total" }&.dig("summary")
        away_road = away_records.find { |r| r["type"] == "road" }&.dig("summary")

        game.home_record = home_overall if home_overall.present?
        game.away_record = away_overall if away_overall.present?
        game.home_home_record = home_home if home_home.present?
        game.away_road_record = away_road if away_road.present?

        # Fetch H2H from game summary
        event_id = event["id"]
        begin
          summary_uri = URI("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/summary?event=#{event_id}")
          http2 = Net::HTTP.new(summary_uri.host, summary_uri.port)
          http2.use_ssl = true
          req2 = Net::HTTP::Get.new(summary_uri)
          req2["User-Agent"] = "Mozilla/5.0"
          resp2 = http2.request(req2)
          summary = JSON.parse(resp2.body)

          season_series = summary["seasonseries"]&.first
          if season_series
            game.h2h_summary = season_series["summary"] # e.g., "TOR leads series 3-0"
          end
        rescue => e
          puts "Error fetching H2H for #{event_id}: #{e.message}"
        end

        if game.changed?
          game.save!
          updated += 1
          print "."
        end
      end
    end

    puts "\nUpdated #{updated} games with team stats"
  end

  desc "Fetch all ESPN data (odds + injuries + lineups + team stats + trends + rosters)"
  task fetch_all: [:fetch_rosters, :fetch_odds, :fetch_injuries, :fetch_lineups, :fetch_team_stats, :fetch_team_trends, :capture_lines, :save_results] do
    puts "\nAll ESPN data updated!"
  end

  desc "Fetch team trends: standings, recent games, ATS/OU records"
  task fetch_team_trends: :environment do
    require 'net/http'
    require 'json'

    puts "Fetching team trends from ESPN..."

    sport = Sport.find_by(slug: "basketball")
    unless sport
      puts "Sport not found"
      exit
    end

    trends_data = {}

    # Team ID mapping for ESPN API
    team_ids = {
      "ATL" => "1", "BOS" => "2", "BKN" => "17", "CHA" => "30", "CHI" => "4",
      "CLE" => "5", "DAL" => "6", "DEN" => "7", "DET" => "8", "GSW" => "9",
      "HOU" => "10", "IND" => "11", "LAC" => "12", "LAL" => "13", "MEM" => "29",
      "MIA" => "14", "MIL" => "15", "MIN" => "16", "NOP" => "3", "NYK" => "18",
      "OKC" => "25", "ORL" => "19", "PHI" => "20", "PHX" => "21", "POR" => "22",
      "SAC" => "23", "SAS" => "24", "TOR" => "28", "UTA" => "26", "WAS" => "27"
    }

    # Step 1: Fetch standings for all teams
    puts "\n[1/3] Fetching standings..."
    begin
      uri = URI("https://site.api.espn.com/apis/v2/sports/basketball/nba/standings")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "Mozilla/5.0"
      response = http.request(request)
      standings_data = JSON.parse(response.body)

      standings_data["children"]&.each do |conference|
        conference.dig("standings", "entries")&.each do |entry|
          team = entry["team"]
          abbr = team["abbreviation"]

          stats = {}
          entry["stats"]&.each do |stat|
            stats[stat["name"]] = stat["displayValue"] || stat["value"]
          end

          # Calculate games played from record
          record = stats["overall"] || "#{stats['wins']&.to_i}-#{stats['losses']&.to_i}"
          wins = stats["wins"]&.to_i || record.split("-").first.to_i
          losses = stats["losses"]&.to_i || record.split("-").last.to_i
          games_played = wins + losses
          games_played = 1 if games_played == 0  # Avoid division by zero

          # Calculate PPG (points for / games played)
          points_for = stats["pointsFor"]&.to_f || 0
          points_against = stats["pointsAgainst"]&.to_f || 0
          ppg = (points_for / games_played).round(1)
          opp_ppg = (points_against / games_played).round(1)

          trends_data[abbr] = {
            "name" => team["displayName"],
            "record" => record,
            "wins" => wins,
            "losses" => losses,
            "home_record" => stats["Home"] || stats["home"],
            "away_record" => stats["Road"] || stats["away"],
            "streak" => stats["streak"],
            "last_10" => stats["Last Ten Games"] || stats["l10"],
            "conference_rank" => stats["playoffSeed"]&.to_i,
            "pct" => stats["winPercent"] || stats["gamesBehind"],
            "ppg" => ppg,
            "opp_ppg" => opp_ppg,
            "diff" => stats["differential"] || stats["pointDifferential"],
            "recent_games" => [],
            "ats" => { "wins" => 0, "losses" => 0, "pushes" => 0, "record" => "N/A" },
            "ou" => { "overs" => 0, "unders" => 0, "pushes" => 0, "record" => "N/A" }
          }
        end
      end
      puts "  Loaded standings for #{trends_data.keys.count} teams"
    rescue => e
      puts "  Error fetching standings: #{e.message}"
    end

    # Step 2: Fetch recent games for each team (last 10)
    puts "\n[2/3] Fetching recent games..."
    team_ids.each do |abbr, team_id|
      next unless trends_data[abbr]

      begin
        uri = URI("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/teams/#{team_id}/schedule?season=2026&seasontype=2")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "Mozilla/5.0"
        response = http.request(request)
        schedule_data = JSON.parse(response.body)

        recent_games = []
        ats_wins = 0
        ats_losses = 0
        ats_pushes = 0
        ou_overs = 0
        ou_unders = 0
        ou_pushes = 0

        events = schedule_data["events"] || []

        # Filter completed games and get last 10
        completed = events.select { |e|
          status = e.dig("competitions", 0, "status", "type", "name")
          status == "STATUS_FINAL"
        }.last(10)

        completed.each do |event|
          comp = event["competitions"]&.first
          next unless comp

          home_team = comp["competitors"]&.find { |c| c["homeAway"] == "home" }
          away_team = comp["competitors"]&.find { |c| c["homeAway"] == "away" }
          next unless home_team && away_team

          is_home = home_team.dig("team", "abbreviation") == abbr
          team_comp = is_home ? home_team : away_team
          opp_comp = is_home ? away_team : home_team

          # Score can be a Hash with {value, displayValue} or a simple value
          team_score_raw = team_comp["score"]
          opp_score_raw = opp_comp["score"]
          team_score = team_score_raw.is_a?(Hash) ? (team_score_raw["value"] || team_score_raw["displayValue"]).to_i : team_score_raw.to_i
          opp_score = opp_score_raw.is_a?(Hash) ? (opp_score_raw["value"] || opp_score_raw["displayValue"]).to_i : opp_score_raw.to_i

          won = team_comp["winner"]
          opp_abbr = opp_comp.dig("team", "abbreviation")

          # Get spread and total from odds if available
          odds = comp["odds"]&.first
          spread = nil
          total = nil

          if odds
            spread_detail = odds["details"] # e.g., "LAL -3.5"
            total = odds["overUnder"]&.to_f

            if spread_detail.present?
              parts = spread_detail.split(" ")
              if parts.length == 2
                fav_team = parts[0]
                spread_value = parts[1].to_f

                # Calculate team's spread (negative if favorite, positive if underdog)
                if fav_team == abbr
                  spread = spread_value
                elsif fav_team == opp_abbr
                  spread = -spread_value
                end
              end
            end
          end

          # Calculate ATS result
          if spread
            margin = team_score - opp_score
            covered_by = margin + spread  # If positive, team covered

            if covered_by > 0
              ats_wins += 1
              ats_result = "W"
            elsif covered_by < 0
              ats_losses += 1
              ats_result = "L"
            else
              ats_pushes += 1
              ats_result = "P"
            end
          else
            ats_result = nil
          end

          # Calculate O/U result
          if total && total > 0
            game_total = team_score + opp_score
            if game_total > total
              ou_overs += 1
              ou_result = "O"
            elsif game_total < total
              ou_unders += 1
              ou_result = "U"
            else
              ou_pushes += 1
              ou_result = "P"
            end
          else
            ou_result = nil
          end

          recent_games << {
            "date" => event["date"],
            "opponent" => opp_abbr,
            "home" => is_home,
            "score" => "#{team_score}-#{opp_score}",
            "result" => won ? "W" : "L",
            "spread" => spread,
            "ats" => ats_result,
            "total" => total,
            "ou" => ou_result
          }
        end

        trends_data[abbr]["recent_games"] = recent_games.reverse  # Most recent first
        trends_data[abbr]["ats"] = {
          "wins" => ats_wins,
          "losses" => ats_losses,
          "pushes" => ats_pushes,
          "record" => "#{ats_wins}-#{ats_losses}#{ats_pushes > 0 ? "-#{ats_pushes}" : ""}"
        }
        trends_data[abbr]["ou"] = {
          "overs" => ou_overs,
          "unders" => ou_unders,
          "pushes" => ou_pushes,
          "record" => "#{ou_overs}-#{ou_unders}#{ou_pushes > 0 ? "-#{ou_pushes}" : ""}"
        }

        print "."
        sleep 0.2  # Rate limiting
      rescue => e
        puts "\n  Error fetching #{abbr}: #{e.message}"
      end
    end

    # Step 3: Calculate additional metrics
    puts "\n\n[3/3] Calculating trend metrics..."
    trends_data.each do |abbr, data|
      next unless data["recent_games"]&.any?

      games = data["recent_games"]
      last_5 = games.first(5)

      # Scoring trend (avg points last 5 vs season)
      if last_5.any?
        recent_ppg = last_5.map { |g| g["score"].split("-").first.to_i }.sum / last_5.count.to_f
        data["recent_ppg"] = recent_ppg.round(1)

        if data["ppg"]
          trend = recent_ppg - data["ppg"].to_f
          data["scoring_trend"] = trend.round(1)
          data["scoring_trend_dir"] = trend > 1 ? "↑" : (trend < -1 ? "↓" : "→")
        end
      end

      # Win streak / losing streak from recent games
      streak_count = 0
      streak_type = nil
      games.each do |g|
        if streak_type.nil?
          streak_type = g["result"]
          streak_count = 1
        elsif g["result"] == streak_type
          streak_count += 1
        else
          break
        end
      end
      data["current_streak"] = "#{streak_type}#{streak_count}"

      # Home/Away recent form
      home_games = games.select { |g| g["home"] }
      away_games = games.reject { |g| g["home"] }

      data["home_form"] = home_games.first(5).map { |g| g["result"] }.join if home_games.any?
      data["away_form"] = away_games.first(5).map { |g| g["result"] }.join if away_games.any?

      # ATS trend (last 5)
      ats_results = games.first(5).map { |g| g["ats"] }.compact
      data["ats_last_5"] = ats_results.join if ats_results.any?

      # O/U trend (last 5)
      ou_results = games.first(5).map { |g| g["ou"] }.compact
      data["ou_last_5"] = ou_results.join if ou_results.any?
    end

    # Save to cache file
    cache_path = Rails.root.join("tmp", "team_trends.json")
    File.write(cache_path, JSON.pretty_generate(trends_data))

    puts "\nSaved team trends to #{cache_path}"
    puts "\nSample output (#{trends_data.keys.first}):"
    sample = trends_data[trends_data.keys.first]
    puts "  Record: #{sample['record']} | Streak: #{sample['current_streak']}"
    puts "  Home: #{sample['home_record']} | Away: #{sample['away_record']}"
    puts "  PPG: #{sample['ppg']} | Recent PPG: #{sample['recent_ppg']} (#{sample['scoring_trend_dir']}#{sample['scoring_trend']&.abs})"
    puts "  ATS (L10): #{sample.dig('ats', 'record')} | Last 5: #{sample['ats_last_5']}"
    puts "  O/U (L10): #{sample.dig('ou', 'record')} | Last 5: #{sample['ou_last_5']}"
    puts "  Recent: #{sample['recent_games']&.first(3)&.map { |g| "#{g['result']} vs #{g['opponent']}" }&.join(', ')}"
  end

  desc "Fetch live scores from NBA official API (one-time)"
  task fetch_live_scores: :environment do
    require 'net/http'
    require 'json'

    sport = Sport.find_by(slug: "basketball")
    unless sport
      puts "Sport not found"
      exit
    end

    uri = URI("https://cdn.nba.com/static/json/liveData/scoreboard/todaysScoreboard_00.json")

    begin
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "Mozilla/5.0 (compatible; Gate9Sports/1.0)"
      response = http.request(request)
      data = JSON.parse(response.body)
    rescue => e
      puts "Error: #{e.message}"
      exit
    end

    updated = 0
    games_data = data.dig("scoreboard", "games") || []

    games_data.each do |g|
      home_abbr = g.dig("homeTeam", "teamTricode")
      away_abbr = g.dig("awayTeam", "teamTricode")

      # Find game by teams (today's games)
      game = Game.where(sport: sport)
                 .where(home_abbr: home_abbr, away_abbr: away_abbr)
                 .where("game_date >= ? AND game_date < ?", Date.current.beginning_of_day, Date.current.end_of_day + 1.day)
                 .first
      next unless game

      # Update scores
      game.home_score = g.dig("homeTeam", "score").to_i
      game.away_score = g.dig("awayTeam", "score").to_i

      # Parse status (e.g., "Q3 8:54", "Half", "Final", "9:30 pm ET")
      status_text = g["gameStatusText"] || ""
      game_status_num = g["gameStatus"] # 1=scheduled, 2=live, 3=final

      case game_status_num
      when 1
        game.status = "scheduled"
      when 2
        game.status = "live"
        # Parse period and clock from status_text (e.g., "Q3 8:54")
        if status_text =~ /Q(\d+)\s+([\d:]+)/
          game.period = $1.to_i
          game.clock = $2
        elsif status_text.downcase.include?("half")
          game.period = 2
          game.clock = "HT"
        elsif status_text =~ /OT(\d*)\s+([\d:]+)/
          game.period = 4 + ($1.presence || 1).to_i
          game.clock = $2
        end
      when 3
        game.status = "finished"
        game.period = g["period"]
      end

      # Linescores (quarter by quarter)
      home_periods = g.dig("homeTeam", "periods")
      away_periods = g.dig("awayTeam", "periods")
      if home_periods
        game.home_linescores = home_periods.map { |p| p["score"].to_i }.to_json
      end
      if away_periods
        game.away_linescores = away_periods.map { |p| p["score"].to_i }.to_json
      end

      if game.changed?
        game.save!
        updated += 1
        status_emoji = game.status == "live" ? "🔴" : (game.status == "finished" ? "✅" : "⏳")
        clock_info = game.status == "live" ? " Q#{game.period} #{game.clock}" : ""
        puts "#{status_emoji} #{game.away_abbr} #{game.away_score} @ #{game.home_abbr} #{game.home_score}#{clock_info}"
      end
    end

    puts "\nUpdated #{updated} games"
  end

  desc "Capture pre-game lines for today's games (run BEFORE games start)"
  task capture_lines: :environment do
    puts "Capturing pre-game lines for upcoming games..."

    sport = Sport.find_by(slug: "basketball")
    unless sport
      puts "Sport not found"
      exit
    end

    # Get today's and tomorrow's games that haven't started
    upcoming_games = Game.where(sport: sport)
                         .where("game_date >= ? AND game_date <= ?", Time.current, 2.days.from_now)
                         .where(status: [nil, "Scheduled", "scheduled"])
                         .where.not(home_spread: nil)

    captured = 0
    upcoming_games.find_each do |game|
      result = game.game_result || game.build_game_result

      # Only capture if not already captured
      if result.lines_captured_at.blank?
        result.opening_spread ||= game.home_spread
        result.closing_spread = game.home_spread
        result.opening_total ||= game.total_line
        result.closing_total = game.total_line
        result.lines_captured_at = Time.current
        result.save!
        captured += 1
        puts "  #{game.away_abbr} @ #{game.home_abbr}: Spread #{game.home_spread}, Total #{game.total_line}"
      else
        # Update closing line (may change closer to game time)
        result.closing_spread = game.home_spread
        result.closing_total = game.total_line
        result.save!
        puts "  #{game.away_abbr} @ #{game.home_abbr}: Updated closing line"
      end
    end

    puts "\nCaptured lines for #{captured} games"
  end

  desc "Backfill past game results from ESPN (one-time setup)"
  task backfill_results: :environment do
    require 'net/http'
    require 'json'

    puts "Backfilling past game results from ESPN..."

    sport = Sport.find_by(slug: "basketball")
    unless sport
      puts "Sport not found"
      exit
    end

    # Get games from the last 30 days that don't have results
    past_games = Game.where(sport: sport)
                     .where("game_date < ?", Time.current)
                     .where("game_date > ?", 30.days.ago)
                     .includes(:game_result)

    backfilled = 0

    # Fetch by date to minimize API calls
    dates = past_games.pluck(:game_date).map(&:to_date).uniq.sort

    dates.each do |date|
      date_str = date.strftime("%Y%m%d")
      puts "\n[#{date}]"

      begin
        uri = URI("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates=#{date_str}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE  # Development only
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "Mozilla/5.0"
        response = http.request(request)
        data = JSON.parse(response.body)

        (data["events"] || []).each do |event|
          competition = event["competitions"]&.first
          next unless competition

          home_comp = competition["competitors"]&.find { |c| c["homeAway"] == "home" }
          away_comp = competition["competitors"]&.find { |c| c["homeAway"] == "away" }
          next unless home_comp && away_comp

          home_abbr = home_comp.dig("team", "abbreviation")
          away_abbr = away_comp.dig("team", "abbreviation")

          # Find matching game
          game = Game.where(sport: sport)
                     .where(home_abbr: home_abbr, away_abbr: away_abbr)
                     .where("DATE(game_date) = ?", date)
                     .first
          next unless game

          # Get scores
          home_score = home_comp["score"].to_i
          away_score = away_comp["score"].to_i
          next if home_score == 0 && away_score == 0  # Game not finished

          # Update game record
          game.update!(
            home_score: home_score,
            away_score: away_score,
            status: "finished"
          )

          # Create or update game_result
          result = game.game_result || game.build_game_result
          next if result.result_captured_at.present?

          # Get odds from competition
          odds = competition["odds"]&.first
          if odds
            spread_detail = odds["details"]
            total = odds["overUnder"]&.to_f

            if spread_detail.present?
              parts = spread_detail.split(" ")
              if parts.length == 2
                fav_team = parts[0]
                spread_value = parts[1].to_f

                if fav_team == home_abbr
                  result.closing_spread = spread_value
                elsif fav_team == away_abbr
                  result.closing_spread = -spread_value
                end
              end
            end

            result.closing_total = total if total.present? && total > 0
          end

          result.home_score = home_score
          result.away_score = away_score
          result.margin = home_score - away_score

          # Calculate ATS
          if result.closing_spread.present?
            adjusted = result.margin + result.closing_spread
            result.spread_result = adjusted > 0 ? 'home_covered' : (adjusted < 0 ? 'away_covered' : 'push')
            result.spread_covered_home = (result.spread_result == 'home_covered')
          end

          # Calculate O/U
          if result.closing_total.present?
            total_pts = home_score + away_score
            result.total_result = total_pts > result.closing_total ? 'over' : (total_pts < result.closing_total ? 'under' : 'push')
            result.total_over = (result.total_result == 'over')
          end

          result.result_captured_at = Time.current
          result.save!
          backfilled += 1

          status = "#{away_abbr} #{away_score} @ #{home_abbr} #{home_score}"
          ats_info = result.closing_spread ? " | Spread: #{result.closing_spread} → #{result.spread_result}" : ""
          ou_info = result.closing_total ? " | Total: #{result.closing_total} → #{result.total_result}" : ""
          puts "  #{status}#{ats_info}#{ou_info}"
        end

        sleep 0.3  # Rate limiting
      rescue => e
        puts "  Error: #{e.message}"
      end
    end

    puts "\n\nBackfilled #{backfilled} game results"

    # Show sample ATS/OU records
    puts "\nSample Team Records:"
    %w[LAL BOS OKC].each do |team|
      ats = GameResult.ats_record_for_team(team)
      ou = GameResult.ou_record_for_team(team)
      puts "  #{team}: ATS #{ats[:record]} | O/U #{ou[:record]}"
    end
  end

  desc "Save game results and calculate ATS/OU (run AFTER games finish)"
  task save_results: :environment do
    puts "Saving game results..."

    sport = Sport.find_by(slug: "basketball")
    unless sport
      puts "Sport not found"
      exit
    end

    # Get finished games that don't have results saved
    finished_games = Game.where(sport: sport)
                         .where(status: ["finished", "Finished", "Final"])
                         .where.not(home_score: nil)
                         .where.not(away_score: nil)
                         .includes(:game_result)

    saved = 0
    finished_games.find_each do |game|
      result = game.game_result || game.build_game_result

      # Skip if already calculated
      next if result.result_captured_at.present?

      # If no lines were captured, try to get from game data
      if result.closing_spread.nil? && game.home_spread.present?
        result.opening_spread ||= game.home_spread
        result.closing_spread = game.home_spread
      end
      if result.closing_total.nil? && game.total_line.present?
        result.opening_total ||= game.total_line
        result.closing_total = game.total_line
      end

      result.home_score = game.home_score
      result.away_score = game.away_score
      result.margin = game.home_score - game.away_score

      # Calculate ATS result
      if result.closing_spread.present?
        adjusted_margin = result.margin + result.closing_spread
        result.spread_result = if adjusted_margin > 0
          'home_covered'
        elsif adjusted_margin < 0
          'away_covered'
        else
          'push'
        end
        result.spread_covered_home = (result.spread_result == 'home_covered')
      end

      # Calculate O/U result
      if result.closing_total.present?
        total_points = result.home_score + result.away_score
        result.total_result = if total_points > result.closing_total
          'over'
        elsif total_points < result.closing_total
          'under'
        else
          'push'
        end
        result.total_over = (result.total_result == 'over')
      end

      result.result_captured_at = Time.current
      result.save!
      saved += 1

      spread_emoji = result.spread_result == 'home_covered' ? '✅' : (result.spread_result == 'away_covered' ? '❌' : '🔄')
      ou_emoji = result.total_result == 'over' ? '⬆️' : (result.total_result == 'under' ? '⬇️' : '🔄')

      puts "  #{game.away_abbr} #{result.away_score} @ #{game.home_abbr} #{result.home_score}"
      puts "    Spread: #{result.closing_spread} → #{spread_emoji} #{result.spread_result}"
      puts "    Total: #{result.closing_total} → #{ou_emoji} #{result.total_result} (#{result.home_score + result.away_score})"
    end

    puts "\nSaved results for #{saved} games"

    # Show current ATS/OU records for a sample team
    if saved > 0
      sample_team = "LAL"
      ats = GameResult.ats_record_for_team(sample_team)
      ou = GameResult.ou_record_for_team(sample_team)
      puts "\n#{sample_team} Current Records:"
      puts "  ATS: #{ats[:record]}"
      puts "  O/U: #{ou[:record]}"
    end
  end

  desc "Poll live scores continuously (run in background)"
  task live_poll: :environment do
    require 'net/http'
    require 'json'

    puts "Starting live score polling... (Ctrl+C to stop)"
    puts "Polling every 30 seconds during active games"

    sport = Sport.find_by(slug: "basketball")
    unless sport
      puts "Sport not found"
      exit
    end

    loop do
      # Check if there are any games today
      today = Date.current
      today_games = Game.where(sport: sport)
                        .where("DATE(game_date) = ?", today)

      if today_games.none?
        puts "[#{Time.current.strftime('%H:%M:%S')}] No games today. Sleeping 5 minutes..."
        sleep 300
        next
      end

      # Check if any games are live or about to start (within 30 min)
      now = Time.current
      active_or_upcoming = today_games.where(status: "live").or(
        today_games.where("game_date BETWEEN ? AND ?", now - 30.minutes, now + 30.minutes)
      )

      if active_or_upcoming.none? && today_games.where(status: ["scheduled", "live"]).none?
        puts "[#{Time.current.strftime('%H:%M:%S')}] No active games. Sleeping 5 minutes..."
        sleep 300
        next
      end

      # Fetch scores
      begin
        uri = URI("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        http.read_timeout = 10
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "Mozilla/5.0 (compatible; Gate9Sports/1.0)"
        response = http.request(request)
        data = JSON.parse(response.body)

        updated = 0
        live_count = 0

        (data["events"] || []).each do |event|
          competition = event["competitions"]&.first
          next unless competition

          home_comp = competition["competitors"]&.find { |c| c["homeAway"] == "home" }
          away_comp = competition["competitors"]&.find { |c| c["homeAway"] == "away" }
          next unless home_comp && away_comp

          home_abbr = home_comp.dig("team", "abbreviation")
          away_abbr = away_comp.dig("team", "abbreviation")

          game_date = Time.parse(event["date"]).in_time_zone("Asia/Seoul").to_date
          game = Game.where(sport: sport)
                     .where(home_abbr: home_abbr, away_abbr: away_abbr)
                     .where("DATE(game_date) = ?", game_date)
                     .first
          next unless game

          status = event["status"] || {}
          status_type = status.dig("type", "name")

          game.home_score = home_comp["score"].to_i
          game.away_score = away_comp["score"].to_i
          game.period = status["period"]
          game.clock = status["displayClock"]

          case status_type
          when "STATUS_IN_PROGRESS"
            game.status = "live"
            live_count += 1
          when "STATUS_FINAL"
            game.status = "finished"
          when "STATUS_SCHEDULED"
            game.status = "scheduled"
          when "STATUS_HALFTIME"
            game.status = "live"
            game.clock = "HT"
            live_count += 1
          end

          home_linescores = home_comp["linescores"]&.map { |ls| ls["value"].to_i }
          away_linescores = away_comp["linescores"]&.map { |ls| ls["value"].to_i }
          game.home_linescores = home_linescores.to_json if home_linescores
          game.away_linescores = away_linescores.to_json if away_linescores

          if game.changed?
            game.save!
            updated += 1

            # Broadcast via Turbo Streams if ActionCable is available
            if defined?(Turbo::StreamsChannel)
              Turbo::StreamsChannel.broadcast_replace_to(
                "live_scores",
                target: "game_#{game.id}",
                partial: "schedule/game_score",
                locals: { game: game }
              )
            end
          end
        end

        puts "[#{Time.current.strftime('%H:%M:%S')}] Updated #{updated} games, #{live_count} live"

        # Sleep based on activity
        if live_count > 0
          sleep 30  # Active games: 30 seconds
        else
          sleep 60  # No live games: 1 minute
        end

      rescue => e
        puts "[#{Time.current.strftime('%H:%M:%S')}] Error: #{e.message}"
        sleep 60
      end
    end
  end

  desc "Fetch all team rosters from ESPN (player → team mapping)"
  task fetch_rosters: :environment do
    require 'net/http'
    require 'json'

    puts "Fetching NBA rosters from ESPN..."

    # ESPN Team IDs
    team_ids = {
      "ATL" => "1", "BOS" => "2", "BKN" => "17", "CHA" => "30", "CHI" => "4",
      "CLE" => "5", "DAL" => "6", "DEN" => "7", "DET" => "8", "GSW" => "9",
      "HOU" => "10", "IND" => "11", "LAC" => "12", "LAL" => "13", "MEM" => "29",
      "MIA" => "14", "MIL" => "15", "MIN" => "16", "NOP" => "3", "NYK" => "18",
      "OKC" => "25", "ORL" => "19", "PHI" => "20", "PHX" => "21", "POR" => "22",
      "SAC" => "23", "SAS" => "24", "TOR" => "28", "UTA" => "26", "WAS" => "27"
    }

    rosters = {}
    players_by_name = {}

    team_ids.each do |abbr, team_id|
      begin
        uri = URI("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/teams/#{team_id}/roster")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "Mozilla/5.0"
        response = http.request(request)
        data = JSON.parse(response.body)

        team_name = data.dig("team", "displayName") || abbr
        athletes = data["athletes"] || []

        rosters[abbr] = {
          "team_name" => team_name,
          "updated_at" => Time.current.iso8601,
          "players" => []
        }

        athletes.each do |athlete|
          player = {
            "id" => athlete["id"],
            "name" => athlete["displayName"],
            "full_name" => athlete["fullName"],
            "position" => athlete.dig("position", "abbreviation"),
            "jersey" => athlete["jersey"],
            "status" => athlete.dig("injuries", 0, "status") || "Active"
          }
          rosters[abbr]["players"] << player

          # Index by name for quick lookup
          players_by_name[athlete["displayName"]] = {
            "team" => abbr,
            "team_name" => team_name,
            "position" => player["position"],
            "jersey" => player["jersey"]
          }
          # Also index by full name
          if athlete["fullName"] != athlete["displayName"]
            players_by_name[athlete["fullName"]] = players_by_name[athlete["displayName"]]
          end
        end

        print "."
        sleep 0.2  # Rate limiting
      rescue => e
        puts "\nError fetching #{abbr}: #{e.message}"
      end
    end

    # Save rosters by team
    rosters_path = Rails.root.join("tmp", "rosters.json")
    File.write(rosters_path, JSON.pretty_generate(rosters))
    puts "\nSaved team rosters to #{rosters_path}"

    # Save player lookup (name → team)
    players_path = Rails.root.join("tmp", "players.json")
    File.write(players_path, JSON.pretty_generate(players_by_name))
    puts "Saved player lookup to #{players_path}"

    # Summary
    total_players = rosters.values.sum { |r| r["players"].count }
    puts "\nTotal: #{rosters.keys.count} teams, #{total_players} players"

    # Show some key players as verification
    puts "\nKey player verification:"
    %w[Anthony\ Davis LeBron\ James Luka\ Doncic Nikola\ Jokic Stephen\ Curry].each do |name|
      info = players_by_name[name]
      if info
        puts "  #{name} → #{info['team']} (#{info['team_name']})"
      else
        puts "  #{name} → NOT FOUND"
      end
    end
  end
end
