# frozen_string_literal: true

# G9 Sports - Robust Data Sync
# 안정적인 데이터 수집을 위한 태스크
# - 재시도 로직
# - 멀티 소스 fallback
# - 수집 결과 로깅

namespace :data do
  # HTTP 요청 헬퍼 (재시도 포함)
  def fetch_with_retry(url, max_retries: 3, timeout: 30)
    require 'net/http'
    require 'json'

    retries = 0
    begin
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      http.open_timeout = timeout
      http.read_timeout = timeout

      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

      response = http.request(request)
      return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)

      raise "HTTP #{response.code}"
    rescue => e
      retries += 1
      if retries <= max_retries
        sleep(2 ** retries) # exponential backoff
        retry
      end
      raise e
    end
  end

  # 수집 로그 기록
  def log_sync(source, status, details = nil)
    log_path = Rails.root.join("tmp", "sync_log.json")
    logs = File.exist?(log_path) ? JSON.parse(File.read(log_path)) : []

    logs << {
      timestamp: Time.current.iso8601,
      source: source,
      status: status,
      details: details
    }

    # 최근 100개만 유지
    logs = logs.last(100)
    File.write(log_path, JSON.pretty_generate(logs))
  end

  desc "오늘 경기 오즈 수집 (ESPN)"
  task sync_odds: :environment do
    puts "📊 오즈 수집 시작..."

    sport = Sport.find_by(slug: "basketball")
    updated = 0
    failed = 0

    (0..2).each do |day_offset|
      date = (Date.current + day_offset).strftime("%Y%m%d")

      begin
        data = fetch_with_retry("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates=#{date}")

        (data["events"] || []).each do |event|
          competition = event["competitions"]&.first
          next unless competition

          home_team = competition["competitors"]&.find { |c| c["homeAway"] == "home" }
          away_team = competition["competitors"]&.find { |c| c["homeAway"] == "away" }
          next unless home_team && away_team

          home_abbr = home_team.dig("team", "abbreviation")
          away_abbr = away_team.dig("team", "abbreviation")

          game_date = Time.parse(event["date"]).in_time_zone("Asia/Seoul").to_date
          game = Game.where(sport: sport, home_abbr: home_abbr, away_abbr: away_abbr)
                     .where("DATE(game_date) = ?", game_date).first
          next unless game

          odds = competition["odds"]&.first
          if odds
            spread_detail = odds["details"]
            over_under = odds["overUnder"]

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
          end
        end
      rescue => e
        puts "  ❌ #{date}: #{e.message}"
        failed += 1
      end
    end

    log_sync("odds", updated > 0 ? "success" : "partial", { updated: updated, failed: failed })
    puts "✅ 오즈 업데이트: #{updated}경기 (실패: #{failed})"
  end

  desc "부상자 수집 (ESPN)"
  task sync_injuries: :environment do
    puts "🏥 부상자 수집 시작..."

    begin
      data = fetch_with_retry("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/injuries")

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

      injuries_by_team = {}
      total = 0

      (data["injuries"] || []).each do |team_data|
        team_name = team_data["displayName"]
        team_abbr = team_abbrs[team_name] || team_name[0..2].upcase

        injuries_by_team[team_abbr] = (team_data["injuries"] || []).map do |injury|
          total += 1
          {
            name: injury.dig("athlete", "displayName"),
            position: injury.dig("athlete", "position", "abbreviation"),
            status: injury["status"],
            injury: injury["shortComment"] || injury["longComment"]
          }
        end
      end

      cache_path = Rails.root.join("tmp", "injuries.json")
      File.write(cache_path, JSON.pretty_generate(injuries_by_team))

      log_sync("injuries", "success", { total: total, teams: injuries_by_team.keys.count })
      puts "✅ 부상자 수집: #{total}명 (#{injuries_by_team.keys.count}팀)"

    rescue => e
      log_sync("injuries", "failed", { error: e.message })
      puts "❌ 부상자 수집 실패: #{e.message}"
    end
  end

  desc "팀 스탯 수집 (ESPN)"
  task sync_team_stats: :environment do
    puts "📈 팀 스탯 수집 시작..."

    begin
      # ESPN Team Stats
      data = fetch_with_retry("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/teams")

      stats = {}
      (data["sports"]&.first&.dig("leagues")&.first&.dig("teams") || []).each do |team_data|
        team = team_data["team"]
        abbr = team["abbreviation"]

        # 기본 정보 저장
        stats[abbr] = {
          name: team["displayName"],
          record: team.dig("record", "items")&.first&.dig("summary") || "N/A"
        }
      end

      # Standings에서 추가 정보
      standings_data = fetch_with_retry("https://site.api.espn.com/apis/v2/sports/basketball/nba/standings")

      (standings_data["children"] || []).each do |conf|
        (conf.dig("standings", "entries") || []).each do |entry|
          abbr = entry.dig("team", "abbreviation")
          next unless abbr && stats[abbr]

          entry["stats"]&.each do |stat|
            case stat["name"]
            when "wins" then stats[abbr][:wins] = stat["value"].to_i
            when "losses" then stats[abbr][:losses] = stat["value"].to_i
            when "streak" then stats[abbr][:streak] = stat["displayValue"]
            when "playoffSeed" then stats[abbr][:seed] = stat["value"].to_i
            end
          end
        end
      end

      cache_path = Rails.root.join("tmp", "team_stats.json")
      File.write(cache_path, JSON.pretty_generate(stats))

      log_sync("team_stats", "success", { teams: stats.keys.count })
      puts "✅ 팀 스탯 수집: #{stats.keys.count}팀"

    rescue => e
      log_sync("team_stats", "failed", { error: e.message })
      puts "❌ 팀 스탯 수집 실패: #{e.message}"
    end
  end

  desc "전체 데이터 동기화 (오즈 + 부상 + 스탯)"
  task sync_all: :environment do
    puts "=" * 60
    puts "🔄 G9 데이터 동기화 시작: #{Time.current.in_time_zone('Asia/Seoul').strftime('%Y-%m-%d %H:%M')} KST"
    puts "=" * 60
    puts ""

    results = {}

    # 1. 오즈
    puts "[1/3] 오즈 수집..."
    begin
      Rake::Task["data:sync_odds"].invoke
      results[:odds] = "✅"
    rescue => e
      results[:odds] = "❌ #{e.message}"
    end
    Rake::Task["data:sync_odds"].reenable
    puts ""

    # 2. 부상자
    puts "[2/3] 부상자 수집..."
    begin
      Rake::Task["data:sync_injuries"].invoke
      results[:injuries] = "✅"
    rescue => e
      results[:injuries] = "❌ #{e.message}"
    end
    Rake::Task["data:sync_injuries"].reenable
    puts ""

    # 3. 팀 스탯
    puts "[3/3] 팀 스탯 수집..."
    begin
      Rake::Task["data:sync_team_stats"].invoke
      results[:team_stats] = "✅"
    rescue => e
      results[:team_stats] = "❌ #{e.message}"
    end
    Rake::Task["data:sync_team_stats"].reenable
    puts ""

    # 요약
    puts "=" * 60
    puts "📋 동기화 결과:"
    results.each do |key, status|
      puts "  #{key}: #{status}"
    end
    puts "=" * 60
  end

  desc "수집 로그 확인"
  task sync_status: :environment do
    log_path = Rails.root.join("tmp", "sync_log.json")

    unless File.exist?(log_path)
      puts "수집 로그 없음"
      exit
    end

    logs = JSON.parse(File.read(log_path))
    puts "📋 최근 수집 로그 (최근 10건):"
    puts "-" * 60

    logs.last(10).each do |log|
      emoji = log["status"] == "success" ? "✅" : (log["status"] == "partial" ? "⚠️" : "❌")
      puts "#{emoji} #{log['timestamp']} | #{log['source']} | #{log['status']}"
      puts "   #{log['details']}" if log['details']
    end
  end

  desc "오늘 경기 데이터 완성도 체크"
  task check_today: :environment do
    puts "📋 오늘 경기 데이터 체크"
    puts "=" * 60

    games = Game.where("DATE(game_date) = ?", Date.current).order(:game_date)

    if games.empty?
      puts "오늘 경기 없음"
      exit
    end

    complete = 0
    incomplete = 0

    games.each do |g|
      issues = []
      issues << "스프레드 없음" if g.home_spread.blank?
      issues << "토탈 없음" if g.total_line.blank?

      if issues.any?
        puts "⚠️  #{g.away_abbr} @ #{g.home_abbr}: #{issues.join(', ')}"
        incomplete += 1
      else
        puts "✅ #{g.away_abbr} @ #{g.home_abbr}: #{g.home_abbr} #{g.home_spread} | O/U #{g.total_line}"
        complete += 1
      end
    end

    puts "-" * 60
    puts "완성: #{complete}/#{games.count} (#{(complete.to_f / games.count * 100).round}%)"
  end
end
