# frozen_string_literal: true
# comment_count only counted overlay-posted comments; replies made natively on
# the auto-created discussion topics never synced. Backfill from topics and
# index topic_id for the post_created sync hook (and recycler correctness —
# the recycler treats comment_count>0 as "keep forever").
class SyncShortCommentCounts < ActiveRecord::Migration[7.0]
  def up
    add_index :discourse_shorts, :topic_id unless index_exists?(:discourse_shorts, :topic_id)
    execute <<~SQL
      UPDATE discourse_shorts ds
      SET comment_count = GREATEST(t.posts_count - 1, 0)
      FROM topics t
      WHERE t.id = ds.topic_id
    SQL
  end

  def down
    remove_index :discourse_shorts, :topic_id if index_exists?(:discourse_shorts, :topic_id)
  end
end
