# frozen_string_literal: true
class CreateDiscourseShorts < ActiveRecord::Migration[7.0]
  def change
    create_table :discourse_shorts do |t|
      t.string  :video_id, null: false
      t.string  :provider, null: false, default: "youtube"
      t.string  :title
      t.string  :tags
      t.integer :submitted_by_id
      t.string  :status, null: false, default: "approved"
      t.string  :source, null: false, default: "manual"
      t.integer :likes, null: false, default: 0
      t.integer :dislikes, null: false, default: 0
      t.integer :views, null: false, default: 0
      t.bigint  :watch_seconds, null: false, default: 0
      t.timestamps
    end
    add_index :discourse_shorts, :video_id, unique: true
    add_index :discourse_shorts, :status

    create_table :discourse_shorts_reactions do |t|
      t.integer :short_id, null: false
      t.integer :user_id, null: false
      t.string  :direction, null: false
      t.timestamps
    end
    add_index :discourse_shorts_reactions, [:short_id, :user_id], unique: true, name: "idx_shorts_react_short_user"
  end
end
