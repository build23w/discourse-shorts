# frozen_string_literal: true

class CreateShortsReactionRewardClaims < ActiveRecord::Migration[7.0]
  def up
    create_table :discourse_shorts_reaction_reward_claims do |t|
      t.integer :short_id, null: false
      t.integer :voter_user_id, null: false
      t.integer :author_user_id, null: false
      t.integer :amount, null: false
      t.datetime :rewarded_at, null: false
      t.timestamps
    end

    add_index :discourse_shorts_reaction_reward_claims,
              %i[short_id voter_user_id],
              unique: true,
              name: "idx_shorts_reward_claim_once"
    add_index :discourse_shorts_reaction_reward_claims,
              %i[short_id rewarded_at],
              name: "idx_shorts_reward_claim_short_day"
    add_index :discourse_shorts_reaction_reward_claims,
              %i[author_user_id rewarded_at],
              name: "idx_shorts_reward_claim_author_day"

    historical_amount = [SiteSetting.shorts_like_reward_amount.to_i, 0].max
    execute <<~SQL
      INSERT INTO discourse_shorts_reaction_reward_claims
        (short_id, voter_user_id, author_user_id, amount, rewarded_at, created_at, updated_at)
      SELECT reactions.short_id,
             reactions.user_id,
             shorts.submitted_by_id,
             #{historical_amount},
             COALESCE(reactions.updated_at, reactions.created_at, CURRENT_TIMESTAMP),
             CURRENT_TIMESTAMP,
             CURRENT_TIMESTAMP
        FROM discourse_shorts_reactions reactions
        JOIN discourse_shorts shorts ON shorts.id = reactions.short_id
       WHERE reactions.rewarded = TRUE
         AND shorts.submitted_by_id IS NOT NULL
      ON CONFLICT (short_id, voter_user_id) DO NOTHING
    SQL
  end

  def down
    drop_table :discourse_shorts_reaction_reward_claims
  end
end
