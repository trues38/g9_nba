# frozen_string_literal: true

# RALPH System - Recursive Autonomous Learning & Prediction Helper
#
# 주간 자동화 사이클:
# 1. 완료된 경기 결과 평가
# 2. 분석가별 정확도 재계산 (rolling 8주)
# 3. 가중치 자동 조정
#
# 실행: 매주 월요일 15:00 KST (06:00 UTC)
#
namespace :ralph do
  desc 'RALPH 전체 사이클 실행 (평가 → 계산 → 조정)'
  task cycle: :environment do
    puts "=" * 60
    puts "🤖 RALPH System - Weekly Cycle"
    puts "   Started at: #{Time.current.in_time_zone('Asia/Seoul').strftime('%Y-%m-%d %H:%M KST')}"
    puts "=" * 60

    Rake::Task['ralph:evaluate'].invoke
    Rake::Task['ralph:calculate'].invoke
    Rake::Task['ralph:adjust'].invoke

    puts "\n✅ RALPH cycle completed!"
  end

  desc '완료된 경기 결과 평가'
  task evaluate: :environment do
    puts "\n📊 Step 1: Evaluating completed games..."

    # Find reports with results but unevaluated picks
    reports = Report.joins(:analyst_picks)
                    .where.not(result: [nil, 'pending'])
                    .where(analyst_picks: { correct: nil })
                    .distinct

    evaluated_count = 0
    reports.find_each do |report|
      AnalystPick.evaluate_for_report(report)
      evaluated_count += 1
      print '.'
    end

    puts "\n   ✓ Evaluated #{evaluated_count} reports"
  end

  desc '분석가별 정확도 계산 (rolling 8주)'
  task calculate: :environment do
    puts "\n📈 Step 2: Calculating analyst accuracy (rolling 8 weeks)..."

    # Rolling 8-week window
    end_date = Date.current
    start_date = end_date - 8.weeks

    accuracy_results = AnalystPick.accuracy_all(
      start_date: start_date,
      end_date: end_date
    )

    puts "\n   Analyst Performance (#{start_date} ~ #{end_date}):"
    puts "   " + "-" * 50

    accuracy_results.each do |analyst, data|
      pct = (data[:accuracy] * 100).round(1)
      bar = '█' * (pct / 5).to_i + '░' * (20 - (pct / 5).to_i)
      puts "   #{analyst.ljust(12)} #{data[:correct]}/#{data[:total]} (#{pct}%) #{bar}"
    end

    # Store in instance variable for adjust task
    @accuracy_results = accuracy_results
  end

  desc '가중치 자동 조정'
  task adjust: :environment do
    puts "\n⚖️  Step 3: Adjusting analyst weights..."

    # Recalculate if not already done
    unless @accuracy_results
      end_date = Date.current
      start_date = end_date - 8.weeks
      @accuracy_results = AnalystPick.accuracy_all(
        start_date: start_date,
        end_date: end_date
      )
    end

    adjustments = []

    @accuracy_results.each do |analyst, data|
      accuracy = data[:accuracy]
      sample_size = data[:total]

      # Skip if insufficient sample size
      if sample_size < 10
        puts "   #{analyst}: Skipped (sample size #{sample_size} < 10)"
        next
      end

      aw = AnalystWeight.find_or_initialize_by(analyst_name: analyst)
      old_accuracy = aw.accuracy
      old_weight = aw.weight

      # Update accuracy
      aw.accuracy = accuracy
      aw.sample_size = sample_size
      aw.last_backtest_date = Date.current

      # Calculate new weight based on accuracy
      new_weight = case accuracy
                   when 0.60.. then 1.0
                   when 0.55..0.60 then 0.7
                   when 0.50..0.55 then 0.3
                   when 0.45..0.50 then -0.3
                   else -0.5
                   end

      # Determine signal type
      new_signal_type = case new_weight
                        when 0.8.. then 'main'
                        when 0.5..0.8 then 'secondary'
                        when -0.5..0.5 then 'neutral'
                        else 'reverse'
                        end

      aw.weight = new_weight
      aw.signal_type = new_signal_type
      aw.notes = "RALPH auto-adjusted: #{Date.current}"
      aw.save!

      # Track changes
      weight_change = old_weight ? (new_weight - old_weight).round(2) : new_weight
      adjustments << {
        analyst: analyst,
        accuracy: accuracy,
        old_weight: old_weight,
        new_weight: new_weight,
        change: weight_change
      }
    end

    puts "\n   Weight Adjustments:"
    puts "   " + "-" * 50

    adjustments.each do |adj|
      change_str = adj[:old_weight] ? "#{adj[:old_weight]} → #{adj[:new_weight]}" : "NEW: #{adj[:new_weight]}"
      direction = adj[:change] > 0 ? '↑' : (adj[:change] < 0 ? '↓' : '→')
      puts "   #{adj[:analyst].ljust(12)} #{change_str} #{direction} (acc: #{(adj[:accuracy] * 100).round(1)}%)"
    end

    puts "\n   ✓ Updated #{adjustments.length} analyst weights"
  end

  desc '현재 분석가 가중치 상태 확인'
  task status: :environment do
    puts "\n📋 Current Analyst Weights:"
    puts "-" * 60

    AnalystWeight.order(weight: :desc).each do |aw|
      signal_emoji = case aw.signal_type
                     when 'main' then '⭐'
                     when 'secondary' then '📊'
                     when 'reverse' then '🔄'
                     else '📌'
                     end

      puts "#{signal_emoji} #{aw.analyst_name.ljust(12)} " \
           "Weight: #{format('%+.1f', aw.weight || 0).rjust(4)} | " \
           "Accuracy: #{((aw.accuracy || 0) * 100).round(1)}% | " \
           "Samples: #{aw.sample_size || 0} | " \
           "Type: #{aw.signal_type}"
    end

    puts "-" * 60
    puts "Last updated: #{AnalystWeight.maximum(:last_backtest_date) || 'Never'}"
  end

  desc '특정 기간 분석가 성과 리포트'
  task :report, [:weeks] => :environment do |_, args|
    weeks = (args[:weeks] || 8).to_i
    end_date = Date.current
    start_date = end_date - weeks.weeks

    puts "\n📊 Analyst Performance Report"
    puts "   Period: #{start_date} ~ #{end_date} (#{weeks} weeks)"
    puts "=" * 60

    results = AnalystPick.accuracy_all(start_date: start_date, end_date: end_date)

    if results.empty?
      puts "   No data available for this period."
      return
    end

    # Sort by accuracy
    sorted = results.sort_by { |_, v| -v[:accuracy] }

    puts "\n   Ranking:"
    sorted.each_with_index do |(analyst, data), idx|
      pct = (data[:accuracy] * 100).round(1)
      medal = case idx
              when 0 then '🥇'
              when 1 then '🥈'
              when 2 then '🥉'
              else '  '
              end
      puts "   #{medal} #{(idx + 1).to_s.rjust(2)}. #{analyst.ljust(12)} #{data[:correct]}/#{data[:total]} (#{pct}%)"
    end

    # Best combination analysis
    puts "\n   Optimal Combinations:"

    # CONTRARIAN + anti-SHARP
    contrarian_data = results['CONTRARIAN']
    sharp_data = results['SHARP']

    if contrarian_data && sharp_data
      # When CONTRARIAN and SHARP disagree, CONTRARIAN wins
      puts "   • CONTRARIAN + anti-SHARP: Theoretical advantage when signals diverge"
    end

    puts "=" * 60
  end
end
