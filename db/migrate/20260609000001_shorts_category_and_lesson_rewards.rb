# frozen_string_literal: true
class ShortsCategoryAndLessonRewards < ActiveRecord::Migration[7.0]
  def up
    unless column_exists?(:discourse_shorts, :category)
      add_column :discourse_shorts, :category, :string
    end
    unless index_exists?(:discourse_shorts, :category)
      add_index :discourse_shorts, :category
    end
    unless column_exists?(:discourse_shorts_progress, :rewarded_at)
      add_column :discourse_shorts_progress, :rewarded_at, :datetime
    end
    unless index_exists?(:discourse_shorts_progress, [:user_id, :rewarded_at], name: "idx_shorts_prog_user_rewarded")
      add_index :discourse_shorts_progress, [:user_id, :rewarded_at], name: "idx_shorts_prog_user_rewarded"
    end
    # Backfill category for existing shorts using the keyword classifier so the
    # explicit-category filter has data on day one. Per-row guarded; small lib.
    if defined?(DiscourseShorts::Short) && defined?(DiscourseShorts::Journey)
      DiscourseShorts::Short.where(category: nil).find_each do |s|
        begin
          area, = DiscourseShorts::Journey.classify(title: s.title.to_s, tags: s.tags.to_s.split(","))
          s.update_columns(category: area) if area.present?
        rescue StandardError
          nil
        end
      end
    end
  end

  def down
    remove_column :discourse_shorts, :category if column_exists?(:discourse_shorts, :category)
    remove_column :discourse_shorts_progress, :rewarded_at if column_exists?(:discourse_shorts_progress, :rewarded_at)
  end
end
