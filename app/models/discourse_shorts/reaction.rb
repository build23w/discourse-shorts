# frozen_string_literal: true
module DiscourseShorts
  class Reaction < ::ActiveRecord::Base
    self.table_name = "discourse_shorts_reactions"
  end
end
