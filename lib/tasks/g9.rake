# frozen_string_literal: true

namespace :g9 do
  desc "Run G9 Engine for today's games"
  task daily: :environment do
    puts "🏀 G9 Engine v2.3 - Daily Analysis"
    puts "=" * 60

    begin
      service = G9EngineService.new
      result = service.run_daily

      puts "\n📊 분석 결과:"
      puts "-" * 60

      actionable = result[:picks].select { |p| p[:actionable] }

      if actionable.any?
        puts "\n💎 ACTION PICKS (Edge 80+):"
        actionable.each do |p|
          puts "  #{p[:signal]} #{p[:matchup]} → #{p[:recommended]} (Edge #{p[:edge_score]})"
        end
      else
        puts "\n⚠️ 오늘은 Edge 80+ 경기 없음 - PASS"
      end

      puts "\n📄 리포트 저장: #{result[:path]}"
      puts "=" * 60
    rescue G9EngineService::EngineError => e
      puts "❌ Engine Error: #{e.message}"
      exit 1
    rescue => e
      puts "❌ Error: #{e.message}"
      puts e.backtrace.first(5).join("\n")
      exit 1
    end
  end

  desc "Run G9 Engine for a specific date (YYYYMMDD)"
  task :analyze, [:date] => :environment do |_, args|
    date_str = args[:date] || Date.current.strftime('%Y%m%d')

    puts "🏀 G9 Engine v2.3 - Analyzing #{date_str}"
    puts "=" * 60

    begin
      service = G9EngineService.new
      picks = service.analyze_date(date_str)

      if picks.empty?
        puts "⚠️ #{date_str}에 경기 데이터 없음"
        exit 0
      end

      puts "\n| Matchup | Edge | Pick | Signal | Flow |"
      puts "|---------|------|------|--------|------|"

      picks.each do |p|
        puts "| #{p[:matchup]} | #{p[:edge_score]} | #{p[:recommended]} | #{p[:signal]} | #{p[:flow]} |"
      end

      puts "\n" + "-" * 60
      puts "💎 Edge 80+: #{picks.count { |p| p[:edge_score] >= 80 && !p[:risky] }}개"
      puts "🚨 RISKY: #{picks.count { |p| p[:risky] }}개"
      puts "🚫 PASS: #{picks.count { |p| p[:edge_score] < 60 }}개"
    rescue => e
      puts "❌ Error: #{e.message}"
      exit 1
    end
  end

  desc "Backtest G9 Engine for date range"
  task :backtest, [:start_date, :end_date] => :environment do |_, args|
    start_date = args[:start_date] || (Date.current - 14).strftime('%Y%m%d')
    end_date = args[:end_date] || Date.current.strftime('%Y%m%d')

    puts "🏀 G9 Engine v2.3 - Backtest"
    puts "📅 #{start_date} ~ #{end_date}"
    puts "=" * 60

    service = G9EngineService.new
    client = Neo4jClient.new

    # 티어별 집계
    tiers = {
      'A_STRONG_85+' => { games: 0, wins: 0 },
      'B_BET_80-84' => { games: 0, wins: 0 },
      'C_CAUTION_70-79' => { games: 0, wins: 0 },
      'D_NEUTRAL_60-69' => { games: 0, wins: 0 },
      'E_PASS_<60' => { games: 0, wins: 0 }
    }

    # 날짜 범위 내 모든 경기 분석
    result = client.query(<<~CYPHER, { start_date: start_date, end_date: end_date })
      WITH $start_date AS start_date, $end_date AS end_date

      MATCH (g:Game)
      WHERE g.date >= start_date AND g.date <= end_date AND g.status = 'Final'
      MATCH (home:Team {abbr: g.home_team})
      MATCH (away:Team {abbr: g.away_team})

      OPTIONAL MATCH (hr:TeamRegime) WHERE hr.team CONTAINS home.name

      WITH g, home, away,
           coalesce(home.win_pct, 0.5) AS h_pct,
           coalesce(away.win_pct, 0.5) AS a_pct,
           coalesce(home.net_rtg, 0) AS h_net,
           coalesce(away.net_rtg, 0) AS a_net

      WITH g, home, away,
           50 + (h_pct - a_pct) * 30 +
           CASE WHEN abs(h_net - a_net) >= 10 THEN
             CASE WHEN h_net > a_net THEN 20 ELSE -20 END
             ELSE (h_net - a_net) * 2 END + 5 AS raw_edge

      WITH g, home, away, raw_edge,
           CASE WHEN raw_edge >= 50 THEN raw_edge ELSE 100 - raw_edge END AS edge_score,
           CASE WHEN raw_edge >= 50 THEN 'HOME' ELSE 'AWAY' END AS pick_side,
           CASE WHEN g.home_score > g.away_score THEN 'HOME' ELSE 'AWAY' END AS winner

      WITH
        CASE
          WHEN edge_score >= 85 THEN 'A_STRONG_85+'
          WHEN edge_score >= 80 THEN 'B_BET_80-84'
          WHEN edge_score >= 70 THEN 'C_CAUTION_70-79'
          WHEN edge_score >= 60 THEN 'D_NEUTRAL_60-69'
          ELSE 'E_PASS_<60'
        END AS tier,
        pick_side = winner AS correct

      RETURN tier,
             count(*) AS games,
             sum(CASE WHEN correct THEN 1 ELSE 0 END) AS wins,
             round(toFloat(sum(CASE WHEN correct THEN 1 ELSE 0 END)) / count(*) * 100, 1) AS accuracy
      ORDER BY tier
    CYPHER

    puts "\n| 티어 | 경기수 | 적중 | 적중률 |"
    puts "|------|--------|------|--------|"

    total_games = 0
    total_wins = 0
    edge80_games = 0
    edge80_wins = 0

    result.each do |r|
      tier = r['tier']
      games = r['games'].is_a?(Hash) ? r['games']['low'] : r['games'].to_i
      wins = r['wins'].is_a?(Hash) ? r['wins']['low'] : r['wins'].to_i
      accuracy = r['accuracy'].to_f

      puts "| #{tier} | #{games} | #{wins} | #{accuracy}% |"

      total_games += games
      total_wins += wins

      if tier.start_with?('A_') || tier.start_with?('B_')
        edge80_games += games
        edge80_wins += wins
      end
    end

    puts "|------|--------|------|--------|"
    puts "| TOTAL | #{total_games} | #{total_wins} | #{(total_wins.to_f / total_games * 100).round(1)}% |" if total_games > 0

    if edge80_games > 0
      puts "\n💎 Edge 80+ 통합: #{edge80_wins}/#{edge80_games} = #{(edge80_wins.to_f / edge80_games * 100).round(1)}%"
    end

    puts "=" * 60
  end

  desc "Sync Team stats from Neo4j to update win_pct"
  task sync_stats: :environment do
    puts "🔄 Syncing Team stats..."

    client = Neo4jClient.new

    result = client.query(<<~CYPHER)
      MATCH (t:Team)
      OPTIONAL MATCH (hg:Game)
      WHERE hg.home_team = t.abbr AND hg.status = 'Final' AND hg.date >= '20251001'
      WITH t,
           count(hg) AS home_games,
           sum(CASE WHEN hg.home_score > hg.away_score THEN 1 ELSE 0 END) AS home_wins

      OPTIONAL MATCH (ag:Game)
      WHERE ag.away_team = t.abbr AND ag.status = 'Final' AND ag.date >= '20251001'
      WITH t, home_games, home_wins,
           count(ag) AS away_games,
           sum(CASE WHEN ag.away_score > ag.home_score THEN 1 ELSE 0 END) AS away_wins

      WITH t,
           home_games + away_games AS total_games,
           home_wins + away_wins AS total_wins,
           CASE WHEN home_games + away_games > 0
                THEN toFloat(home_wins + away_wins) / (home_games + away_games)
                ELSE 0.5 END AS win_pct
      SET t.games = total_games,
          t.wins = total_wins,
          t.win_pct = win_pct,
          t.stats_date = date()

      RETURN t.name, t.abbr, t.wins + '-' + (t.games - t.wins) AS record,
             round(t.win_pct * 100, 1) AS win_pct
      ORDER BY t.win_pct DESC
    CYPHER

    puts "Updated #{result.count} teams"
    result.first(5).each do |r|
      puts "  #{r['t.abbr']}: #{r['record']} (#{r['win_pct']}%)"
    end
    puts "  ..."
  end

  desc "Update TeamRegime flow_state based on recent streaks"
  task update_regime: :environment do
    puts "🔄 Updating TeamRegime flow_state..."

    client = Neo4jClient.new

    result = client.query(<<~CYPHER)
      MATCH (t:Team)
      OPTIONAL MATCH (g:Game)
      WHERE (g.home_team = t.abbr OR g.away_team = t.abbr)
        AND g.status = 'Final'
        AND g.date >= '20251001'
      WITH t, g
      ORDER BY g.date DESC
      WITH t, collect(g)[0..4] AS last5

      WITH t,
           reduce(streak = 0, g IN last5 |
             CASE
               WHEN (g.home_team = t.abbr AND g.home_score > g.away_score) OR
                    (g.away_team = t.abbr AND g.away_score > g.home_score)
               THEN CASE WHEN streak >= 0 THEN streak + 1 ELSE 1 END
               ELSE CASE WHEN streak <= 0 THEN streak - 1 ELSE -1 END
             END
           ) AS streak

      WITH t,
           CASE
             WHEN streak >= 5 THEN 'HOT_STREAK'
             WHEN streak >= 3 THEN 'STRONG_UP'
             WHEN streak > 0 THEN 'WARMING'
             WHEN streak = 0 THEN 'NEUTRAL'
             WHEN streak > -3 THEN 'COOLING'
             WHEN streak > -5 THEN 'SLUMP'
             ELSE 'COLD_STREAK'
           END AS flow_state,
           streak

      MATCH (r:TeamRegime) WHERE r.team CONTAINS t.name
      SET r.flow_state = flow_state,
          r.current_streak = streak,
          r.updated_at = datetime()

      RETURN t.name, flow_state, streak
      ORDER BY streak DESC
    CYPHER

    puts "Updated #{result.count} TeamRegimes"
    result.first(10).each do |r|
      puts "  #{r['t.name']}: #{r['flow_state']} (#{r['streak']})"
    end
  end

  desc "Sync ATS/O-U stats for Teams based on game results"
  task sync_ats: :environment do
    puts "🎯 Syncing ATS/O-U stats..."

    client = Neo4jClient.new

    # ATS 홈/원정 커버율 계산
    result = client.query(<<~CYPHER)
      MATCH (t:Team)

      // 홈 ATS
      OPTIONAL MATCH (hg:Game)
      WHERE hg.home_team = t.abbr AND hg.status = 'Final' AND hg.date >= '20251001'
        AND hg.spread IS NOT NULL
      WITH t,
           count(hg) AS home_ats_games,
           sum(CASE
             WHEN hg.home_score + hg.spread > hg.away_score THEN 1
             ELSE 0
           END) AS home_ats_covers

      // 원정 ATS
      OPTIONAL MATCH (ag:Game)
      WHERE ag.away_team = t.abbr AND ag.status = 'Final' AND ag.date >= '20251001'
        AND ag.spread IS NOT NULL
      WITH t, home_ats_games, home_ats_covers,
           count(ag) AS away_ats_games,
           sum(CASE
             WHEN ag.away_score > ag.home_score + ag.spread THEN 1
             ELSE 0
           END) AS away_ats_covers

      // O/U 계산
      OPTIONAL MATCH (og:Game)
      WHERE (og.home_team = t.abbr OR og.away_team = t.abbr)
        AND og.status = 'Final' AND og.date >= '20251001'
        AND og.total IS NOT NULL
      WITH t, home_ats_games, home_ats_covers, away_ats_games, away_ats_covers,
           count(og) AS ou_games,
           sum(CASE
             WHEN og.home_score + og.away_score > og.total THEN 1
             ELSE 0
           END) AS overs

      SET t.ats_home_pct = CASE WHEN home_ats_games > 0
                            THEN toFloat(home_ats_covers) / home_ats_games
                            ELSE 0.5 END,
          t.ats_away_pct = CASE WHEN away_ats_games > 0
                            THEN toFloat(away_ats_covers) / away_ats_games
                            ELSE 0.5 END,
          t.over_pct = CASE WHEN ou_games > 0
                        THEN toFloat(overs) / ou_games
                        ELSE 0.5 END,
          t.ats_updated = date()

      RETURN t.abbr, t.name,
             round(t.ats_home_pct * 100, 1) AS home_ats,
             round(t.ats_away_pct * 100, 1) AS away_ats,
             round(t.over_pct * 100, 1) AS over_pct
      ORDER BY t.ats_home_pct DESC
    CYPHER

    puts "Updated #{result.count} teams"
    puts "\n| Team | Home ATS | Away ATS | Over% |"
    puts "|------|----------|----------|-------|"
    result.first(10).each do |r|
      puts "| #{r['t.abbr']} | #{r['home_ats']}% | #{r['away_ats']}% | #{r['over_pct']}% |"
    end
    puts "..."
  end

  desc "Sync spread/total lines from SQLite to Neo4j"
  task sync_lines: :environment do
    puts "📊 Syncing spread/total lines to Neo4j..."

    client = Neo4jClient.new

    # SQLite에서 스프레드가 있는 경기 + GameResult 조인
    games_with_lines = Game.joins(:game_result)
                          .where.not(home_spread: nil)
                          .where("games.game_date >= ?", 3.months.ago)
                          .includes(:game_result)

    puts "Found #{games_with_lines.count} games with spread data"

    synced = 0
    games_with_lines.find_each do |game|
      result = game.game_result
      date_str = game.game_date.strftime('%Y%m%d')

      # Neo4j Game 노드 업데이트
      client.query(<<~CYPHER, {
        date: date_str,
        home: game.home_abbr,
        away: game.away_abbr,
        spread: game.home_spread.to_f,
        total: game.total_line&.to_f,
        closing_spread: result.closing_spread&.to_f,
        closing_total: result.closing_total&.to_f,
        spread_result: result.spread_result,
        total_result: result.total_result
      })
        MATCH (g:Game)
        WHERE g.date = $date AND g.home_team = $home AND g.away_team = $away
        SET g.spread = $spread,
            g.total = $total,
            g.closing_spread = $closing_spread,
            g.closing_total = $closing_total,
            g.spread_result = $spread_result,
            g.total_result = $total_result,
            g.lines_synced = datetime()
        RETURN g.date, g.home_team
      CYPHER

      synced += 1
      print "." if synced % 50 == 0
    end

    puts "\n✅ Synced #{synced} games"

    # 동기화 결과 확인
    verify = client.query(<<~CYPHER)
      MATCH (g:Game)
      WHERE g.spread IS NOT NULL
      RETURN count(g) AS games_with_spread,
             count(CASE WHEN g.spread_result IS NOT NULL THEN 1 END) AS games_with_result
    CYPHER

    v = verify.first
    puts "📈 Neo4j: #{v['games_with_spread']} games with spread, #{v['games_with_result']} with result"
  end

  desc "Run Spread Engine for a specific date"
  task :spread, [:date] => :environment do |_, args|
    date_str = args[:date] || Date.current.strftime('%Y%m%d')

    puts "🎯 G9 Spread Engine - Analyzing #{date_str}"
    puts "=" * 60

    begin
      service = G9EngineService.new
      picks = service.analyze_spread(date_str)

      if picks.empty?
        puts "⚠️ #{date_str}에 경기 데이터 없음"
        exit 0
      end

      puts "\n| Matchup | Spread Edge | Pick | Expected Margin | Signal |"
      puts "|---------|-------------|------|-----------------|--------|"

      picks.each do |p|
        puts "| #{p[:matchup]} | #{p[:spread_edge_score]} | #{p[:recommended]} (#{p[:pick_side]}) | #{p[:expected_margin]} | #{p[:signal]} |"
      end

      puts "\n" + "-" * 60
      actionable = picks.count { |p| p[:actionable] }
      puts "💎 Spread 75+: #{actionable}개"
      puts "🚫 PASS: #{picks.count { |p| p[:spread_edge_score] < 55 }}개"
    rescue => e
      puts "❌ Error: #{e.message}"
      exit 1
    end
  end

  desc "Backtest Spread Engine"
  task :spread_backtest, [:start_date, :end_date] => :environment do |_, args|
    start_date = args[:start_date] || (Date.current - 30).strftime('%Y%m%d')
    end_date = args[:end_date] || Date.current.strftime('%Y%m%d')

    puts "🎯 G9 Spread Engine - Backtest"
    puts "📅 #{start_date} ~ #{end_date}"
    puts "=" * 60

    client = Neo4jClient.new

    # Spread 백테스트 쿼리
    result = client.query(<<~CYPHER, { start_date: start_date, end_date: end_date })
      WITH $start_date AS start_date, $end_date AS end_date

      MATCH (g:Game)
      WHERE g.date >= start_date AND g.date <= end_date
        AND g.status = 'Final'
        AND g.spread IS NOT NULL
        AND g.spread_result IS NOT NULL
      MATCH (home:Team {abbr: g.home_team})
      MATCH (away:Team {abbr: g.away_team})

      // TeamRegime
      OPTIONAL MATCH (hr:TeamRegime) WHERE hr.team CONTAINS home.name
      OPTIONAL MATCH (ar:TeamRegime) WHERE ar.team CONTAINS away.name

      WITH g, home, away,
           coalesce(home.net_rtg, 0) AS h_net,
           coalesce(away.net_rtg, 0) AS a_net,
           coalesce(home.ats_home_pct, 0.5) AS h_ats,
           coalesce(away.ats_away_pct, 0.5) AS a_ats,
           coalesce(hr.flow_state, 'NEUTRAL') AS h_flow,
           coalesce(ar.flow_state, 'NEUTRAL') AS a_flow

      // 예상 마진
      WITH g, home, away, h_net, a_net, h_ats, a_ats, h_flow, a_flow,
           (h_net - a_net) + 3.5 AS expected_margin

      // Spread Edge Score
      WITH g, home, away, expected_margin,
           50 +
           CASE
             WHEN expected_margin > 12 THEN 15
             WHEN expected_margin > 8 THEN 10
             WHEN expected_margin > 5 THEN 5
             WHEN expected_margin > 0 THEN 0
             WHEN expected_margin > -5 THEN -5
             WHEN expected_margin > -8 THEN -10
             ELSE -15
           END +
           CASE WHEN h_ats > 0.55 THEN 5 WHEN h_ats < 0.45 THEN -5 ELSE 0 END +
           CASE WHEN h_flow IN ['HOT_STREAK', 'STRONG_UP'] THEN 3
                WHEN h_flow IN ['COLD_STREAK', 'SLUMP'] THEN -3 ELSE 0 END +
           CASE WHEN a_flow IN ['HOT_STREAK', 'STRONG_UP'] THEN -3
                WHEN a_flow IN ['COLD_STREAK', 'SLUMP'] THEN 3 ELSE 0 END
           AS raw_edge

      WITH g,
           CASE WHEN raw_edge >= 50 THEN raw_edge ELSE 100 - raw_edge END AS spread_edge,
           CASE WHEN raw_edge >= 50 THEN 'HOME' ELSE 'AWAY' END AS pick_side,
           g.spread_result AS actual_result

      // 티어별 집계
      WITH
        CASE
          WHEN spread_edge >= 80 THEN 'A_STRONG_80+'
          WHEN spread_edge >= 75 THEN 'B_BET_75-79'
          WHEN spread_edge >= 65 THEN 'C_LEAN_65-74'
          WHEN spread_edge >= 55 THEN 'D_WATCH_55-64'
          ELSE 'E_PASS_<55'
        END AS tier,
        CASE
          WHEN pick_side = 'HOME' AND actual_result = 'home_covered' THEN true
          WHEN pick_side = 'AWAY' AND actual_result = 'away_covered' THEN true
          ELSE false
        END AS correct

      RETURN tier,
             count(*) AS games,
             sum(CASE WHEN correct THEN 1 ELSE 0 END) AS wins,
             round(toFloat(sum(CASE WHEN correct THEN 1 ELSE 0 END)) / count(*) * 100, 1) AS accuracy
      ORDER BY tier
    CYPHER

    puts "\n| 티어 | 경기수 | 적중 | 적중률 |"
    puts "|------|--------|------|--------|"

    total_games = 0
    total_wins = 0
    edge75_games = 0
    edge75_wins = 0

    result.each do |r|
      tier = r['tier']
      games = r['games'].is_a?(Hash) ? r['games']['low'] : r['games'].to_i
      wins = r['wins'].is_a?(Hash) ? r['wins']['low'] : r['wins'].to_i
      accuracy = r['accuracy'].to_f

      puts "| #{tier} | #{games} | #{wins} | #{accuracy}% |"

      total_games += games
      total_wins += wins

      if tier.start_with?('A_') || tier.start_with?('B_')
        edge75_games += games
        edge75_wins += wins
      end
    end

    puts "|------|--------|------|--------|"
    puts "| TOTAL | #{total_games} | #{total_wins} | #{(total_wins.to_f / total_games * 100).round(1)}% |" if total_games > 0

    if edge75_games > 0
      puts "\n💎 Spread Edge 75+ 통합: #{edge75_wins}/#{edge75_games} = #{(edge75_wins.to_f / edge75_games * 100).round(1)}%"

      # ROI 계산 (-110 기준)
      roi = (edge75_wins * 0.91 - (edge75_games - edge75_wins)) / edge75_games * 100
      puts "💰 예상 ROI: #{roi.round(1)}% (at -110)"
    end

    puts "=" * 60
  end

  desc "Run Pickem Underdog Engine for a specific date"
  task :pickem, [:date] => :environment do |_, args|
    date_str = args[:date] || Date.current.strftime('%Y%m%d')

    puts "🎯 G9 Pickem Underdog Engine - Analyzing #{date_str}"
    puts "=" * 60
    puts "📊 백테스트: 0-0.5pt = 58.2%, 0-1.5pt = 56.4%"
    puts ""

    begin
      service = G9EngineService.new
      picks = service.analyze_pickem(date_str)

      if picks.empty?
        puts "⚠️ #{date_str}에 픽켐 조건 충족 경기 없음"
        puts "   (조건: 스프레드 0-1.5pt + 어웨이 Net Rating 우위)"
        exit 0
      end

      puts "\n| Time ET | Matchup | Spread | Net Edge | Pickem Edge | Type | Signal |"
      puts "|---------|---------|--------|----------|-------------|------|--------|"

      picks.each do |p|
        time = p[:time_et] || '-'
        puts "| #{time} | #{p[:matchup]} | +#{p[:spread]} | +#{p[:net_rtg_edge]} | #{p[:pickem_edge_score]} | #{p[:pickem_type]} | #{p[:signal]} |"
      end

      puts "\n" + "-" * 60
      actionable = picks.select { |p| p[:actionable] }
      puts "🎯 Pickem 75+: #{actionable.count}개"

      if actionable.any?
        puts "\n### ACTION PICKS ###"
        actionable.each do |p|
          puts "  #{p[:signal]} #{p[:matchup]} → #{p[:recommended]} +#{p[:spread]}"
          puts "     Net Rating Edge: +#{p[:net_rtg_edge]} (#{p[:away]}가 #{p[:net_rtg_edge]}점 우위)"
        end
      end
    rescue => e
      puts "❌ Error: #{e.message}"
      puts e.backtrace.first(3).join("\n")
      exit 1
    end
  end

  desc "Backtest Pickem Underdog strategy"
  task :pickem_backtest, [:start_date, :end_date] => :environment do |_, args|
    start_date = args[:start_date] || '20240101'
    end_date = args[:end_date] || '20251231'

    puts "🎯 G9 Pickem Underdog - Backtest"
    puts "📅 #{start_date} ~ #{end_date}"
    puts "=" * 60

    client = Neo4jClient.new

    # Pickem Underdog 백테스트 쿼리
    result = client.query(<<~CYPHER, { start_date: start_date, end_date: end_date })
      WITH $start_date AS start_date, $end_date AS end_date

      // 픽켐 조건: 0-1.5pt 스프레드
      MATCH (g:Game)
      WHERE g.date >= start_date AND g.date <= end_date
        AND g.status = 'Final'
        AND g.spread IS NOT NULL
        AND g.spread >= 0
        AND g.spread <= 1.5
        AND g.spread_result IS NOT NULL
      MATCH (home:Team {abbr: g.home_team})
      MATCH (away:Team {abbr: g.away_team})

      // 어웨이팀이 Net Rating 우위
      WHERE coalesce(away.net_rtg, 0) > coalesce(home.net_rtg, 0)

      WITH g, home, away,
           coalesce(away.net_rtg, 0) - coalesce(home.net_rtg, 0) AS net_edge,
           g.spread AS spread,
           g.spread_result AS result

      // 스프레드 범위별 분류
      WITH
        CASE
          WHEN spread <= 0.5 THEN 'A_TIGHT_0-0.5'
          WHEN spread <= 1.0 THEN 'B_MID_0.5-1.0'
          ELSE 'C_WIDE_1.0-1.5'
        END AS spread_tier,
        CASE
          WHEN net_edge >= 8 THEN 'STRONG_8+'
          WHEN net_edge >= 5 THEN 'MID_5-8'
          WHEN net_edge >= 3 THEN 'SLIGHT_3-5'
          ELSE 'MINIMAL_0-3'
        END AS edge_tier,
        result = 'away_covered' AS away_covered

      // 스프레드 범위별 집계
      RETURN spread_tier,
             count(*) AS games,
             sum(CASE WHEN away_covered THEN 1 ELSE 0 END) AS away_covers,
             round(toFloat(sum(CASE WHEN away_covered THEN 1 ELSE 0 END)) / count(*) * 100, 1) AS cover_pct
      ORDER BY spread_tier
    CYPHER

    puts "\n### 스프레드 범위별 어웨이 커버율 ###"
    puts "| 스프레드 범위 | 경기수 | 어웨이 커버 | 커버율 |"
    puts "|---------------|--------|-------------|--------|"

    total_games = 0
    total_covers = 0

    result.each do |r|
      tier = r['spread_tier']
      games = r['games'].is_a?(Hash) ? r['games']['low'] : r['games'].to_i
      covers = r['away_covers'].is_a?(Hash) ? r['away_covers']['low'] : r['away_covers'].to_i
      pct = r['cover_pct'].to_f

      puts "| #{tier} | #{games} | #{covers} | #{pct}% |"

      total_games += games
      total_covers += covers
    end

    puts "|---------------|--------|-------------|--------|"
    if total_games > 0
      total_pct = (total_covers.to_f / total_games * 100).round(1)
      puts "| TOTAL | #{total_games} | #{total_covers} | #{total_pct}% |"

      # ROI 계산 (-110 기준)
      roi = (total_covers * 0.91 - (total_games - total_covers)) / total_games * 100
      puts "\n💰 예상 ROI: #{roi.round(1)}% (at -110)"
    end

    # Net Rating Edge별 분석
    result2 = client.query(<<~CYPHER, { start_date: start_date, end_date: end_date })
      WITH $start_date AS start_date, $end_date AS end_date

      MATCH (g:Game)
      WHERE g.date >= start_date AND g.date <= end_date
        AND g.status = 'Final'
        AND g.spread IS NOT NULL
        AND g.spread >= 0
        AND g.spread <= 1.5
        AND g.spread_result IS NOT NULL
      MATCH (home:Team {abbr: g.home_team})
      MATCH (away:Team {abbr: g.away_team})

      WHERE coalesce(away.net_rtg, 0) > coalesce(home.net_rtg, 0)

      WITH g,
           coalesce(away.net_rtg, 0) - coalesce(home.net_rtg, 0) AS net_edge,
           g.spread_result = 'away_covered' AS away_covered

      WITH
        CASE
          WHEN net_edge >= 8 THEN 'A_STRONG_8+'
          WHEN net_edge >= 5 THEN 'B_MID_5-8'
          WHEN net_edge >= 3 THEN 'C_SLIGHT_3-5'
          ELSE 'D_MINIMAL_0-3'
        END AS edge_tier,
        away_covered

      RETURN edge_tier,
             count(*) AS games,
             sum(CASE WHEN away_covered THEN 1 ELSE 0 END) AS away_covers,
             round(toFloat(sum(CASE WHEN away_covered THEN 1 ELSE 0 END)) / count(*) * 100, 1) AS cover_pct
      ORDER BY edge_tier
    CYPHER

    puts "\n### Net Rating Edge별 어웨이 커버율 ###"
    puts "| Net Edge | 경기수 | 어웨이 커버 | 커버율 |"
    puts "|----------|--------|-------------|--------|"

    result2.each do |r|
      tier = r['edge_tier']
      games = r['games'].is_a?(Hash) ? r['games']['low'] : r['games'].to_i
      covers = r['away_covers'].is_a?(Hash) ? r['away_covers']['low'] : r['away_covers'].to_i
      pct = r['cover_pct'].to_f

      puts "| #{tier} | #{games} | #{covers} | #{pct}% |"
    end

    puts "=" * 60
  end

  desc "Run Total Engine (Over/Under) for a specific date"
  task :total, [:date] => :environment do |_, args|
    date_str = args[:date] || Date.current.strftime('%Y%m%d')

    puts "📊 G9 Total Engine - Analyzing #{date_str}"
    puts "=" * 60

    begin
      service = G9EngineService.new
      picks = service.analyze_total(date_str)

      if picks.empty?
        puts "⚠️ #{date_str}에 경기 데이터 없음"
        exit 0
      end

      puts "\n| Matchup | Total Edge | Pick | Expected | Market | Diff | Signal |"
      puts "|---------|------------|------|----------|--------|------|--------|"

      picks.each do |p|
        puts "| #{p[:matchup]} | #{p[:total_edge_score]} | #{p[:pick_side]} | #{p[:expected_total]} | #{p[:market_total]} | #{p[:total_diff]} | #{p[:signal]} |"
      end

      puts "\n" + "-" * 60
      actionable = picks.count { |p| p[:actionable] }
      puts "💎 Total 72+: #{actionable}개"
      puts "📈 OVER: #{picks.count { |p| p[:pick_side] == 'OVER' }}개"
      puts "📉 UNDER: #{picks.count { |p| p[:pick_side] == 'UNDER' }}개"
    rescue => e
      puts "❌ Error: #{e.message}"
      exit 1
    end
  end

  desc "Backtest Total Engine (Over/Under)"
  task :total_backtest, [:start_date, :end_date] => :environment do |_, args|
    start_date = args[:start_date] || (Date.current - 30).strftime('%Y%m%d')
    end_date = args[:end_date] || Date.current.strftime('%Y%m%d')

    puts "📊 G9 Total Engine - Backtest"
    puts "📅 #{start_date} ~ #{end_date}"
    puts "=" * 60

    client = Neo4jClient.new

    # Total 백테스트 쿼리
    result = client.query(<<~CYPHER, { start_date: start_date, end_date: end_date })
      WITH $start_date AS start_date, $end_date AS end_date

      MATCH (g:Game)
      WHERE g.date >= start_date AND g.date <= end_date
        AND g.status = 'Final'
        AND g.total IS NOT NULL
        AND g.total_result IS NOT NULL
      MATCH (home:Team {abbr: g.home_team})
      MATCH (away:Team {abbr: g.away_team})

      WITH g, home, away,
           coalesce(home.off_rtg, 114) AS h_off,
           coalesce(away.off_rtg, 114) AS a_off,
           coalesce(home.def_rtg, 114) AS h_def,
           coalesce(away.def_rtg, 114) AS a_def,
           coalesce(home.over_pct, 0.5) AS h_over,
           coalesce(away.over_pct, 0.5) AS a_over

      // 예상 토탈
      WITH g, home, away, h_off, a_off, h_def, a_def, h_over, a_over,
           h_off + a_off AS expected_total,
           g.total AS market_total

      // Total Edge Score
      WITH g, expected_total, market_total,
           expected_total - market_total AS diff,
           50 +
           CASE
             WHEN expected_total - market_total > 10 THEN 15
             WHEN expected_total - market_total > 5 THEN 10
             WHEN expected_total - market_total > 2 THEN 5
             WHEN expected_total - market_total > -2 THEN 0
             WHEN expected_total - market_total > -5 THEN -5
             WHEN expected_total - market_total > -10 THEN -10
             ELSE -15
           END +
           CASE WHEN h_off > 118 AND a_off > 118 THEN 5
                WHEN h_off < 110 AND a_off < 110 THEN -5 ELSE 0 END +
           CASE WHEN h_def > 116 AND a_def > 116 THEN 5
                WHEN h_def < 108 AND a_def < 108 THEN -5 ELSE 0 END +
           CASE WHEN h_over > 0.55 AND a_over > 0.55 THEN 3
                WHEN h_over < 0.45 AND a_over < 0.45 THEN -3 ELSE 0 END
           AS raw_edge

      WITH g,
           CASE WHEN raw_edge >= 50 THEN raw_edge ELSE 100 - raw_edge END AS total_edge,
           CASE WHEN raw_edge >= 50 THEN 'OVER' ELSE 'UNDER' END AS pick_side,
           g.total_result AS actual_result

      // 티어별 집계
      WITH
        CASE
          WHEN total_edge >= 78 THEN 'A_STRONG_78+'
          WHEN total_edge >= 72 THEN 'B_BET_72-77'
          WHEN total_edge >= 62 THEN 'C_LEAN_62-71'
          WHEN total_edge >= 52 THEN 'D_WATCH_52-61'
          ELSE 'E_PASS_<52'
        END AS tier,
        CASE
          WHEN pick_side = 'OVER' AND actual_result = 'over' THEN true
          WHEN pick_side = 'UNDER' AND actual_result = 'under' THEN true
          ELSE false
        END AS correct

      RETURN tier,
             count(*) AS games,
             sum(CASE WHEN correct THEN 1 ELSE 0 END) AS wins,
             round(toFloat(sum(CASE WHEN correct THEN 1 ELSE 0 END)) / count(*) * 100, 1) AS accuracy
      ORDER BY tier
    CYPHER

    puts "\n| 티어 | 경기수 | 적중 | 적중률 |"
    puts "|------|--------|------|--------|"

    total_games = 0
    total_wins = 0
    edge72_games = 0
    edge72_wins = 0

    result.each do |r|
      tier = r['tier']
      games = r['games'].is_a?(Hash) ? r['games']['low'] : r['games'].to_i
      wins = r['wins'].is_a?(Hash) ? r['wins']['low'] : r['wins'].to_i
      accuracy = r['accuracy'].to_f

      puts "| #{tier} | #{games} | #{wins} | #{accuracy}% |"

      total_games += games
      total_wins += wins

      if tier.start_with?('A_') || tier.start_with?('B_')
        edge72_games += games
        edge72_wins += wins
      end
    end

    puts "|------|--------|------|--------|"
    puts "| TOTAL | #{total_games} | #{total_wins} | #{(total_wins.to_f / total_games * 100).round(1)}% |" if total_games > 0

    if edge72_games > 0
      puts "\n📊 Total Edge 72+ 통합: #{edge72_wins}/#{edge72_games} = #{(edge72_wins.to_f / edge72_games * 100).round(1)}%"

      # ROI 계산 (-110 기준)
      roi = (edge72_wins * 0.91 - (edge72_games - edge72_wins)) / edge72_games * 100
      puts "💰 예상 ROI: #{roi.round(1)}% (at -110)"
    end

    puts "=" * 60
  end

  desc "Run all engines (ML + Spread + Pickem + Total) for a date"
  task :all, [:date] => :environment do |_, args|
    date_str = args[:date] || Date.current.strftime('%Y%m%d')

    puts "🏀 G9 Engine Suite - Full Analysis #{date_str}"
    puts "=" * 60

    service = G9EngineService.new
    results = service.analyze_all(date_str)

    puts "\n### ML (Moneyline) ###"
    results[:ml].each do |p|
      next unless p[:actionable]
      puts "💎 #{p[:matchup]} → #{p[:recommended]} (Edge #{p[:edge_score]}) #{p[:signal]}"
    end
    puts "(#{results[:ml].count { |p| p[:actionable] }} actionable)" if results[:ml].any?

    puts "\n### SPREAD (ATS) ###"
    results[:spread].each do |p|
      next unless p[:actionable]
      puts "💎 #{p[:matchup]} → #{p[:recommended]} #{p[:pick_side]} (Edge #{p[:spread_edge_score]}) #{p[:signal]}"
    end
    puts "(#{results[:spread].count { |p| p[:actionable] }} actionable)" if results[:spread].any?

    puts "\n### PICKEM UNDERDOG (58.2% Edge) ###"
    if results[:pickem].any?
      results[:pickem].each do |p|
        emoji = p[:actionable] ? '🎯' : '📍'
        puts "#{emoji} #{p[:matchup]} → #{p[:recommended]} +#{p[:spread]} (Net Edge +#{p[:net_rtg_edge]}) #{p[:signal]}"
      end
      puts "(#{results[:pickem].count { |p| p[:actionable] }} actionable)"
    else
      puts "  (픽켐 조건 충족 경기 없음)"
    end

    puts "\n### TOTAL (O/U) ###"
    results[:total].each do |p|
      next unless p[:actionable]
      puts "💎 #{p[:matchup]} → #{p[:pick_side]} (Edge #{p[:total_edge_score]}) #{p[:signal]}"
    end
    puts "(#{results[:total].count { |p| p[:actionable] }} actionable)" if results[:total].any?

    puts "\n" + "=" * 60
  end

  desc "Full daily cycle: sync stats → update regime → analyze → report"
  task cycle: :environment do
    puts "🔄 G9 Full Daily Cycle"
    puts "=" * 60

    puts "\n[1/6] Syncing Team stats..."
    Rake::Task["g9:sync_stats"].invoke

    puts "\n[2/6] Syncing spread/total lines..."
    Rake::Task["g9:sync_lines"].invoke

    puts "\n[3/6] Syncing ATS stats..."
    Rake::Task["g9:sync_ats"].invoke

    puts "\n[4/6] Updating TeamRegime..."
    Rake::Task["g9:update_regime"].invoke

    puts "\n[5/6] Running full analysis..."
    Rake::Task["g9:all"].invoke

    puts "\n[6/6] Complete!"
    puts "=" * 60
  end
end
