# Sports
basketball = Sport.find_or_create_by!(slug: "basketball") do |s|
  s.name = "Basketball"
  s.icon = "basketball"
  s.active = true
  s.position = 1
end

baseball = Sport.find_or_create_by!(slug: "baseball") do |s|
  s.name = "Baseball"
  s.icon = "baseball"
  s.active = true
  s.position = 2
end

soccer = Sport.find_or_create_by!(slug: "soccer") do |s|
  s.name = "Soccer"
  s.icon = "soccer"
  s.active = true
  s.position = 3
end

# Sample Games
game1 = Game.find_or_create_by!(external_id: "nba_20260115_atl_lal") do |g|
  g.sport = basketball
  g.home_team = "Los Angeles Lakers"
  g.away_team = "Atlanta Hawks"
  g.home_abbr = "LAL"
  g.away_abbr = "ATL"
  g.game_date = Time.current.beginning_of_day + 12.hours + 30.minutes
  g.venue = "Crypto.com Arena"
  g.status = "scheduled"
end

game2 = Game.find_or_create_by!(external_id: "nba_20260115_den_no") do |g|
  g.sport = basketball
  g.home_team = "New Orleans Pelicans"
  g.away_team = "Denver Nuggets"
  g.home_abbr = "NO"
  g.away_abbr = "DEN"
  g.game_date = Time.current.beginning_of_day + 11.hours
  g.venue = "Smoothie King Center"
  g.status = "scheduled"
end

# Sample Report
Report.find_or_create_by!(game: game1, pick: "ATL +2.0") do |r|
  r.title = "ATL @ LAL Analysis"
  r.confidence = "★★★☆☆"
  r.status = "published"
  r.published_at = Time.current
  r.content = <<~CONTENT
    ## 1. 오늘의 결론

    📌 추천: ATL +2.0
    💪 신뢰도: ★★★☆☆
    📝 한 줄: "ATS 엣지 없음, 부상 변수로 ATL 소폭 유리"

    ## 2. 핵심 지표

    | 항목 | 수치 | 판정 |
    |------|------|------|
    | ATS 커버율 | LAL 홈 49.4%, ATL 원정 49.4% | ➖ 엣지 없음 |
    | 상대전적 | H2H 1-2 (LAL 관점) | ✅ ATL 유리 |
    | 부상 영향 | LAL 핵심 2명 Q, Reaves OUT | ✅ ATL 유리 |

    ## 3. 분석

    레이커스의 부상 상황이 심각하다.

    - Austin Reaves OUT (4주): 3번째 득점 옵션 상실
    - Luka Doncic Questionable: 사타구니 부상
    - LeBron James Questionable: 노장 관리

    ATS 데이터만 보면 엣지가 없지만, 부상 변수와 H2H 우위로 ATL +2.0 소폭 추천.

    ## 4. 리스크

    ⚠️ 반대 요소:
    • ATL 대승 후 이완 경향
    • LAL 홈코트 어드밴티지

    🔍 경기 전 확인:
    • Doncic/LeBron 출전 여부
  CONTENT
end

# Sample Insights
Insight.find_or_create_by!(sport: basketball, title: "레이커스 부상 위기 분석") do |i|
  i.category = "team_analysis"
  i.tags = "LAL, 부상, 시즌분석"
  i.status = "published"
  i.published_at = Time.current - 2.hours
  i.content = <<~CONTENT
    레이커스가 부상 위기에 직면했다.

    현재 부상자 현황:
    • Austin Reaves: OUT (4주, 골반)
    • Luka Doncic: Questionable (사타구니)
    • LeBron James: Questionable (관리)
    • Jaxson Hayes: OUT (햄스트링)

    여러 분석가들은 레이커스의 현 상황을 우려하고 있다.
    벤치 득점력이 급격히 하락했으며, 주전 의존도가 높아졌다.

    향후 2주간 레이커스 언더독 베팅 시 주의가 필요하다.
  CONTENT
end

Insight.find_or_create_by!(sport: basketball, title: "NBA 주간 ATS 트렌드") do |i|
  i.category = "betting_edge"
  i.tags = "ATS, 트렌드, 주간분석"
  i.status = "published"
  i.published_at = Time.current - 5.hours
  i.content = <<~CONTENT
    이번 주 NBA ATS 주요 트렌드:

    1. 홈 언더독 강세
    - 홈 언더독 ATS: 58.3% (지난주)
    - 특히 +3.5 ~ +6.5 구간에서 커버율 높음

    2. 백투백 첫 경기 주의
    - B2B 첫 경기 페이버릿 커버율: 44.2%
    - 피로도보다 다음 경기 대비 경향

    3. 컨퍼런스 간 경기
    - 동부 vs 서부: 서부팀 ATS 52.1%
    - 홈/원정 무관하게 서부 소폭 유리
  CONTENT
end

puts "Seed data created successfully!"
puts "Sports: #{Sport.count}"
puts "Games: #{Game.count}"
puts "Reports: #{Report.count}"
puts "Insights: #{Insight.count}"
