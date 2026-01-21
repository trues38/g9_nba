# frozen_string_literal: true

# Neo4jClient - Neo4j HTTP API 클라이언트
#
# 사용법:
#   client = Neo4jClient.new
#   client.query("MATCH (n) RETURN count(n) as count")
#   client.create_narrative_context(data)
#   client.create_tactical_concept(data)
#
class Neo4jClient
  require "net/http"
  require "uri"
  require "json"
  require "base64"

  class QueryError < StandardError; end

  # 연결 정보 (환경변수 또는 기본값)
  HOST = ENV.fetch("NEO4J_HOST", "86.48.2.202")
  PORT = ENV.fetch("NEO4J_PORT", "7474")
  USER = ENV.fetch("NEO4J_USER", "neo4j")
  PASSWORD = ENV.fetch("NEO4J_PASSWORD", "nba_vultr_2025")

  def initialize
    @base_url = "http://#{HOST}:#{PORT}/db/neo4j/tx/commit"
    @auth = Base64.strict_encode64("#{USER}:#{PASSWORD}")
  end

  # 단일 Cypher 쿼리 실행
  def query(cypher, params = {})
    execute_statements([{ statement: cypher, parameters: params }])
  end

  # 여러 쿼리 실행 (트랜잭션)
  def multi_query(statements)
    execute_statements(statements.map { |s| { statement: s[:cypher], parameters: s[:params] || {} } })
  end

  # NarrativeContext 생성
  def create_narrative_context(data)
    nc_id = generate_nc_id(data[:team], data[:type])

    statements = [
      # 1. NarrativeContext 생성
      {
        cypher: <<~CYPHER,
          MERGE (nc:NarrativeContext {nc_id: $nc_id})
          SET nc.type = $type,
              nc.description = $description,
              nc.team = $team,
              nc.player_involved = $player,
              nc.source_url = $source_url,
              nc.source_title = $source_title,
              nc.extracted_at = datetime()
          RETURN nc.nc_id as id
        CYPHER
        params: {
          nc_id: nc_id,
          type: data[:type],
          description: data[:description],
          team: data[:team],
          player: data[:player],
          source_url: data[:source_url],
          source_title: data[:source_title]
        }
      },
      # 2. Team 연결
      {
        cypher: <<~CYPHER,
          MATCH (t:Team {abbreviation: $team})
          MATCH (nc:NarrativeContext {nc_id: $nc_id})
          MERGE (nc)-[:NARRATIVE_ABOUT]->(t)
        CYPHER
        params: { team: data[:team], nc_id: nc_id }
      }
    ]

    # 3. Player 연결 (있으면)
    if data[:player].present?
      statements << {
        cypher: <<~CYPHER,
          MATCH (p:Player)
          WHERE p.display_name = $player OR p.name = $player
          MATCH (nc:NarrativeContext {nc_id: $nc_id})
          MERGE (nc)-[:INVOLVES_PLAYER]->(p)
        CYPHER
        params: { player: data[:player], nc_id: nc_id }
      }
    end

    multi_query(statements)
    nc_id
  end

  # TacticalConcept 생성
  def create_tactical_concept(data)
    statements = [
      # 1. TacticalConcept 생성
      {
        cypher: <<~CYPHER,
          MERGE (tc:TacticalConcept {name: $name})
          SET tc.category = $category,
              tc.description = $description,
              tc.mechanism = $mechanism,
              tc.source_url = $source_url,
              tc.status = 'pending',
              tc.created_at = datetime()
          RETURN tc.name as name
        CYPHER
        params: {
          name: data[:name],
          category: data[:category],
          description: data[:description],
          mechanism: data[:mechanism],
          source_url: data[:source_url]
        }
      }
    ]

    # 2. Team 연결 (있으면)
    if data[:team].present?
      statements << {
        cypher: <<~CYPHER,
          MATCH (t:Team {abbreviation: $team})
          MATCH (tc:TacticalConcept {name: $name})
          MERGE (t)-[:RUNS]->(tc)
        CYPHER
        params: { team: data[:team], name: data[:name] }
      }
    end

    # 3. Player 연결 (있으면)
    if data[:player].present?
      statements << {
        cypher: <<~CYPHER,
          MATCH (p:Player)
          WHERE p.display_name = $player OR p.name = $player
          MATCH (tc:TacticalConcept {name: $name})
          MERGE (p)-[:EXPRESSES]->(tc)
        CYPHER
        params: { player: data[:player], name: data[:name] }
      }
    end

    multi_query(statements)
    data[:name]
  end

  # Team 목록 조회
  def teams
    result = query("MATCH (t:Team) RETURN t.abbreviation as abbr, t.name as name ORDER BY t.abbreviation")
    result.map { |r| { abbr: r["abbr"], name: r["name"] } }
  end

  # Player 검색
  def search_players(term)
    result = query(
      "MATCH (p:Player) WHERE p.display_name =~ $pattern OR p.name =~ $pattern RETURN p.display_name as name LIMIT 20",
      { pattern: "(?i).*#{term}.*" }
    )
    result.map { |r| r["name"] }
  end

  private

  def execute_statements(statements)
    uri = URI.parse(@base_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 10
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Basic #{@auth}"
    request.body = { statements: statements }.to_json

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      raise QueryError, "HTTP #{response.code}: #{response.body}"
    end

    data = JSON.parse(response.body)

    if data["errors"]&.any?
      raise QueryError, data["errors"].map { |e| e["message"] }.join(", ")
    end

    # 첫 번째 결과의 데이터 반환
    results = data.dig("results", 0, "data") || []
    results.map { |r| r["row"]&.first.is_a?(Hash) ? r["row"].first : Hash[data.dig("results", 0, "columns").zip(r["row"])] }
  end

  def generate_nc_id(team, type)
    date = Date.current.strftime("%Y_%m")
    slug = type.to_s.upcase.gsub(/\s+/, "_").gsub(/[^A-Z0-9_]/, "")[0..20]
    "YT_#{team}_#{date}_#{slug}"
  end
end
