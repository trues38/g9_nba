namespace :feedback do
  # Standard factor tags
  PICK_FACTORS = {
    "INJ_KEY_OUT" => "Key player OUT",
    "INJ_MULTIPLE" => "Multiple players OUT",
    "INJ_GTD_RISK" => "GTD player risk",
    "SCHED_B2B" => "Back-to-back",
    "SCHED_3IN4" => "3 in 4 days",
    "SCHED_REST" => "Rest advantage",
    "SCHED_TRAVEL" => "Travel fatigue",
    "FORM_HOT" => "Hot streak",
    "FORM_COLD" => "Cold streak",
    "FORM_ATS_HOT" => "ATS hot",
    "FORM_ATS_COLD" => "ATS cold",
    "LINE_SHARP" => "Sharp money",
    "LINE_VALUE" => "Line value",
    "PUBLIC_FADE" => "Fade public",
    "MATCH_STYLE" => "Style matchup",
    "MATCH_PACE" => "Pace mismatch",
    "MATCH_DEFENSE" => "Defense matchup",
    "SIT_REVENGE" => "Revenge game",
    "SIT_CHEMISTRY" => "Chemistry issues",
    "TOTAL_PACE" => "Pace-based",
    "TOTAL_DEFENSE" => "Defense-based"
  }.freeze

  FAILURE_REASONS = {
    "FAIL_INJ_UPDATE" => "Late injury news",
    "FAIL_INJ_WRONG" => "Injury impact wrong",
    "FAIL_FORM_WRONG" => "Form read wrong",
    "FAIL_LINE_MOVED" => "Line moved against",
    "FAIL_BLOWOUT" => "Unexpected blowout",
    "FAIL_CLOSE_LOSS" => "Lost by hook",
    "FAIL_OT" => "OT changed result",
    "FAIL_GARBAGE" => "Garbage time",
    "FAIL_PACE_WRONG" => "Pace wrong",
    "FAIL_RANDOM" => "Bad beat/variance"
  }.freeze

  desc "Show available factor tags"
  task tags: :environment do
    puts "PICK FACTORS:"
    puts "-" * 40
    PICK_FACTORS.each { |k, v| puts "  #{k.ljust(18)} #{v}" }
    puts "\nFAILURE REASONS:"
    puts "-" * 40
    FAILURE_REASONS.each { |k, v| puts "  #{k.ljust(18)} #{v}" }
  end

  desc "Analyze performance by factor"
  task analyze: :environment do
    reports = Report.where.not(result: nil).includes(:game)

    puts "=" * 60
    puts "FACTOR PERFORMANCE ANALYSIS"
    puts "=" * 60

    # Spread factors
    puts "\n📊 SPREAD FACTORS:"
    puts "-" * 40
    factor_stats = Hash.new { |h, k| h[k] = { wins: 0, losses: 0 } }

    reports.each do |r|
      sd = r.structured_data || {}
      factors = sd["spread_factors"] || []
      result = sd["spread_result"]
      next unless result.present?

      factors.each do |f|
        if result == "win"
          factor_stats[f][:wins] += 1
        else
          factor_stats[f][:losses] += 1
        end
      end
    end

    factor_stats.sort_by { |_, v| -(v[:wins] + v[:losses]) }.each do |factor, stats|
      total = stats[:wins] + stats[:losses]
      pct = total > 0 ? (stats[:wins].to_f / total * 100).round(1) : 0
      emoji = pct >= 55 ? "✅" : (pct >= 45 ? "➖" : "❌")
      name = PICK_FACTORS[factor] || factor
      puts "#{emoji} #{factor.ljust(18)} #{stats[:wins]}-#{stats[:losses]} (#{pct}%) - #{name}"
    end

    # O/U factors
    puts "\n📊 O/U FACTORS:"
    puts "-" * 40
    ou_factor_stats = Hash.new { |h, k| h[k] = { wins: 0, losses: 0 } }

    reports.each do |r|
      sd = r.structured_data || {}
      factors = sd["ou_factors"] || []
      result = sd["ou_result"]
      next unless result.present?

      factors.each do |f|
        if result == "win"
          ou_factor_stats[f][:wins] += 1
        else
          ou_factor_stats[f][:losses] += 1
        end
      end
    end

    ou_factor_stats.sort_by { |_, v| -(v[:wins] + v[:losses]) }.each do |factor, stats|
      total = stats[:wins] + stats[:losses]
      pct = total > 0 ? (stats[:wins].to_f / total * 100).round(1) : 0
      emoji = pct >= 55 ? "✅" : (pct >= 45 ? "➖" : "❌")
      name = PICK_FACTORS[factor] || factor
      puts "#{emoji} #{factor.ljust(18)} #{stats[:wins]}-#{stats[:losses]} (#{pct}%) - #{name}"
    end

    # Failure reasons
    puts "\n📊 FAILURE REASONS:"
    puts "-" * 40
    failure_stats = Hash.new(0)

    reports.each do |r|
      sd = r.structured_data || {}
      (sd["spread_failure"] || []).each { |f| failure_stats[f] += 1 }
      (sd["ou_failure"] || []).each { |f| failure_stats[f] += 1 }
    end

    failure_stats.sort_by { |_, v| -v }.each do |reason, count|
      name = FAILURE_REASONS[reason] || reason
      puts "  #{reason.ljust(18)} #{count}x - #{name}"
    end

    # Confidence calibration
    puts "\n📊 CONFIDENCE CALIBRATION:"
    puts "-" * 40
    (1..5).each do |conf|
      conf_reports = reports.select { |r| r.confidence == conf }
      next if conf_reports.empty?

      spread_wins = conf_reports.count { |r| r.structured_data&.dig("spread_result") == "win" }
      spread_total = conf_reports.count { |r| r.structured_data&.dig("spread_result").present? }
      ou_wins = conf_reports.count { |r| r.structured_data&.dig("ou_result") == "win" }
      ou_total = conf_reports.count { |r| r.structured_data&.dig("ou_result").present? }

      spread_pct = spread_total > 0 ? (spread_wins.to_f / spread_total * 100).round(1) : 0
      ou_pct = ou_total > 0 ? (ou_wins.to_f / ou_total * 100).round(1) : 0

      puts "  Confidence #{conf}/5: Spread #{spread_wins}-#{spread_total - spread_wins} (#{spread_pct}%), O/U #{ou_wins}-#{ou_total - ou_wins} (#{ou_pct}%)"
    end

    # Pick type breakdown
    puts "\n📊 PICK TYPE BREAKDOWN:"
    puts "-" * 40

    home_fav = reports.select { |r|
      sd = r.structured_data || {}
      sd["pick_type"] == "home_favorite"
    }
    away_fav = reports.select { |r|
      sd = r.structured_data || {}
      sd["pick_type"] == "away_favorite"
    }
    home_dog = reports.select { |r|
      sd = r.structured_data || {}
      sd["pick_type"] == "home_underdog"
    }
    away_dog = reports.select { |r|
      sd = r.structured_data || {}
      sd["pick_type"] == "away_underdog"
    }

    [
      ["Home Favorite", home_fav],
      ["Away Favorite", away_fav],
      ["Home Underdog", home_dog],
      ["Away Underdog", away_dog]
    ].each do |name, reps|
      next if reps.empty?
      wins = reps.count { |r| r.structured_data&.dig("spread_result") == "win" }
      total = reps.count { |r| r.structured_data&.dig("spread_result").present? }
      pct = total > 0 ? (wins.to_f / total * 100).round(1) : 0
      puts "  #{name.ljust(15)} #{wins}-#{total - wins} (#{pct}%)"
    end
  end

  desc "Show season summary"
  task summary: :environment do
    reports = Report.where.not(result: nil).includes(:game)

    puts "=" * 60
    puts "SEASON SUMMARY"
    puts "=" * 60

    spread_w = reports.count { |r| r.structured_data&.dig("spread_result") == "win" }
    spread_l = reports.count { |r| r.structured_data&.dig("spread_result") == "loss" }
    ou_w = reports.count { |r| r.structured_data&.dig("ou_result") == "win" }
    ou_l = reports.count { |r| r.structured_data&.dig("ou_result") == "loss" }

    spread_pct = (spread_w + spread_l) > 0 ? (spread_w.to_f / (spread_w + spread_l) * 100).round(1) : 0
    ou_pct = (ou_w + ou_l) > 0 ? (ou_w.to_f / (ou_w + ou_l) * 100).round(1) : 0
    total_pct = (spread_w + ou_w + spread_l + ou_l) > 0 ?
      ((spread_w + ou_w).to_f / (spread_w + ou_w + spread_l + ou_l) * 100).round(1) : 0

    puts "\nOVERALL RECORD:"
    puts "  Spread: #{spread_w}-#{spread_l} (#{spread_pct}%)"
    puts "  O/U:    #{ou_w}-#{ou_l} (#{ou_pct}%)"
    puts "  Total:  #{spread_w + ou_w}-#{spread_l + ou_l} (#{total_pct}%)"

    # ROI calculation (assuming -110 odds)
    spread_roi = spread_w * 100 - spread_l * 110
    ou_roi = ou_w * 100 - ou_l * 110
    puts "\nROI (assuming $100 units, -110 odds):"
    puts "  Spread: $#{spread_roi > 0 ? '+' : ''}#{spread_roi}"
    puts "  O/U:    $#{ou_roi > 0 ? '+' : ''}#{ou_roi}"
    puts "  Total:  $#{(spread_roi + ou_roi) > 0 ? '+' : ''}#{spread_roi + ou_roi}"

    # Recent form
    puts "\nLAST 7 DAYS:"
    recent = reports.select { |r| r.result_recorded_at && r.result_recorded_at > 7.days.ago }
    recent_spread_w = recent.count { |r| r.structured_data&.dig("spread_result") == "win" }
    recent_spread_l = recent.count { |r| r.structured_data&.dig("spread_result") == "loss" }
    recent_ou_w = recent.count { |r| r.structured_data&.dig("ou_result") == "win" }
    recent_ou_l = recent.count { |r| r.structured_data&.dig("ou_result") == "loss" }
    puts "  Spread: #{recent_spread_w}-#{recent_spread_l}"
    puts "  O/U:    #{recent_ou_w}-#{recent_ou_l}"
  end
end
