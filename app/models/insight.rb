class Insight < ApplicationRecord
  belongs_to :sport

  validates :title, presence: true
  validates :content, presence: true

  scope :published, -> { where(status: "published").order(published_at: :desc) }
  scope :draft, -> { where(status: "draft") }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_category, ->(cat) { where(category: cat) if cat.present? }

  CATEGORIES = %w[team_analysis league_trends player_focus betting_edge].freeze

  def publish!
    update(status: "published", published_at: Time.current)
  end

  def published?
    status == "published"
  end

  def tags_array
    tags.to_s.split(",").map(&:strip)
  end
end
