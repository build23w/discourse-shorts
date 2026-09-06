# frozen_string_literal: true
# v0.9.0 — the Monday growth report, ported from the Cowork task of 2026-08-31,
# posted into the desk's staff log topic instead of a chat reply. Same numbers,
# same 2026-08-31 baseline, read straight from the models/reports.
module DiscourseShorts
  module Desk
    module Growth
      BASELINE = { signups_30: 6, signups_7: 1, active_30: 15, active_7: 4, topics_30: 13, topics_7: 6, posts_30: 64, posts_7: 15 }.freeze

      def self.total(type, start_date, end_date)
        r = ::Report.find(type, start_date: start_date, end_date: end_date)
        return nil unless r && r.data
        d = r.data
        if d.first.is_a?(Hash) && d.first[:data]
          d.map { |s| [s[:label], s[:data].sum { |x| x[:y].to_i }] }.to_h
        else
          d.sum { |x| x[:y].to_i }
        end
      rescue StandardError => e
        "err: #{e.message[0, 60]}"
      end

      def self.build
        today = Date.today
        d30 = (today - 30).to_time
        d7 = (today - 7).to_time
        stop = today.to_time.end_of_day
        raw_stats = (::About.new.stats rescue {}) || {}
        stats = Hash.new { |h, k| h[k] = raw_stats[k] || raw_stats[k.to_s] || raw_stats[k.to_sym] }
        lines = []
        lines << "SIGNUPS 30d: #{total('signups', d30, stop)} / 7d: #{total('signups', d7, stop)} (baseline 2026-08-31: #{BASELINE[:signups_30]} / #{BASELINE[:signups_7]})"
        lines << "ACTIVE USERS 30d: #{stats[:active_users_30_days]} / 7d: #{stats[:active_users_7_days]} (baseline #{BASELINE[:active_30]} / #{BASELINE[:active_7]})"
        lines << "TOPICS 30d: #{stats[:topics_30_days]} / 7d: #{stats[:topics_7_days]} (baseline #{BASELINE[:topics_30]} / #{BASELINE[:topics_7]})"
        lines << "POSTS 30d: #{stats[:posts_30_days]} / 7d: #{stats[:posts_7_days]} (baseline #{BASELINE[:posts_30]} / #{BASELINE[:posts_7]})"
        pv = total("consolidated_page_views", d30, stop)
        lines << "PAGE VIEWS 30d: #{pv.is_a?(Hash) ? pv.map { |k, v| "#{k}=#{v}" }.join(', ') : pv}"
        email = ::EmailLog.where("created_at > ?", 7.days.ago).group(:email_type).count
        lines << "EMAIL 7d: " + (email.empty? ? "none" : email.sort_by { |_, n| -n }.map { |t, n| "#{t}=#{n}" }.join(", "))
        digests = email.keys.any? { |t| t.to_s =~ /digest|picks|recap|dormant/ }
        lines << (digests ? "digests ARE sending" : "still no digest rows")
        desk = ::Post.where(user_id: Forum.poster.id).where("created_at > ?", 7.days.ago)
        lines << "DESK 7d: #{desk.where(post_number: 1).count} topics, #{desk.where('post_number > 1').count} replies as #{Forum.poster.username}; AI calls today #{Ai.calls_today}"
        top = ::Report.find("top_referred_topics", start_date: d30, end_date: stop, limit: 6)
        (top&.data || []).first(6).each { |r| lines << "TOP REFERRED: #{r[:num_clicks]} clicks — #{r[:topic_title].to_s[0, 70]}" }
        lines
      rescue StandardError => e
        ["report failed: #{e.class} #{e.message[0, 120]}"]
      end
    end
  end
end
