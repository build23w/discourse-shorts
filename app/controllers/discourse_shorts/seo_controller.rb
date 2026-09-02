# frozen_string_literal: true
# v0.7.0 — the indexable face of the shorts library.
#
# Until now the only server-rendered page per short was an OpenGraph stub that
# 302'd humans into the app and showed crawlers a spinner, and nothing linked to
# the shorts from crawlable HTML — so 400 videos were invisible to Google.
# This controller serves the SAME content to everyone (no UA branching, no
# cloaking surface):
#   GET /shorts/v/:video_id   — a landing page per short: inline player, title,
#                               creator, VideoObject JSON-LD, related shorts,
#                               links into the app viewer / discussion / browse
#   GET /shorts/browse        — a plain HTML index of every approved short,
#                               grouped by trade, linking to the landing pages
#   GET /shorts/sitemap.xml   — a Google video sitemap of the same pages
# Discourse's CSP forbids inline <script>, so these pages carry no JS at all;
# inline <style> is allowed and is all they need.
module DiscourseShorts
  class SeoController < ::ApplicationController
    requires_plugin ::DiscourseShorts::PLUGIN_NAME
    skip_before_action :check_xhr
    skip_before_action :redirect_to_login_if_required, raise: false
    skip_before_action :preload_json, raise: false

    RELATED_N = 8
    SITEMAP_MAX = 2000

    def landing
      s = Short.find_by(video_id: params[:video_id]) or raise Discourse::NotFound
      raise Discourse::NotFound unless s.status == "approved"
      base = Discourse.base_url
      e = ->(x) { ERB::Util.html_escape(x.to_s) }

      title = (s.title.presence || "Renovation short").to_s[0, 120]
      owner = s.submitted_by_id ? ::User.find_by(id: s.submitted_by_id) : nil
      house = s.source == "owned" || (owner && owner.staff?)
      creator = house ? "LF Builders" : (owner ? "@#{owner.username}" : "the community")
      creator_url = owner ? "#{base}/u/#{ERB::Util.url_encode(owner.username)}" : "#{base}/watch"
      cat = s.try(:category).presence || (Journey.classify(title: s.title.to_s, tags: Array(s.tag_list)).first rescue "general")
      cat_label = Journey::AREA_LABELS[cat] || cat.to_s.tr("-", " ").capitalize
      tags = Array(s.tag_list).reject { |t| t.to_s.end_with?("-shorts") }.first(6)
      poster = Media.cdn(s.poster_url.presence) ||
               (s.provider == "youtube" ? "https://i.ytimg.com/vi/#{s.video_id}/hqdefault.jpg" : "#{base}/uploads/default/original/1X/logo.png")
      video_url = s.provider == "upload" ? Media.cdn(s.video_url) : nil
      embed_url = s.provider == "youtube" ? "https://www.youtube.com/embed/#{s.video_id}?playsinline=1&rel=0" : nil
      self_url = "#{base}/shorts/v/#{ERB::Util.url_encode(s.video_id)}"
      viewer = "#{base}/?short=#{ERB::Util.url_encode(s.video_id)}&utm_source=lf_short&utm_medium=landing"
      topic_url = s.topic_id.to_i > 0 ? "#{base}/t/#{s.topic_id}" : nil
      desc = "#{cat_label} short by #{creator} on Home Renovation Reviews, Canada's home renovation community. " \
             "Watch, react, and ask the trades who do this work every day."
      uploaded = (s.created_at || Time.zone.now).iso8601

      related = Short.where(status: "approved").where.not(id: s.id)
      related = related.where(category: cat) if s.respond_to?(:category) && cat.present?
      related = related.order(Arel.sql("(likes - dislikes) DESC, views DESC, id DESC")).limit(RELATED_N).to_a
      if related.length < 4
        more = Short.where(status: "approved").where.not(id: [s.id] + related.map(&:id)).order(views: :desc).limit(RELATED_N - related.length).to_a
        related += more
      end

      ld = {
        "@context" => "https://schema.org",
        "@type" => "VideoObject",
        "name" => title,
        "description" => desc,
        "thumbnailUrl" => [poster],
        "uploadDate" => uploaded,
        "url" => self_url,
        "publisher" => { "@type" => "Organization", "name" => "Home Renovation Reviews", "url" => base },
        "interactionStatistic" => [
          { "@type" => "InteractionCounter", "interactionType" => "https://schema.org/WatchAction", "userInteractionCount" => s.views.to_i },
          { "@type" => "InteractionCounter", "interactionType" => "https://schema.org/LikeAction", "userInteractionCount" => s.likes.to_i }
        ]
      }
      ld["contentUrl"] = video_url if video_url
      ld["embedUrl"] = embed_url if embed_url
      ld["author"] = { "@type" => house ? "Organization" : "Person", "name" => house ? "LF Builders" : (owner&.name.presence || owner&.username || "Community member"), "url" => creator_url }

      # v0.7.1 — feed-style landing: the share link IS a mini shorts feed.
      # Playlist = this short + related, embedded as JSON; a nonce'd script (CSP
      # placeholder, substituted by Discourse's middleware) swaps videos in place,
      # handles swipe/keys/wheel, tap-to-unmute, double-tap heart, auto-advance
      # and history.replaceState so every swipe is a real /shorts/v/ URL. With
      # JS blocked the page is still a complete, indexable video page.
      item = ->(x, own) {
        thumb = Media.cdn(x.poster_url.presence) || (x.provider == "youtube" ? "https://i.ytimg.com/vi/#{x.video_id}/hqdefault.jpg" : "")
        xcat = x.try(:category).presence || "general"
        {
          id: x.video_id, title: x.title.to_s[0, 120], poster: thumb,
          video: x.provider == "upload" ? Media.cdn(x.video_url) : nil,
          yt: x.provider == "youtube" ? x.video_id : nil,
          cat: (Journey::AREA_LABELS[xcat] || xcat.to_s.tr("-", " ").capitalize),
          by: own, views: x.views.to_i, likes: x.likes.to_i, comments: x.comment_count.to_i,
          topic: x.topic_id.to_i > 0 ? "#{base}/t/#{x.topic_id}" : nil,
          url: "#{base}/shorts/v/#{ERB::Util.url_encode(x.video_id)}"
        }
      }
      playlist = [item.call(s, creator)] + related.map { |r|
        ro = r.submitted_by_id ? ::User.find_by(id: r.submitted_by_id) : nil
        item.call(r, (r.source == "owned" || ro&.staff?) ? "LF Builders" : (ro ? "@#{ro.username}" : "the community"))
      }
      pl_json = playlist.to_json
      nonce = (::ContentSecurityPolicy.respond_to?(:nonce_placeholder) ? ::ContentSecurityPolicy.nonce_placeholder(response.headers) : nil) rescue nil

      player =
        if video_url
          %(<video id="v" class="pl" playsinline autoplay muted loop preload="auto" poster="#{e.call(poster)}" src="#{e.call(video_url)}" controls></video>)
        else
          %(<iframe id="yt" class="pl" src="#{e.call(embed_url)}&autoplay=1&mute=1" title="#{e.call(title)}" allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe>)
        end

      rel_html = related.map.with_index do |r, i|
        thumb = Media.cdn(r.poster_url.presence) || (r.provider == "youtube" ? "https://i.ytimg.com/vi/#{r.video_id}/hqdefault.jpg" : poster)
        %(<a class="rc" data-i="#{i + 1}" href="#{e.call("#{base}/shorts/v/#{ERB::Util.url_encode(r.video_id)}")}"><img loading="lazy" src="#{e.call(thumb)}" alt=""><span>#{e.call(r.title.to_s[0, 70])}</span></a>)
      end.join

      script = nonce ? <<~JS : ""
        <script nonce="#{nonce}">
        (function(){
          var PL=JSON.parse(document.getElementById('pl').textContent), i=0, watched=0, unmuted=false;
          var stage=document.getElementById('stage'), ttl=document.getElementById('ttl'), by=document.getElementById('by'), cat=document.getElementById('cat');
          var likes=document.getElementById('likes'), cmts=document.getElementById('cmts'), openA=document.getElementById('open'), cmtA=document.getElementById('cmt'), likeA=document.getElementById('like');
          var prog=document.getElementById('prog'), joinbar=document.getElementById('joinbar'), counter=document.getElementById('ctr');
          function appUrl(it,intent){ return '/?short='+encodeURIComponent(it.id)+'&utm_source=lf_short&utm_medium=landing'+(intent?'&intent='+intent:''); }
          function esc(s){ return String(s==null?'':s).replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;'); }
          function render(){
            var it=PL[i];
            if(it.video){ stage.innerHTML='<video id="v" class="pl" playsinline autoplay muted loop preload="auto" poster="'+esc(it.poster)+'" src="'+esc(it.video)+'"></video>'; var v=document.getElementById('v'); v.muted=!unmuted; v.play().catch(function(){}); v.addEventListener('timeupdate',function(){ if(v.duration) prog.style.width=(100*v.currentTime/v.duration)+'%'; }); v.addEventListener('ended',function(){}); }
            else { stage.innerHTML='<iframe id="yt" class="pl" src="https://www.youtube.com/embed/'+encodeURIComponent(it.yt)+'?playsinline=1&rel=0&autoplay=1&mute='+(unmuted?0:1)+'" allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe>'; prog.style.width='0'; }
            ttl.textContent=it.title; by.textContent=it.by; cat.textContent=it.cat; likes.textContent=it.likes; cmts.textContent=it.comments;
            openA.href=appUrl(it); likeA.href=appUrl(it,'like'); cmtA.href=it.topic||appUrl(it,'comment');
            counter.textContent=(i+1)+' / '+PL.length; document.title=it.title+' — Renovation Shorts';
            try{ history.replaceState(null,'',it.url); }catch(e){}
            document.querySelectorAll('.rc').forEach(function(a){ a.classList.toggle('on', a.getAttribute('data-i')==String(i)); });
            var nx=PL[i+1]; if(nx&&nx.poster){ var im=new Image(); im.src=nx.poster; }
            watched++; if(watched===3 && joinbar){ joinbar.hidden=false; }
          }
          function go(n){ if(n<0||n>=PL.length) return; i=n; render(); window.scrollTo(0,0); }
          document.getElementById('next').addEventListener('click',function(){ go(i+1); });
          document.getElementById('prev').addEventListener('click',function(){ go(i-1); });
          document.addEventListener('keydown',function(e){ if(e.key==='ArrowDown'||e.key==='ArrowRight'||e.key==='j'){ e.preventDefault(); go(i+1);} if(e.key==='ArrowUp'||e.key==='ArrowLeft'||e.key==='k'){ e.preventDefault(); go(i-1);} if(e.key==='m'){ toggleMute(); } });
          var sy=null; stage.addEventListener('touchstart',function(e){ sy=e.touches[0].clientY; },{passive:true});
          stage.addEventListener('touchend',function(e){ if(sy===null) return; var dy=e.changedTouches[0].clientY-sy; sy=null; if(dy<-60) go(i+1); else if(dy>60) go(i-1); },{passive:true});
          var wl=0; stage.addEventListener('wheel',function(e){ var t=Date.now(); if(t-wl<700) return; if(Math.abs(e.deltaY)>30){ wl=t; go(i+(e.deltaY>0?1:-1)); } },{passive:true});
          function toggleMute(){ var v=document.getElementById('v'); if(v){ v.muted=!v.muted; unmuted=!v.muted; mute.textContent=v.muted?'🔇':'🔊'; } }
          var mute=document.getElementById('mute'); mute.addEventListener('click',toggleMute);
          var lastTap=0; stage.addEventListener('click',function(e){ var t=Date.now(); var v=document.getElementById('v'); if(t-lastTap<300){ heart(e); lastTap=0; return; } lastTap=t; if(v){ if(!unmuted){ v.muted=false; unmuted=true; mute.textContent='🔊'; return; } v.paused?v.play():v.pause(); } });
          function heart(e){ var h=document.createElement('div'); h.className='heart'; h.textContent='▲'; h.style.left=(e.clientX-28)+'px'; h.style.top=(e.clientY-28)+'px'; document.body.appendChild(h); setTimeout(function(){ h.remove(); },900); setTimeout(function(){ location.href=likeA.href; },500); }
          document.querySelectorAll('.rc').forEach(function(a){ a.addEventListener('click',function(e){ var n=parseInt(a.getAttribute('data-i'),10); if(!isNaN(n)&&PL[n]){ e.preventDefault(); go(n); } }); });
          document.querySelectorAll('.rc').forEach(function(a){ a.classList.toggle('on', a.getAttribute('data-i')==='0'); });
          counter.textContent='1 / '+PL.length;
          (function(){ var v=document.getElementById('v'); if(v){ v.removeAttribute('controls'); v.addEventListener('timeupdate',function(){ if(v.duration) prog.style.width=(100*v.currentTime/v.duration)+'%'; }); } })();
          var nav=document.getElementById('share'); nav.addEventListener('click',function(e){ e.preventDefault(); var it=PL[i]; var d={title:it.title,text:'Watch this renovation short',url:it.url}; if(navigator.share){ navigator.share(d).catch(function(){}); } else if(navigator.clipboard){ navigator.clipboard.writeText(it.url); nav.textContent='Copied'; setTimeout(function(){ nav.innerHTML='⤴<b>Share</b>'; },1500); } });
        })();
        </script>
      JS

      html = <<~HTML
        <!DOCTYPE html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <title>#{e.call(title)} — Renovation Shorts | Home Renovation Reviews</title>
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="description" content="#{e.call(desc)}">
        <meta name="theme-color" content="#0b0f17">
        <link rel="canonical" href="#{e.call(self_url)}">
        <meta property="og:type" content="video.other">
        <meta property="og:site_name" content="Home Renovation Reviews">
        <meta property="og:title" content="#{e.call(title)}">
        <meta property="og:description" content="#{e.call(desc)}">
        <meta property="og:image" content="#{e.call(poster)}">
        <meta property="og:url" content="#{e.call(self_url)}">
        #{embed_url ? %(<meta property="og:video" content="#{e.call(embed_url)}"><meta property="og:video:type" content="text/html"><meta property="og:video:width" content="720"><meta property="og:video:height" content="1280">) : ""}
        #{video_url ? %(<meta property="og:video" content="#{e.call(video_url)}"><meta property="og:video:type" content="video/mp4"><meta property="og:video:width" content="720"><meta property="og:video:height" content="1280">) : ""}
        <meta name="twitter:card" content="summary_large_image">
        <meta name="twitter:title" content="#{e.call(title)}">
        <meta name="twitter:description" content="#{e.call(desc)}">
        <meta name="twitter:image" content="#{e.call(poster)}">
        <script type="application/ld+json">#{ld.to_json}</script>
        <style>
          :root{color-scheme:dark}
          *{box-sizing:border-box}
          html,body{margin:0;background:#0b0f17;color:#fff;font-family:system-ui,Segoe UI,Arial,sans-serif;line-height:1.35}
          a{color:#fff}
          .wrap{display:grid;grid-template-columns:minmax(0,1fr);min-height:100dvh}
          .feed{position:relative;height:100dvh;background:#000;overflow:hidden}
          #stage{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;cursor:pointer}
          .pl{width:100%;height:100%;border:0;display:block;object-fit:contain;background:#000}
          .brand{position:absolute;left:12px;top:calc(10px + env(safe-area-inset-top,0px));z-index:5;font-size:12px;white-space:nowrap;font-weight:900;letter-spacing:.02em;text-decoration:none;background:rgba(0,0,0,.55);padding:6px 10px;border:1px solid rgba(255,255,255,.18)}
          .brand .full{display:none}
          @media(min-width:520px){.brand .full{display:inline}.brand .short{display:none}}
          .browse{position:absolute;right:12px;top:calc(10px + env(safe-area-inset-top,0px));z-index:5;font-size:12px;font-weight:800;text-decoration:none;background:rgba(0,0,0,.55);padding:6px 10px;border:1px solid rgba(255,255,255,.18)}
          #mute{position:absolute;left:12px;top:calc(48px + env(safe-area-inset-top,0px));z-index:6;width:40px;height:40px;border:0;background:rgba(0,0,0,.55);color:#fff;font-size:18px;cursor:pointer}
          .meta{position:absolute;left:12px;right:84px;bottom:calc(18px + env(safe-area-inset-bottom,0px));z-index:5;text-shadow:0 1px 8px rgba(0,0,0,.8);pointer-events:none}
          .meta h1{font-size:17px;margin:0 0 4px;font-weight:800;line-height:1.25}
          .meta .sub{font-size:12.5px;opacity:.9}
          .meta .sub b{font-weight:800}
          .rail{position:absolute;right:8px;bottom:calc(24px + env(safe-area-inset-bottom,0px));z-index:6;display:flex;flex-direction:column;gap:10px;align-items:center}
          .rail a,.rail button{display:flex;flex-direction:column;align-items:center;justify-content:center;width:58px;height:54px;border:0;background:rgba(0,0,0,.55);color:#fff;text-decoration:none;font-size:20px;line-height:1;cursor:pointer;padding:0}
          .rail b{font-size:10.5px;font-weight:800;margin-top:3px;letter-spacing:.02em}
          .rail .app{background:#f0820c}
          .navbtns{position:absolute;left:8px;top:50%;transform:translateY(-50%);z-index:6;display:none;flex-direction:column;gap:8px}
          .navbtns button{width:44px;height:44px;border:1px solid rgba(255,255,255,.25);background:rgba(0,0,0,.55);color:#fff;font-size:20px;cursor:pointer}
          #prog{position:absolute;left:0;bottom:0;height:3px;width:0;background:#f0820c;z-index:7;transition:width .25s linear}
          #ctr{position:absolute;right:12px;top:calc(48px + env(safe-area-inset-top,0px));z-index:5;font-size:11px;font-weight:800;background:rgba(0,0,0,.55);padding:4px 8px}
          #joinbar{position:absolute;left:12px;right:84px;bottom:calc(120px + env(safe-area-inset-bottom,0px));z-index:6;background:#fff;color:#1c2b46;padding:10px 12px;font-size:13px;display:flex;gap:10px;align-items:center}
          #joinbar[hidden]{display:none}
          #joinbar a{background:#f0820c;color:#fff;text-decoration:none;font-weight:900;padding:8px 12px;white-space:nowrap}
          .heart{position:fixed;z-index:50;font-size:56px;color:#f0820c;pointer-events:none;animation:pop .9s ease-out forwards;text-shadow:0 2px 12px rgba(0,0,0,.6)}
          @keyframes pop{0%{transform:scale(.4);opacity:0}30%{transform:scale(1.2);opacity:1}100%{transform:scale(1) translateY(-60px);opacity:0}}
          .side{padding:18px 16px 40px;max-width:980px;margin:0 auto;width:100%}
          .side h2{font-size:15px;margin:18px 0 10px;color:#cfd6e0}
          .btn{display:inline-block;background:#f0820c;color:#fff;text-decoration:none;font-weight:800;padding:12px 18px;margin:0 8px 8px 0;font-size:14px}
          .btn.alt{background:transparent;border:1px solid rgba(255,255,255,.3)}
          .desc{font-size:14px;color:#cfd6e0;margin:10px 0 14px}
          .chips span{display:inline-block;border:1px solid rgba(255,255,255,.2);padding:3px 9px;font-size:12px;margin:0 6px 6px 0;text-transform:capitalize;color:#cfd6e0}
          .rel{display:grid;grid-template-columns:repeat(auto-fill,minmax(110px,1fr));gap:10px}
          .rc{display:block;text-decoration:none;color:#fff;font-size:12.5px;font-weight:600;border:2px solid transparent}
          .rc.on{border-color:#f0820c}
          .rc img{width:100%;aspect-ratio:9/16;object-fit:cover;background:#111;display:block;margin-bottom:5px}
          footer{max-width:980px;margin:0 auto;padding:0 16px 30px;font-size:12px;color:#8a94a6}
          footer a{color:#cfd6e0}
          @media(min-width:900px){
            .wrap{grid-template-columns:minmax(0,420px) 1fr;gap:26px;max-width:1180px;margin:0 auto;padding:22px 16px}
            .feed{height:min(78vh,760px);position:sticky;top:22px}
            .navbtns{display:flex}
            .side{padding:6px 0 40px}
            .meta h1{font-size:19px}
          }
        </style>
        </head><body>
        <div class="wrap">
          <div class="feed">
            <a class="brand" href="#{e.call(base)}/"><span class="short">HRR Shorts</span><span class="full">Home Renovation Reviews</span></a>
            <span id="ctr">1 / #{playlist.length}</span>
            <a class="browse" href="#{e.call(base)}/watch">Browse all</a>
            <div id="stage">#{player}</div>
            <button id="mute" type="button" aria-label="Sound on/off">🔇</button>
            <div class="meta"><h1 id="ttl">#{e.call(title)}</h1><div class="sub"><b id="by">#{e.call(creator)}</b> · <span id="cat">#{e.call(cat_label)}</span></div></div>
            <div class="rail">
              <a id="like" href="#{e.call(viewer)}&intent=like" title="Like (opens the app)">▲<b id="likes">#{s.likes.to_i}</b></a>
              <a id="cmt" href="#{e.call(topic_url || viewer)}" title="Comments">💬<b id="cmts">#{s.comment_count.to_i}</b></a>
              <a id="share" href="#{e.call(self_url)}" title="Share">⤴<b>Share</b></a>
              <a id="open" class="app" href="#{e.call(viewer)}" title="Open in the app">▶<b>App</b></a>
            </div>
            <div class="navbtns"><button id="prev" type="button" aria-label="Previous">↑</button><button id="next" type="button" aria-label="Next">↓</button></div>
            <div id="joinbar" hidden><span>Enjoying these? <b>Join free</b> to like, comment and post your own.</span><a href="#{e.call(base)}/signup?utm_source=lf_short&utm_medium=landing">Join</a></div>
            <div id="prog"></div>
          </div>
          <section class="side">
            <p><a class="btn" href="#{e.call(viewer)}">▶ Watch in the Shorts feed</a>#{topic_url ? %(<a class="btn alt" href="#{e.call(topic_url)}">Discussion (#{s.comment_count.to_i})</a>) : ""}</p>
            <p class="desc">#{e.call(desc)} Swipe or use ↑ ↓ to keep watching.</p>
            <div class="chips">#{tags.map { |t| "<span>#{e.call(t)}</span>" }.join}</div>
            <h2>Up next · more #{e.call(cat_label.downcase)} shorts</h2>
            <div class="rel">#{rel_html}</div>
            <p style="margin-top:18px"><a href="#{e.call(base)}/watch" style="color:#f0820c;font-weight:800">Browse every short by trade →</a></p>
          </section>
        </div>
        <footer>Short-form renovation videos from Canadian homeowners and trades. Free account · <a href="#{e.call(base)}/signup">join to upload your own</a>.</footer>
        <script type="application/json" id="pl">#{pl_json}</script>
        #{script}
        </body></html>
      HTML
      response.headers["Cache-Control"] = "public, max-age=300"
      render html: html.html_safe, content_type: "text/html", layout: false
    end

    def browse
      base = Discourse.base_url
      e = ->(x) { ERB::Util.html_escape(x.to_s) }
      rows = Short.where(status: "approved").order(Arel.sql("(likes - dislikes) DESC, views DESC, id DESC")).limit(SITEMAP_MAX).to_a
      groups = rows.group_by { |s| s.try(:category).presence || "general" }
      sections = groups.sort_by { |k, v| -v.length }.map do |cat, list|
        label = Journey::AREA_LABELS[cat] || cat.to_s.tr("-", " ").capitalize
        items = list.map do |s|
          thumb = Media.cdn(s.poster_url.presence) || (s.provider == "youtube" ? "https://i.ytimg.com/vi/#{s.video_id}/mqdefault.jpg" : "")
          %(<li><a href="#{e.call("#{base}/shorts/v/#{ERB::Util.url_encode(s.video_id)}")}">#{thumb.present? ? %(<img loading="lazy" src="#{e.call(thumb)}" alt="">) : ""}<span>#{e.call(s.title.to_s[0, 80])}</span></a></li>)
        end.join
        %(<section><h2 id="#{e.call(cat)}">#{e.call(label)} <small>#{list.length}</small></h2><ul>#{items}</ul></section>)
      end.join
      html = <<~HTML
        <!DOCTYPE html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <title>Renovation Shorts — #{rows.length} short videos by trade | Home Renovation Reviews</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="description" content="Browse #{rows.length} short renovation videos — kitchens, bathrooms, tiling, concrete, roofing and more — from Canadian homeowners and the trades on Home Renovation Reviews.">
        <link rel="canonical" href="#{e.call(base)}/shorts/browse">
        <style>
          body{margin:0;background:#f5f6f8;color:#1c2b46;font-family:system-ui,Segoe UI,Arial,sans-serif}
          .top{background:#fff;border-bottom:1px solid #e4e6ea;padding:12px 16px;font-weight:800}
          .top a{text-decoration:none;color:#1c2b46}
          main{max-width:1100px;margin:0 auto;padding:16px}
          h1{font-size:24px;margin:8px 0 4px} .lead{color:#556;margin:0 0 16px}
          h2{font-size:17px;margin:22px 0 8px} h2 small{color:#889;font-weight:600}
          ul{list-style:none;margin:0;padding:0;display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:10px}
          li a{display:block;text-decoration:none;color:#1c2b46;font-size:12.5px;font-weight:600}
          li img{width:100%;aspect-ratio:9/16;object-fit:cover;background:#111;display:block;margin-bottom:4px}
          .app{display:inline-block;background:#111;color:#fff;text-decoration:none;font-weight:800;padding:10px 16px;margin:6px 0 10px}
        </style>
        </head><body>
        <div class="top"><a href="#{e.call(base)}/">Home Renovation Reviews</a></div>
        <main>
          <h1>Renovation Shorts</h1>
          <p class="lead">#{rows.length} short videos from real renovations, grouped by trade. Tap any short for its page, or open the full-screen feed.</p>
          <a class="app" href="#{e.call(base)}/watch">▶ Open the Shorts feed</a>
          #{sections}
        </main>
        </body></html>
      HTML
      response.headers["Cache-Control"] = "public, max-age=900"
      render html: html.html_safe, content_type: "text/html", layout: false
    end

    def sitemap
      base = Discourse.base_url
      e = ->(x) { ERB::Util.html_escape(x.to_s) }
      rows = Short.where(status: "approved").order(id: :desc).limit(SITEMAP_MAX).to_a
      urls = rows.map do |s|
        loc = "#{base}/shorts/v/#{ERB::Util.url_encode(s.video_id)}"
        poster = Media.cdn(s.poster_url.presence) || (s.provider == "youtube" ? "https://i.ytimg.com/vi/#{s.video_id}/hqdefault.jpg" : nil)
        title = (s.title.presence || "Renovation short").to_s[0, 100]
        cat = s.try(:category).presence || "general"
        desc = "#{Journey::AREA_LABELS[cat] || cat} short on Home Renovation Reviews"
        media = s.provider == "upload" ? "<video:content_loc>#{e.call(Media.cdn(s.video_url))}</video:content_loc>" : "<video:player_loc>#{e.call("https://www.youtube.com/embed/#{s.video_id}")}</video:player_loc>"
        <<~URL
          <url><loc>#{e.call(loc)}</loc><lastmod>#{(s.updated_at || s.created_at || Time.zone.now).iso8601}</lastmod>
          <video:video>#{poster ? "<video:thumbnail_loc>#{e.call(poster)}</video:thumbnail_loc>" : ""}<video:title>#{e.call(title)}</video:title><video:description>#{e.call(desc)}</video:description>#{media}<video:publication_date>#{(s.created_at || Time.zone.now).iso8601}</video:publication_date><video:view_count>#{s.views.to_i}</video:view_count><video:family_friendly>yes</video:family_friendly></video:video></url>
        URL
      end.join
      xml = %(<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:video="http://www.google.com/schemas/sitemap-video/1.1">\n<url><loc>#{e.call(base)}/shorts/browse</loc></url>\n#{urls}</urlset>\n)
      response.headers["Cache-Control"] = "public, max-age=3600"
      render xml: xml
    end
  end
end
