# frozen_string_literal: true

class CreateWeaknessPredictions < ActiveRecord::Migration[8.0]
  def change
    create_table :weakness_predictions do |t|
      t.references :game, null: false, foreign_key: true
      t.string :team, null: false           # 예측 대상 팀 (약점 보유팀)
      t.string :trigger_type, null: false   # B2B, 3IN4, REST_DISADVANTAGE, etc.
      t.string :trigger_detail              # 상세 정보 (예: "2nd of B2B", "3rd game in 4 days")
      t.string :predicted_outcome           # LOSS, UNDER, COVER_FAIL 등
      t.string :actual_outcome              # 실제 결과
      t.boolean :hit                        # 예측 적중 여부
      t.float :confidence                   # 예측 신뢰도 (0.0 ~ 1.0)
      t.string :source                      # Rails/Neo4j 데이터 소스
      t.datetime :triggered_at              # 트리거 감지 시점
      t.datetime :evaluated_at              # 결과 평가 시점

      t.timestamps
    end

    add_index :weakness_predictions, [:team, :trigger_type]
    add_index :weakness_predictions, [:trigger_type, :hit]
    add_index :weakness_predictions, :evaluated_at
  end
end
