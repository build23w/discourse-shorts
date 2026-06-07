# frozen_string_literal: true
class AddShortsVp9Url < ActiveRecord::Migration[7.0]
  def change
    add_column :discourse_shorts, :vp9_url, :string unless column_exists?(:discourse_shorts, :vp9_url)
  end
end
