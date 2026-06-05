# frozen_string_literal: true
class AddShortsShares < ActiveRecord::Migration[7.0]
  def change
    add_column :discourse_shorts, :shares, :integer, null: false, default: 0 unless column_exists?(:discourse_shorts, :shares)
  end
end
