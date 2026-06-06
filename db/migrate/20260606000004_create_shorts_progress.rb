# frozen_string_literal: true

class CreateShortsProgress < ActiveRecord::Migration[7.0]
  def change
    create_table :discourse_shorts_progress do |t|
      t.integer :user_id, null: false
      t.integer :short_id, null: false
      t.integer :seconds, default: 0, null: false
      t.integer :watches, default: 0, null: false
      t.boolean :completed, default: false, null: false
      t.timestamps
    end
    add_index :discourse_shorts_progress, %i[user_id short_id], unique: true, name: "idx_shorts_progress_user_short"
    add_index :discourse_shorts_progress, :short_id, name: "idx_shorts_progress_short"
  end
end
