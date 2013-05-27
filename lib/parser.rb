#!/usr/bin/env ruby

require 'fileutils'
require 'logger'
require 'optparse'
require 'sinatra/base'
require 'yaml'

INFINITY = 1/0.0

module STAC

# Return a string to prefix action display: "clock : user / scenario"
  def self.act_prefix(clock, state)
    u = state[:ac_user_num] ? ("u%03u" % state[:ac_user_num]) : "uuuu"
    s = state[:ac_scen_num] ? ("s%02u" % state[:ac_scen_num]) : "sss"
    ("%04u" % clock) + ":#{u}/#{s}"
  end

  class StressTestAC < Sinatra::Base

    VERSION        = 0.007
    INFO_STRING    = "Stress Tester for AppCloud (version #{VERSION})"
    DEFAULT_CONFIG = '../config/stac2.yml'
    WORKER_THREADS = 16

    attr_accessor :logger

    class << self

      def int_option(name, opt)
        begin
          i = Integer(opt)
          return i if i >= 0
        rescue
        end
        puts "FATAL: option \'--#{name}\' requires positive integer value, found \'#{opt}\'"
        exit!
      end

      def flt_option(name, opt)
        begin
          f = Float(opt)
          return f if f >= 0
        rescue
        end
        puts "FATAL: option \'--#{name}\' requires positive float value, found \'#{opt}\'"
        exit!
      end

      def parse_options_and_config
        return @config if @config

        # The following values can be changed via the command line
        config_file   = File.join(File.dirname(__FILE__), DEFAULT_CONFIG)
        log_file      = nil
        status_port   = nil
        thin_logging  = nil
        log_level     = nil
        dry_run_plan  = nil
        max_runtime   = nil
        clock_jitter  = nil
        ac_admin_user = nil
        ac_admin_pass = nil
        no_http_uses  = nil
        time_scaling  = nil
        thread_count  = nil
        update_freq   = nil
        unique_stacid = nil
        equalize_sctm = nil
        stagger_scen  = nil
        log_rsrc_use  = nil
        nats_server   = nil
        pause_at_end  = nil
        log_end_stat  = nil
        http_url      = nil
        health_intvl  = 0
        more_defiles  = []
        more_defdirs  = []
        run_this_mix  = []
        
        end_user_sum  = nil
        think_time    = nil
        http_duration = nil

        # Parse any command-line options
        options = OptionParser.new do |opts|

          opts.banner = 'Usage: stac [OPTIONS] ac_address'

          opts.on("-c", "--config FILE", "Configuration File") do |opt|
            config_file = opt
          end

          opts.on("-l", "--logfile FILE", "Log file (default=stdout)") do |opt|
            log_file = opt
          end

          opts.on("-L", "--log_level LVL", "Logging level") do |opt|
            log_level = opt
          end

          opts.on("-d", "--duration SECS", "Cap running time (seconds)") do |opt|
            max_runtime = int_option("max_runtime", opt)
          end

          opts.on("-f", "--defile FILE", "Add definition file") do |opt|
            more_defiles << opt
          end

          opts.on("-i", "--identifier UNIQUE_ID", "Set user/app name prefix to allow multiple STAC's to coexist") do |opt|
            unique_stacid = opt
          end

          opts.on("-j", "--clock_jitter PCT", "Set clock jitter in percent (0..100)") do |opt|
            clock_jitter = int_option("clock_jitter", opt)
          end

          opts.on("-w", "--update_freq SECS", "Time between warm'n'fuzzy updates in seconds") do |opt|
            update_freq  = flt_option("update_freq", opt)
          end

          opts.on("-m", "--max_runtime SECS", "Cap running time (seconds)") do |opt|
            max_runtime = int_option("max_runtime", opt)
          end

          opts.on("-n", "--new_def_dir PATH", "Add definition directory") do |opt|
            more_defdirs << opt
          end

          opts.on("-p", "--port PORTNUM", "Change status port number") do |opt|
            status_port = int_option("port", opt)
          end

          opts.on("-t", "--thin_logging", "Enable Thin logging") do |opt|
            thin_logging = true
          end

          opts.on("-u", "--dry_run", "Pretend to execute test plan.") do |opt|
            dry_run_plan = true
          end

          opts.on("-v", "--verbose", "Display extra detail (mostly for debugging)") do |opt|
            $verbose = true
          end

          opts.on("-q", "--quiet", "Minimal console output") do |opt|
            $bequiet = true
          end

          opts.on("-n", "--newgen", "Use newgen CLI interfaces") do |opt|
            $newgen = true
          end

          opts.on("-x", "--extra_detail", "Log more detail about app crashes and such") do |opt|
            $xdetail = true
          end

          opts.on("-s", "--equalize_scen_time", "Equalize scenario running time") do |opt|
            equalize_sctm = true
          end

          opts.on("-S", "--stagger_scen", "Stagger scenarios") do |opt|
            stagger_scen = true
          end

          opts.on("-e", "--pause_at_end", "Pause before cleanup to enable inspection") do |opt|
            pause_at_end = true
          end

          opts.on("-k", "--log_end_stat", "Log detailed ending state of the system") do |opt|
            log_end_stat = true
          end

          opts.on("-r", "--run_mix MIXNAME", "Run specified test mix") do |opt|
            run_this_mix << opt
          end

          opts.on("--ac_admin_user USERNAME", "Set AppCloud admin user login") do |opt|
            ac_admin_user = opt
          end

          opts.on("--ac_admin_pass PASSWORD", "Set AppCloud admin user password") do |opt|
            ac_admin_pass = opt
          end

          opts.on("--time-scale SCALE", "Scale all time duration values") do |opt|
            time_scaling = flt_option("scale", opt)
          end

          opts.on("--thread-count NUM", "Number of executor threads") do |opt|
            thread_count = int_option("thread-count", opt)
          end

          opts.on("--no_http_uses", "Don't issue HTTP use actions") do |opt|
            no_http_uses = opt
          end

          opts.on("--nats_server HOST", "Specify user:pass@host:port of nats server") do |opt|
            nats_server = opt
          end

          opts.on("--health_intvl SECS", "How often to log health stats (0=disabled)") do |opt|
            health_intvl = int_option("health_intvl", opt)
          end

          opts.on("--url URL", "Add a URL for simply testing") do |url|
            http_url = url
          end

          opts.on("-U", "--log_resource_use SECS", "Log our resource usage with given frequency") do |opt|
            log_rsrc_use = int_option("log_resource_use", opt)
          end

          opts.on("--url URL", "Add a URL for simply testing") do |opt|
            http_url = opt
          end

          opts.on("--end-user count", "End User count for Http Request") do |opt|
            end_user_sum = opt
          end

          opts.on("--think-time SECS", "Set the thinking time for Http Request") do |opt|
            think_time = opt
          end

          opts.on("--http-duration SECS", "Set the Http Duration, the default is INFINITY but controlled by max_runtime") do |opt|
            http_duration = opt
          end

          opts.on("-h", "--help", "Help") do
            puts opts
            exit
          end
        end
        options.parse!(ARGV)

        # We should have one argument at this point - the target AC
        # Commented out following code because I don't think it's must-have
        #if ARGV.length != 1
        #  puts "FATAL: expected one argument (URL for target AC) but found #{ARGV.length}"
        #  exit
        #end

        # Load the config file
        begin
          @config = File.open(config_file) do |f|
            YAML.load(f)
          end
        rescue => e
          puts "Could not read configuration file:  #{e}"
          exit
        end

        # Save any command line overrides in @config
        @config['status_port'  ] = status_port   if status_port
        @config['thin_logging' ] = thin_logging  if thin_logging
        @config['log_file'     ] = log_file      if log_file
        @config['what_to_run'  ] = run_this_mix  if run_this_mix.length > 0
        @config['log_level'    ] = log_level     if log_level
        @config['max_runtime'  ] = max_runtime   if max_runtime
        @config['clock_jitter' ] = clock_jitter  if clock_jitter
        @config['dry_run_plan' ] = dry_run_plan  if dry_run_plan
        @config['ac_admin_user'] = ac_admin_user if ac_admin_user
        @config['ac_admin_pass'] = ac_admin_pass if ac_admin_pass
        @config['no_http_uses' ] = no_http_uses  if no_http_uses
        @config['time_scaling' ] = time_scaling  if time_scaling
        @config['thread_count' ] = thread_count  if thread_count
        @config['update_freq'  ] = update_freq   if update_freq
        @config['unique_stacid'] = unique_stacid if unique_stacid
        @config['equalize_sctm'] = equalize_sctm if equalize_sctm
        @config['stagger_scen' ] = stagger_scen  if stagger_scen
        @config['nats_server'  ] = nats_server   if nats_server
        @config['health_intvl' ] = health_intvl  if health_intvl
        @config['http_url' ]     = http_url      if http_url
        @config['log_rsrc_use' ] = log_rsrc_use  if log_rsrc_use
        @config['pause_at_end' ] = pause_at_end  if pause_at_end
        @config['log_end_stat' ] = log_end_stat  if log_end_stat
        @config['seed' ]         = SeedManager.get_seed
        @config[:end_user_sum  ] = end_user_sum  if end_user_sum
        @config[:think_time    ] = think_time    if think_time
        @config[:http_duration ] = http_duration if http_duration

        # Can't log health info without a nats server
        if @config['health_intvl'] > 0 and not @config['nats_server']
          puts "WARNING: health logging disabled without 'nats' server"
          @config['health_intvl'] = 0
        end

        # Pull in the new client stuff only if necessary
        require '../vmc/lib/vmc/client' if $newgen

        # Stash the target URL in the config hash as well
        @config[:target_AC] = ARGV[0] ? ARGV[0] : @config['target_AC'] 
        
        # e.g, convert api.vcap.me to vcap.me
        targetArrayTemp = @config[:target_AC].split('.')
        targetArrayTemp.shift
        @config[:apps_URI] = targetArrayTemp.join('.')

        # Load any definitions from given directories and individual files
        if more_defdirs.length > 0
          load_defdirs = @config['def_dirs'] || []
          @config['def_dirs' ] = load_defdirs + more_defdirs
        end

        if more_defiles.length > 0
          load_defiles = @config['def_files'] || []
          @config['def_files'] = load_defiles + more_defiles
        end

        return @config
      end # method parse_options_and_config

    end # class << self

    def initialize
      super
      @logger = @@logger
    end

    configure do

      @config = nil

      # Grab the configuration (and parse command-line options if necessary)
      config = StressTestAC.parse_options_and_config

      # Initialize logger - either with a file or STDOUT
      log_file = config['log_file']
      log_file = STDOUT unless log_file and log_file != "" and log_file != "STDOUT"
      @@logger = Logger.new(log_file)

      # Set logging level
      @@logger.level = case config['log_level']
        when 'DEBUG' then Logger::DEBUG
        when 'INFO'  then Logger::INFO
        when 'WARN'  then Logger::WARN
        when 'ERROR' then Logger::ERROR
        when 'FATAL' then Logger::FATAL
        when nil     then Logger::UNKNOWN
        else
          puts "FATAL: invalid logging level value #{config['log_level']}"
          exit
      end

      #TestDef_Base.set_logger(@@logger)

      # Set the clock jitter value (if present)
      ActionQueue.set_logger(@@logger)
      ActionQueue.set_jitter(@config['clock_jitter']) if @config['clock_jitter']

      # Create pidfile (and ensure we delete it when done)
      pidfile = config['pid']
      begin
        begin
          FileUtils.mkdir_p(File.dirname(pidfile))
        rescue => e
          logger.fatal "Can't create pid directory, exiting: #{e}"
        end
        File.open(pidfile, 'w') { |f| f.puts "#{Process.pid}" }

        # This is just a hack
        local_ip = "127.0.0.1"

        # Set a bunch of values in our instance
        sinatra_keys = {
          :logger => @@logger,
          :local_host => "#{local_ip}:#{config['status_port']}",
          :port => config['status_port'],
          :logging => false,
          :proxy => config['proxy'],
          :no_proxy => config['no_proxy'],
        }
        sinatra_keys.each {|k,v| StressTestAC.set(k, v) }

        # Announce we are starting up
        logger.info("Starting #{INFO_STRING}")
        logger.debug("PID: #{Process.pid}")

        # Create an instance of the test runner class
        runner = StressTestRunner.new(config, logger)

        exit_proc = proc do
          logger.info("AC Stress Tester exiting..")
          runner.abort_test
        end

        stop_proc = proc do
          exit_proc.call
          exit
        end

        ['TERM', 'INT'].each { |sig| trap(sig, stop_proc) }

        # Start EM Thread
        Thread.new do
          EM.threadpool_size = WORKER_THREADS
          logger.debug("Using #{EM.threadpool_size} worker threads")

          EM.error_handler do |err|
            logger.error "Eventmachine problem, #{err}"
            logger.error("#{err.backtrace.join("\n")}")
          end
        end

        # This doesn't really belong here, but for now ...
        runner.run_test

        exit_proc.call
      ensure
        FileUtils.rm_f(pidfile) if pidfile
      end

    end # configure do .. end

    get '/' do
      INFO_STRING
    end

  end # class StressTestAC
end
