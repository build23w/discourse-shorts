# frozen_string_literal: true
# v0.9.0 — the three writing jobs of the desk, ported from the Cowork task
# prompts of 2026-09-05: a daily researched topic, the answer desk for unanswered
# member threads, and the refresh desk for threads that already earn search
# clicks. The model only sees excerpts from Sources::PACK and every draft passes
# `guard` (no unsupported $ / % figures, no banned filler, ends with a question)
# before it is posted. A draft that fails twice is dropped, never "fixed up".
module DiscourseShorts
  module Desk
    module Writer
      VOICE = <<~TXT
        You write as BuildersLTD, "the Contractor" — the house account of LF Builders, a Greater Toronto renovation company operating since 1979, on home.renovation.reviews (Home Renovation Reviews, Canada's home renovation community). Write as "we" (the crew). Plain, direct, specific. Short paragraphs. No headers, no bullet lists longer than 4 items, no emojis, no exclamation marks, no markdown headings.
        HONESTY: never invent a personal anecdote, a specific past job, a client, a photo, or a number. Every price range, code requirement or product fact must come from the SOURCE EXCERPTS you are given, and you name the source in the sentence ("Toronto's building department lists…", "Ontario's Building Code requires…", "Toronto Hydro's current rates show…"). If the excerpts do not cover it, say what you would check and where instead of guessing. Prices in CAD, ranges not points. Do not state any dollar figure or percentage that is not in the excerpts.
        Ontario / GTA context first (permits are municipal; the Ontario Building Code applies; Tarion for new homes; HST). Do not assume the reader is in the US unless they say so.
        Recommend a licensed pro or a permit when the work needs one (electrical = ESA-licensed contractor; gas = TSSA; structural = engineer). Never tell someone to skip a permit.
        Never mention $RENO, rewards, tokens, or the Discord. Never link to lfbuilders.ca or pitch LF Builders' services. No links except the source pages named in the excerpts, at most two.
        Never write filler ("Great question", "Thanks for sharing", "Hope this helps", "still holds up"). Never use the words delve, tapestry, vibrant, robust, leverage, seamless, elevate, unlock, journey, game-changer, or "it's important to note".
        End with ONE concrete question that would let the crew give a better answer (dimensions, age of house, city, photos of the problem), not a generic "let us know".
      TXT

      BANNED = /\b(delve|tapestry|vibrant|robust|leverage|seamless|elevate|unlock|journey|game-changer)\b|it'?s important to note|great question|thanks for sharing|hope this helps|still holds up|\$RENO|lfbuilders\.ca|discord/i

      # ---------- honesty guard ----------
      # [[kind, digits], ...] — kind :dollar or :pct
      def self.figures(text)
        t = text.to_s
        dollars = t.scan(/\$\s?\d[\d,]*(?:\.\d+)?/).map { |m| [:dollar, m.delete("$ ,")] }
        pcts = t.scan(/\d+(?:\.\d+)?\s?(?:%|per ?cent)/i).map { |m| [:pct, m[/\d+(?:\.\d+)?/]] }
        (dollars + pcts).uniq
      end

      # A figure is supported when the same number appears in a fetched source in
      # the same role ("$1,600" / "1,600 dollars" or "80%" / "80 per cent").
      def self.unsupported_figures(draft, sources_text)
        src = sources_text.to_s.delete(",")
        figures(draft).reject do |kind, digits|
          n = Regexp.escape(digits.sub(/\.0+\z/, ""))
          if kind == :dollar
            src =~ /\$\s?#{n}(?:\.\d+)?(?!\d)/ || src =~ /(?<!\d)#{n}(?:\.\d+)?\s?(?:dollars|CAD|per (?:square|sq|linear|hour|day|month|year))/i
          else
            src =~ /(?<!\d)#{n}\s?(?:%|per ?cent)/i
          end
        end.map { |kind, digits| kind == :dollar ? "$#{digits}" : "#{digits}%" }
      end

      def self.problems(draft, sources_text, min_words:, max_words:)
        issues = []
        words = draft.to_s.split(/\s+/).size
        issues << "too short (#{words} words)" if words < min_words
        issues << "too long (#{words} words)" if words > max_words
        bad = unsupported_figures(draft, sources_text)
        issues << "unsupported figures: #{bad.join(', ')}" if bad.any?
        issues << "banned phrase: #{draft[BANNED]}" if draft =~ BANNED
        issues << "contains a heading" if draft =~ /^\s*#/
        issues << "no closing question" unless draft.to_s.strip.lines.reject(&:blank?).last.to_s.strip.end_with?("?")
        issues << "contains an exclamation mark" if draft.include?("!")
        issues
      end

      # Two attempts; the second one names the problems. Returns the draft or nil.
      def self.compose(system:, user:, sources_text:, min_words:, max_words:, max_tokens: 900)
        draft = Ai.chat(system: system, user: user, max_tokens: max_tokens, temperature: 0.4)
        return nil if draft.blank?
        draft = clean(draft)
        issues = problems(draft, sources_text, min_words: min_words, max_words: max_words)
        return draft if issues.empty?
        Rails.logger.info("[hrr-desk] draft rejected (#{issues.join('; ')}), retrying once")
        retry_user = user + "\n\nYOUR PREVIOUS DRAFT WAS REJECTED FOR: #{issues.join('; ')}. Rewrite it fixing every problem. Remove any figure that is not in the excerpts rather than replacing it with another number."
        draft2 = Ai.chat(system: system, user: retry_user, max_tokens: max_tokens, temperature: 0.3)
        return nil if draft2.blank?
        draft2 = clean(draft2)
        issues2 = problems(draft2, sources_text, min_words: min_words, max_words: max_words)
        return draft2 if issues2.empty?
        Rails.logger.warn("[hrr-desk] draft dropped (#{issues2.join('; ')})")
        nil
      end

      def self.clean(text)
        s = text.to_s.strip
        s = s.gsub(/\A```(?:markdown|md|text)?\s*/i, "").gsub(/```\s*\z/, "")
        s = s.sub(/\A(?:here(?:'s| is) (?:the|a|my)[^\n]*\n+)/i, "")
        s = s.gsub(/^\s*(Title|Reply|Body|Draft)\s*:\s*/i, "")
        s.strip
      end

      def self.excerpts_for(ids, query, max_sources: 4)
        srcs = Array(ids).map { |i| Sources.find(i.to_s.strip) }.compact.uniq.first(max_sources)
        srcs = Sources.match(query, limit: max_sources) if srcs.empty?
        parts = srcs.map do |s|
          ex = Sources.excerpt(s, query)
          ex.present? ? "SOURCE #{s.id} — #{s.label} (#{s.url}):\n#{ex}" : nil
        end.compact
        [parts.join("\n\n"), srcs.select { |s| parts.any? { |p| p.start_with?("SOURCE #{s.id} ") } }]
      end

      # ---------- daily topic ----------
      def self.daily_topic!
        return { skipped: "ai disabled" } unless Ai.enabled?
        cats = SiteSetting.hrr_desk_topic_categories.to_s.split("|").map(&:to_i).select { |i| ::Category.exists?(id: i) }
        return { error: "no topic categories" } if cats.empty?
        cat_lines = cats.map { |i| "#{i} = #{::Category.find(i).name}" }.join("\n")
        today = Time.now.utc
        month = today.strftime("%B")
        plan_prompt = <<~TXT
          Today is #{today.strftime('%A %-d %B %Y')} (#{month}, Greater Toronto). Choose ONE question a GTA homeowner would type into Google this week and that home.renovation.reviews should answer as a new topic.
          Think about the season and what people are dealing with now, the housing cycle, permits, and this week's local news.

          Toronto headlines this week:
          #{Sources.headlines_text(limit: 14)}

          Topics already on the forum (do NOT repeat these questions or close variants):
          #{Forum.recent_titles.first(80).map { |t| "- #{t}" }.join("\n")}

          Sources you may research (ids). Pick 2 to 4 that actually contain the facts for your question:
          #{Sources.index_text}

          Categories (id = name):
          #{cat_lines}

          Reply with ONLY a JSON object: {"title": "<question in plain words, 45-70 characters, no colon subtitle, no clickbait>", "category_id": <id>, "tags": ["2-4 lowercase tags"], "sources": ["id", "id"], "angle": "<one sentence: what the reader needs and what makes it timely>"}
        TXT
        plan = Ai.chat(system: "You plan content for a Canadian home renovation forum. Answer with JSON only.", user: plan_prompt, max_tokens: 400, json: true, temperature: 0.6)
        return { error: "no plan" } unless plan.is_a?(Hash) && plan["title"].to_s.length.between?(25, 110)
        title = plan["title"].to_s.strip.gsub(/\s+/, " ").sub(/\.\z/, "")
        return { skipped: "duplicate: #{title}" } if Forum.duplicate?(title)
        cat = cats.include?(plan["category_id"].to_i) ? plan["category_id"].to_i : cats.first
        sources_text, used = excerpts_for(plan["sources"], "#{title} #{plan['angle']}")
        return { skipped: "no sources fetched for #{title}" } if sources_text.blank?
        write_prompt = <<~TXT
          Write the opening post for a new forum topic titled: "#{title}"
          Angle: #{plan['angle']}
          Date: #{today.strftime('%-d %B %Y')}.

          SOURCE EXCERPTS (the only facts and figures you may use; name the source in the sentence):
          #{sources_text}

          Requirements: 300-500 words. Open by answering the question in the first two sentences. Then the specifics: figures with the named source, what changes the answer (age of house, size, city), the permit/code reality for Ontario, the mistake people make, and "what we'd do" from a crew's point of view (general practice, not an invented job). Close with two lines: one inviting members to post their own numbers or photos, and one direct question. Plain prose, no title line, no headings, no sign-off.
        TXT
        raw = compose(system: VOICE, user: write_prompt, sources_text: sources_text, min_words: 240, max_words: 620, max_tokens: 1100)
        return { skipped: "draft failed guard for #{title}" } if raw.nil?
        res = Forum.new_topic!(title: title, raw: raw, category_id: cat, tags: Array(plan["tags"]).map(&:to_s))
        res.merge(title: title, sources: used.map(&:url))
      end

      # ---------- answer desk ----------
      def self.answer_desk!(max: 3)
        return { skipped: "ai disabled" } unless Ai.enabled?
        done = []
        Forum.candidates.each do |topic|
          break if done.count { |d| d[:posted] || d[:unlisted] } >= max
          first = topic.first_post
          next unless first
          transcript = Forum.transcript(topic, tail: 0)
          triage_prompt = <<~TXT
            A member started this topic on a Canadian home renovation forum and nobody has replied yet.

            #{transcript}

            Decide what it is. Reply with ONLY JSON: {"kind": "spam" | "question" | "project" | "intro", "confidence": 0.0-1.0, "reason": "<one sentence>", "sources": ["ids from the list below that contain facts needed for a good reply, 0-3"], "focus": "<the one thing a reply must address>"}
            "spam" = a business advertising itself, an off-topic product, an SEO link drop, non-renovation content, or property services outside Canada/US with a link.
            "question" = a real question. "project" = someone showing or describing their own project. "intro" = an introduction with nothing to answer.

            Sources:
            #{Sources.index_text}
          TXT
          triage = Ai.chat(system: "You triage forum posts. JSON only.", user: triage_prompt, max_tokens: 300, json: true, temperature: 0.2)
          next unless triage.is_a?(Hash)
          kind = triage["kind"].to_s
          conf = triage["confidence"].to_f
          has_link = first.raw.to_s =~ %r{https?://}
          if kind == "spam" && (conf >= 0.85 || (conf >= 0.7 && has_link))
            done << { topic_id: topic.id, title: topic.title, unlisted: true, reason: triage["reason"].to_s[0, 140] }.merge(Forum.unlist!(topic, triage["reason"].to_s))
            next
          end
          next if kind == "spam"
          sources_text, used = excerpts_for(triage["sources"], "#{topic.title} #{triage['focus']}")
          short = kind != "question"
          write_prompt = <<~TXT
            Reply to this new forum topic as the crew.

            #{transcript}

            What the reply must address: #{triage['focus']}
            #{short ? "This is #{kind == 'intro' ? 'an introduction' : 'a project post'} with nothing to answer: write 40-80 words that engage with a specific detail of what they posted and ask one real question about it." : "Write 120-280 words: answer the actual question first, then the one or two things they have not thought of, then the question back."}

            SOURCE EXCERPTS (the only facts and figures you may use; if empty, do not state any figures):
            #{sources_text.presence || '(none)'}

            Plain prose, no greeting line, no sign-off, no title.
          TXT
          raw = compose(system: VOICE, user: write_prompt, sources_text: sources_text, min_words: short ? 35 : 100, max_words: short ? 120 : 330, max_tokens: 700)
          if raw.nil?
            done << { topic_id: topic.id, title: topic.title, skipped: "draft failed guard" }
            next
          end
          res = Forum.reply!(topic, raw, min_length: short ? 120 : 200)
          done << { topic_id: topic.id, title: topic.title, kind: kind, posted: res[:url].present?, sources: used.map(&:url) }.merge(res)
        end
        done
      end

      # ---------- refresh desk ----------
      def self.refresh_desk!(max: 3)
        return { skipped: "ai disabled" } unless Ai.enabled?
        out = []
        Forum.refresh_candidates.first(6).each do |c|
          break if out.count { |o| o[:posted] } >= max
          topic = c[:topic]
          transcript = Forum.transcript(topic, tail: 10)
          decide_prompt = <<~TXT
            This thread on a Canadian home renovation forum gets #{c[:clicks]} search/referral clicks a month. Today is #{Time.now.utc.strftime('%-d %B %Y')}.

            #{transcript}

            Is there a real 2026 update worth posting? Good updates: a current CAD figure with a named source, an Ontario code or permit change, a product or method that replaced what the thread recommends, a seasonal angle for this month, a Canadian angle for a thread that only talks about the US/UK. A "still relevant" reply is NOT an update.
            Sources available (ids):
            #{Sources.index_text}

            Reply with ONLY JSON: {"update": true|false, "why": "<one sentence>", "sources": ["1-3 ids"], "angle": "<the update in one sentence>"}
          TXT
          decision = Ai.chat(system: "You edit a home renovation forum. JSON only.", user: decide_prompt, max_tokens: 300, json: true, temperature: 0.2)
          unless decision.is_a?(Hash) && decision["update"] == true
            out << { topic_id: topic.id, title: topic.title, skipped: decision.is_a?(Hash) ? decision["why"].to_s[0, 120] : "no decision" }
            next
          end
          sources_text, used = excerpts_for(decision["sources"], "#{topic.title} #{decision['angle']}")
          if sources_text.blank?
            out << { topic_id: topic.id, title: topic.title, skipped: "no sources" }
            next
          end
          write_prompt = <<~TXT
            Post an update to this thread as the crew.

            #{transcript}

            The update: #{decision['angle']}

            SOURCE EXCERPTS (the only facts and figures you may use; name the source in the sentence):
            #{sources_text}

            120-250 words. Open with the update itself in the first sentence (no "2026 update:" label, no greeting). Then what changed the answer, then one concrete question back to the thread. Plain prose, at most one short list of 4 items. No sign-off.
          TXT
          raw = compose(system: VOICE, user: write_prompt, sources_text: sources_text, min_words: 100, max_words: 300, max_tokens: 700)
          if raw.nil?
            out << { topic_id: topic.id, title: topic.title, skipped: "draft failed guard" }
            next
          end
          res = Forum.reply!(topic, raw)
          out << { topic_id: topic.id, title: topic.title, posted: res[:url].present?, sources: used.map(&:url) }.merge(res)
        end
        out
      end
    end
  end
end
