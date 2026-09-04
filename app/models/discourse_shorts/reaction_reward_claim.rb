# frozen_string_literal: true

module DiscourseShorts
  class ReactionRewardClaim < ::ActiveRecord::Base
    self.table_name = "discourse_shorts_reaction_reward_claims"

    belongs_to :short, class_name: "DiscourseShorts::Short"
  end
end
