# frozen_string_literal: true
module DiscourseShorts
  class Short < ::ActiveRecord::Base
    self.table_name = "discourse_shorts"
    def tag_list
      tags.to_s.split(",").map(&:strip).reject(&:blank?)
    end
  end
end
