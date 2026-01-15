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

  desc "Fetch all ESPN data (odds + injuries + lineups)"
  task fetch_all: [:fetch_odds, :fetch_injuries, :fetch_lineups] do
    puts "\nAll ESPN data updated!"
  end
end
