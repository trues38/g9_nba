# Gate9 Sports

NBA 경기 일정, 오즈, 부상, 라인업 정보를 제공하는 **유료 스포츠 분석 서비스**.

## 서비스 개요

- **타겟**: 스포츠 베팅/분석에 관심있는 유료 구독자
- **핵심 가치**: B2B/3in4 스케줄 엣지 + 오즈 + 부상/라인업 통합 정보
- **리포트 생성**: Claude + GPT + 수동 편집 혼합 (향후 자동화 전환 예정)
- **데이터 파이프라인**: 자체 GraphQL 서버에서 수집 → 가공 → 리포트 생성
- **도메인**: 미정 (현재 IP 접속: 86.48.2.202)

## Tech Stack

- **Framework**: Rails 8.1.2
- **Frontend**: Hotwire (Turbo + Stimulus), Tailwind CSS
- **Database**: SQLite (production 포함)
- **Deployment**: Kamal → Contabo VPS (86.48.2.202)
- **Registry**: GitHub Container Registry (ghcr.io/trues38/gate9_sports)

## 주요 기능

### 1. 스케줄 (메인)
- 날짜별 경기 목록
- 시간대 표시 (한국어=KST, 영어=ET)
- 게임 상태 (upcoming/live/finished) 자동 판단
- B2B/3in4 스케줄 엣지 표시
- 스프레드/오버언더 표시
- 부상자/라인업 (펼쳐보기)

### 2. 리포트
- 경기별 분석 리포트
- 관리자가 작성 → publish

### 3. 인사이트
- 일반 분석 글

## 데이터 소스

| 데이터 | 소스 | Rake Task |
|--------|------|-----------|
| 시즌 일정 | NBA API | `nba:import_schedule` |
| 오즈 (스프레드/토탈) | ESPN API | `nba:fetch_odds` |
| 부상자 | ESPN API | `nba:fetch_injuries` |
| 라인업 | BasketballMonster 스크래핑 | `nba:fetch_lineups` |
| B2B/3in4 | 자체 계산 | `nba:calculate_edge` |

### 데이터 갱신 (Cron)
```bash
# 서버에서 매일 실행
docker exec gate9_sports-web bin/rails nba:fetch_all
```

## 프로젝트 구조

```
app/
├── controllers/
│   ├── schedule_controller.rb    # 메인 스케줄
│   ├── reports_controller.rb
│   ├── insights_controller.rb
│   └── admin/                    # 관리자
├── models/
│   ├── sport.rb                  # 종목 (basketball 등)
│   ├── game.rb                   # 경기
│   ├── report.rb                 # 분석 리포트
│   └── insight.rb                # 인사이트
├── helpers/
│   └── application_helper.rb     # game_status, injuries, lineups
├── views/
│   └── schedule/index.html.erb   # 메인 화면
└── javascript/controllers/
    ├── toggle_controller.js      # 펼치기/접기
    └── auto_refresh_controller.js # 경기시간 맞춰 자동 새로고침

lib/tasks/
└── nba.rake                      # 데이터 fetching tasks

tmp/
├── injuries.json                 # 부상자 캐시
└── lineups.json                  # 라인업 캐시
```

## DB 스키마 (주요)

### games
- `home_team`, `away_team`, `home_abbr`, `away_abbr`
- `game_date` (UTC 저장, 표시시 timezone 변환)
- `home_spread`, `away_spread`, `total_line` (오즈)
- `home_edge`, `away_edge` (B2B/3in4 등)
- `venue`, `status`

### reports
- `game_id`, `title`, `content`, `pick`, `confidence`
- `status` (draft/published), `published_at`

## 로컬 개발

```bash
# 서버 시작
bin/rails server

# 데이터 갱신
bin/rails nba:fetch_all

# 콘솔
bin/rails console
```

## 배포

```bash
# GitHub token 설정 필요
export GITHUB_TOKEN=$(gh auth token)

# 배포
kamal deploy
```

### 서버 접속
- **URL**: http://86.48.2.202/basketball/schedule
- **Admin**: http://86.48.2.202/admin/reports?token=gate9_admin_x7k9m2p5

## URLs

- 스케줄: `/:sport/schedule` (예: /basketball/schedule)
- 리포트 목록: `/:sport/reports`
- 리포트 상세: `/:sport/reports/:id`
- 관리자: `/admin/reports`, `/admin/games`

## 현재 상태

### 완료
- [x] 시즌 일정 import
- [x] 오즈 연동 (ESPN)
- [x] 부상자 연동 (ESPN)
- [x] 라인업 연동 (BasketballMonster)
- [x] B2B/3in4 계산
- [x] 게임 상태 표시 (live/finished)
- [x] 스마트 자동 새로고침 (경기시간 기준)
- [x] 시간대 로케일 지원 (KST/ET)

### TODO (우선순위 미정)
- [ ] 실시간 스코어 연동
- [ ] 알림/푸시 (경기 시작, 엣지 알림 등)
- [ ] 히스토리/통계 (과거 적중률, 팀 성적)
- [ ] 다른 종목 확장 (MLB, NFL 등)
- [ ] 결제/구독 시스템
- [ ] 리포트 자동화 (현재 수동)

## 주의사항

- `game_date`는 UTC로 저장, 표시할 때 `in_time_zone("Asia/Seoul")` 또는 `America/New_York` 사용
- 라인업은 경기 당일에만 데이터 있음 (BasketballMonster 특성)
- Admin 접근시 `?token=` 필요
