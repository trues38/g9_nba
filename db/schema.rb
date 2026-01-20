# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_01_20_000000) do
  create_table "game_results", force: :cascade do |t|
    t.integer "away_score"
    t.decimal "closing_spread", precision: 4, scale: 1
    t.decimal "closing_total", precision: 5, scale: 1
    t.datetime "created_at", null: false
    t.integer "game_id", null: false
    t.integer "home_score"
    t.datetime "lines_captured_at"
    t.integer "margin"
    t.decimal "opening_spread", precision: 4, scale: 1
    t.decimal "opening_total", precision: 5, scale: 1
    t.datetime "result_captured_at"
    t.boolean "spread_covered_home"
    t.string "spread_result"
    t.boolean "total_over"
    t.string "total_result"
    t.datetime "updated_at", null: false
    t.index ["game_id"], name: "index_game_results_on_game_id"
    t.index ["lines_captured_at"], name: "index_game_results_on_lines_captured_at"
    t.index ["spread_result"], name: "index_game_results_on_spread_result"
    t.index ["total_result"], name: "index_game_results_on_total_result"
  end

  create_table "games", force: :cascade do |t|
    t.string "away_abbr"
    t.string "away_edge"
    t.text "away_linescores"
    t.string "away_record"
    t.string "away_road_record"
    t.integer "away_score"
    t.decimal "away_spread"
    t.string "away_team"
    t.string "clock"
    t.datetime "created_at", null: false
    t.string "external_id"
    t.datetime "game_date"
    t.string "h2h_summary"
    t.string "home_abbr"
    t.string "home_edge"
    t.string "home_home_record"
    t.text "home_linescores"
    t.string "home_record"
    t.integer "home_score"
    t.decimal "home_spread"
    t.string "home_team"
    t.integer "period"
    t.integer "rest_days"
    t.string "schedule_note"
    t.integer "sport_id", null: false
    t.string "status"
    t.decimal "total_line"
    t.datetime "updated_at", null: false
    t.string "venue"
    t.index ["away_abbr"], name: "index_games_on_away_abbr"
    t.index ["external_id"], name: "index_games_on_external_id", unique: true
    t.index ["game_date"], name: "index_games_on_game_date"
    t.index ["home_abbr", "away_abbr", "game_date"], name: "index_games_on_home_abbr_and_away_abbr_and_game_date"
    t.index ["home_abbr"], name: "index_games_on_home_abbr"
    t.index ["sport_id", "game_date"], name: "index_games_on_sport_id_and_game_date"
    t.index ["sport_id"], name: "index_games_on_sport_id"
    t.index ["status"], name: "index_games_on_status"
  end

  create_table "insights", force: :cascade do |t|
    t.string "category"
    t.text "content"
    t.datetime "created_at", null: false
    t.datetime "published_at"
    t.integer "sport_id", null: false
    t.string "status"
    t.string "tags"
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["published_at"], name: "index_insights_on_published_at"
    t.index ["sport_id", "status"], name: "index_insights_on_sport_id_and_status"
    t.index ["sport_id"], name: "index_insights_on_sport_id"
    t.index ["status"], name: "index_insights_on_status"
  end

  create_table "reports", force: :cascade do |t|
    t.integer "actual_away_score"
    t.integer "actual_home_score"
    t.string "analyst_consensus"
    t.string "confidence"
    t.text "content"
    t.datetime "created_at", null: false
    t.boolean "free", default: false
    t.integer "game_id", null: false
    t.string "pick"
    t.decimal "pick_line"
    t.string "pick_side"
    t.string "pick_type"
    t.datetime "published_at"
    t.string "result"
    t.text "result_note"
    t.datetime "result_recorded_at"
    t.decimal "stake", default: "1.0"
    t.string "status"
    t.json "structured_data"
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["free"], name: "index_reports_on_free"
    t.index ["game_id", "status"], name: "index_reports_on_game_id_and_status"
    t.index ["game_id"], name: "index_reports_on_game_id"
    t.index ["pick_type"], name: "index_reports_on_pick_type"
    t.index ["published_at"], name: "index_reports_on_published_at"
    t.index ["result", "pick_type"], name: "index_reports_on_result_and_pick_type"
    t.index ["result"], name: "index_reports_on_result"
    t.index ["status"], name: "index_reports_on_status"
  end

  create_table "sports", force: :cascade do |t|
    t.boolean "active"
    t.datetime "created_at", null: false
    t.string "icon"
    t.string "name"
    t.integer "position"
    t.string "slug"
    t.datetime "updated_at", null: false
  end

  add_foreign_key "game_results", "games"
  add_foreign_key "games", "sports"
  add_foreign_key "insights", "sports"
  add_foreign_key "reports", "games"
end
