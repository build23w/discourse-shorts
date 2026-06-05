# frozen_string_literal: true
class ShortsOwnedCommentsRewards < ActiveRecord::Migration[7.0]
  def change
    # provider="upload" support (LF-produced videos hosted on Discourse), owner
    # attribution, the linked discussion topic, and gentle algorithmic precedence.
    add_column :discourse_shorts, :video_url,     :string                 unless column_exists?(:discourse_shorts, :video_url)
    add_column :discourse_shorts, :upload_ref,    :string                 unless column_exists?(:discourse_shorts, :upload_ref)
    add_column :discourse_shorts, :poster_url,    :string                 unless column_exists?(:discourse_shorts, :poster_url)
    add_column :discourse_shorts, :topic_id,      :integer                unless column_exists?(:discourse_shorts, :topic_id)
    add_column :discourse_shorts, :comment_count, :integer, null: false, default: 0 unless column_exists?(:discourse_shorts, :comment_count)
    add_column :discourse_shorts, :priority,      :integer, null: false, default: 0 unless column_exists?(:discourse_shorts, :priority)

    add_index :discourse_shorts, :topic_id unless index_exists?(:discourse_shorts, :topic_id)
    add_index :discourse_shorts, :priority unless index_exists?(:discourse_shorts, :priority)

    # Track which like-reactions have already paid the author $RENO so toggling a
    # like off/on never double-pays and daily caps stay accurate.
    add_column :discourse_shorts_reactions, :rewarded, :boolean, null: false, default: false unless column_exists?(:discourse_shorts_reactions, :rewarded)
  end
end
