namespace :nba do
  desc "Backfill historical scores from ESPN"
  task backfill_scores: :environment do
    require 'net/http'
    require 'json'

    sport = Sport.find_by(slug: "basketball")
    unless sport
      puts "Sport not found"
      exit
    end

    updated = 0
    errors = 0
    days_to_fetch = 90

    puts "Backfilling scores for past #{days_to_fetch} days..."

    (1..days_to_fetch).each do |days_ago|
      date = (Date.current - days_ago).strftime("%Y%m%d")

      uri = URI("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates=#{date}")

      begin
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        http.read_timeout = 10
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "Mozilla/5.0 (compatible; Gate9Sports/1.0)"
        response = http.request(request)
        data = JSON.parse(response.body)

        day_updated = 0

        (data["events"] || []).each do |event|
          comp = event["competitions"]&.first
          next unless comp

          home = comp["competitors"]&.find { |c| c["homeAway"] == "home" }
          away = comp["competitors"]&.find { |c| c["homeAway"] == "away" }
          next unless home && away

          home_abbr = home.dig("team", "abbreviation")
          away_abbr = away.dig("team", "abbreviation")

          game_date = Time.parse(event["date"]).in_time_zone("Asia/Seoul").to_date
          game = Game.where(sport: sport)
                     .where(home_abbr: home_abbr, away_abbr: away_abbr)
                     .where("DATE(game_date) = ?", game_date)
                     .first
          next unless game

          status_type = event.dig("status", "type", "name")
          if status_type == "STATUS_FINAL"
            game.home_score = home["score"].to_i
            game.away_score = away["score"].to_i
            game.status = "finished"
            game.period = event.dig("status", "period")

            home_linescores = home["linescores"]&.map { |ls| ls["value"].to_i }
            away_linescores = away["linescores"]&.map { |ls| ls["value"].to_i }
            game.home_linescores = home_linescores.to_json if home_linescores
            game.away_linescores = away_linescores.to_json if away_linescores

            if game.changed?
              game.save!
              updated += 1
              day_updated += 1
            end
          end
        end

        print "." if day_updated > 0
        sleep 0.3  # Rate limiting

      rescue => e
        errors += 1
        puts "\nError on #{date}: #{e.message}"
      end
    end

    puts "\n\nBackfill complete: #{updated} games updated, #{errors} errors"
  end
end
