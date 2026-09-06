# frozen_string_literal: true
# v0.9.0 — GET /shorts/shirt-feed.json: the Shirt Lab carousel feed the HrrShirtFeed
# job keeps in PluginStore. Public, cacheable, same shape as the theme setting.
module DiscourseShorts
  class ShirtFeedController < ::ApplicationController
    requires_plugin ::DiscourseShorts::PLUGIN_NAME
    skip_before_action :check_xhr
    skip_before_action :redirect_to_login_if_required, raise: false
    skip_before_action :preload_json, raise: false

    def show
      feed = ::DiscourseShorts::Desk::ShirtLab.feed || { "updated" => nil, "items" => [] }
      expires_in 30.minutes, public: true
      render json: feed
    end
  end
end
