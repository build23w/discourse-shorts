# frozen_string_literal: true
# Production scale: indexes on hot columns that were doing full table scans.
# - submitted_by_id: analytics (Short.where(submitted_by_id)) + the like-reward
#   author cap JOIN (ds.submitted_by_id).
# - source: the ingest recycler filters source='ingest'.
# - reactions (short_id, rewarded): the per-like reward cap COUNTs.
# (Tables are small today so a plain index builds instantly; no CONCURRENTLY
#  needed and it avoids any in-transaction edge case in the migration runner.)
class ShortsPerfIndexes < ActiveRecord::Migration[7.0]
  def change
    add_index :discourse_shorts, :submitted_by_id unless index_exists?(:discourse_shorts, :submitted_by_id)
    add_index :discourse_shorts, :source unless index_exists?(:discourse_shorts, :source)
    unless index_exists?(:discourse_shorts_reactions, [:short_id, :rewarded], name: 'idx_shorts_react_short_rewarded')
      add_index :discourse_shorts_reactions, [:short_id, :rewarded], name: 'idx_shorts_react_short_rewarded'
    end
  end
end
