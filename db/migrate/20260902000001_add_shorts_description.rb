# frozen_string_literal: true
# v0.8.0 — a creator-written description per short. Until now a short carried
# only a title, so its share/landing page had nothing real to put in the meta
# description, og:description or JSON-LD (Garrett, 2026-09-02).
class AddShortsDescription < ActiveRecord::Migration[7.0]
  def change
    add_column :discourse_shorts, :description, :text unless column_exists?(:discourse_shorts, :description)
  end
end
