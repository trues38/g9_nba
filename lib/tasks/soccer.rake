namespace :soccer do
  # ESPN league codes for top 5 leagues
  LEAGUES = {
    "eng.1" => { name: "English Premier League", slug: "epl" },
    "esp.1" => { name: "Spanish LALIGA", slug: "laliga" },
    "ger.1" => { name: "German Bundesliga", slug: "bundesliga" },
    "ita.1" => { name: "Italian Serie A", slug: "seriea" },
    "fra.1" => { name: "French Ligue 1", slug: "ligue1" }
  }

  desc "Import soccer schedule from ESPN for all 5 leagues"
  task import_schedule: :environment do
    require 'net/http'
    require 'json'

    puts "Fetching soccer schedule from ESPN..."

    sport = Sport.find_or_create_by!(slug: "soccer") do |s|
      s.name = "Soccer"
      s.active = true
    end

    imported = 0
    skipped = 0

    LEAGUES.each do |league_code, league_info|
      puts "\n=== #{league_info[:name]} ==="

      # Fetch next 14 days of matches
      (0..13).each do |day_offset|
        date = (Date.current + day_offset).strftime("%Y%m%d")
        uri = URI("https://site.api.espn.com/apis/site/v2/sports/soccer/#{league_code}/scoreboard?dates=#{date}")

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

          event_id = event["id"]
          home_team = home_comp.dig("team", "displayName")
          away_team = away_comp.dig("team", "displayName")
          home_abbr = home_comp.dig("team", "abbreviation")
          away_abbr = away_comp.dig("team", "abbreviation")
          game_time = event["date"]
          venue = competition.dig("venue", "fullName") || "TBD"

          next unless home_team && away_team && game_time

          begin
            parsed_time = Time.parse(game_time)
          rescue
            next
          end

          existing = Game.find_by(external_id: "soccer_#{event_id}")
          if existing
            skipped += 1
            next
          end

          Game.create!(
            sport: sport,
            external_id: "soccer_#{event_id}",
            home_team: home_team,
            away_team: away_team,
            home_abbr: home_abbr,
            away_abbr: away_abbr,
            game_date: parsed_time,
            venue: venue,
            status: "Scheduled",
            schedule_note: league_info[:slug]  # Store league info
          )
          imported += 1
          print "."
        end
      end
    end

    puts "\n\nImported #{imported} games, skipped #{skipped} existing"
    puts "Total soccer games: #{Game.where(sport: sport).count}"
  end

  desc "Fetch odds from ESPN for soccer matches"
  task fetch_odds: :environment do
    require 'net/http'
    require 'json'

    puts "Fetching soccer odds from ESPN..."

    sport = Sport.find_by(slug: "soccer")
    unless sport
      puts "Run soccer:import_schedule first."
      exit
    end

    updated = 0

    LEAGUES.each do |league_code, league_info|
      puts "\n=== #{league_info[:name]} ==="

      # Fetch next 7 days
      (0..6).each do |day_offset|
        date = (Date.current + day_offset).strftime("%Y%m%d")
        uri = URI("https://site.api.espn.com/apis/site/v2/sports/soccer/#{league_code}/scoreboard?dates=#{date}")

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

          event_id = event["id"]
          game = Game.find_by(external_id: "soccer_#{event_id}")
          next unless game

          # Extract odds
          odds = competition["odds"]&.first
          if odds
            # Soccer odds format: "TEAM -105" or spread
            spread_detail = odds["details"]
            over_under = odds["overUnder"]

            if spread_detail.present?
              parts = spread_detail.split(" ")
              if parts.length >= 2
                fav_team = parts[0]
                spread_value = parts[1].to_f

                # For soccer, spread is usually in goals (e.g., -0.5, -1.5)
                if fav_team == game.home_abbr
                  game.home_spread = spread_value
                  game.away_spread = -spread_value
                elsif fav_team == game.away_abbr
                  game.away_spread = spread_value
                  game.home_spread = -spread_value
                end
              end
            end

            game.total_line = over_under if over_under.present?

            if game.changed?
              game.save!
              updated += 1
              print "."
            end
          end
        end
      end
    end

    puts "\n\nUpdated #{updated} games with odds"
  end

  desc "Fetch team records from ESPN for soccer matches"
  task fetch_team_stats: :environment do
    require 'net/http'
    require 'json'

    puts "Fetching soccer team stats from ESPN..."

    sport = Sport.find_by(slug: "soccer")
    unless sport
      puts "Run soccer:import_schedule first."
      exit
    end

    updated = 0

    LEAGUES.each do |league_code, league_info|
      puts "\n=== #{league_info[:name]} ==="

      (0..6).each do |day_offset|
        date = (Date.current + day_offset).strftime("%Y%m%d")
        uri = URI("https://site.api.espn.com/apis/site/v2/sports/soccer/#{league_code}/scoreboard?dates=#{date}")

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

          event_id = event["id"]
          game = Game.find_by(external_id: "soccer_#{event_id}")
          next unless game

          home_comp = competition["competitors"]&.find { |c| c["homeAway"] == "home" }
          away_comp = competition["competitors"]&.find { |c| c["homeAway"] == "away" }
          next unless home_comp && away_comp

          # Extract records (format: "W-D-L" for soccer)
          home_records = home_comp["records"] || []
          away_records = away_comp["records"] || []

          home_overall = home_records.find { |r| r["type"] == "total" }&.dig("summary")
          away_overall = away_records.find { |r| r["type"] == "total" }&.dig("summary")

          game.home_record = home_overall if home_overall.present?
          game.away_record = away_overall if away_overall.present?

          if game.changed?
            game.save!
            updated += 1
            print "."
          end
        end
      end
    end

    puts "\n\nUpdated #{updated} games with team stats"
  end

  desc "Fetch standings from ESPN for all leagues"
  task fetch_standings: :environment do
    require 'net/http'
    require 'json'

    puts "Fetching soccer standings from ESPN..."

    LEAGUES.each do |league_code, league_info|
      puts "\n=== #{league_info[:name]} ==="

      uri = URI("https://site.api.espn.com/apis/v2/sports/soccer/#{league_code}/standings")

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
        next
      end

      children = data["children"] || []
      next if children.empty?

      entries = children.first.dig("standings", "entries") || []
      puts "Top 5:"
      entries.first(5).each_with_index do |entry, idx|
        team = entry["team"]
        stats = entry["stats"].each_with_object({}) { |s, h| h[s["name"]] = s["displayValue"] || s["value"] }
        puts "  #{idx + 1}. #{team['displayName']}: #{stats['points']}pts (W#{stats['wins']}-D#{stats['ties']}-L#{stats['losses']})"
      end

      # Save to cache for view access
      cache_path = Rails.root.join("tmp", "soccer_standings_#{league_info[:slug]}.json")
      standings_data = entries.map do |entry|
        team = entry["team"]
        stats = entry["stats"].each_with_object({}) { |s, h| h[s["name"]] = s["displayValue"] || s["value"] }
        {
          team: team["displayName"],
          abbr: team["abbreviation"],
          points: stats["points"].to_i,
          wins: stats["wins"].to_i,
          draws: stats["ties"].to_i,
          losses: stats["losses"].to_i,
          gf: stats["pointsFor"].to_i,
          ga: stats["pointsAgainst"].to_i,
          gd: stats["pointDifferential"].to_i
        }
      end
      File.write(cache_path, JSON.pretty_generate(standings_data))
    end

    puts "\nStandings saved to tmp/soccer_standings_*.json"
  end

  desc "Fetch xG data from Understat (requires Python)"
  task fetch_xg: :environment do
    puts "Fetching xG data from Understat..."

    # Check if Python script exists
    script_path = Rails.root.join("..", "soccer", "collectors", "understat_xg_collector.py")

    unless File.exist?(script_path)
      puts "Error: Understat collector not found at #{script_path}"
      puts "xG data collection requires the Python collector script."
      exit
    end

    # Run Python script
    puts "Running Understat collector..."
    system("cd #{Rails.root.join('..', 'soccer')} && python3 collectors/understat_xg_collector.py")

    puts "xG data collection complete."
  end

  desc "Fetch injuries from Transfermarkt (scraping)"
  task fetch_injuries: :environment do
    require 'net/http'
    require 'nokogiri'

    puts "Fetching soccer injuries..."
    puts "Note: This requires implementation for PhysioRoom/Transfermarkt scraping"

    # Placeholder - would need actual implementation
    injuries_by_league = {}

    LEAGUES.each do |league_code, league_info|
      injuries_by_league[league_info[:slug]] = []
      # TODO: Implement actual scraping from PhysioRoom or Transfermarkt
    end

    # Save placeholder
    cache_path = Rails.root.join("tmp", "soccer_injuries.json")
    File.write(cache_path, JSON.pretty_generate(injuries_by_league))

    puts "Injuries saved to #{cache_path}"
    puts "TODO: Implement actual injury scraping"
  end

  desc "Fetch all soccer data (schedule + odds + team stats + standings)"
  task fetch_all: [:fetch_odds, :fetch_team_stats, :fetch_standings] do
    puts "\nAll soccer data updated!"
  end
end
