# frozen_string_literal: true

namespace :weakness do
  desc "Detect weakness triggers for upcoming games"
  task detect: :environment do
    puts "🔍 Detecting weakness triggers for upcoming games..."

    # Get games in next 24 hours
    upcoming_games = Game.where(
      "game_date > ? AND game_date < ?",
      Time.current,
      24.hours.from_now
    ).where.not(home_edge: nil).or(
      Game.where(
        "game_date > ? AND game_date < ?",
        Time.current,
        24.hours.from_now
      ).where.not(away_edge: nil)
    )

    puts "Found #{upcoming_games.count} games with edge data"

    total_triggers = 0
    upcoming_games.each do |game|
      predictions = WeaknessPrediction.detect_triggers_for_game(game)
      next if predictions.empty?

      puts "  #{game.away_team} @ #{game.home_team}:"
      predictions.each do |pred|
        puts "    - #{pred.team}: #{pred.trigger_type} (#{pred.trigger_detail})"
        total_triggers += 1
      end
    end

    puts "\n✅ Created #{total_triggers} weakness predictions"
  end

  desc "Evaluate weakness predictions for finished games"
  task evaluate: :environment do
    puts "📊 Evaluating weakness predictions..."

    # Find games with unevaluated predictions
    unevaluated = WeaknessPrediction.unevaluated
                                    .joins(:game)
                                    .where("games.status = ? OR games.home_score IS NOT NULL", "finished")

    puts "Found #{unevaluated.count} unevaluated predictions"

    evaluated_count = 0
    hits = 0

    unevaluated.group_by(&:game_id).each do |game_id, predictions|
      game = Game.find(game_id)
      game_result = GameResult.find_by(game: game)

      unless game_result&.spread_result.present?
        puts "  ⚠️  No result for #{game.away_team} @ #{game.home_team}"
        next
      end

      predictions.each do |pred|
        pred.evaluate_outcome(game_result)
        evaluated_count += 1
        hits += 1 if pred.hit?
        status = pred.hit? ? "✅ HIT" : "❌ MISS"
        puts "  #{status} #{pred.team} #{pred.trigger_type}: #{pred.predicted_outcome} → #{pred.actual_outcome}"
      end
    end

    if evaluated_count > 0
      hit_rate = (hits.to_f / evaluated_count * 100).round(1)
      puts "\n📈 Evaluated #{evaluated_count} predictions: #{hits} hits (#{hit_rate}%)"
    else
      puts "\nNo predictions to evaluate"
    end
  end

  desc "Show weakness prediction statistics"
  task stats: :environment do
    puts "📊 Weakness Prediction Statistics"
    puts "=" * 50

    stats = WeaknessPrediction.statistics

    puts "\nOverall:"
    puts "  Total predictions: #{stats[:total_predictions]}"
    puts "  Evaluated: #{stats[:evaluated]}"
    puts "  Unevaluated: #{stats[:unevaluated]}"
    puts "  Overall hit rate: #{stats[:overall_hit_rate]}%"

    if stats[:by_trigger].any?
      puts "\nBy Trigger Type:"
      stats[:by_trigger].each do |trigger_stat|
        puts "  #{trigger_stat[:trigger_type]}:"
        puts "    Total: #{trigger_stat[:total]}"
        puts "    Hits: #{trigger_stat[:hits]} (#{trigger_stat[:hit_rate]}%)"
      end
    end

    # Top teams with weakness
    puts "\nTop Teams by Weakness (Hit Rate):"
    teams = WeaknessPrediction.evaluated
                              .group(:team)
                              .having(Arel.sql("COUNT(*) >= 3"))
                              .order(Arel.sql("AVG(CASE WHEN hit THEN 1 ELSE 0 END) DESC"))
                              .limit(10)
                              .pluck(:team, Arel.sql("COUNT(*)"), Arel.sql("SUM(CASE WHEN hit THEN 1 ELSE 0 END)"))

    teams.each do |team, total, hits_count|
      hit_rate = (hits_count.to_f / total * 100).round(1)
      puts "  #{team}: #{hits_count}/#{total} (#{hit_rate}%)"
    end
  end

  desc "Run full weakness cycle: detect → evaluate → stats"
  task cycle: :environment do
    Rake::Task["weakness:detect"].invoke
    puts "\n"
    Rake::Task["weakness:evaluate"].invoke
    puts "\n"
    Rake::Task["weakness:stats"].invoke
  end

  desc "Backfill weakness predictions from historical games"
  task backfill: :environment do
    require 'json'

    puts "🔄 Backfilling weakness predictions from historical data..."

    # Load advanced stats
    advanced_stats = WeaknessPrediction.load_advanced_stats
    puts "  Advanced stats loaded: #{advanced_stats.keys.count} teams"

    # Get finished games with edge data
    finished_games = Game.where(status: "finished")
                         .where.not(home_score: nil)
                         .where("home_edge IS NOT NULL OR away_edge IS NOT NULL")
                         .order(:game_date)

    puts "  Found #{finished_games.count} finished games with edge data"

    created = 0
    evaluated = 0
    hits = 0

    finished_games.find_each do |game|
      # Detect triggers (schedule-based)
      triggers = []

      # Home team schedule triggers
      if game.home_edge.present?
        home_triggers = WeaknessPrediction.detect_team_triggers(game, :home)
        home_triggers.each do |t|
          triggers << { team: game.home_team, abbr: game.home_abbr, side: :home, **t }
        end
      end

      # Away team schedule triggers
      if game.away_edge.present?
        away_triggers = WeaknessPrediction.detect_team_triggers(game, :away)
        away_triggers.each do |t|
          triggers << { team: game.away_team, abbr: game.away_abbr, side: :away, **t }
        end
      end

      # Matchup triggers (if advanced stats available)
      if advanced_stats.any?
        home_matchup = WeaknessPrediction.detect_matchup_triggers(game, :home, advanced_stats)
        home_matchup.each do |t|
          triggers << { team: game.home_team, abbr: game.home_abbr, side: :home, **t }
        end

        away_matchup = WeaknessPrediction.detect_matchup_triggers(game, :away, advanced_stats)
        away_matchup.each do |t|
          triggers << { team: game.away_team, abbr: game.away_abbr, side: :away, **t }
        end
      end

      next if triggers.empty?

      # Create and evaluate predictions
      triggers.each do |trigger|
        pred = WeaknessPrediction.find_or_initialize_by(
          game: game,
          team: trigger[:team],
          trigger_type: trigger[:type]
        )

        if pred.new_record?
          pred.trigger_detail = trigger[:detail]
          pred.confidence = trigger[:confidence]
          pred.predicted_outcome = trigger[:predicted_outcome]
          pred.triggered_at = game.game_date
          pred.source = "Rails_Backfill"
          pred.save!
          created += 1
        end

        # Evaluate if not already evaluated
        next if pred.evaluated_at.present?

        # Determine actual outcome based on game result
        is_home = (trigger[:side] == :home)
        team_score = is_home ? game.home_score : game.away_score
        opp_score = is_home ? game.away_score : game.home_score
        won = team_score > opp_score

        # For COVER_FAIL prediction, check if team lost (simplified without spread)
        # With spread: check ATS result
        game_result = game.game_result

        if game_result&.spread_result.present?
          # Use ATS result
          case game_result.spread_result
          when "home_covered"
            actual = is_home ? "COVERED" : "COVER_FAIL"
          when "away_covered"
            actual = is_home ? "COVER_FAIL" : "COVERED"
          else
            actual = "PUSH"
          end
        else
          # Fallback to straight-up result (less accurate but still useful)
          actual = won ? "WIN" : "LOSS"
          # Map to cover result (team that lost likely failed to cover)
          actual = won ? "COVERED" : "COVER_FAIL"
        end

        pred.actual_outcome = actual
        pred.hit = (pred.predicted_outcome == actual)
        pred.evaluated_at = Time.current
        pred.save!

        evaluated += 1
        hits += 1 if pred.hit?
      end
    end

    puts "\n📊 Backfill Results:"
    puts "  Created: #{created} predictions"
    puts "  Evaluated: #{evaluated}"
    puts "  Hits: #{hits} (#{evaluated > 0 ? (hits.to_f / evaluated * 100).round(1) : 0}%)"

    # Show breakdown by trigger type
    puts "\n📈 Hit Rate by Trigger Type:"
    WeaknessPrediction::TRIGGER_TYPES.each do |trigger_type|
      preds = WeaknessPrediction.evaluated.by_trigger(trigger_type)
      next if preds.count < 3

      hit_rate = (preds.hits.count.to_f / preds.count * 100).round(1)
      puts "  #{trigger_type}: #{preds.hits.count}/#{preds.count} (#{hit_rate}%)"
    end
  end

  desc "Sync weakness hit rates to Neo4j TeamRegime"
  task sync_neo4j: :environment do
    require "net/http"
    require "json"

    puts "🔄 Syncing weakness hit rates to Neo4j..."

    # Get hit rates by team and trigger
    team_stats = {}

    WeaknessPrediction.evaluated.each do |pred|
      team_stats[pred.team] ||= {}
      team_stats[pred.team][pred.trigger_type] ||= { hits: 0, total: 0 }
      team_stats[pred.team][pred.trigger_type][:total] += 1
      team_stats[pred.team][pred.trigger_type][:hits] += 1 if pred.hit?
    end

    # Neo4j connection
    uri = URI("http://86.48.2.202:7474/db/neo4j/tx/commit")

    team_stats.each do |team, triggers|
      triggers.each do |trigger_type, stats|
        next if stats[:total] < 3  # Minimum samples

        hit_rate = (stats[:hits].to_f / stats[:total] * 100).round(1)

        # Create/update WeaknessTrigger node with validated hit rate
        cypher = <<~CYPHER
          MERGE (wt:WeaknessTrigger {team: $team, trigger_type: $trigger_type})
          SET wt.validated_hit_rate = $hit_rate,
              wt.sample_size = $sample_size,
              wt.last_updated = datetime(),
              wt.source = 'Rails_WeaknessPrediction'
          WITH wt
          MATCH (tr:TeamRegime {team: $team})
          MERGE (tr)-[:HAS_TRIGGER]->(wt)
          RETURN wt
        CYPHER

        body = {
          statements: [{
            statement: cypher,
            parameters: {
              team: team,
              trigger_type: trigger_type,
              hit_rate: hit_rate,
              sample_size: stats[:total]
            }
          }]
        }.to_json

        http = Net::HTTP.new(uri.host, uri.port)
        request = Net::HTTP::Post.new(uri.path)
        request["Content-Type"] = "application/json"
        request.basic_auth("neo4j", "nba_vultr_2025")
        request.body = body

        response = http.request(request)

        if response.code == "200"
          puts "  ✅ #{team} - #{trigger_type}: #{hit_rate}% (n=#{stats[:total]})"
        else
          puts "  ❌ #{team} - #{trigger_type}: Failed (#{response.code})"
        end
      end
    end

    puts "\n✅ Sync complete"
  end
end
