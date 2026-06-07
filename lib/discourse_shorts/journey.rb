# frozen_string_literal: true

module DiscourseShorts
  # The "lovely" learning engine. Orders the shorts rail like a patient
  # teacher rather than a slot machine: lean into the skills the user loves,
  # hand them the next difficulty step in those skills, keep opening doors to
  # areas they haven't met yet, and say so out loud (the `journey` payload
  # carries warm microcopy + a next-up suggestion for the rail to render).
  #
  # Design rules:
  #   * LOVE   — areas the user likes/completes get the strongest boost.
  #   * GROWTH — in a loved area, the next level up outranks more-of-the-same.
  #   * DISCOVERY — never let the rail collapse into one topic; the first 12
  #     cards always include at least 2 growth and 2 discovery items.
  #   * RESPECT — already-watched shorts sink (teach, don't loop); dislikes
  #     genuinely cool an area down; everything degrades to the global
  #     popularity order for anonymous or brand-new users.
  module Journey
    AREAS = {
      "painting"      => %w[paint painting primer roller brush caulk silicone stain],
      "tiling"        => %w[tile tiling grout backsplash mosaic shower-wall],
      "flooring"      => %w[floor flooring vinyl laminate hardwood subfloor plank],
      "drywall"       => %w[drywall mud taping sanding patch joint],
      "plumbing"      => %w[plumb plumbing pipe pipes drain faucet vanity toilet sink],
      "electrical"    => %w[electrical wiring outlet switch pendant breaker smart],
      "carpentry"     => %w[wood carpentry framing frame door trim mantel deck cabinet shelf steel-stud],
      "concrete"      => %w[concrete cement slab broom driveway],
      "exterior"      => %w[roof roofing siding eavestrough gutter window fence patio interlock landscap],
      "waterproofing" => %w[waterproof basement leak moisture sump],
      "tools"         => %w[tool tools drill saw level measure workbench],
    }.freeze

    AREA_LABELS = {
      "painting" => "Painting", "tiling" => "Tiling", "flooring" => "Flooring",
      "drywall" => "Drywall", "plumbing" => "Plumbing", "electrical" => "Electrical",
      "carpentry" => "Carpentry", "concrete" => "Concrete", "exterior" => "Exterior",
      "waterproofing" => "Waterproofing", "tools" => "Tools", "general" => "Home reno",
    }.freeze

    LEVEL1 = %w[basic basics beginner intro 101 first starter simple easy start].freeze
    LEVEL3 = %w[pro advanced master expert trick tricks perfect speed secret].freeze

    def self.classify(h)
      hay = +"#{h[:title]} #{Array(h[:tags]).join(' ')}"
      hay.downcase!
      area = "general"
      AREAS.each do |a, kws|
        if kws.any? { |k| hay.include?(k) }
          area = a
          break
        end
      end
      level = 2
      level = 1 if LEVEL1.any? { |k| hay.include?(k) }
      level = 3 if LEVEL3.any? { |k| hay.include?(k) }
      [area, level]
    end

    # Cached 5 min per user; rebuilt from progress + reactions.
    def self.learner_state(user, base)
      ::Discourse.cache.fetch("shorts_journey_state_v1_#{user.id}", expires_in: 5.minutes) do
        build_state(user, base)
      end
    rescue StandardError
      empty_state
    end

    def self.empty_state
      { seen: {}, love: {}, area_level: Hash.new(0), area_watch: Hash.new(0),
        completed_total: 0, explored: [] }
    end

    def self.build_state(user, base)
      by_id = {}
      base.each { |h| by_id[h[:id]] = h }

      prog = Progress.where(user_id: user.id).order(updated_at: :desc).limit(500)
                     .pluck(:short_id, :seconds, :watches, :completed)
      ups = Reaction.where(user_id: user.id, direction: "up").limit(500).pluck(:short_id)
      downs = Reaction.where(user_id: user.id, direction: "down").limit(500).pluck(:short_id)

      missing = (prog.map(&:first) + ups + downs).uniq - by_id.keys
      if missing.present?
        Short.where(id: missing.first(300)).pluck(:id, :title, :tags).each do |id, t, tg|
          by_id[id] = { id: id, title: t.to_s, tags: tg.to_s.split(",") }
        end
      end

      area_watch = Hash.new(0)
      area_complete = Hash.new(0)
      area_like = Hash.new(0)
      area_dislike = Hash.new(0)
      area_level = Hash.new(0)
      seen = {}
      completed_total = 0

      prog.each do |sid, _secs, _watches, completed|
        h = by_id[sid] or next
        area, lvl = classify(h)
        seen[sid] = true
        area_watch[area] += 1
        next unless completed
        completed_total += 1
        area_complete[area] += 1
        area_level[area] = lvl if lvl > area_level[area]
      end
      ups.each { |sid| (h = by_id[sid]) && area_like[classify(h).first] += 1 }
      downs.each { |sid| (h = by_id[sid]) && area_dislike[classify(h).first] += 1 }

      love = {}
      (area_watch.keys + area_like.keys).uniq.each do |a|
        love[a] = 2.0 * area_like[a] + 1.0 * area_complete[a] + 0.3 * area_watch[a] - 1.5 * area_dislike[a]
      end
      max = love.values.max.to_f
      love.transform_values! { |v| (v / max).clamp(0.0, 1.0) } if max.positive?

      { seen: seen, love: love, area_level: area_level, area_watch: area_watch,
        completed_total: completed_total, explored: area_watch.keys.sort }
    end

    # Returns [ordered_shorts, journey_payload].
    def self.curate(base, state, user_id)
      bucket = Time.now.to_i / 1800
      seed = ((bucket * 40_503) + user_id) % 9973 + 1

      scored = base.map do |h|
        area, lvl = classify(h)
        love = state[:love][area].to_f
        growth = (love >= 0.35 && lvl == state[:area_level][area].to_i + 1) ? 1.0 : 0.0
        discovery = state[:area_watch][area].to_i.zero? ? 1.0 : 0.0
        quality = (h[:likes].to_i - h[:dislikes].to_i + h[:priority].to_i).clamp(0, 50) / 50.0
        rewatch = state[:seen][h[:id]] ? 1.0 : 0.0
        jitter = ((h[:id].to_i * seed) % 97) / 97.0
        fresh = (h[:created_at].to_i > 72.hours.ago.to_i && !state[:seen][h[:id]]) ? 1.0 : 0.0
        score = 3.0 * love + 2.6 * growth + 1.6 * discovery + 1.2 * fresh + 0.8 * quality +
                0.5 * jitter - 2.2 * rewatch
        { h: h, area: area, lvl: lvl, growth: growth, discovery: discovery, fresh: fresh, score: score }
      end

      ranked = scored.sort_by { |x| -x[:score] }
      ensure_teaching_quota(ranked, 12)
      [ranked.map { |x| x[:h] }, summary(state, ranked)]
    end

    # Of the first `window` cards, guarantee at least 2 growth and 2
    # discovery items so the rail always teaches, never just echoes.
    def self.ensure_teaching_quota(ranked, window)
      %i[growth discovery fresh].each_with_index do |kind, k|
        head = ranked.first(window)
        have = head.count { |x| x[kind].to_f > 0 }
        next if have >= 2
        pulls = ranked.drop(window).select { |x| x[kind].to_f > 0 }.first(2 - have)
        pulls.each_with_index do |c, j|
          ranked.delete(c)
          ranked.insert([2 + k + 4 * j, ranked.length].min, c)
        end
      end
    end

    def self.summary(state, ranked)
      explored = state[:explored].length
      total = AREAS.keys.length
      completed = state[:completed_total]
      loved = state[:love].sort_by { |_, v| -v }.first(2).select { |_, v| v > 0.2 }.map(&:first)

      nxt = ranked.find { |x| x[:growth].to_f > 0 } || ranked.find { |x| x[:discovery].to_f > 0 }
      next_up = nil
      if nxt
        next_up = {
          short_id: nxt[:h][:id],
          title: nxt[:h][:title],
          area: nxt[:area],
          area_label: AREA_LABELS[nxt[:area]] || nxt[:area].capitalize,
          level: nxt[:lvl],
          reason: nxt[:growth].to_f > 0 ? "level_up" : "new_area",
        }
      end

      {
        completed: completed,
        areas_explored: explored,
        areas_total: total,
        loved_areas: loved,
        loved_labels: loved.map { |a| AREA_LABELS[a] || a.capitalize },
        next_up: next_up,
        encouragement: encouragement(state, loved, next_up),
      }
    end

    def self.encouragement(state, loved, next_up)
      c = state[:completed_total]
      explored = state[:explored].length
      if c.zero?
        "Pick any short — 30 seconds is all it takes to learn your first renovation trick."
      elsif c < 5
        "#{c} lesson#{c == 1 ? '' : 's'} down. Every pro on this forum started exactly here."
      elsif loved.present? && next_up && next_up[:reason] == "level_up"
        "Your #{AREA_LABELS[loved.first] || loved.first} skills are compounding — ready for the next level?"
      elsif next_up && next_up[:reason] == "new_area"
        "#{c} lessons in. There's a whole #{next_up[:area_label]} world you haven't opened yet."
      elsif explored >= 6
        "#{explored} of #{AREAS.keys.length} skill areas explored. You're becoming the person friends call before the contractor."
      else
        "#{c} lessons and counting. Keep going — houses don't stand a chance."
      end
    end
  end
end
