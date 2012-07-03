require 'yajl'
require 'sinatra/base'
require 'sinatra/synchrony'
#require 'sinatra/reloader' if ENV['RACK_ENV'] == 'development'

%w[connection_pool graph params version].each { |file| require "batsd-dash/#{file}" }

module BatsdDash
  class App < Sinatra::Base
    #configure(:development) { register Sinatra::Reloader }

    configure do
      register Sinatra::Synchrony
      helpers ParamsHelper, GraphHelper, ConnectionHelpers

      set :haml, :format => :html5

      EM::Synchrony.next_tick { ConnectionPool::initialize_connection_pool }
    end

    helpers do
      def render_error(msg)
        render_json 400, error: msg
      end

      def render_json(code = 200, json)
        halt code, String === json ? json : Yajl::Encoder.encode(json)
      end
    end

    get "/" do
      haml :root
    end

    get "/version", :provides => :json do
      render_json version: BatsdDash::VERSION
    end

    get "/available", :provides => :json do
      connection_pool.async_available_list.callback do |json|
        render_json json
      end
    end

    %w[ counters timers gauges ].each do |datatype|
      # this route renders the template (with codes for the graph)
      get "/#{datatype}", :provides => :html do
        haml :view
      end

      # actual data API route
      get "/#{datatype}", :provides => :json do
        metrics = parse_metrics
        range = parse_time_range

        return render_error('Invalid time range') unless range
        return render_error('Invalid metrics') if metrics.empty?

        results = { range: range.dup.map! { |n| n * 1000 }, metrics: [] }
        collect_opts = { zero_fill: !params[:no_zero_fill], range: results[:range] }

        metrics.each do |metric|
          statistic = "#{datatype}:#{metric}"
          deferrable = connection_pool.async_values(statistic, range)

          deferrable.errback { |e| return render_error(e.message) }
          deferrable.callback do |json|
            values = json[statistic]

            # merge in interval if its not already; interval is always same
            collect_opts.merge!(interval: json['interval'] || 0) unless collect_opts.has_key?(:interval)
            # process values for graphing and add to results
            results[:metrics] << { label: metric, data: collect_for_graph(values, collect_opts) }
          end
        end

        cache_control :no_cache, :no_store
        render_json results
      end
    end
  end
end
