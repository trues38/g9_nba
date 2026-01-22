# frozen_string_literal: true

namespace :report do
  desc "Generate comprehensive daily analysis report (Neo4j + 5-Analyst + Triggers)"
  task daily: :environment do
    require 'json'
    require 'net/http'

    today = Date.current
    games = Game.where('DATE(game_date) = ?', today).order(:game_date)

    if games.empty?
      puts "오늘 경기 없음"
      exit
    end

    # Load all data
    advanced_stats = WeaknessPrediction.load_advanced_stats
    team_trends = load_team_trends
    analyst_weights = AnalystWeight.all.index_by(&:analyst_name)
    global_triggers = fetch_global_triggers
    team_regimes = fetch_team_regimes

    # Detect triggers
    games.each { |g| WeaknessPrediction.detect_triggers_for_game(g) }

    # Generate report
    report = generate_comprehensive_report(
      games, advanced_stats, team_trends, analyst_weights, global_triggers, team_regimes
    )

    puts report

    # Save to file
    report_path = Rails.root.join("tmp", "reports", "#{today}.md")
    FileUtils.mkdir_p(report_path.dirname)
    File.write(report_path, report)
    puts "\n📄 저장: #{report_path}"
  end

  desc "Evaluate yesterday's predictions"
  task evaluate: :environment do
    yesterday = Date.current - 1
    games = Game.where('DATE(game_date) = ?', yesterday)
                .where(status: ['finished', 'Final'])

    if games.empty?
      puts "어제 완료된 경기 없음"
      exit
    end

    puts "📊 어제 경기 결과 평가 (#{yesterday}):"
    puts "-" * 50

    total = 0
    hits = 0

    games.each do |game|
      preds = WeaknessPrediction.where(game: game, evaluated_at: nil)
      next if preds.empty?

      game_result = game.game_result
      unless game_result&.spread_result.present?
        puts "  ⚠️ #{game.away_abbr} @ #{game.home_abbr}: 결과 없음"
        next
      end

      preds.each do |pred|
        pred.evaluate_outcome(game_result)
        total += 1
        hits += 1 if pred.hit?

        status = pred.hit? ? "✅ HIT" : "❌ MISS"
        puts "  #{status} #{pred.team} #{pred.trigger_type}"
      end
    end

    if total > 0
      hit_rate = (hits.to_f / total * 100).round(1)
      puts "\n📈 어제 결과: #{hits}/#{total} (#{hit_rate}%)"
    end
  end

  desc "Full daily cycle"
  task cycle: :environment do
    puts "🔄 Daily Report Cycle"
    puts "=" * 60

    puts "\n[1/5] 데이터 수집..."
    Rake::Task["nba:fetch_odds"].invoke rescue puts "  - odds: skip"
    Rake::Task["nba:fetch_advanced_stats"].invoke rescue puts "  - advanced_stats: skip"
    Rake::Task["nba:fetch_team_trends"].invoke rescue puts "  - trends: skip"

    puts "\n[2/5] 트리거 감지..."
    Rake::Task["weakness:detect"].invoke

    puts "\n[3/5] 리포트 생성..."
    Rake::Task["report:daily"].invoke

    puts "\n[4/5] 전일 결과 평가..."
    Rake::Task["report:evaluate"].invoke rescue puts "  (평가할 결과 없음)"

    puts "\n[5/5] Neo4j 동기화..."
    Rake::Task["weakness:sync_neo4j"].invoke rescue puts "  (동기화 skip)"

    puts "\n" + "=" * 60
    puts "✅ Daily cycle complete"
  end

  private

  def load_team_trends
    path = Rails.root.join("tmp", "team_trends.json")
    return {} unless File.exist?(path)
    JSON.parse(File.read(path))
  rescue
    {}
  end

  def fetch_global_triggers
    require 'net/http'
    triggers = {}

    uri = URI('http://86.48.2.202:7474/db/neo4j/tx/commit')
    body = {statements: [{statement: 'MATCH (gt:GlobalTrigger) RETURN gt.trigger_type, gt.hit_rate, gt.signal_level'}]}.to_json

    http = Net::HTTP.new(uri.host, uri.port)
    request = Net::HTTP::Post.new(uri.path)
    request['Content-Type'] = 'application/json'
    request.basic_auth('neo4j', 'nba_vultr_2025')
    request.body = body

    response = http.request(request)
    JSON.parse(response.body)['results'][0]['data'].each do |r|
      triggers[r['row'][0]] = {hit_rate: r['row'][1], signal: r['row'][2]}
    end
    triggers
  rescue => e
    puts "  Warning: GlobalTriggers fetch failed: #{e.message}"
    {}
  end

  def fetch_team_regimes
    require 'net/http'
    regimes = {}

    uri = URI('http://86.48.2.202:7474/db/neo4j/tx/commit')
    query = <<~CYPHER
      MATCH (tr:TeamRegime)
      OPTIONAL MATCH (tr)-[:HAS_TRIGGER]->(wt:WeaknessTrigger)
      WHERE wt.source = 'Rails_WeaknessPrediction' AND wt.validated_hit_rate >= 60
      RETURN tr.team as team, collect({trigger: wt.trigger_type, hit_rate: wt.validated_hit_rate}) as triggers
    CYPHER

    body = {statements: [{statement: query}]}.to_json
    http = Net::HTTP.new(uri.host, uri.port)
    request = Net::HTTP::Post.new(uri.path)
    request['Content-Type'] = 'application/json'
    request.basic_auth('neo4j', 'nba_vultr_2025')
    request.body = body

    response = http.request(request)
    JSON.parse(response.body)['results'][0]['data'].each do |r|
      team = r['row'][0]
      triggers = r['row'][1].reject { |t| t['trigger'].nil? }
      regimes[team] = triggers if triggers.any?
    end
    regimes
  rescue => e
    puts "  Warning: TeamRegime fetch failed: #{e.message}"
    {}
  end

  def generate_comprehensive_report(games, advanced_stats, team_trends, analyst_weights, global_triggers, team_regimes)
    today = Date.current
    report = []

    report << "=" * 70
    report << "🏀 Gate9 Sports - Daily Analysis Report"
    report << "📅 #{today.strftime('%Y-%m-%d')} (KST)"
    report << "=" * 70
    report << ""

    # Section 1: Analyst Weights
    report << "## 📊 5인 분석가 가중치 (RALPH)"
    report << ""
    report << "| 분석가 | 정확도 | 가중치 | 신호 | 활용 |"
    report << "|--------|--------|--------|------|------|"
    %w[CONTRARIAN SYSTEM SCOUT MOMENTUM SHARP].each do |name|
      aw = analyst_weights[name]
      next unless aw
      emoji = case aw.signal_type
              when 'main' then '🎯'
              when 'secondary' then '✅'
              when 'reverse' then '🔄'
              else '➖'
              end
      usage = case aw.signal_type
              when 'main' then '메인 시그널'
              when 'secondary' then '보조 시그널'
              when 'reverse' then '역지표'
              else '참고용'
              end
      report << "| #{emoji} #{name} | #{(aw.accuracy * 100).round(1)}% | #{aw.weight > 0 ? '+' : ''}#{aw.weight} | #{aw.signal_type} | #{usage} |"
    end
    report << ""

    # Section 2: Global Trigger Hit Rates
    report << "## 🎯 검증된 트리거 (전체 히트율)"
    report << ""
    sorted_triggers = global_triggers.sort_by { |_, v| -(v[:hit_rate] || 0) }
    sorted_triggers.each do |trigger, data|
      emoji = data[:signal] == 'STRONG' ? '🔥' : (data[:signal] == 'MODERATE' ? '✅' : '➖')
      report << "- #{emoji} **#{trigger}**: #{data[:hit_rate]}% [#{data[:signal]}]"
    end
    report << ""

    # Section 3: Game Analysis
    report << "## 🏀 오늘 경기 분석"
    report << ""

    recommendations = []

    games.each do |g|
      preds = WeaknessPrediction.where(game: g)
      home_stats = advanced_stats[g.home_abbr] || {}
      away_stats = advanced_stats[g.away_abbr] || {}
      home_trends = team_trends[g.home_abbr] || {}
      away_trends = team_trends[g.away_abbr] || {}

      report << "-" * 70
      report << "### #{g.away_abbr} @ #{g.home_abbr}"
      report << "⏰ #{g.game_date.in_time_zone('Asia/Seoul').strftime('%H:%M')} KST"
      if g.home_spread
        report << "📈 라인: #{g.home_abbr} #{g.home_spread} / O/U #{g.total_line}"
      end
      report << ""

      # Team Stats Comparison
      report << "**팀 비교:**"
      report << "| | #{g.away_abbr} | #{g.home_abbr} |"
      report << "|---|---|---|"
      report << "| 전적 | #{away_trends['record'] || 'N/A'} | #{home_trends['record'] || 'N/A'} |"
      report << "| 최근 5경기 | #{away_trends['current_streak'] || 'N/A'} | #{home_trends['current_streak'] || 'N/A'} |"
      report << "| OFF RTG | ##{away_stats['off_rank']} (#{away_stats['off_rtg']}) | ##{home_stats['off_rank']} (#{home_stats['off_rtg']}) |"
      report << "| DEF RTG | ##{away_stats['def_rank']} (#{away_stats['def_rtg']}) | ##{home_stats['def_rank']} (#{home_stats['def_rtg']}) |"
      report << "| ATS | #{away_trends.dig('ats', 'record') || 'N/A'} | #{home_trends.dig('ats', 'record') || 'N/A'} |"
      report << ""

      # Neo4j TeamRegime Weaknesses
      home_regime = team_regimes[g.home_team] || []
      away_regime = team_regimes[g.away_team] || []

      if home_regime.any? || away_regime.any?
        report << "**검증된 팀 약점 (Neo4j):**"
        away_regime.each do |w|
          report << "- #{g.away_abbr}: #{w['trigger']} (#{w['hit_rate']}%)"
        end
        home_regime.each do |w|
          report << "- #{g.home_abbr}: #{w['trigger']} (#{w['hit_rate']}%)"
        end
        report << ""
      end

      # Active Triggers
      if preds.any?
        report << "**🎯 활성 트리거:**"
        best_confidence = 0
        best_pick = nil

        preds.each do |p|
          gt = global_triggers[p.trigger_type] || {}
          hit_rate = gt[:hit_rate] || 50
          signal = gt[:signal] || 'NEUTRAL'
          emoji = signal == 'STRONG' ? '🔥' : (signal == 'MODERATE' ? '✅' : '➖')

          report << "- #{emoji} **#{p.trigger_type}** on #{p.team}"
          report << "  - #{p.trigger_detail}"
          report << "  - 히트율: #{hit_rate}% [#{signal}]"

          if hit_rate >= 60 && hit_rate > best_confidence
            opp = (p.team == g.home_team) ? g.away_abbr : g.home_abbr
            best_pick = opp
            best_confidence = hit_rate
          end
        end
        report << ""

        if best_pick
          report << "**📌 트리거 시그널: #{best_pick} (#{best_confidence.round(0)}%)**"
          recommendations << {
            game: "#{g.away_abbr}@#{g.home_abbr}",
            pick: best_pick,
            confidence: best_confidence,
            trigger: preds.map(&:trigger_type).join('+')
          }
        end
      else
        report << "**트리거: 없음**"
      end

      # 5-Analyst Quick Assessment (Rule-based)
      report << ""
      report << "**5인 분석가 퀵 체크:**"
      analyst_picks = generate_analyst_picks(g, home_stats, away_stats, home_trends, away_trends, preds)

      analyst_picks.each do |analyst, pick_data|
        aw = analyst_weights[analyst]
        weight_info = aw ? "(#{aw.weight > 0 ? '+' : ''}#{aw.weight})" : ""
        report << "- #{analyst} #{weight_info}: #{pick_data[:pick]} - #{pick_data[:reason]}"
      end

      # Calculate weighted recommendation
      if analyst_picks.any?
        weighted = AnalystWeight.get_recommendation(
          analyst_picks.transform_values { |v| v[:pick] == g.away_abbr ? 'AWAY' : 'HOME' }
        )

        report << ""
        report << "**가중 추천:** #{weighted[:recommendation]} (diff: #{weighted[:diff]}, #{weighted[:confidence]})"
      end

      report << ""
    end

    # Summary
    if recommendations.any?
      report << "=" * 70
      report << "## 📋 오늘의 트리거 시그널 요약"
      report << ""
      recommendations.sort_by { |r| -r[:confidence] }.each do |r|
        emoji = r[:confidence] >= 70 ? '🔥' : '✅'
        report << "#{emoji} **#{r[:game]}**: #{r[:pick]} (#{r[:confidence].round(0)}%) [#{r[:trigger]}]"
      end
    end

    report << ""
    report << "=" * 70
    report << "⚠️ 백테스트 기반 참고용 - 책임 베팅"
    report << "📊 데이터: Rails SQLite + Neo4j + NBA.com"
    report << "=" * 70

    report.join("\n")
  end

  # Rule-based analyst picks for quick assessment
  def generate_analyst_picks(game, home_stats, away_stats, home_trends, away_trends, triggers)
    picks = {}

    # SHARP: Based on line value and stats
    if home_stats['off_rtg'] && away_stats['off_rtg']
      net_diff = (home_stats['net_rtg'] || 0) - (away_stats['net_rtg'] || 0)
      if net_diff > 3
        picks['SHARP'] = {pick: game.home_abbr, reason: "Net RTG 우위 +#{net_diff.round(1)}"}
      elsif net_diff < -3
        picks['SHARP'] = {pick: game.away_abbr, reason: "Net RTG 우위 +#{(-net_diff).round(1)}"}
      else
        picks['SHARP'] = {pick: 'PASS', reason: "밸류 없음 (diff: #{net_diff.round(1)})"}
      end
    end

    # SCOUT: Based on matchup (OFF vs DEF rankings)
    if home_stats['off_rank'] && away_stats['def_rank']
      home_matchup = away_stats['def_rank'] - home_stats['off_rank']  # positive = good for home
      away_matchup = home_stats['def_rank'] - away_stats['off_rank']

      if home_matchup > 10
        picks['SCOUT'] = {pick: game.home_abbr, reason: "매치업 유리 (상대 수비 ##{away_stats['def_rank']})"}
      elsif away_matchup > 10
        picks['SCOUT'] = {pick: game.away_abbr, reason: "매치업 유리 (상대 수비 ##{home_stats['def_rank']})"}
      else
        picks['SCOUT'] = {pick: 'EVEN', reason: "매치업 비슷"}
      end
    end

    # CONTRARIAN: Fade the public (assume heavy favorite is overbet)
    if game.home_spread && game.home_spread.abs >= 7
      underdog = game.home_spread < 0 ? game.away_abbr : game.home_abbr
      picks['CONTRARIAN'] = {pick: underdog, reason: "빅 언더독 커버 경향 (#{game.home_spread.abs}pt)"}
    else
      picks['CONTRARIAN'] = {pick: 'PASS', reason: "스프레드 적당"}
    end

    # MOMENTUM: Based on recent form
    home_streak = home_trends['current_streak'] || ''
    away_streak = away_trends['current_streak'] || ''

    home_hot = home_streak.start_with?('W') && home_streak[1..-1].to_i >= 3
    away_hot = away_streak.start_with?('W') && away_streak[1..-1].to_i >= 3
    home_cold = home_streak.start_with?('L') && home_streak[1..-1].to_i >= 3
    away_cold = away_streak.start_with?('L') && away_streak[1..-1].to_i >= 3

    if home_hot && away_cold
      picks['MOMENTUM'] = {pick: game.home_abbr, reason: "#{home_streak} vs #{away_streak}"}
    elsif away_hot && home_cold
      picks['MOMENTUM'] = {pick: game.away_abbr, reason: "#{away_streak} vs #{home_streak}"}
    else
      picks['MOMENTUM'] = {pick: 'EVEN', reason: "폼 비슷"}
    end

    # SYSTEM: Based on triggers
    if triggers.any?
      strong_trigger = triggers.find { |t|
        gt = fetch_global_triggers[t.trigger_type]
        gt && gt[:signal] == 'STRONG'
      }

      if strong_trigger
        opp = (strong_trigger.team == game.home_team) ? game.away_abbr : game.home_abbr
        picks['SYSTEM'] = {pick: opp, reason: "트리거: #{strong_trigger.trigger_type}"}
      else
        moderate_triggers = triggers.select { |t|
          gt = fetch_global_triggers[t.trigger_type]
          gt && gt[:hit_rate] && gt[:hit_rate] >= 55
        }
        if moderate_triggers.any?
          opp = (moderate_triggers.first.team == game.home_team) ? game.away_abbr : game.home_abbr
          picks['SYSTEM'] = {pick: opp, reason: "약한 트리거: #{moderate_triggers.map(&:trigger_type).join('+')}"}
        else
          picks['SYSTEM'] = {pick: 'PASS', reason: "유의미한 트리거 없음"}
        end
      end
    else
      picks['SYSTEM'] = {pick: 'PASS', reason: "트리거 없음"}
    end

    picks
  end
end
