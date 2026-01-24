# frozen_string_literal: true

# G9EngineService - Neo4j 기반 Edge Score 픽 엔진
#
# 백테스트 결과 (ML):
#   - Edge 85+: 100% (14/14)
#   - Edge 80-84: 80% (8/10)
#   - Edge 80+ 통합: 91.7% (22/24)
#
# 백테스트 결과 (Pickem Underdog):
#   - 0-0.5pt Away Underdog: 58.2% (2023-25 시즌)
#   - 0-1.5pt Away Underdog: 56.4%
#   - 플레이오프 Pickem: 71%
#
# 픽 타입:
#   - ML: Moneyline (승패)
#   - SPREAD: Against The Spread
#   - PICKEM: Pickem Underdog (특수 전략)
#   - TOTAL: Over/Under
#
# 사용법:
#   service = G9EngineService.new
#   picks = service.analyze_date('20260124')           # ML
#   picks = service.analyze_spread('20260124')         # Spread
#   picks = service.analyze_pickem('20260124')         # Pickem Underdog
#   picks = service.analyze_all('20260124')            # ML + Spread + Pickem + Total
#
class G9EngineService
  class EngineError < StandardError; end

  # Edge Score 임계값
  THRESHOLDS = {
    strong_bet: 85,
    bet: 80,
    caution: 70,
    lean: 60
  }.freeze

  # Spread 전용 임계값 (더 보수적)
  SPREAD_THRESHOLDS = {
    strong_bet: 80,
    bet: 75,
    caution: 65,
    lean: 55
  }.freeze

  # Total 전용 임계값
  TOTAL_THRESHOLDS = {
    strong_bet: 78,
    bet: 72,
    caution: 62,
    lean: 52
  }.freeze

  # Pickem Underdog 전략 설정
  # 백테스트: 0-0.5pt = 58.2%, 0-1.5pt = 56.4%
  PICKEM_CONFIG = {
    tight_spread: 0.5,      # 타이트 픽켐 (58.2% 승률)
    wide_spread: 1.5,       # 와이드 픽켐 (56.4% 승률)
    min_net_rtg_edge: 3.0,  # 최소 Net Rating 우위
    strong_net_rtg_edge: 8.0 # 강한 Net Rating 우위
  }.freeze

  # 위험 flow_state (Edge 65-80에서 37.5% 적중률)
  RISKY_FLOWS = %w[WARMING].freeze

  def initialize
    @client = Neo4jClient.new
  end

  # 특정 날짜의 경기 분석
  # @param date_str [String] 'YYYYMMDD' 형식
  # @return [Array<Hash>] 분석 결과 배열
  def analyze_date(date_str)
    result = @client.query(engine_query, { target_date: date_str })
    parse_results(result)
  rescue Neo4jClient::QueryError => e
    raise EngineError, "Neo4j query failed: #{e.message}"
  end

  # 오늘 경기 분석
  def analyze_today
    today = Date.current.strftime('%Y%m%d')
    analyze_date(today)
  end

  # === Spread Engine ===

  # Spread 분석 (ATS)
  # @param date_str [String] 'YYYYMMDD' 형식
  # @return [Array<Hash>] Spread 분석 결과
  def analyze_spread(date_str)
    result = @client.query(spread_engine_query, { target_date: date_str })
    parse_spread_results(result)
  rescue Neo4jClient::QueryError => e
    raise EngineError, "Spread query failed: #{e.message}"
  end

  # 오늘 Spread 분석
  def analyze_spread_today
    today = Date.current.strftime('%Y%m%d')
    analyze_spread(today)
  end

  # === Total Engine ===

  # Total 분석 (Over/Under)
  # @param date_str [String] 'YYYYMMDD' 형식
  # @return [Array<Hash>] Total 분석 결과
  def analyze_total(date_str)
    result = @client.query(total_engine_query, { target_date: date_str })
    parse_total_results(result)
  rescue Neo4jClient::QueryError => e
    raise EngineError, "Total query failed: #{e.message}"
  end

  # 오늘 Total 분석
  def analyze_total_today
    today = Date.current.strftime('%Y%m%d')
    analyze_total(today)
  end

  # === Pickem Underdog Engine ===

  # Pickem Underdog 분석 (0-1.5pt 어웨이 언더독)
  # 백테스트 결과: 58.2% (0-0.5pt), 56.4% (0-1.5pt)
  # @param date_str [String] 'YYYYMMDD' 형식
  # @return [Array<Hash>] Pickem 분석 결과
  def analyze_pickem(date_str)
    result = @client.query(pickem_engine_query, { target_date: date_str })
    parse_pickem_results(result)
  rescue Neo4jClient::QueryError => e
    raise EngineError, "Pickem query failed: #{e.message}"
  end

  # 오늘 Pickem 분석
  def analyze_pickem_today
    today = Date.current.strftime('%Y%m%d')
    analyze_pickem(today)
  end

  # 전체 분석 (ML + Spread + Pickem + Total)
  def analyze_all(date_str)
    {
      ml: analyze_date(date_str),
      spread: analyze_spread(date_str),
      pickem: analyze_pickem(date_str),
      total: analyze_total(date_str)
    }
  end

  # 분석 결과로 리포트 생성
  def generate_report(picks, date: Date.current)
    lines = []
    lines << header(date)
    lines << ""
    lines << summary_section(picks)
    lines << ""
    lines << picks_section(picks)
    lines << ""
    lines << footer
    lines.join("\n")
  end

  # 전체 파이프라인: 분석 + 리포트 생성 + 저장
  def run_daily(date: Date.current)
    date_str = date.strftime('%Y%m%d')
    picks = analyze_date(date_str)
    report = generate_report(picks, date: date)

    # 파일 저장
    report_dir = Rails.root.join('tmp', 'reports', 'g9')
    FileUtils.mkdir_p(report_dir)
    report_path = report_dir.join("#{date.strftime('%Y-%m-%d')}.md")
    File.write(report_path, report)

    { picks: picks, report: report, path: report_path }
  end

  private

  # === Total Engine Query ===

  # Total Edge Score 쿼리
  # 예상 토탈 = home_off_rtg + away_off_rtg (약 228-232 평균)
  def total_engine_query
    <<~CYPHER
      WITH $target_date AS target_date

      // 1. 경기 + 팀 매칭
      MATCH (g:Game)
      WHERE g.date = target_date
      MATCH (home:Team {abbr: g.home_team})
      MATCH (away:Team {abbr: g.away_team})

      // 2. 데이터 수집
      WITH g, home, away,
           coalesce(home.off_rtg, 114) AS h_off,
           coalesce(away.off_rtg, 114) AS a_off,
           coalesce(home.def_rtg, 114) AS h_def,
           coalesce(away.def_rtg, 114) AS a_def,
           coalesce(home.pace, 100) AS h_pace,
           coalesce(away.pace, 100) AS a_pace,
           coalesce(home.over_pct, 0.5) AS h_over_pct,
           coalesce(away.over_pct, 0.5) AS a_over_pct

      // 3. 예상 토탈 계산
      // 공식: (홈공격 + 원정공격) * 평균페이스 / 100 조정
      WITH g, home, away, h_off, a_off, h_def, a_def, h_pace, a_pace, h_over_pct, a_over_pct,
           (h_off + a_off) * ((h_pace + a_pace) / 200.0) AS expected_total,
           coalesce(g.total, 230) AS market_total

      // 4. Total Edge Score 계산
      WITH g, home, away, h_off, a_off, h_def, a_def, h_pace, a_pace,
           h_over_pct, a_over_pct, expected_total, market_total,
           expected_total - market_total AS total_diff,
           // 기본 50
           50 +
           // 예상 vs 마켓 차이 (Over/Under 방향)
           CASE
             WHEN expected_total - market_total > 10 THEN 15   // Strong Over
             WHEN expected_total - market_total > 5 THEN 10    // Over
             WHEN expected_total - market_total > 2 THEN 5     // Slight Over
             WHEN expected_total - market_total > -2 THEN 0    // Neutral
             WHEN expected_total - market_total > -5 THEN -5   // Slight Under
             WHEN expected_total - market_total > -10 THEN -10 // Under
             ELSE -15                                           // Strong Under
           END +
           // 공격력 조합 (양팀 고효율 → Over)
           CASE
             WHEN h_off > 118 AND a_off > 118 THEN 5  // 양팀 고효율
             WHEN h_off < 110 AND a_off < 110 THEN -5 // 양팀 저효율
             ELSE 0
           END +
           // 수비력 조합 (양팀 약수비 → Over)
           CASE
             WHEN h_def > 116 AND a_def > 116 THEN 5  // 양팀 약수비
             WHEN h_def < 108 AND a_def < 108 THEN -5 // 양팀 강수비
             ELSE 0
           END +
           // Over% 트렌드
           CASE
             WHEN h_over_pct > 0.55 AND a_over_pct > 0.55 THEN 3
             WHEN h_over_pct < 0.45 AND a_over_pct < 0.45 THEN -3
             ELSE 0
           END
           AS raw_total_edge

      // 5. 정규화 및 픽 결정
      WITH g, home, away, h_off, a_off, h_def, a_def,
           expected_total, market_total, total_diff, raw_total_edge,
           CASE WHEN raw_total_edge >= 50 THEN raw_total_edge
                ELSE 100 - raw_total_edge END AS total_edge,
           CASE WHEN raw_total_edge >= 50 THEN 'OVER' ELSE 'UNDER' END AS pick_side

      RETURN
        g.date AS date,
        away.abbr AS away,
        home.abbr AS home,
        round(total_edge, 1) AS total_edge_score,
        pick_side,
        round(expected_total, 1) AS expected_total,
        round(market_total, 1) AS market_total,
        round(total_diff, 1) AS total_diff,
        round(h_off, 1) AS home_off_rtg,
        round(a_off, 1) AS away_off_rtg,
        round(h_def, 1) AS home_def_rtg,
        round(a_def, 1) AS away_def_rtg,
        g.status AS status,
        g.home_score AS home_score,
        g.away_score AS away_score,
        g.total_result AS actual_result
      ORDER BY total_edge DESC
    CYPHER
  end

  # Total 결과 파싱
  def parse_total_results(raw_results)
    raw_results.map do |r|
      edge = r['total_edge_score'].to_f
      signal = determine_total_signal(edge, r['pick_side'])

      {
        date: r['date'],
        matchup: "#{r['away']} @ #{r['home']}",
        away: r['away'],
        home: r['home'],
        pick_type: 'TOTAL',
        total_edge_score: edge,
        pick_side: r['pick_side'],
        expected_total: r['expected_total'].to_f,
        market_total: r['market_total'].to_f,
        total_diff: r['total_diff'].to_f,
        home_off_rtg: r['home_off_rtg'].to_f,
        away_off_rtg: r['away_off_rtg'].to_f,
        home_def_rtg: r['home_def_rtg'].to_f,
        away_def_rtg: r['away_def_rtg'].to_f,
        status: r['status'],
        home_score: r['home_score'],
        away_score: r['away_score'],
        actual_result: r['actual_result'],
        signal: signal,
        actionable: edge >= TOTAL_THRESHOLDS[:bet]
      }
    end
  end

  # Total Signal 결정
  def determine_total_signal(edge, side)
    prefix = side == 'OVER' ? '📈' : '📉'

    case edge
    when TOTAL_THRESHOLDS[:strong_bet]..Float::INFINITY
      "#{prefix} STRONG #{side}"
    when TOTAL_THRESHOLDS[:bet]...TOTAL_THRESHOLDS[:strong_bet]
      "#{prefix} #{side} BET"
    when TOTAL_THRESHOLDS[:caution]...TOTAL_THRESHOLDS[:bet]
      "#{prefix} #{side} LEAN"
    when TOTAL_THRESHOLDS[:lean]...TOTAL_THRESHOLDS[:caution]
      "➖ #{side} WATCH"
    else
      '🚫 TOTAL PASS'
    end
  end

  # === Pickem Underdog Engine Query ===

  # Pickem Underdog 쿼리
  # 조건: 스프레드 -1.5 ~ 0 (홈 1.5점 이내 페이보릿) + 어웨이팀 Net Rating 우위
  # 백테스트 결과:
  #   - TIGHT (0-0.5pt): 70.0% (21/30)
  #   - WIDE (1.0-1.5pt): 59.6% (34/57)
  #   - 전체: 63.2% (55/87)
  def pickem_engine_query
    <<~CYPHER
      WITH $target_date AS target_date

      // 1. Pickem 경기 필터 (홈이 1.5점 이내 페이보릿)
      // 스프레드 규칙: 음수 = 홈 페이보릿 (예: -1.5 = 홈이 1.5점 유리)
      MATCH (g:Game)
      WHERE g.date = target_date
        AND g.spread IS NOT NULL
        AND g.spread >= -1.5 AND g.spread <= 0

      // 2. 팀 매칭
      MATCH (home:Team {abbr: g.home_team})
      MATCH (away:Team {abbr: g.away_team})

      // 3. Net Rating 비교
      WITH g, home, away,
           coalesce(away.net_rtg, 0) AS a_net,
           coalesce(home.net_rtg, 0) AS h_net,
           coalesce(away.win_pct, 0.5) AS a_pct,
           coalesce(home.win_pct, 0.5) AS h_pct

      // 4. 어웨이팀이 Net Rating 우위인 경우만 (핵심 조건)
      WHERE a_net > h_net

      // 5. Pickem Edge Score 계산
      // 어웨이 언더독 스프레드 = -spread (예: spread=-1.5 → 어웨이 +1.5)
      WITH g, home, away, a_net, h_net, a_pct, h_pct,
           a_net - h_net AS net_rtg_edge,
           -g.spread AS away_spread,  // 어웨이 관점 스프레드
           // 기본 점수 60 (조건 충족 시)
           60 +
           // Net Rating 우위 보너스 (백테스트: 5-8pt = 66.7%)
           CASE
             WHEN a_net - h_net >= 8 THEN 15   // 강한 우위
             WHEN a_net - h_net >= 5 THEN 20   // 최적 구간 (66.7%)
             WHEN a_net - h_net >= 3 THEN 10   // 중간 우위
             ELSE 15                            // 약한 우위도 64.1%
           END +
           // 타이트 스프레드 보너스 (백테스트: TIGHT = 70%)
           CASE
             WHEN g.spread >= -0.5 THEN 15     // TIGHT (70%)
             WHEN g.spread >= -1.0 THEN 5      // MEDIUM
             ELSE 0                             // WIDE (59.6%)
           END +
           // 승률 우위 보너스
           CASE
             WHEN a_pct - h_pct >= 0.15 THEN 5  // 15%+ 승률 우위
             WHEN a_pct - h_pct >= 0.10 THEN 3  // 10%+ 승률 우위
             ELSE 0
           END
           AS pickem_edge

      RETURN
        g.date AS date,
        g.date_et AS date_et,
        g.time_et AS time_et,
        away.abbr AS away,
        home.abbr AS home,
        -g.spread AS spread,  // 어웨이 관점으로 변환 (+1.5 형태)
        round(pickem_edge, 1) AS pickem_edge_score,
        away.abbr AS recommended,
        'AWAY' AS pick_side,
        round(a_net, 1) AS away_net_rtg,
        round(h_net, 1) AS home_net_rtg,
        round(net_rtg_edge, 1) AS net_rtg_edge,
        round(a_pct * 100) AS away_win_pct,
        round(h_pct * 100) AS home_win_pct,
        g.total AS total_line,
        g.status AS status,
        g.home_score AS home_score,
        g.away_score AS away_score,
        g.spread_result AS actual_result,
        CASE
          WHEN g.spread >= -0.5 THEN 'TIGHT'   // 70% 커버율
          WHEN g.spread >= -1.0 THEN 'MEDIUM'
          ELSE 'WIDE'                           // 59.6% 커버율
        END AS pickem_type
      ORDER BY pickem_edge DESC
    CYPHER
  end

  # Pickem 결과 파싱
  def parse_pickem_results(raw_results)
    raw_results.map do |r|
      edge = r['pickem_edge_score'].to_f
      signal = determine_pickem_signal(edge, r['pickem_type'])

      {
        date: r['date'],
        date_et: r['date_et'],
        time_et: r['time_et'],
        matchup: "#{r['away']} @ #{r['home']}",
        away: r['away'],
        home: r['home'],
        pick_type: 'PICKEM',
        spread: r['spread'].to_f,
        pickem_edge_score: edge,
        recommended: r['recommended'],
        pick_side: r['pick_side'],
        away_net_rtg: r['away_net_rtg'].to_f,
        home_net_rtg: r['home_net_rtg'].to_f,
        net_rtg_edge: r['net_rtg_edge'].to_f,
        away_win_pct: r['away_win_pct'].to_i,
        home_win_pct: r['home_win_pct'].to_i,
        total_line: r['total_line'],
        status: r['status'],
        home_score: r['home_score'],
        away_score: r['away_score'],
        actual_result: r['actual_result'],
        pickem_type: r['pickem_type'],
        signal: signal,
        actionable: edge >= 75  # Pickem은 75+ 액션
      }
    end
  end

  # Pickem Signal 결정
  def determine_pickem_signal(edge, pickem_type)
    type_emoji = case pickem_type
                 when 'TIGHT' then '🎯'  # 타이트 (58.2%)
                 when 'MEDIUM' then '📍' # 중간
                 else '📌'               # 와이드 (56.4%)
                 end

    case edge
    when 90..Float::INFINITY
      "#{type_emoji} ELITE PICKEM"
    when 85...90
      "#{type_emoji} STRONG PICKEM"
    when 80...85
      "#{type_emoji} PICKEM BET"
    when 75...80
      "#{type_emoji} PICKEM LEAN"
    when 70...75
      "➖ PICKEM WATCH"
    else
      '🚫 PICKEM PASS'
    end
  end

  # === Spread Engine Query ===

  # Spread Edge Score 쿼리 v2.0
  # 핵심: 예상 마진 vs 시장 라인 비교로 실제 베팅 가치 판단
  # 예상 마진 = (home_net_rtg - away_net_rtg) + 3.5 (홈 어드밴티지)
  # 라인 차이 = expected_margin - market_spread (양수 = 홈 커버 유리)
  def spread_engine_query
    <<~CYPHER
      WITH $target_date AS target_date

      // 1. 경기 + 팀 매칭
      MATCH (g:Game)
      WHERE g.date = target_date
      MATCH (home:Team {abbr: g.home_team})
      MATCH (away:Team {abbr: g.away_team})

      // 2. TeamRegime 조인
      OPTIONAL MATCH (hr:TeamRegime) WHERE hr.team CONTAINS home.name
      OPTIONAL MATCH (ar:TeamRegime) WHERE ar.team CONTAINS away.name

      // 3. 데이터 수집
      WITH g, home, away,
           coalesce(home.net_rtg, 0) AS h_net,
           coalesce(away.net_rtg, 0) AS a_net,
           coalesce(home.ats_home_pct, 0.5) AS h_ats_home,
           coalesce(away.ats_away_pct, 0.5) AS a_ats_away,
           coalesce(hr.flow_state, 'NEUTRAL') AS h_flow,
           coalesce(ar.flow_state, 'NEUTRAL') AS a_flow,
           coalesce(g.spread, 0) AS market_spread

      // 4. 예상 마진 계산 (Net Rating 차이 + 홈 어드밴티지)
      // 라인 차이 = 예상 마진 - 시장 스프레드
      // 양수 = 홈이 시장 예상보다 강함 → 홈 커버 유리
      // 음수 = 어웨이가 시장 예상보다 강함 → 어웨이 커버 유리
      WITH g, home, away, h_net, a_net, h_ats_home, a_ats_away, h_flow, a_flow, market_spread,
           (h_net - a_net) + 3.5 AS expected_margin,
           ((h_net - a_net) + 3.5) - market_spread AS line_diff

      // 5. Spread Edge Score 계산 (라인 대비 기대마진 기반)
      WITH g, home, away, h_net, a_net, h_ats_home, a_ats_away, h_flow, a_flow,
           market_spread, expected_margin, line_diff,
           // 기본 50
           50 +
           // 라인 차이 기반 조정 (핵심 로직)
           // 양수 = 홈 커버 유리, 음수 = 어웨이 커버 유리
           CASE
             WHEN line_diff > 8 THEN 20      // 홈 8점+ 저평가
             WHEN line_diff > 5 THEN 15      // 홈 5-8점 저평가
             WHEN line_diff > 3 THEN 10      // 홈 3-5점 저평가
             WHEN line_diff > 1 THEN 5       // 홈 1-3점 저평가
             WHEN line_diff > -1 THEN 0      // 1점 이내 = 정당 라인
             WHEN line_diff > -3 THEN -5     // 어웨이 1-3점 저평가
             WHEN line_diff > -5 THEN -10    // 어웨이 3-5점 저평가
             WHEN line_diff > -8 THEN -15    // 어웨이 5-8점 저평가
             ELSE -20                         // 어웨이 8점+ 저평가
           END +
           // ATS 트렌드 보너스 (보조)
           CASE WHEN h_ats_home > 0.55 THEN 3
                WHEN h_ats_home < 0.45 THEN -3
                ELSE 0 END +
           CASE WHEN a_ats_away > 0.55 THEN -3
                WHEN a_ats_away < 0.45 THEN 3
                ELSE 0 END +
           // Flow 조정 (보조)
           CASE
             WHEN h_flow IN ['HOT_STREAK', 'STRONG_UP'] THEN 2
             WHEN h_flow IN ['COLD_STREAK', 'SLUMP'] THEN -2
             ELSE 0
           END +
           CASE
             WHEN a_flow IN ['HOT_STREAK', 'STRONG_UP'] THEN -2
             WHEN a_flow IN ['COLD_STREAK', 'SLUMP'] THEN 2
             ELSE 0
           END
           AS raw_spread_edge

      // 6. 정규화 및 픽 결정
      WITH g, home, away, h_net, a_net, h_ats_home, a_ats_away, h_flow, a_flow,
           market_spread, expected_margin, line_diff, raw_spread_edge,
           CASE WHEN raw_spread_edge >= 50 THEN raw_spread_edge
                ELSE 100 - raw_spread_edge END AS spread_edge,
           CASE WHEN raw_spread_edge >= 50 THEN 'HOME' ELSE 'AWAY' END AS pick_side,
           CASE WHEN raw_spread_edge >= 50 THEN home.abbr ELSE away.abbr END AS pick_team

      RETURN
        g.date AS date,
        away.abbr AS away,
        home.abbr AS home,
        round(spread_edge, 1) AS spread_edge_score,
        pick_side,
        pick_team AS recommended,
        round(expected_margin, 1) AS expected_margin,
        round(market_spread, 1) AS market_spread,
        round(line_diff, 1) AS line_diff,
        round(h_net, 1) AS home_net_rtg,
        round(a_net, 1) AS away_net_rtg,
        round(h_ats_home * 100, 1) AS home_ats_pct,
        round(a_ats_away * 100, 1) AS away_ats_pct,
        h_flow AS home_flow,
        a_flow AS away_flow,
        g.status AS status,
        g.home_score AS home_score,
        g.away_score AS away_score
      ORDER BY spread_edge DESC
    CYPHER
  end

  # Spread 결과 파싱
  def parse_spread_results(raw_results)
    raw_results.map do |r|
      edge = r['spread_edge_score'].to_f
      line_diff = r['line_diff'].to_f
      signal = determine_spread_signal(edge, line_diff)

      {
        date: r['date'],
        matchup: "#{r['away']} @ #{r['home']}",
        away: r['away'],
        home: r['home'],
        pick_type: 'SPREAD',
        spread_edge_score: edge,
        recommended: r['recommended'],
        pick_side: r['pick_side'],
        expected_margin: r['expected_margin'].to_f,
        market_spread: r['market_spread'].to_f,
        line_diff: line_diff,
        home_net_rtg: r['home_net_rtg'].to_f,
        away_net_rtg: r['away_net_rtg'].to_f,
        home_ats_pct: r['home_ats_pct'].to_f,
        away_ats_pct: r['away_ats_pct'].to_f,
        home_flow: r['home_flow'],
        away_flow: r['away_flow'],
        status: r['status'],
        home_score: r['home_score'],
        away_score: r['away_score'],
        signal: signal,
        actionable: edge >= SPREAD_THRESHOLDS[:bet]
      }
    end
  end

  # Spread Signal 결정
  # line_diff: 예상 마진 - 시장 스프레드 (양수=홈 저평가, 음수=어웨이 저평가)
  def determine_spread_signal(edge, line_diff = 0)
    value_label = if line_diff.abs >= 5
                    " (#{line_diff > 0 ? '+' : ''}#{line_diff.round(1)}pt)"
                  else
                    ""
                  end

    case edge
    when SPREAD_THRESHOLDS[:strong_bet]..Float::INFINITY
      "💎 STRONG SPREAD#{value_label}"
    when SPREAD_THRESHOLDS[:bet]...SPREAD_THRESHOLDS[:strong_bet]
      "💎 SPREAD BET#{value_label}"
    when SPREAD_THRESHOLDS[:caution]...SPREAD_THRESHOLDS[:bet]
      '⚠️ SPREAD LEAN'
    when SPREAD_THRESHOLDS[:lean]...SPREAD_THRESHOLDS[:caution]
      '➖ SPREAD WATCH'
    else
      '🚫 SPREAD PASS'
    end
  end

  # === ML Engine Query ===

  # G9 Engine v2.3 Cypher 쿼리
  def engine_query
    <<~CYPHER
      WITH $target_date AS target_date

      // 1. 경기 + 팀 매칭
      MATCH (g:Game)
      WHERE g.date = target_date
      MATCH (home:Team {abbr: g.home_team})
      MATCH (away:Team {abbr: g.away_team})

      // 2. TeamRegime 조인
      OPTIONAL MATCH (hr:TeamRegime) WHERE hr.team CONTAINS home.name
      OPTIONAL MATCH (ar:TeamRegime) WHERE ar.team CONTAINS away.name

      // 3. 데이터 수집
      WITH g, home, away,
           coalesce(home.win_pct, 0.5) AS h_pct,
           coalesce(away.win_pct, 0.5) AS a_pct,
           coalesce(home.net_rtg, 0) AS h_net,
           coalesce(away.net_rtg, 0) AS a_net,
           coalesce(hr.flow_state, 'NEUTRAL') AS h_flow,
           coalesce(ar.flow_state, 'NEUTRAL') AS a_flow

      // 4. Edge Score 계산
      WITH g, home, away, h_pct, a_pct, h_net, a_net, h_flow, a_flow,
           50 +
           (h_pct - a_pct) * 30 +
           CASE
             WHEN abs(h_net - a_net) >= 10 THEN
               CASE WHEN h_net > a_net THEN 20 ELSE -20 END
             ELSE (h_net - a_net) * 2
           END +
           5 AS raw_edge

      // 5. 정규화
      WITH g, home, away, h_pct, a_pct, h_net, a_net, h_flow, a_flow, raw_edge,
           CASE WHEN raw_edge >= 50 THEN raw_edge ELSE 100 - raw_edge END AS edge,
           CASE WHEN raw_edge >= 50 THEN home.abbr ELSE away.abbr END AS pick,
           CASE WHEN raw_edge >= 50 THEN 'HOME' ELSE 'AWAY' END AS side,
           CASE WHEN raw_edge >= 50 THEN h_flow ELSE a_flow END AS fav_flow

      // 6. Signal 결정
      WITH g, home, away, edge, pick, side, fav_flow, h_pct, a_pct, h_net, a_net,
           CASE WHEN edge >= 65 AND edge < 80 AND fav_flow IN ['WARMING']
                THEN true ELSE false END AS is_risky

      RETURN
        g.date AS date,
        away.abbr AS away,
        home.abbr AS home,
        round(edge, 1) AS edge_score,
        pick AS recommended,
        side,
        fav_flow AS flow,
        is_risky AS risky,
        round(h_pct * 100) AS home_win_pct,
        round(a_pct * 100) AS away_win_pct,
        round(h_net, 1) AS home_net_rtg,
        round(a_net, 1) AS away_net_rtg,
        g.status AS status,
        g.home_score AS home_score,
        g.away_score AS away_score
      ORDER BY edge DESC
    CYPHER
  end

  # 쿼리 결과 파싱
  def parse_results(raw_results)
    raw_results.map do |r|
      edge = r['edge_score'].to_f
      signal = determine_signal(edge, r['risky'])

      {
        date: r['date'],
        matchup: "#{r['away']} @ #{r['home']}",
        away: r['away'],
        home: r['home'],
        edge_score: edge,
        recommended: r['recommended'],
        side: r['side'],
        flow: r['flow'],
        risky: r['risky'],
        signal: signal,
        home_win_pct: r['home_win_pct'].to_i,
        away_win_pct: r['away_win_pct'].to_i,
        home_net_rtg: r['home_net_rtg'].to_f,
        away_net_rtg: r['away_net_rtg'].to_f,
        status: r['status'],
        home_score: r['home_score'],
        away_score: r['away_score'],
        actionable: edge >= THRESHOLDS[:bet] && !r['risky']
      }
    end
  end

  # Signal 결정
  def determine_signal(edge, risky)
    return '🚨 RISKY' if risky && edge >= 65 && edge < 80

    case edge
    when THRESHOLDS[:strong_bet]..Float::INFINITY
      '💎 STRONG BET'
    when THRESHOLDS[:bet]...THRESHOLDS[:strong_bet]
      '💎 BET'
    when THRESHOLDS[:caution]...THRESHOLDS[:bet]
      '⚠️ CAUTION'
    when THRESHOLDS[:lean]...THRESHOLDS[:caution]
      '➖ LEAN'
    else
      '🚫 PASS'
    end
  end

  # 리포트 헤더
  def header(date)
    <<~HEADER.strip
      ======================================================================
      🏀 G9 Engine v2.3 - Daily Analysis Report
      📅 #{date.strftime('%Y-%m-%d')} (KST)
      ======================================================================

      ## 📊 백테스트 검증 성과
      | 티어 | Edge 범위 | 적중률 | Action |
      |------|-----------|--------|--------|
      | 💎 STRONG | 85+ | 100% | 강승부 |
      | 💎 BET | 80-84 | 80% | 베팅 |
      | ⚠️ CAUTION | 70-79 | 61% | 주의 |
      | ➖ LEAN | 60-69 | 68% | 관망 |
      | 🚫 PASS | <60 | 54% | 패스 |
    HEADER
  end

  # 요약 섹션
  def summary_section(picks)
    actionable = picks.select { |p| p[:actionable] }
    strong = picks.count { |p| p[:edge_score] >= THRESHOLDS[:strong_bet] && !p[:risky] }
    bet = picks.count { |p| p[:edge_score] >= THRESHOLDS[:bet] && p[:edge_score] < THRESHOLDS[:strong_bet] && !p[:risky] }
    risky = picks.count { |p| p[:risky] }

    lines = []
    lines << "## 🎯 오늘의 요약"
    lines << ""
    lines << "- 총 경기: #{picks.count}개"
    lines << "- 💎 STRONG BET (85+): #{strong}개"
    lines << "- 💎 BET (80-84): #{bet}개"
    lines << "- 🚨 RISKY (WARMING): #{risky}개"
    lines << ""

    if actionable.any?
      lines << "### 🏆 액션 가능 픽 (Edge 80+)"
      lines << ""
      actionable.each do |p|
        lines << "- **#{p[:matchup]}**: #{p[:recommended]} (Edge #{p[:edge_score]}) #{p[:signal]}"
      end
    else
      lines << "### ⚠️ 오늘은 Edge 80+ 경기 없음 - PASS 권장"
    end

    lines.join("\n")
  end

  # 경기별 분석 섹션
  def picks_section(picks)
    lines = []
    lines << "## 🏀 경기별 분석"
    lines << ""

    picks.each do |p|
      lines << "----------------------------------------------------------------------"
      lines << "### #{p[:matchup]}"
      lines << ""
      lines << "| 항목 | 값 |"
      lines << "|------|-----|"
      lines << "| Edge Score | **#{p[:edge_score]}** |"
      lines << "| 추천 | #{p[:recommended]} (#{p[:side]}) |"
      lines << "| Signal | #{p[:signal]} |"
      lines << "| Flow State | #{p[:flow]} |"
      lines << "| Home Win% | #{p[:home_win_pct]}% |"
      lines << "| Away Win% | #{p[:away_win_pct]}% |"
      lines << "| Home Net RTG | #{p[:home_net_rtg]} |"
      lines << "| Away Net RTG | #{p[:away_net_rtg]} |"

      if p[:status] == 'Final' && p[:home_score] && p[:away_score]
        winner = p[:home_score] > p[:away_score] ? p[:home] : p[:away]
        result = p[:recommended] == winner ? '✅ HIT' : '❌ MISS'
        lines << "| 결과 | #{p[:home_score]}-#{p[:away_score]} → #{result} |"
      end

      lines << ""

      # Action 가이드
      if p[:actionable]
        lines << "**🏆 ACTION: #{p[:recommended]} 베팅 권장**"
      elsif p[:risky]
        lines << "**⚠️ RISKY: WARMING 상태 - 베팅 회피 권장**"
      elsif p[:edge_score] >= THRESHOLDS[:caution]
        lines << "**⚠️ CAUTION: 관망 권장**"
      else
        lines << "**🚫 PASS: Edge 부족**"
      end
      lines << ""
    end

    lines.join("\n")
  end

  # 푸터
  def footer
    <<~FOOTER.strip
      ======================================================================
      ⚠️ G9 Engine v2.3 - 백테스트 기반 분석 시스템
      📊 데이터: Neo4j (Team Stats, TeamRegime, Game)
      🎯 철학: "We sell Certainty, not Lottery."
      ======================================================================
    FOOTER
  end
end
