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

ActiveRecord::Schema[8.1].define(version: 2026_01_14_230502) do
  create_table "games", force: :cascade do |t|
    t.string "away_abbr"
    t.string "away_edge"
    t.decimal "away_spread"
    t.string "away_team"
    t.datetime "created_at", null: false
    t.string "external_id"
    t.datetime "game_date"
    t.string "home_abbr"
    t.string "home_edge"
    t.decimal "home_spread"
    t.string "home_team"
    t.integer "rest_days"
    t.string "schedule_note"
    t.integer "sport_id", null: false
    t.string "status"
    t.decimal "total_line"
    t.datetime "updated_at", null: false
    t.string "venue"
    t.index ["sport_id"], name: "index_games_on_sport_id"
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
    t.index ["sport_id"], name: "index_insights_on_sport_id"
  end

  create_table "reports", force: :cascade do |t|
    t.string "confidence"
    t.text "content"
    t.datetime "created_at", null: false
    t.boolean "free", default: false
    t.integer "game_id", null: false
    t.string "pick"
    t.datetime "published_at"
    t.string "status"
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["game_id"], name: "index_reports_on_game_id"
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

  add_foreign_key "games", "sports"
  add_foreign_key "insights", "sports"
  add_foreign_key "reports", "games"
end
