# frozen_string_literal: true

require 'metriks/time_tracker'
require 'net/https'

module Metriks
  class LibratoMetricsReporter
    attr_accessor :prefix, :source, :data

    def initialize(email, token, options = {})
      @email = email
      @token = token

      @prefix = options[:prefix]
      @source = options[:source]

      @registry     = options[:registry] || Metriks::Registry.default
      @interval     = options[:interval] || 60
      @time_tracker = Metriks::TimeTracker.new(@interval)
      @on_error     = options[:on_error] || proc { |ex| }
      @sanitizer    = options[:sanitize] || proc { |key| key.to_s.gsub(/ +/, '_') }
      @timeout      = options[:timeout]  || 10

      @data = {}
      @sent = {}

      @last = Hash.new { |h, k| h[k] = 0 }

      @percentiles = options[:percentiles] || [0.95, 0.999]

      @mutex = Mutex.new
      @running = false
    end

    def start
      return if @thread&.alive?

      @running = true
      @thread = Thread.new do
        while @running
          @time_tracker.sleep

          Thread.new do
            flush
          end
        end
      end
    end

    def stop
      @running = false

      return unless @thread

      @thread.join
      @thread = nil
    end

    def restart
      stop
      start
    end

    def flush
      @mutex.synchronize do
        write
      end
    rescue Exception => e
      begin
        @on_error[e]
      rescue StandardError
        nil
      end
    end

    def submit
      return if @data.empty?

      url = URI.parse('https://metrics-api.librato.com/v1/metrics')
      req = Net::HTTP::Post.new(url.path)
      req.basic_auth(@email, @token)
      req.set_form_data(@data)

      store = OpenSSL::X509::Store.new
      store.set_default_paths

      http              = Net::HTTP.new(url.host, url.port)
      http.verify_mode  = OpenSSL::SSL::VERIFY_PEER
      http.use_ssl      = true
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      http.cert_store   = store

      case res = http.start { |conn| conn.request(req) }
      when Net::HTTPSuccess, Net::HTTPRedirection
        # OK
      else
        raise RequestFailedError.new(req, res, @data.dup)
      end
    ensure
      @data.clear
    end

    def write
      time = @time_tracker.now_floored

      @registry.each do |name, metric|
        next if name.nil? || name.empty?

        name = sanitize_name(name)

        case metric
        when Metriks::Meter
          count = metric.count
          datapoint(name, count - @last[name], time, display_min: 0,
                                                     summarize_function: 'sum')
          @last[name] = count
        when Metriks::Counter
          datapoint(name, metric.count, time, summarize_function: 'average')
        when Metriks::Gauge
          datapoint(name, metric.value, time, summarize_function: 'average')
        when Metriks::Histogram, Metriks::HdrHistogram, Metriks::Timer, Metriks::UtilizationTimer
          if metric.is_a?(Metriks::UtilizationTimer) || metric.is_a?(Metriks::Timer)
            count = metric.count
            datapoint(name, count - @last[name], time, display_min: 0,
                                                       summarize_function: 'sum')
            @last[name] = count
          end

          if metric.is_a?(Metriks::UtilizationTimer)
            datapoint("#{name}.one_minute_utilization",
                      metric.one_minute_utilization, time,
                      display_min: 0, summarize_function: 'average')
          end

          snapshot = metric.snapshot

          datapoint("#{name}.median", snapshot.median, time, display_min: 0,
                                                             summarize_function: 'average')

          @percentiles.each do |percentile|
            percentile_name = (percentile * 100).to_f.to_s.gsub(/0+$/, '').gsub('.', '')
            datapoint("#{name}.#{percentile_name}th_percentile",
                      snapshot.value(percentile), time, display_min: 0,
                                                        summarize_function: 'max')
          end

          metric.flush_histogram if metric.respond_to?(:flush_histogram)
        end
      end

      return unless @data.length.positive?

      submit
    end

    def datapoint(name, value, time, attributes = {})
      idx = @data.length

      name = "#{prefix}.#{name}" if prefix

      @data["gauges[#{idx}][name]"]         = name
      @data["gauges[#{idx}][measure_time]"] = time.to_i
      @data["gauges[#{idx}][value]"]        = value

      @data["gauges[#{idx}][source]"] = @source unless @source.to_s.empty?

      return if @sent[name]

      @sent[name] = true

      @data["gauges[#{idx}][period]"] = @interval
      @data["gauges[#{idx}][attributes][aggregate]"] = true

      attributes.each do |k, v|
        @data["gauges[#{idx}][attributes][#{k}]"] = v
      end
    end

    def sanitize_name(name)
      case @sanitizer
      when String
        return name.gsub(/[^.:_\-0-9a-zA-Z]/, @sanitizer)[0...255]
      when Proc
        sanitized = @sanitizer.call(name)
      else
        raise 'The :sanitize option must be a replacement ' \
          'string or a Proc that will be passed the metric name to sanitize.'
      end

      if sanitized.size > 255 || sanitized =~ /[^.:_\-0-9a-zA-Z]/
        raise InvalidKeyError, 'Librato metric names must match ' \
          "/[.:_\-0-9a-zA-Z]+/, and must be less than 255 characters."
      else
        sanitized
      end
    end

    class InvalidKeyError < StandardError; end

    class RequestFailedError < StandardError
      attr_reader :req, :res, :data

      def initialize(req, res, data = nil)
        @req = req
        @res = res
        @data = data
        super
      end

      def to_s
        "#{res.code}  #{res.message.dump}"
      end
    end
  end
end
