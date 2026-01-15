class Game < ApplicationRecord
  belongs_to :sport
  has_many :reports, dependent: :destroy

  validates :home_team, presence: true
  validates :away_team, presence: true
  validates :game_date, presence: true

  scope :upcoming, -> { where("game_date >= ?", Time.current).order(:game_date) }
  scope :today, -> { where(game_date: Time.current.beginning_of_day..Time.current.end_of_day) }
  scope :recent, -> { where("game_date < ?", Time.current).order(game_date: :desc) }

  def display_name
    "#{away_abbr || away_team} @ #{home_abbr || home_team}"
  end

  def short_date
    game_date&.strftime("%m/%d %H:%M")
  end
end
