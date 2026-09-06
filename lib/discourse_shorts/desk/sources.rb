# frozen_string_literal: true
# v0.9.0 — what the desk is allowed to cite. Sidekiq has no web search, so the
# honesty rule ("only state facts you read this run, name the source") is kept a
# different way: every figure the model may use comes from a fixed pack of
# authoritative Ontario / GTA / federal pages that were verified to resolve on
# 2026-09-06, fetched live at write time, and the draft is checked afterwards so
# that no dollar or percentage figure survives unless it appears in a fetched
# source (see Writer.number_check). Headlines come from three Toronto RSS feeds.
module DiscourseShorts
  module Desk
    module Sources
      Source = Struct.new(:id, :url, :label, :topics, keyword_init: true)

      PACK = [
        Source.new(id: "to-permit", url: "https://www.toronto.ca/services-payments/building-construction/apply-for-a-building-permit/",
                   label: "City of Toronto — Apply for a building permit", topics: %w[permit toronto basement deck addition garage renovation plans inspection]),
        Source.new(id: "to-permit-fees", url: "https://www.toronto.ca/services-payments/building-construction/apply-for-a-building-permit/building-permit-fees/",
                   label: "City of Toronto — Building permit fees", topics: %w[permit fee cost toronto basement deck addition]),
        Source.new(id: "to-flooding", url: "https://www.toronto.ca/services-payments/water-environment/how-to-use-less-water/basement-flooding/",
                   label: "City of Toronto — Basement flooding", topics: %w[flood flooding basement sump sewer backwater storm water rain]),
        Source.new(id: "to-flood-subsidy", url: "https://www.toronto.ca/services-payments/water-environment/how-to-use-less-water/basement-flooding/basement-flooding-protection-subsidy-program/",
                   label: "City of Toronto — Basement Flooding Protection Subsidy Program", topics: %w[flood flooding basement sump backwater subsidy rebate pump]),
        Source.new(id: "on-obc", url: "https://www.ontario.ca/page/ontarios-building-code",
                   label: "Ontario.ca — Ontario's Building Code", topics: %w[code permit structural stairs railing egress window insulation basement deck bedroom]),
        Source.new(id: "on-consumer", url: "https://www.ontario.ca/page/consumer-protection-ontario",
                   label: "Ontario.ca — Consumer Protection Ontario", topics: %w[contractor contract deposit scam dispute cancel consumer]),
        Source.new(id: "on-seniors-credit", url: "https://www.ontario.ca/page/seniors-home-safety-tax-credit",
                   label: "Ontario.ca — Seniors' Home Safety Tax Credit", topics: %w[senior accessibility tax credit grab bar ramp stairlift walk-in]),
        Source.new(id: "tarion", url: "https://www.tarion.com/homeowners",
                   label: "Tarion — Homeowners (new home warranty)", topics: %w[tarion warranty new build builder condo pre-construction]),
        Source.new(id: "hcra", url: "https://www.hcraontario.ca/",
                   label: "Home Construction Regulatory Authority (Ontario)", topics: %w[builder licence licensed new build tarion hcra]),
        Source.new(id: "esa", url: "https://esasafe.com/",
                   label: "Electrical Safety Authority (Ontario)", topics: %w[electrical panel wiring outlet esa licensed electrician ev charger knob tube aluminum]),
        Source.new(id: "tssa", url: "https://www.tssa.org/en/index.aspx",
                   label: "Technical Standards and Safety Authority (Ontario)", topics: %w[gas furnace fireplace water heater boiler tssa propane bbq]),
        Source.new(id: "radon", url: "https://www.canada.ca/en/health-canada/services/health-risks-safety/radiation/radon.html",
                   label: "Health Canada — Radon", topics: %w[radon basement air test mitigation]),
        Source.new(id: "cra-accessibility", url: "https://www.canada.ca/en/revenue-agency/services/tax/individuals/topics/about-your-tax-return/tax-return/completing-a-tax-return/deductions-credits-expenses/line-31285-home-accessibility-expenses.html",
                   label: "CRA — Home accessibility expenses (line 31285)", topics: %w[tax credit accessibility senior disability ramp bathroom]),
        Source.new(id: "hrs", url: "https://www.homerenovationsavings.ca/",
                   label: "Home Renovation Savings Program (Enbridge / IESO)", topics: %w[rebate heat pump insulation windows attic air sealing energy audit furnace smart thermostat]),
        Source.new(id: "enbridge-rebates", url: "https://www.enbridgegas.com/residential/rebates-energy-conservation",
                   label: "Enbridge Gas — Residential rebates", topics: %w[rebate heat pump insulation attic furnace water heater energy gas]),
        Source.new(id: "enbridge-rates", url: "https://www.enbridgegas.com/residential/my-account/rates",
                   label: "Enbridge Gas — Residential rates", topics: %w[gas bill rate furnace heating cost]),
        Source.new(id: "th-rates", url: "https://www.torontohydro.com/for-home/rates",
                   label: "Toronto Hydro — Residential rates", topics: %w[hydro electricity bill rate time-of-use heat pump ev charger baseboard]),
        Source.new(id: "oeb-rates", url: "https://www.oeb.ca/consumer-information-and-protection/electricity-rates",
                   label: "Ontario Energy Board — Electricity rates", topics: %w[hydro electricity rate bill time-of-use ultra-low]),
        Source.new(id: "ibc-home", url: "https://www.ibc.ca/insurance-basics/home/home-insurance-coverage-basics",
                   label: "Insurance Bureau of Canada — Home insurance coverage basics", topics: %w[insurance claim flood sewer backup water damage roof storm coverage]),
        Source.new(id: "cmhc-mli", url: "https://www.cmhc-schl.gc.ca/consumers/home-buying/mortgage-loan-insurance-for-consumers",
                   label: "CMHC — Mortgage loan insurance", topics: %w[mortgage cmhc financing refinance renovation loan]),
        Source.new(id: "wsib-clearance", url: "https://www.wsib.ca/en/clearances",
                   label: "WSIB — Clearance certificates", topics: %w[contractor wsib clearance liability hire insurance crew]),
        Source.new(id: "miss-building", url: "https://www.mississauga.ca/services-and-programs/building-and-renovating/",
                   label: "City of Mississauga — Building and renovating", topics: %w[mississauga permit basement deck addition]),
        Source.new(id: "bram-permits", url: "https://www.brampton.ca/EN/residents/Building-Permits/Pages/Welcome.aspx",
                   label: "City of Brampton — Building permits", topics: %w[brampton permit basement second unit deck]),
      ].freeze

      FEEDS = [
        ["Global News Toronto", "https://globalnews.ca/toronto/feed/"],
        ["CityNews Toronto", "https://toronto.citynews.ca/feed/"],
        ["Toronto Star GTA", "https://www.thestar.com/search/?f=rss&t=article&c=news/gta*&l=50"],
      ].freeze

      HOME_WORDS = /\b(home|house|homeowner|renovat|basement|roof|flood|storm|permit|condo|contractor|hydro|heat|furnace|insulat|mortgage|housing|rent|tenant|landlord|property|construction|build|sewer|water|snow|winter|gutter|eavestrough|window|door|kitchen|bathroom|deck|fence|tree|power outage|rebate|tax)/i

      def self.find(id)
        PACK.find { |s| s.id == id || s.url == id }
      end

      # One-line index the model chooses from (ids + labels only, no text).
      def self.index_text
        PACK.map { |s| "#{s.id}: #{s.label}" }.join("\n")
      end

      # Sources whose topic words overlap the text, best first.
      def self.match(text, limit: 4)
        words = text.to_s.downcase.scan(/[a-z][a-z\-]{2,}/)
        scored = PACK.map do |s|
          score = s.topics.count { |t| words.any? { |w| w.start_with?(t) || t.start_with?(w) } }
          [score, s]
        end
        scored.select { |sc, _| sc > 0 }.sort_by { |sc, _| -sc }.first(limit).map(&:last)
      end

      # Fetch a source and return an excerpt built around the query words (so the
      # figures the model needs are inside the window we send it).
      def self.excerpt(source, query, max_chars: 2600)
        cached = PluginStore.get(Ai::STORE, "src-#{source.id}")
        text = nil
        if cached.is_a?(Hash) && cached["at"].to_i > 6.hours.ago.to_i
          text = cached["text"]
        else
          code, body = Http.get(source.url, timeout: 25)
          if code == 200 && body.length > 500
            text = Http.text_of(body)[0, 60_000]
            PluginStore.set(Ai::STORE, "src-#{source.id}", { "at" => Time.now.to_i, "text" => text })
          end
        end
        return nil if text.blank?
        window(text, query, max_chars)
      end

      def self.window(text, query, max_chars)
        words = query.to_s.downcase.scan(/[a-z][a-z\-]{3,}/).uniq.first(12)
        return text[0, max_chars] if words.empty?
        best_at, best_score = 0, -1
        step = [max_chars / 2, 400].max
        (0...text.length).step(step) do |i|
          chunk = text[i, max_chars].downcase
          score = words.sum { |w| chunk.scan(w).length } + chunk.scan(/\$\s?\d/).length
          if score > best_score
            best_score, best_at = score, i
          end
        end
        text[best_at, max_chars]
      end

      # Recent Toronto headlines (title + date), home-related ones first.
      def self.headlines(limit: 14)
        items = []
        FEEDS.each do |name, url|
          code, body = Http.get(url, timeout: 20)
          next unless code == 200
          body.scan(%r{<item>(.*?)</item>}m).each do |(item)|
            title = item[%r{<title>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>}m, 1].to_s.strip
            date = item[%r{<pubDate>(.*?)</pubDate>}m, 1].to_s.strip
            next if title.blank?
            items << { source: name, title: CGI.unescapeHTML(CGI.unescapeHTML(title))[0, 140], date: date[0, 25], home: !!(title =~ HOME_WORDS) }
          end
        end
        items.uniq { |i| i[:title] }.sort_by { |i| i[:home] ? 0 : 1 }.first(limit)
      rescue StandardError => e
        Rails.logger.warn("[hrr-desk] headlines failed: #{e.message}")
        []
      end

      def self.headlines_text(limit: 14)
        headlines(limit: limit).map { |h| "- #{h[:title]} (#{h[:source]}, #{h[:date]})" }.join("\n")
      end
    end
  end
end
