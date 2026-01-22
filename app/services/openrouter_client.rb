# frozen_string_literal: true

# OpenRouterClient - OpenRouter API를 통한 무료 LLM 호출
#
# 사용법:
#   client = OpenRouterClient.new
#   result = client.analyze_insights(script)
#   result[:narratives]  # NarrativeContext 배열
#   result[:tactics]     # TacticalConcept 배열
#
class OpenrouterClient
  require "net/http"
  require "uri"
  require "json"

  class ApiError < StandardError; end

  BASE_URL = "https://openrouter.ai/api/v1/chat/completions"

  # 무료 모델 목록 (우선순위)
  FREE_MODELS = [
    "meta-llama/llama-3.1-8b-instruct:free",
    "mistralai/mistral-7b-instruct:free",
    "google/gemma-2-9b-it:free"
  ].freeze

  def initialize(api_key: nil, model: nil)
    @api_key = api_key || ENV.fetch("OPENROUTER_API_KEY", nil)
    @model = model || FREE_MODELS.first
  end

  # YouTube 스크립트에서 인사이트 자동 추출
  def analyze_insights(script, team_hint: nil)
    prompt = build_analysis_prompt(script, team_hint)
    response = chat(prompt)
    parse_insights_response(response)
  rescue StandardError => e
    { error: e.message, narratives: [], tactics: [] }
  end

  # 일반 채팅 API 호출
  def chat(message, system: nil)
    messages = []
    messages << { role: "system", content: system } if system
    messages << { role: "user", content: message }

    call_api(messages)
  end

  private

  def call_api(messages)
    uri = URI.parse(BASE_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 30
    http.read_timeout = 120  # LLM 응답 대기

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{@api_key}" if @api_key
    request["HTTP-Referer"] = "https://gate9sports.com"
    request["X-Title"] = "Gate9 ROE2"

    request.body = {
      model: @model,
      messages: messages,
      temperature: 0.3,  # 일관된 출력
      max_tokens: 2000
    }.to_json

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      raise ApiError, "HTTP #{response.code}: #{response.body}"
    end

    data = JSON.parse(response.body)

    if data["error"]
      raise ApiError, data["error"]["message"]
    end

    data.dig("choices", 0, "message", "content") || ""
  end

  def build_analysis_prompt(script, team_hint)
    <<~PROMPT
      NBA 분석 영상 스크립트에서 인사이트를 추출해주세요.

      ## 추출할 내용

      1. **NarrativeContext (서사적 맥락)** - 경기에 영향을 미치는 상황
         - Star Absence Impact: 스타 선수 결장
         - Player Emergence: 신예/벤치 선수 부상
         - Star Leadership: 스타의 리더십 발휘
         - Schedule Context: 일정 관련 (B2B, 원정 등)
         - Revenge Game: 복수전
         - Injury Return: 부상 복귀
         - Milestone: 기록 달성

      2. **TacticalConcept (전술적 개념)** - 팀의 전술/전략
         - OFFENSE: 공격 전술 (Spain PnR, DHO, Motion 등)
         - DEFENSE: 수비 전술 (Drop, Switch, Zone 등)
         - TRANSITION: 전환 공격
         - ROSTER_MANAGEMENT: 로테이션 관리
         - SPECIAL: 특수 상황 전술

      ## 출력 형식 (JSON)

      ```json
      {
        "narratives": [
          {
            "type": "Star Absence Impact",
            "team": "DEN",
            "player": "Nikola Jokic",
            "description": "요키치 12경기 결장 중 벤치에서 코칭"
          }
        ],
        "tactics": [
          {
            "name": "Gap Defense",
            "category": "DEFENSE",
            "team": "OKC",
            "player": null,
            "description": "외곽 슈터 압박하는 갭 디펜스",
            "mechanism": "수비수가 슈터와 볼핸들러 사이 갭에 위치"
          }
        ]
      }
      ```

      #{team_hint ? "힌트: 이 영상은 #{team_hint} 관련입니다." : ""}

      ## 스크립트

      #{script.to_s[0..4000]}

      ---
      위 스크립트를 분석하여 JSON 형식으로만 응답해주세요. 설명 없이 JSON만 출력하세요.
    PROMPT
  end

  def parse_insights_response(response)
    # JSON 블록 추출
    json_match = response.match(/```json\s*(.*?)\s*```/m) ||
                 response.match(/\{.*\}/m)

    return { narratives: [], tactics: [], raw: response } unless json_match

    json_str = json_match[1] || json_match[0]
    data = JSON.parse(json_str)

    {
      narratives: (data["narratives"] || []).map { |n| normalize_narrative(n) },
      tactics: (data["tactics"] || []).map { |t| normalize_tactic(t) },
      raw: response
    }
  rescue JSON::ParserError
    { narratives: [], tactics: [], raw: response, parse_error: true }
  end

  def normalize_narrative(n)
    {
      type: n["type"] || "Unknown",
      team: normalize_team(n["team"]),
      player: n["player"],
      description: n["description"] || ""
    }
  end

  def normalize_tactic(t)
    {
      name: t["name"] || "Unknown",
      category: t["category"] || "OFFENSE",
      team: normalize_team(t["team"]),
      player: t["player"],
      description: t["description"] || "",
      mechanism: t["mechanism"] || ""
    }
  end

  def normalize_team(team)
    return nil if team.blank?

    # 팀명 → 약어 매핑
    team_map = {
      "Thunder" => "OKC", "Oklahoma City" => "OKC",
      "Nuggets" => "DEN", "Denver" => "DEN",
      "Lakers" => "LAL", "Los Angeles Lakers" => "LAL",
      "Celtics" => "BOS", "Boston" => "BOS",
      "Warriors" => "GSW", "Golden State" => "GSW",
      "Bucks" => "MIL", "Milwaukee" => "MIL",
      "76ers" => "PHI", "Sixers" => "PHI", "Philadelphia" => "PHI",
      "Suns" => "PHX", "Phoenix" => "PHX",
      "Heat" => "MIA", "Miami" => "MIA",
      "Knicks" => "NYK", "New York" => "NYK",
      "Mavericks" => "DAL", "Dallas" => "DAL",
      "Clippers" => "LAC", "Los Angeles Clippers" => "LAC",
      "Cavaliers" => "CLE", "Cleveland" => "CLE",
      "Grizzlies" => "MEM", "Memphis" => "MEM",
      "Kings" => "SAC", "Sacramento" => "SAC",
      "Timberwolves" => "MIN", "Minnesota" => "MIN",
      "Pelicans" => "NOP", "New Orleans" => "NOP",
      "Hawks" => "ATL", "Atlanta" => "ATL",
      "Bulls" => "CHI", "Chicago" => "CHI",
      "Raptors" => "TOR", "Toronto" => "TOR",
      "Nets" => "BKN", "Brooklyn" => "BKN",
      "Magic" => "ORL", "Orlando" => "ORL",
      "Pacers" => "IND", "Indiana" => "IND",
      "Hornets" => "CHA", "Charlotte" => "CHA",
      "Wizards" => "WAS", "Washington" => "WAS",
      "Pistons" => "DET", "Detroit" => "DET",
      "Spurs" => "SAS", "San Antonio" => "SAS",
      "Trail Blazers" => "POR", "Blazers" => "POR", "Portland" => "POR",
      "Jazz" => "UTA", "Utah" => "UTA",
      "Rockets" => "HOU", "Houston" => "HOU"
    }

    # 이미 약어면 그대로
    return team.upcase if team.length == 3

    team_map[team] || team
  end
end
