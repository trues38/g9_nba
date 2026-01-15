class Report < ApplicationRecord
  belongs_to :game

  validates :content, presence: true

  scope :published, -> { where(status: "published").order(published_at: :desc) }
  scope :draft, -> { where(status: "draft") }
  scope :recent, -> { order(created_at: :desc) }

  delegate :sport, to: :game

  def publish!
    update(status: "published", published_at: Time.current)
  end

  def published?
    status == "published"
  end

  def confidence_stars
    confidence || "---"
  end
end
