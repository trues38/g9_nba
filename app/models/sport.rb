class Sport < ApplicationRecord
  has_many :games, dependent: :destroy
  has_many :insights, dependent: :destroy
  has_many :reports, through: :games

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true

  scope :active, -> { where(active: true).order(:position) }

  SLUGS = {
    basketball: "basketball",
    baseball: "baseball",
    soccer: "soccer"
  }.freeze
end
