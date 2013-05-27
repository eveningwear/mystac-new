module STAC

  # The following class executes a test plan (i.e. a series of "vmc"
  # and "user" actions).
  class StressTestExec < VMC::BaseClient

    def initialize(config, logger, target)
      @config  = config
      @logger  = logger
      @target  = target
      
      @http_loader = HttpLoader::StacLoadGenerator.new(logger) unless @config['no_http_uses']

      # Make sure we delete any users/apps/etc. we create before exiting
      @cleanup      = []
      @cleanup_acts = 0
      @cleanup_lock = Mutex.new

      # This lock protects the peak instance count
      @instcnt_lock = Mutex.new

      # Lock for pulling things from the action queue
      @queue_lock   = Mutex.new

      # Lock for recording "dev" execution stats (such as time elapsed)
      @stats_lock   = Mutex.new

      # Initialize a few other instance variables
      @stop_run_now  = false
      @test_run_done = false
      @doing_cleanup = false

      # Initialize the dev/use action counts and lock
      @usr_act_count = 0
      @dev_act_count = 0
      @dev_act_done  = 0
      @dev_act_aborted = 0
      @lck_act_count = Mutex.new

      # Not executing any commands yet, no instances yet, etc.
      @cur_dev_cmds  = nil
      @cur_instances = 0
      @max_instances = 0
    end

    def adj_overall_instcnt(diff)
      @instcnt_lock.synchronize do
        @cur_instances += diff
        @max_instances = @cur_instances if @max_instances < @cur_instances
      end
    end

    def rec_dev_action_result_norm(failed, time_beg, time_end = Time.now)
      @stats_lock.synchronize do
        if failed
          @dev_act_fails += 1
        else
          @dev_act_cnt_n += 1
          @dev_act_nrmtm += time_end - time_beg
##########if time_end - time_beg > 0.4 ; puts "Dev action took %5.2f seconds:" % (time_end - time_beg) ; caller.each { |s| puts "  " + s } ; end
        end
      end
    end

    def rec_dev_action_result_slow(failed, time_beg, time_end = Time.now)
      @stats_lock.synchronize do
        if failed
          @dev_act_fails += 1
        else
          @dev_act_cnt_s += 1
          @dev_act_slwtm += time_end - time_beg
        end
      end
    end

    def display(msg, nl=true)
      if nl
        puts(msg)
      else
        print(msg)
        STDOUT.flush
      end
    end

    def fatal_error(msg)
      @logger.error(msg)
      STDERR.puts(msg)
      abort_test
      exit 1
    end

    def internal_error(msg)
      msg = "INTERNAL STAC ERROR: " + msg
      @logger.error(msg)
      STDERR.puts(msg)
      exit 1
    end

    def slumber(tim)
      while tim > 0
        sleep(tim < 0.5 ? tim : 0.5)
        return false if @test_run_done or @stop_run_now
        tim -= 0.5
      end
      true
    end

    def auth_hdr(user)
      auth = { 'AUTHORIZATION' => "#{@admin_token}" }
      auth['PROXY-USER'] = user if user
      auth
    end

    def log_avg_info(uselog, str)
      if uselog then @logger.info(str) else puts str end
    end

    def report_averages(uselog, prefix="")
      return if @config['dry_run_plan']
      return if @test_run_done and prefix == ""

      marker = ""
      marker = @config['unique_stacid'] if @config['unique_stacid'] and not uselog

      #total_dev_actions = @dev_act_done + @dev_act_count
      #log_avg_info(uselog, "#{marker}#{prefix}#{100 * @dev_act_done / total_dev_actions}% dev defs complete (#{@dev_act_done} of #{total_dev_actions} with #{@dev_act_aborted} aborted)")

      inst = (prefix == "") ? @max_instances : @cur_instances
      log_avg_info(uselog, "#{marker}#{prefix}Approximate total app instance count: #{inst}") if inst > 0

      log_avg_info(uselog, "#{marker}#{prefix}Total number of 'dev' actions issued: #{@dev_act_cnt_n + @dev_act_cnt_s + @dev_act_fails}")
      log_avg_info(uselog, "#{marker}#{prefix}Total number of 'dev' actions failed: #{@dev_act_fails}") if @dev_act_fails > 0 or prefix == ""

      # Display average time per dev action (if we've had successes)
      if @dev_act_cnt_n > 0
        log_avg_info(uselog, "#{marker}#{prefix}Average time of 'dev' action / normal: %5.2f sec" % (@dev_act_nrmtm/@dev_act_cnt_n))
      end
      if @dev_act_cnt_s > 0
        log_avg_info(uselog, "#{marker}#{prefix}Average time of 'dev' action /  slow : %5.2f sec" % (@dev_act_slwtm/@dev_act_cnt_s))
      end

      log_avg_info(uselog, "#{marker}#{prefix}#{@http_loader.get_totals}") if @http_loader and (@http_loader.get_total_requests > 0 or prefix == "")
    end

    # Check the response for an error; return true if OK, log the error and
    # return false otherwise. Optionally also record a "dev" action result
    # and time (when 'beg_time' is not false).

    def handle_response(response, beg_time = nil)

if $newgen and response.kind_of? Array
  puts "UNDONE: handle response from newgen API call -- #{response.inspect} !!!!!!!!!!"
  exit!
end

      # If no response or the response looks OK, things are happy
      if (response and response.status < 400)
        rec_dev_action_result_norm(false, beg_time) if beg_time
        return true
      end

      # Something went wrong - log the failure if beg_time given
      rec_dev_action_result_norm(true, beg_time, Time.now) if beg_time

      # Try to log a decent error message
      if not response.content or response.content == ""
        @logger.error("Unknown error in response from server (status=#{response.status})")
      else
        begin
          error_json = JSON.parse(response.content)
          @logger.error(error_json['description'].to_s)
        rescue
          response.content ||= "System error has occurred."
          @logger.error(response.content.to_s)
        end
      end

      # Let the caller know that things didn't go too well
      false
    end

    def action_to_s(a)
      act = a[:action]
      # The action type should be use or dev
      return "Use #{act}"                          if a[:act_type].kind_of? TestDef_Usr
      return "Dev #{VMC_Actions.action_to_s(act)}" if a[:act_type].kind_of? TestDef_Dev
      # This is very suspicious
      "[unknown #{act} of type #{a[:act_type].class}]"
    end

    # Given an application name (and user) returns the instance count from AC;
    #
    # if all goes well we return the following triple:
    #   [ total_instances , running_instances , crashed_instances ]
    #
    # If we can't get the instance counts from AC, we return [0,0,0].
    def app_instance_count(app, user, client)
      # Instance counts: tcnt=total, rcnt=running, ccnt=crashed
      rcnt = tcnt = ccnt = 0

      # ISSUE: should we record the timing for this CC call?
      if $newgen
        begin
          inst = client.app_instances(app)
          # Empty array means no instances at all
          return 0,0,0 if inst.is_a? Array
        rescue => e
          @logger.warn("Request for instances of app #{app} failed: #{e.inspect}")
          return 0,0,0
        end
      else
        inst = get_app_instances_internal(@droplets_uri, app, auth_hdr(user))
      end

      # Make sure the resulting app info has instance info
      if $newgen
        inst = inst[:instances ] if inst
      else
        inst = inst["instances"] if inst
      end
      return 0,0,0 unless inst

      # Count the total and running instances
      if $newgen
        inst.each { |i| tcnt += 1; rcnt += 1 if i[:state ] == "RUNNING" }
      else
        inst.each { |i| tcnt += 1; rcnt += 1 if i["state"] == "RUNNING" }
      end

      # Are there any crashed instances?
      crsh = get_app_crashes(app, user, client)
      ccnt = crsh.length if crsh and crsh.length > 0

      return [tcnt, rcnt, ccnt]
    end

    def get_app_info(app, user, client)
      # ISSUE: should we record the timing for this CC call?
      if $newgen
        begin
          return client.app_info(app)
        rescue => e
          @logger.error("Could not get info for app #{app}: #{e.inspect}")
          return nil
        end
      else
        response = get_app_internal(@droplets_uri, app, auth_hdr(user))
        if response.status != 200
          raise AppInfoError.new(response, app, user)
        end
        JSON.parse(response.content)
      end
    end

    def log_crash_detail(app, user, client, last)
      crsh = get_app_crashes(app, user, client)

      # Look for any new crashed instances
      index = 0
      crsh.each do |c|
        iid = c['instance']
        its = c['since']
        if not last.index(iid)
          @logger.warn("App #{app} has new crashed instance #{iid}")
          grab_crash_logs(app, user, client, index, true)
        end
        index += 1
      end

      # Return the current (updated) list of crashed instances to the caller
      return crsh.collect { |c| c['instance'] }
    end

    # Change the instance count of the given app; the desired new number of
    # instances (passesd in 'inst') may be lower or higher compared to the
    # current instance count. We return the new count of running instances,
    # which could be lower than the desired count if we run out of time.
    #
    # The 'ainf' argument references the "app info" descriptor that is used
    # in the execution loop to keep track of apps (see the code that handles
    # the VMC_PUSH_APP action in execute_plan() for an example of its use).
    #
    # Note that when ainf[:inst_total] is zero, this means that we just did
    # an initial push of an app (and thus its current instance count should
    # be considered to be zero, even if AC already knows about some of the
    # instances).

    def set_instance_count(app, user, client, inst, starting, ainf)
      # Get hold of the current instance count
      cnts = app_instance_count(app, user, client)
      bcnt = cnts[0]          # total   count
      init = cnts[1]          # running count
      crsh = cnts[2]          # crashed count

      # If we're starting a new app, count all instances as new
      bcnt = 0 unless ainf[:inst_total] > 0

      # Keep track of how long this entire thing takes
      beg_time = Time.now

      # We haven't logged any crash information yet
      llog = []

      # ISSUE: what is a reasonable length of time to wait for this?
      # For now we use the following formula:
      #
      #    initial app push/start: wait up to 60 seconds
      #
      #    increase in instance count: wait up to 30 + <inst-cnt-diff> * 2 seconds
      #
      #    decrease in instance count: wait up to 30 seconds

      diff = inst - init
      secs = ((diff > 0) ? diff * 2 : 0) + (starting ? 60 : 30)

      # Let's cap the wait time at a max. of 60 seconds
      secs = 60 if secs > 60

      # Report crashed instances only once
      repcrsh = false

      # Wait for the right number of instances to be running
      while secs > 0
        # Get the current number of instances
        cnts = app_instance_count(app, user, client)

        # Update the instance count info for the app
        ainf[:inst_total  ] = cnts[0]
        ainf[:inst_running] = cnts[1]
        ainf[:inst_crashed] = cnts[2]

        # Done if we've reached the desired instance count (or test is ending)
        break if cnts[1] >= inst or @stop_run_now

        # Check for crashes
        if cnts[2] > 0
          if cnts[2] != repcrsh
            @logger.warn("We have #{cnts[2]} crashed instances of #{app} with crash mode \'#{ainf[:crash_info]}\'")
            repcrsh = cnts[2]
          end
          llog = log_crash_detail(app, user, client, llog) if $xdetail
        end

        # Tell AC to give us the number of instances we desire
        info = get_app_info(app, user, client)
        info['instances'] = inst
        if $newgen
          client.update_app(app, info)
        else
          response = update_app_state_internal(@droplets_uri, app, info, auth_hdr(user))
          handle_response(response)
        end

########puts "Waiting for app instances: have #{cnts[1]} but need #{inst}"

        # Wait a bit, up to the chosen time limit
        secs -= 0.5 ; sleep 0.5
      end

      # Keep the peak instance count updated
      adj_overall_instcnt(ainf[:inst_total] - bcnt)

      # Either we've reached the desired instance count or time has run out
      have = ainf[:inst_running]
      if have == inst or @stop_run_now
        # If the test is being stopped, let's just quietly end things
        rec_dev_action_result_slow(false, beg_time)
      else
        # Failed to achieve the desired instance count
        rec_dev_action_result_slow(true,  beg_time)
        @logger.error("After a long wait we only have #{have} instances of #{app} instead of #{inst}")
      end

      # We always return the current running instance count as the result
      have
    end

    # Copied from vmc
    def log_file_paths
      %w[logs/stderr.log logs/stdout.log logs/startup.log]
    end

    # Retrieve logs for a given instance of a running AC app
    def grab_app_logs(app, user, client, inst)
      if not inst.kind_of? Fixnum
        internal_error("grab_app_logs() called with instance #{inst} of type #{instclass}; expecting Fixnum")
      end
      log_file_paths.each do |path|
        beg_time = Time.now
        if $newgen
          begin
            client.app_files(app, path, inst)
            rec_dev_action_result_norm(false, beg_time)
          rescue => e
            rec_dev_action_result_norm(true,  beg_time)
            @logger.error("Could not get log for app #{app}")
          end
        else
          response = get_app_files_internal(@droplets_uri, app, inst, path, auth_hdr(user))
          if response.status != 200
            rec_dev_action_result_norm(false, beg_time)
            raise AppLogError.new(response, app, user)
          elsif not response.content.empty?
            rec_dev_action_result_norm(true,  beg_time)
          end
        end
      end
    end

    def grab_crash_logs(app, user, client, inst, logit = false)
      if not inst.kind_of? Fixnum
        internal_error("grab_crash_logs() called with instance #{inst} of type #{inst.class}; expecting Fixnum")
      end
      ['/logs/err.log', '/logs/staging.log', 'logs/stderr.log', 'logs/stdout.log', 'logs/startup.log'].each do |path|
        beg_time = Time.now
        if $newgen
          begin
            client.app_files(app, path, inst)
            rec_dev_action_result_norm(false, beg_time)
          rescue => e
            rec_dev_action_result_norm(true,  beg_time)
            @logger.error("Could not get crash log for app #{app}")
          end
        else
          response = get_app_files_internal(@droplets_uri, app, inst, path, auth_hdr(user))
          if response.status != 200
            rec_dev_action_result_norm(true,  beg_time)
            if response.status == 400 or response.status == 500
              # ISSUE: how do we know when this is OK vs. failure?
              @logger.info("Response from get_crash_logs(#{path}): #{response.status}")
            else
              raise AppCrashLogError.new(response, app, user)
            end
          else
            rec_dev_action_result_norm(false, beg_time)
            if logit
              @logger.info("Crash log #{path} for app #{app}: #{response.content}")
            end
            if not response.content.empty?
            end
          end
        end
      end
    end

    def get_app_crashes(app, user, client)
      beg_time = Time.now
      if $newgen
        client.app_crashes(app)
      else
        response = get_app_crashes_internal(@droplets_uri, app, auth_hdr(user))
        if response.status == 200
          rec_dev_action_result_norm(false, beg_time)
        else
          rec_dev_action_result_norm(true,  beg_time)
          raise AppCrashesError.new(response, app, user)
        end
        JSON.parse(response.content)['crashes']
      end
    rescue => e
      @logger.error("get_app_crashes error #{e.inspect}")
      raise e
    end

    def eval_exec_arg(arg, app, user)
      return arg unless arg
      arg = arg.to_s unless arg.kind_of? String
      vpos = 0
      sbst = false
      while fpos = arg.index("&", vpos)
        if arg[fpos+1, 14] == "instance_count"
          # Extract the app name
          mtch = arg.match(/\s*\([\:\s*](\w+)\s*\)/, fpos + 15)
          if mtch
            # Replace the reference with the actual instance count
            cnt = app_instance_count(mtch[1], user)
            if cnt[1]
              arg[fpos, 15 + mtch.to_s.length] = cnt[1].to_s
              sbst = true
            end
          end
        end
        vpos = fpos + 1
      end
      arg = eval(arg).to_s if sbst
      arg
    end

    def mem_in_MB(val)
      return val[0 .. -2].to_i        if val[-1,1] == 'M'
      return val[0 .. -2].to_i * 1024 if val[-1,1] == 'G'
      val.to_i
    end

    # Invent a unique name for the service
    def invent_service_name(app, user, type, vend, pref_only = false)
      amps = user.index("@")
      user = amps ? user[0,amps-1] : user
      name = "svc_#{name}_#{app}_#{type}_#{vend}_"
      return name + (pref_only ? "" : fast_uuid[0..6])
    end

    def find_matching_service(app, user, client, stab, desc)
      base = invent_service_name(app, user, desc[:svc_type], desc[:svc_vendor], true)
      stab.each { |s| return s if s[0,base.length] == base }
      nil
    end

    def add_app_service(app, user, client, svc)
      # Get hold of the various service attributes
      s_type = svc[:type   ]
      s_vend = svc[:vendor ]
      s_vers = svc[:version]
      s_tier = svc[:tier   ]
      s_opts = svc[:options]
      s_desc = svc[:desc   ] # for NG client

      # Invent a unique name for the service
      name = invent_service_name(app, user, s_type, s_vend)

      info =
      {
        :name    => name,
        :type    => s_type,
        :vendor  => s_vend,
        :tier    => s_tier,
        :version => s_vers,
        :options => s_opts
      }

      # Provision the service for the user
      beg_time = Time.now
      if $newgen
        begin
          client.create_service(s_desc, name)   # horrible - FIXME!!!!!!
          rec_dev_action_result_norm(false, beg_time)
        rescue => e
          rec_dev_action_result_norm(true , beg_time)
          @logger.error("Could not create service for app #{app}: #{e.inspect}")
          return false
        end
      else
        response = add_service_internal(@services_uri, info, auth_hdr(user))
        handle_response(response, beg_time)
      end

      # Now add the service to the application's list of services
      info = get_app_info(app, user, client)
      psvc = info['services'] ? info['services'] : []
      psvc << name
      info['services'] = psvc

      beg_time = Time.now
      if $newgen
        begin
          client.bind_service(name, app)
          rec_dev_action_result_norm(false, beg_time)
        rescue => e
          rec_dev_action_result_norm(true , beg_time)
          @logger.error("Could not bind service #{name} to app #{app}: #{e.inspect}")
          return false
        end
      else
        response = update_app_state_internal(@droplets_uri, app, info, auth_hdr(user))
        handle_response(response, beg_time)
      end

      @logger.debug("Provisioned service #{name} for app #{app}")
      true
    end

    def pack_app_bits(dir, zipfile) # copied from zip_util.rb / pack()
      exclude = ['..', '.', '*~', '#*#', '*.log', 'app.zip']
      excludes = exclude.map { |e| "\\#{e}" }
      excludes = excludes.join(' ')
      if RUBY_PLATFORM !~ /mingw/
        return if system("cd #{dir} ; zip -q -r -x #{excludes} #{zipfile} . 2> /dev/null")
      end
      # Do Ruby version if told to or native version failed
      Zip::ZipFile::open(zipfile, true) do |zf|
        Dir.glob("#{dir}/**/*", File::FNM_DOTMATCH).each do |f|
          process = true
          exclude.each { |e| process = false if File.fnmatch(e, File.basename(f)) }
          zf.add(f.sub("#{dir}/",''), f) if (process && File.exists?(f))
        end
      end
    end

    def push_app_bits(app, user, client, is_update, path, svcs=nil, war=nil, hasdb=nil)
      begin
        # Push the app bits - this might take a while
        beg_time = Time.now

        begin
          war = File.expand_path(war, path) if war
          if $newgen
            # Is there an archive already?
            upload_file = File.join(path, "app.zip")
            if not File.exists?(upload_file)
              # Choose unique / temporary name(s) for the upload
####          upload_dir  = "#{Dir.tmpdir}/_stac_#{app}_files"
####          FileUtils.rm_rf(upload_dir)
              upload_file = "#{Dir.tmpdir}/_stac_#{app}.zip"
              FileUtils.rm_f(upload_file)

              # Create the archive for the upload
              pack_app_bits(path, upload_file)
            end

            # Ready to upload the app bits
            client.upload_app(app, upload_file, nil)
          else
            upload_app_bits(path,
                            @resources_uri,
                            @droplets_uri,
                            app,
                            auth_hdr(user),
                            war,
                            hasdb)
          end
        rescue => e
          @logger.error("Could not push application bits: #{e.inspect}\n#{e.backtrace.join("\n")}")
          return false
        end

        # Record the result / time of the 'upload' action
        rec_dev_action_result_slow(false, beg_time)

        # Do we need to provision any services for the app?
        if svcs
          svcs.each { |s| add_app_service(app, user, client, s) }
        end

        # Is the app running?
        info = get_app_info(app, user, client)
        if info['state'] == 'STARTED' or info[:state] == 'STARTED'
          # We're done unless we're doing an app update
          return true unless is_update

          # Stop the app, then start it again with the new bits
          if $newgen
            info[:state] = 'STOPPED'
            begin
              client.update_app(app, info)
            rescue => e
              @logger.error("Could not change app state to STOPPED: #{e.inspect}")
              return true
            end
          else
            info['state'] = 'STOPPED'
            response = update_app_state_internal(@droplets_uri, app, info, auth_hdr(user))
            handle_response(response, beg_time)
          end
        end

        # App is not running, ask to make it so
        if $newgen
          info[:state ] = 'STARTED'
        else
          info['state'] = 'STARTED'
        end

        beg_time = Time.now
        if $newgen
          begin
            client.update_app(app, info)
          rescue => e
            @logger.error("Could not change app state to RUNNING: #{e.inspect}")
          end
        else
          response = update_app_state_internal(@droplets_uri, app, info, auth_hdr(user))
          handle_response(response, beg_time)
        end
      end
      true
    end

    def ctx_mark(user, scen)
      ("u%04u,s" % user) + (scen ? ("%02u" % scen) : "**")
    end

    def delete_app(app, user, client)
      adj_overall_instcnt(-app_instance_count(app, user, client)[0])
      info = get_app_info(app, user, client)
      psvc = info['services']
      if psvc
        psvc.each do |s|
          # Delete the service from the user
          @logger.debug("Removing service #{s} of user #{user}")
          # ISSUE: should we include this in the overall "dev" timing results?
          beg_time = Time.now
          if $newgen
            internal_error("Thing at line #{__LINE__} not yet implemented for -n / newgen")
          else
            remove_service_internal(@services_uri, s, auth_hdr(user))
          end
          rec_dev_action_result_norm(false, beg_time)
        end
      end
      @logger.debug("Deleting app #{app}")
      beg_time = Time.now
      if $newgen
        internal_error("Thing at line #{__LINE__} not yet implemented for -n / newgen")
      else
        delete_app_internal(@droplets_uri, @services_uri, app, info['services'], auth_hdr(user))
      end
      rec_dev_action_result_norm(false, beg_time)
    end

    def delete_user(user)
      @logger.debug("Deleting user #{user}")
      beg_time = Time.now
      if $newgen
        internal_error("Thing at line #{__LINE__} not yet implemented for -n / newgen")
      else
        delete_user_internal(@base_uri, user, auth_hdr(nil))
      end
      rec_dev_action_result_norm(false, beg_time)
    end

    def find_services(app, user, client, svcs)
      # Bail if there are no services to be provisioned
      return nil, false unless svcs and svcs.kind_of? Array and svcs.length > 0

      # Get hold of the available services
      beg_time = Time.now
      if $newgen
        begin
          asvcs = client.services_info
        rescue => e
          @logger.warn("Request for available services failed: #{e.inspect}")
          return [],nil
        end
      else
        response = get("#{@base_uri}/info/services", nil, auth_hdr(nil))
        return [],nil unless handle_response(response, beg_time)
        asvcs = JSON.parse(response.content)
      end

      # This weird flag excludes "*.sqlite3" from the push tarball or something
      hasdb = false

      # For each service the app is asking for, try to find an available match
      provs = []
      svcs.each do |asks|
        s_type = asks[:svc_type]
        s_vend = asks[:svc_vendor]
        s_vers = asks[:svc_version]

        # Find services that match the desired type/vendor/etc.
        s_list = []
        asvcs.each do |type, vendors|
        ##puts "Service type=#{type} vs. #{s_type}, vend=#{vendors.inspect}"
          next if s_type.to_s != type.to_s and type != "generic"
          vendors.each do |vendor, versions|
          ##puts "  Vendor: #{vendor} vs. #{s_vend}, vers=#{versions.inspect}"
            next if s_vend and s_vend.to_s != vendor.to_s
            versions.each do |version, entry|
            ##puts "    Version: #{version} vs. #{s_vers} -> #{entry.inspect}"
              next if s_vers and s_vers.to_s != version.to_s

              # Pick the free tier or whatever tier is first (if any)
              tiers = $newgen ? entry[:tiers] : entry["tiers"]
              tiers = entry["plans"] unless tiers
            ##puts "      Tiers: #{tiers.inspect}"
              if tiers.kind_of? Array
                tier = nil
                tiers.each do |t|
                  tier = "free" if t.kind_of? Hash   and t[:name] == "free" # old style
                  tier = "free" if t.kind_of? String and t        == "free" # new style
                end
                tier = tiers[0]["name"] unless tier
              else
                tier = (tiers.size > 1 and tiers.has_key?("free")) ? "free" : tiers.keys.first
              end

              # UNDONE: grab tier options, if present
              opts = nil

              # Looks like a service we can use - add it to the list
              s_list << {
                          :type    => type,
                          :desc    => entry[:vendor], # weird temporary hack for NG client
                          :vendor  => vendor,
                          :version => version,
                          :tier    => tier,
                          :options => opts
                        }
            end
          end
        end

        # Do we have exactly one matching service?
        if s_list.length != 1
          internal_error("Found #{s_list.length} matching services for type=#{s_type},vendor=#{s_vend},version=#{s_vers}")
        end

        # Add this service to the list we need to provision
        provs << s_list[0]

        # Weird thing (no idea why)
        hasdb = true if s_type == "database"
      end

      # Return the services to be provisioned (and the 'db' flag)
      return provs, hasdb
    end

    def del_app_service(app, user, client, svcs)
      # Get the list of services currently provisioned to the app
      info = get_app_info(app, user, client)
      psvc = info['services']

      # Process each service the caller specified
      svcs = [svcs] if svcs.kind_of? Hash
      svcs.each do |svc|
          # Find a provisioned service that matches the description
          svc_name = find_matching_service(app, user, client, psvc, svc)
          if not svc_name
            @logger.error("Could not delete #{svc.inspect} for app #{app}")
            next
          end

          # Delete the entry from the app's provisioned services
          psvc.delete(svc_name)
          info['services'] = psvc

          # Tell AC that this app no longer needs this service
          begin
            beg_time = Time.now
            if $newgen
              internal_error("Thing at line #{__LINE__} not yet implemented for -n / newgen")
            else
              response = update_app_state_internal(@droplets_uri, app, info, auth_hdr(user))
            end
            handle_response(response, beg_time)
          rescue => e
            @logger.error("Unbind failed for service #{svc_name} / #{svc.inspect} for app #{app}")
          end

          # Finally, remove the service from the user
          if $newgen
            internal_error("Thing at line #{__LINE__} not yet implemented for -n / newgen")
          else
            remove_service_internal(@services_uri, svc_name, auth_hdr(user))
          end
      end
    end
    
    def simulate()
      # Initialize the stats we keep for "dev" actions
      @dev_act_cnt_n = 0  # count of "normal" dev actions that went OK
      @dev_act_cnt_s = 0  # count of  "slow"  dev actions that went OK
      @dev_act_fails = 0  # count of  *all*   dev actions that failed
      @dev_act_nrmtm = 0  # total time spent executing "normal" dev actions
      @dev_act_slwtm = 0  # total time spent executing  "slow"  dev actions
      
      @exec_thrd_cnt = @config['thread_count'] ? @config['thread_count'] : 1
      thrd_cnt = @exec_thrd_cnt
      thrd_tab = []
      
      # Combine the target URL to create the various URL's we'll be using
      @base_uri = "http://" + @config[:target_AC]
      @droplets_uri  = "#{@base_uri}/apps"
      @services_uri  = "#{@base_uri}/services"
      @resources_uri = "#{@base_uri}/resources"
      
      @admin_token = login_internal(@base_uri, @config['ac_admin_user'], @config['ac_admin_pass']) if not @config['http_url']
      @start_time = Time.now
      
      thrd_cnt.times do |thrd_num|
        # This is the start each executor thread ...
        thrd_tab << Thread.new do
          while !@stop_run_now and !@test_run_done
            context_queue = PriorityQueueManager.pop
            break unless context_queue
            
            last_action_item = context_queue[context_queue.length-1]
            to_do_action_item = context_queue.shift
            
            context = to_do_action_item[:context]
            clock = to_do_action_item[:clock]
            last_clock = last_action_item[:clock]
            last_duration = last_action_item[:duration]

            to_do_action = to_do_action_item[:action]
            
            cur_clock = (Time.now - @start_time).to_i
            @logger.info("[%04u]>>[#{context[:scn_id]}][#{context[:global_scn_index]}][#{context[:scn_index]}][#{context[:count_num]}]: #{to_do_action.act_ref.id}" % cur_clock)
            
            while Time.now - @start_time < clock
              sleep(1)
            end

            #Do Action
            execute_action(to_do_action_item)
            
      	    if last_duration==INFINITY 
      	      if to_do_action_item==last_action_item
                context_queue << to_do_action_item
              end
      	    else
              # This is for change the expected clock time of to do action	
              clock = last_clock + last_duration
              context_queue << to_do_action_item
      	    end
            
            PriorityQueueManager.push(context_queue) if context_queue and not context_queue.empty?
          end
        end
      end
      
      # Save the execution thread table in case something goes wrong
      @exec_thrds = thrd_tab
      @exec_thrds.each { |t| t.abort_on_exception = true }

      # Create a thread that will kill everything if/when 'max_runtime' is reached
      if @config['max_runtime']
        time_killer_thread = Thread.new do
          left_time = @config['max_runtime'].to_i - (Time.now - @start_time)
          while left_time > 0 and not @test_run_done and not @stop_run_now
            sleep   0.5
            left_time -= 0.5
          end
          if not @test_run_done and not @stop_run_now
            msg = "Test has been running for #{(Time.now - @start_time).to_i} seconds: trying to stop it"
            @logger.warn(msg)
            puts         msg

            # Tell everyone that it's time to stop
            if not force_stop
              sleep(1)
              # If we've starting cleaning up, no need to panic
              if not @doing_cleanup
                msg = "Execution threads refuse to stop; aborting the test the hard way"
                @logger.error(msg)
                puts          msg
                exit!
              end
            end
          end
        end
      end
      
      # Start a warm-and-fuzzy thread that will regularly display statistics
      fuzzy_thread = Thread.new do

        # Get hold of the update period in seconds
        freq = @config['update_freq'].to_f
        freq = 60 unless freq                 # default = 60 seconds

        while not @test_run_done and not @stop_run_now
          stamp = "[%04u sec]: " % (Time.now - @start_time + 0.5).to_i
          report_averages(true , stamp)
          report_averages(false, stamp)

          @logger.debug("priority queue len: #{priority_context_queue.length}")
          txt = ""
          @cur_dev_cmds.each_with_index do |action, thrd|
            txt += "   Thread #%02u " %thrd
            if action
              txt += "is executing action #{action.inspect}\n"
            else
              txt += "is in IDLE\n"
            end
          end
          @logger.debug("thread state:\n#{txt}")

          # Sleep 'freq' seconds (while checking for the test ending)
          slumber(freq)
        end
      end

      # Wait for the execution threads to finish
      thrd_tab.each { |t| t.join }
      
    ensure
      @test_run_done = true
      cleanup
      final_report
    end

    # This function will be totally removed in the future, jacky
    def execute_plan(queue, dry_run, user_count, context_count)
      @logger.info("Starting test plan execution")

      # The following will record the currently executing command(s)
      @exec_thrd_cnt = @config['thread_count'] ? @config['thread_count'] : 1
      @cur_dev_cmds  = [nil] * @exec_thrd_cnt

      @logger.info("Using #{@exec_thrd_cnt} threads")

      # Combine the target URL to create the various URL's we'll be using
      @base_uri      = "http://" + @target
      @droplets_uri  = "#{@base_uri}/apps"
      @services_uri  = "#{@base_uri}/services"
      @resources_uri = "#{@base_uri}/resources"

      # Are we really doing this, or just pretending?
      dry_run = @config['dry_run_plan']

      # The following will hold the test user clients / emails / auth_tokens
      @user_clients  = []
      @user_emails   = []
      @user_tokens   = []

      # We'll try to figure out the peak instance count of the run
      @cur_instances = 0
      @max_instances = 0

      # Initialize the "stop now" and "test is finished" flags
      @stop_run_now  = false
      @test_run_done = false

      # Initialize the stats we keep for "dev" actions
      @dev_act_cnt_n = 0  # count of "normal" dev actions that went OK
      @dev_act_cnt_s = 0  # count of  "slow"  dev actions that went OK
      @dev_act_fails = 0  # count of  *all*   dev actions that failed
      @dev_act_nrmtm = 0  # total time spent executing "normal" dev actions
      @dev_act_slwtm = 0  # total time spent executing  "slow"  dev actions

      # Login as an administrator
      if not dry_run
        if $newgen
          # Create client instance for the admin user
          # FIXME: later usage of this client is not thread safe.
          @admin_client = VMC::Client.new(@target)
          @admin_client.proxy = nil

          # Log in the admin user
          @admin_token = @admin_client.login(@config['ac_admin_user'], @config['ac_admin_pass'])

          # Enable tracing if desired
          @admin_client.trace = $verbose ? true : false
        else
          @admin_token = login_internal(@base_uri, @config['ac_admin_user'],
                                                   @config['ac_admin_pass'])
        end
      else
        @admin_token = "this is a fake admin user token"
      end

      # Prepare an array to hold the client instances for each user
      user_clients = [nil] * user_count

      # Figure out whether we should try to follow a "real" clock
      real_clock = dry_run ? false : true

      # Initialize the clock and start executing the commands in the queue
      stclk = Time.now
      clock = 0

      # The following holds info about all of the active apps
      my_apps = {}
      ma_lock = Mutex.new

      # Start a thread to log CPU/memory usage, if desired
      if @config['log_rsrc_use'] and @config['log_rsrc_use'] > 0
        Thread.new do
          slp = @config['log_rsrc_use']
          cmd = "ps -o rss=,pcpu= -p #{Process.pid}"
          while slumber(slp)
            rss, cpu = `#{cmd}`.split
            mem = (rss.to_i + 511) / 1024
            @logger.info("Current resource usage: mem =%4u MB , cpu = %4.1f \%" % [mem, cpu.to_f])
          end
        end
      end

      # Count the number of dev/use actions (excluding infinite uses); also,
      # adjust the clock values so that the first action happens right away.
      start_clock    = queue[0][:clock]
      @usr_act_count = 0
      @dev_act_count = 0
      queue.each do |q|
        # Adjust the clock
        q[:clock] -= start_clock

        # For 'use' actions, don't count infinite duration entries
        if q[:act_type].kind_of? TestDef_Usr
          arg = q[:args]
          @usr_act_count += 1 unless arg and arg[:duration] == INFINITY
        end

        # Note - 'dev' actions should never have infinite durations
        if q[:act_type].kind_of? TestDef_Dev
          @dev_act_count += 1
        end
      end

      priority_context_queue = PriorityContextQueue.new(@logger, queue)
      
      puts priority_context_queue.length

      # Start the desired number of threads to execute the test actions
      thrd_cnt = @exec_thrd_cnt
      thrd_tab = []
      thrd_cnt.times do |thrd_num|
        # This is the start each executor thread ...
        thrd_tab << Thread.new do
          while !@stop_run_now and !@test_run_done

            # We need to pull the next available action and run it. We prevent
            # collisions on the client associated with each context by only
            # running 1 item from each context queue at a time (that is what
            # the old code did too)
            #
            # The basic algorithm for grabbing action items from the queue
            # is as follows:
            #
            #   1.
            #   Pull a context queue off the priority queue.  If nil,
            #   we are done as there is no more work to do.  Shift an action
            #   off the context queue.
            #
            #   2.
            #   Compare the current time to the clock value in the first
            #   undone item we found in the previous step; if the item is
            #   way in the future, that means that there is no work to be
            #   done at this time; go to sleep long enough such that we'll
            #   wake up around the time the next item is due; start all
            #   over after waking up.

            # Step 1: get a context_queue from the priority queue, if nil,
            # there is no more work to do.
            a_our = nil
            context_queue = priority_context_queue.pop
            break unless context_queue

            # Get and record the currently executing action for this thread
            a_our = context_queue.shift
            @cur_dev_cmds[thrd_num] = a_our

            # Step 2: if the item is in the future, go to sleep
            # (this is the sleep block from the older code, just shifted over
            # due to shifting out a block level)
            a_clk = a_our[:clock]
            c_clk = real_clock ? (Time.now - stclk) : a_clk
            if c_clk < a_clk
              # Randomize the sleep time a tiny bit to avoid bad behavior
              slptm = (real_clock ? (a_clk - c_clk) : 0) + rand(0.1)
              @logger.debug("Next action #{action_to_s(a_our)} in T#{thrd_num} isn't due for #{slptm} seconds") if slptm > 60
              sleep(slptm)
            end

            # Put this back to what the "old" code expects, including the
            a = a_our

            # Stop if we're shutting down
            break if @stop_run_now

            # If the above loop stops without finding 'a', it means we're done
            break unless a

            # We wrap the rest of the logic in an 'ensure' block to guarantee
            # that we can do appropriate cleanup and accounting
            begin
              retry_action = false

              typ = a[:act_type]
              clk = a[:clock]
              act = a[:action]
              arg = a[:args]

              ctx = a[:context]
              usr = ctx[0]
              scn = ctx[1]
              
              @logger.debug("The thread #{thrd_num} is responsible for action #(act) with argument #{arg}")

              # Do we have a "use" or "dev" action to execute?
              if typ.kind_of? TestDef_Usr
                # Make sure all "use" actions are :symbols
                internal_error("Use action value is not a :symbol") unless act.kind_of? Symbol

                # Pull out the :http_args value, if present
                harg = TestDef_Base.pull_val_from(arg, :http_args)

                do_usr_action(usr, scn, act, arg, harg, clk, dry_run)

                # Update the remaining "use" action count
                if arg[:duration] != INFINITY
                  @lck_act_count.synchronize { @usr_act_count -= 1 }
                end

                next
              end

              # Not "use" - must be a "dev" (i.e. an AC user / admin type) action
              internal_error("Instead of use/dev action we found #{a.class}") unless typ.kind_of? TestDef_Dev
              internal_error("Dev action value is not a Fixnum") unless act.kind_of? Fixnum

              # Figure out when this action should end
              dur = arg[:duration] || 0
              end_time = Time.now + dur

              # Extract the app name, if present
              app = ""
              if arg and arg[:app_name]
                app = arg[:app_name]
              end

              # Get hold of the client / auth token / email for this user (if set)
              client = @user_clients[usr]
              token  = @user_tokens [usr]
              email  = @user_emails [usr]

              # Extract instance info, if present
              icnt = arg[:inst_cnt]
              iinc = nil
              if icnt
                # If the count starts with +/- then it's a relative change
                if icnt.kind_of? String
                  iinc = icnt[0,1]
                  if iinc != "+" and iinc != "-"
                    iinc = nil
                  end
                end
                icnt = eval_exec_arg(icnt, app, email).to_i
              end

              imin = arg[:inst_min] ? eval_exec_arg(arg[:inst_min], app, email).to_i : nil
              imax = arg[:inst_max] ? eval_exec_arg(arg[:inst_max], app, email).to_i : nil
              inum = arg[:inst_num] ? eval_exec_arg(arg[:inst_num], app, email).to_i : nil

              @logger.info("[%04u]>>vmc \{#{ctx_mark(usr,scn)}\} #{VMC_Actions.action_to_s(act)} #{app} #{arg.inspect}" % clk)

              # With a few exceptions, all commands refer to active apps
              case act
              when VMC_Actions::VMC_ADD_USER,
                   VMC_Actions::VMC_DEL_USER,
                   VMC_Actions::VMC_PUSH_APP

              else
                # We should have an app descriptor in our table for the app
                ainf = my_apps[app]
                if not ainf
                  internal_error("my_apps[\'#{app}\'] is missing for user #{email} at #{VMC_Actions.action_to_s(act)}")
                end
              end

              # See what action is specified and carry it out
              case act
              when VMC_Actions::VMC_ADD_USER
                mail   = arg[:email]
                pass   = arg[:password]
                client = nil
                if not dry_run
                  begin
                    beg_time = Time.now
                    if $newgen
                      # We potentially need to delete the user from an unclean shutdown
                      begin
                        @logger.debug("Deleting user: '#{mail}'")
                        @admin_client.delete_user(mail)
                        @logger.debug("Deleted user: '#{mail}'")
                      rescue VMC::Client::NotFound
                        @logger.debug("Did not need to clean up user: '#{mail}'")
                      rescue => e
                        @logger.info("Unexpected error while deleting user: '#{mail}' error: '#{e.inspect}'")
                      end

                      # Create the test user
                      ur = @admin_client.add_user(mail, pass)

                      # Create a client for the user
                      client = VMC::Client.new(@target, @admin_token)
                      client.proxy = nil

                      # Login the client and set the proxy value in the client
                      client.login(@config['ac_admin_user'], @config['ac_admin_pass'])
                      client.proxy = mail

                      # Enable tracing if desired
                      @admin_client.trace = $verbose ? true : false
                    else
                      begin
                        @logger.debug("Deleting user: '#{mail}'")
                        delete_user_internal(@base_uri, mail, auth_hdr(nil))
                        @logger.debug("Deleted user: '#{mail}'")
                      rescue => e
                        # Errors will be the common case
                        @logger.debug("Error deleting user: '#{mail}' error: '#{e.inspect}'")
                      end
                      register_internal(@base_uri, mail, pass)
                    end
                    rec_dev_action_result_norm(false, beg_time)
##hack##          rescue VMC::Client::NotFound
##hack##            rec_dev_action_result_norm(true , beg_time)
##hack##            fatal_error("Could not register test user #{mail}: probably a turd left behind, please reset CC/HM database")
                  rescue => e
                    rec_dev_action_result_norm(true , beg_time)
                    if e.kind_of? RuntimeError and e.to_s[0, 14] == "Invalid email:"
                      fatal_error("Could not register test user #{mail}: probably a turd left behind, please reset CC/HM database")
                    else
                      @logger.error("Could not register test user #{mail}")
                      raise e, e.message, e.backtrace
                    end
                  end
                  token = login_internal(@base_uri, mail, pass)
                else
                  token = "this is a fake token for user #{usr}"
                end

                @user_clients[usr] = client
                @user_tokens [usr] = token
                @user_emails [usr] = mail

                @cleanup_lock.synchronize {
                  @cleanup = [ { :action => VMC_Actions::VMC_DEL_USER, :user => mail } ] + @cleanup
                  @cleanup_acts += 1
                }

              when VMC_Actions::VMC_PUSH_APP
                # Get the various arguments we need to push app bits
                path = TestDef_Base.pull_val_from(arg, :path)
                aurl = TestDef_Base.pull_val_from(arg, :url)
                amem = TestDef_Base.pull_val_from(arg, :mem)
                awar = TestDef_Base.pull_val_from(arg, :war)
                inst = TestDef_Base.pull_val_from(arg, :instances)
                fmwk = TestDef_Base.pull_val_from(arg, :framework)
                exec = TestDef_Base.pull_val_from(arg, :exec_cmd)
                svcs = TestDef_Base.pull_val_from(arg, :services)
                crsh = TestDef_Base.pull_val_from(arg, :crashes)

                # Create and record the app descriptor
                ainf = {
                         :user         => usr,
                         :inst_total   => 0,
                         :inst_running => 0,
                         :inst_crashed => 0,
                         :crash_info   => crsh,
                       }
                ma_lock.synchronize { my_apps[app] = ainf }

                if not dry_run

                  manifest = {
                    :name => "#{app}",
                    :staging => {
                      :framework => fmwk,#changed by jacky
                      :runtime => exec#changed by jacky
                    },
                    :uris      => [aurl],
                    :instances => 1,
                    :resources => { :memory => mem_in_MB(amem) },
                  }

                  # Provision services if the app asked for any
                  provs, hasdb = find_services(app, email, client, svcs)

                  # Send the manifest to the cloud controller
                  beg_time = Time.now
                  begin
                    # Create the app
                    if $newgen
                      client.create_app(app, manifest)
                      rec_dev_action_result_norm(false, beg_time)
                    else
                      response = create_app_internal(@droplets_uri, manifest, auth_hdr(email))
                      handle_response(response, beg_time)
                      #client = VMC::Client.new(@base_uri, @admin_token)
                      #client.create_app(arg[:app_name], manifest)
                    end

                    # App created - make sure we delete it no matter what happens
                    @cleanup_lock.synchronize do
                      @cleanup = [ { :action => VMC_Actions::VMC_DEL_APP, :client   => client,
                                                                          :user     => email,
                                                                          :app_name => app } ] + @cleanup
                      @cleanup_acts += 1
                    end

                    # Now upload the app bits
                    pushed = push_app_bits(app, email, client, false, path, provs, awar, hasdb)
                  rescue => e
                    rec_dev_action_result_norm(true , beg_time)
                    @logger.error("Could not create app #{app} -- #{e.inspect}")
                    pushed = false
                  end

                  # If pushed OK, wait for the correct number of running instances
                  if not pushed or set_instance_count(app, email, client, inst, true, ainf) == 0
                    break if @stop_run_now

                    # Zap all future actions related to this app
                    orig_len = context_queue.length
                    context_queue.delete_if {|a| a[:args] and a[:args][:app_name] == app and not a[:act_type].kind_of? TestDef_Usr}
                    aborted = @lck_act_count.synchronize { aborted = orig_len - context_queue.length }
                    @lck_act_count.synchronize {
                      @dev_act_count   -= aborted
                      @dev_act_done    += aborted
                      @dev_act_aborted += aborted
                    }

                    # We couldn't push or get even one instance of the app running
                    @logger.error("Could not get app #{app} started; aborting run and #{aborted} actions")
                  end
                end

              when VMC_Actions::VMC_UPD_APP

                adef = arg[:app_def]
                if not adef.kind_of? TestDef_App
                  internal_error("Bogus update app type of #{adef.class}")
                end
                begin
                  push_app_bits(app, email, client, true, adef.dir) unless dry_run
                rescue Errno::EACCES => e
                  @logger.warn("Update for app #{app} failed: #{e.inspect}")
                  raise e, e.message, e.backtrace
                end

                # Did we just change the crash mode of the app?
                ainf = my_apps[app]
                oldc = ainf[:crash_info]
                newc = adef.crashes
                if oldc != newc
                  # UNDONE: crash mode changed from #{oldc} to #{newc} for app #{app}
                  ainf[:crash_info] = newc
                end

              when VMC_Actions::VMC_DEL_APP

                if @config['pause_at_end'] or @config['log_end_stat']
                  @logger.warn("Skipping deletion of app #{app}") unless dry_run
                else
                  begin
                    if $newgen
                      internal_error("Action #{VMC_Actions.action_to_s(act)} not yet implemented for -n / newgen")
                    else
                      delete_app(app, email, client) unless dry_run
                    end
                  rescue => e
                    @logger.warn("Deleting app #{app} threw #{e.inspect}")
                  end

                  # Remove the app from the "active apps" table
                  ma_lock.synchronize { my_apps.delete(app) }

                  # Find and kill the cleanup action for this app
                  @cleanup.each do |aa|
                    if aa[:action]   == VMC_Actions::VMC_DEL_APP and
                       aa[:user]     == email and
                       aa[:app_name] == app then

                      # Deactivate this cleanup item
                      aa[:action] = 0

                      # Decrement number of cleanup items left to process
                      @cleanup_lock.synchronize { @cleanup_acts -= 1 }
                      break
                    end
                  end
                end

              when VMC_Actions::VMC_CHK_APP

                if not dry_run
                  # Get the current instance counts and compare against expected
                  cnts = app_instance_count(app, email, client)

                  @logger.debug("Checking app health: crash mode is \'#{ainf[:crash_info]}\' and instances are #{cnts.inspect}")

##################puts "Checking app health: crash mode is \'#{ainf[:crash_info]}\' and instances are #{cnts.inspect}"

                  if cnts[0] != ainf[:inst_total  ] or
                     cnts[1] != ainf[:inst_running] or
                     cnts[2] != ainf[:inst_crashed] then
                    # ISSUE: if there are zero running instances, should we abort?
                    # UNDONE: what else do we need to do here?
                    @logger.warn("app #{app}: instCnt(total) is #{cnts[0]} instead of #{ainf[:inst_total  ]}") unless cnts[0] == ainf[:inst_total  ]
                    @logger.warn("app #{app}: instCnt(runng) is #{cnts[1]} instead of #{ainf[:inst_running]}") unless cnts[1] == ainf[:inst_running]
                    @logger.warn("app #{app}: instCnt(crshd) is #{cnts[2]} instead of #{ainf[:inst_crashed]}") unless cnts[2] == ainf[:inst_crashed]
                  end

                end

              when VMC_Actions::VMC_INSTCNT

                # Do we have a specific instance count change or min/max?
                if icnt
                  # Was the count "+xxx" or "-xxx" ?
                  if iinc
                    ncnt = (dry_run ? 0 : app_instance_count(app, email, client)[1]) + icnt
                    # Make sure the new instance count isn't too low
                    ncnt = 1 if ncnt < 1
                  else
                    ncnt = icnt.to_i
                  end
                  if not dry_run
                    set_instance_count(app, email, client, ncnt, false, ainf)
                  end
                else
                  puts "UNDONE: handle min/max instance count action" ; exit
                end

              when VMC_Actions::VMC_ADD_SVC

                # We should have a :services value (and it must be an array/hash)
                svcs = arg[:services]
                internal_error("Missing :services value in 'add service' action") if not svcs
                if svcs.kind_of? Hash
                  svcs = [ svcs ]
                else
                  internal_error("The :services value #{svcs} in 'add service' is of type #{svcs.class}") unless svcs.kind_of? Array
                end

                if not dry_run
                  # Look for available service(s) to satisfy the request
                  prov, = find_services(app, email, client, svcs)

                  # Bind the services(s) to the user and this app
                  begin
                    prov.each { |p| add_app_service(app, email, p) }
                    @logger.debug("Added service(s) #{svcs.inspect} to app #{app}")
                  rescue Errno::EACCES => e
                    @logger.warn("Adding services to app #{app} failed: #{e.inspect}")
                  end
                end

              when VMC_Actions::VMC_DEL_SVC

                # We should have a :services value (and it must be an array/hash)
                svcs = arg[:services]
                internal_error("Missing :services value in 'delete service' action") if not svcs
                if svcs.kind_of? Hash
                  svcs = [ svcs ]
                else
                  internal_error("The :services value #{svcs} in 'delete service' is of type #{svcs.class}") unless svcs.kind_of? Array
                end
                if not dry_run
                  del_app_service(app, email, svcs)
                  @logger.debug("Deleted service(s) #{svcs.inspect} from app #{app}")
                end

              when VMC_Actions::VMC_APPLOGS, VMC_Actions::VMC_CRSLOGS

                if not dry_run
                  # ISSUE: for crash logs we make sure there are actually crashes
                  #        present before trying to get any logs. Is this correct?
                  crash = get_app_crashes(app, email, client)
                  if not crash or crash.length == 0
                    @logger.debug("app #{app} has no crashes; ignoring get_crash_logs action")
                    next
                  end
                end

                # Get the current number of running instances
                inst = dry_run ? 1 : app_instance_count(app, email, client)[0]

                # Are we supposed to choose random instances?
                irnd = arg[:random] ? true : false

                # The meaning of the various instance values is as follows:
                #
                #   icnt        if present, get that many random instance logs
                #
                #   imin/imax   if present, random number of logs in <min .. max>
                #
                #   inum        if present, use the specific instance number; if
                #               negative, get logs for that many random instances

                # What kind of an instance count / number do we have?
                if icnt
                  # Simple count
                  lcnt = icnt
                  # We better not have min/max or 'inst_num'
                  if imin or imax or inum
                    puts "ERROR: crazy mix of icnt/imin/imax/inum" ; exit
                  end
                elsif imin or imax
                  # We better have both min/max and no 'inst_num'
                  if not imin or not imax or inum
                    puts "ERROR: crazy mix of imin/imax/inum" ; exit
                  end
                  # If min/max is negative, choose a random count
                  if imin < 0 or imax < 0
                    imin = -imin if imin < 0
                    imax = -imax if imax < 0
                    irnd = true
                    lcnt = imin + rand(imax - imin)
                  else
                    lcnt = imax - imin + 1
                  end
                  inum = imin
                elsif inum
                  lcnt = inum
                  if inum < 0
                    irnd = true
                    lcnt = -inum
                    inum = nil
                  end
                else
                  puts "ERROR: no icnt / imin / imax / inum found" ; exit
                end

                if not dry_run
                  # Pull the desired number of app/crash logs
                  lcnt.times do
                    # Pick a random instance unless we have a specific instance number
                    if irnd
                      # UNDONE: for crash logs we need to pick a crashed instance
                      inum = rand(inst).to_i
                    else
                      inum = 0 if inum >= inst
                    end

                    if act == VMC_Actions::VMC_APPLOGS
                  ####puts "Getting app   log for #{app}:#{inum}"
                      grab_app_logs(app, email, inum) unless dry_run
                    else
                  ####puts "Getting crash log for #{app}:#{inum}"
                      grab_crash_logs(app, email, client, inum) unless dry_run
                    end

                    inum += 1
                  end
                end

              when VMC_Actions::VMC_CRASHES
                if not dry_run
                  crash = get_app_crashes(app, email, client)
                end

              else
                internal_error("Unexpected 'dev' action \"#{VMC_Actions.action_to_s(act)}\"")
              end
            rescue => e
              # put our action back on and delay this and any other actions for this
              # app by to give the CC a chance to recover
              defer_time = 60
              retry_action = true
              @logger.error("Execution plan error. Deferring for #{defer_time}s #{a_our.inspect}")
              context_queue.unshift(a_our)
              new_start = Time.now - stclk + defer_time
              context_queue.each do |a|
                diff = a_our[:clock] - a[:clock]
                a[:clock] = new_start + diff if a[:args].nil? or a[:args][:app_name] == app
              end
            ensure
              if a_our and not retry_action and not typ.kind_of? TestDef_Usr
                @lck_act_count.synchronize {
                  @dev_act_count -= 1
                  @dev_act_done  += 1
                }
              end

              # Make sure the action takes the proper amount of time
              slumber(end_time - Time.now) unless dry_run

              # This context queue is ready for more work
              priority_context_queue.push(context_queue) if context_queue and not context_queue.empty?

              # This thread is no longer executing anything
              @cur_dev_cmds[thrd_num] = nil
            end
          end
        end
      end

      # Save the execution thread table in case something goes wrong
      @exec_thrds = thrd_tab
      @exec_thrds.each { |t| t.abort_on_exception = true }

      # Create a thread that will kill everything if/when 'max_runtime' is reached
      if @config['max_runtime']
        time_killer_thread = Thread.new do
          bgtm = Time.now
          slen = tlen = @config['max_runtime'].to_i
          while slen > 0 and not @test_run_done and not @stop_run_now
            sleep   0.5
            slen -= 0.5
          end
          if not @test_run_done and not @stop_run_now
            msg = "Test has been running for #{(Time.now-bgtm).to_i} seconds: trying to stop it"
            @logger.warn(msg)
            puts         msg

            # Tell everyone that it's time to stop
            if not force_stop
              sleep(1)
              # If we've starting cleaning up, no need to panic
              if not @doing_cleanup
                msg = "Execution threads refuse to stop; aborting the test the hard way"
                @logger.error(msg)
                puts          msg
                exit!
              end
            end
          end
        end
      end

      # Start a warm-and-fuzzy thread that will regularly display statistics
      fuzzy_thread = Thread.new do
        # We'll display time elapsed in our updates
        start = Time.now

        # Get hold of the update period in seconds
        freq = @config['update_freq'].to_f
        freq = 60 unless freq                 # default = 60 seconds

        while not @test_run_done and not @stop_run_now
          stamp = "[%04u sec]: " % (Time.now - start + 0.5).to_i
          report_averages(true , stamp)
          report_averages(false, stamp)

          @logger.debug("priority queue len: #{priority_context_queue.length}")
          txt = ""
          @cur_dev_cmds.each_with_index do |action, thrd|
            txt += "   Thread #%02u " %thrd
            if action
              txt += "is executing action #{action.inspect}\n"
            else
              txt += "is in IDLE\n"
            end
          end
          @logger.debug("thread state:\n#{txt}")

          # Sleep 'freq' seconds (while checking for the test ending)
          slumber(freq)
        end
      end

      # Wait for the execution threads to finish
      thrd_tab.each { |t| t.join }

      # Dump summary + log detailed final state if desired
      if @config['log_end_stat'] and not dry_run
        fin_usrs = 0 # number of users we find alive
        fin_apps = 0 # number of apps  we find alive
        fin_good = 0 # number of app instances that look healthy/running
        fin_sick = 0 # number of app instances that look  sickly/crashed

        @logger.info("Detailed end state:")

        # Iterate across all the user we (probably) created
        for u in 0..user_count-1 do
          user = @user_emails [u]
          clnt = @user_clients[u]
          next unless user

          @logger.info("User #{user}:")

          # We have a live user, apparently
          fin_usrs += 1

          # Enumerate this user's applications (if any)
          my_apps.each do |name, ainf|
            next unless ainf[:user] == u
            tcnt, rcnt, ccnt = app_instance_count(name, user, clnt)
            @logger.info("    App #{name}: T=#{tcnt},R=#{rcnt},C=#{ccnt}")
            fin_good += rcnt
            fin_sick += ccnt
          end
        end

        msg  = "#{fin_usrs} live users with #{fin_apps} apps"
        msg += ", #{fin_good} instances good" if fin_good > 0
        msg += ", #{fin_sick} instances sick" if fin_sick > 0

        @logger.info("[final]: " + msg)
        puts "End state: #{msg}"
      end

      # The run ended peacefully - see if we are supposed to pause
      if @config['pause_at_end']
        puts ; puts ; puts
        puts "----------------------------------------------------------"
        puts "Test run ended successfully - please hit enter to clean up"
        STDIN.gets
        puts "----------------------------------------------------------"
      end
    ensure
      @test_run_done = true
      cleanup
      final_report
    end

    def final_report
      @logger.info("Peak app instance count was about #{@max_instances}") if @max_instances != 0
      @logger.info("Estimated instance count error is #{@cur_instances}") if @cur_instances != 0

      if not @config['dry_run_plan']
        report_averages(true,  "[final]: ")
        report_averages(false, "[final]: ")
      end
    end

    def cleanup
      return unless @cleanup_acts > 0

      dry_run = @config['dry_run_plan']

      @doing_cleanup = true

      @cleanup_lock.synchronize do
        @logger.info("CLEANUP: start")

        # Figure out how often we should display progress
        tcnt = @cleanup_acts
        ucnt = tcnt / 10

        # Display updates with a reasonable frequency - not too low, not too high
        ucnt = 50     if ucnt > 50
        ucnt = tcnt+1 if ucnt < 5 or $bequiet or @config['dry_run_plan']

        puts "[CLEANUP] #{tcnt} entries to process" if tcnt > 50

        ccnt = 0
        ncnt = ucnt
        @cleanup.each do |a|
          # Grab the next cleanup action and skip it if it's nil
          act = a[:action] ; next unless act and act > 0

          # Mark the action as done, and update overall count
          a[:action] = 0 ; @cleanup_acts -= 1

          # If this is a "dry run", we never do any real stuff
          next if dry_run

          # Issue occassional updates so the operator doesn't panic
          ccnt += 1
          if ccnt >= ncnt
            pct = (100.0 * ccnt / tcnt + 0.5).to_i
            if pct <= 99
              puts "[CLEANUP] about %02u%% done (#{ccnt} of #{tcnt} items processed)" % pct
            end
            ncnt += ucnt
          end

          # Perform the cleanup action
          case act
          when VMC_Actions::VMC_DEL_USER
            user = a[:user]
            begin
              if $newgen
                @admin_client.delete_user(user)
              else
                delete_user(user)
              end
            rescue => e
              @logger.warn("CLEANUP: deleting user #{user} threw #{e.inspect}")
            end

          when VMC_Actions::VMC_DEL_APP
            app    = a[:app_name]
            user   = a[:user]
            client = a[:client]
            begin
              if $newgen
                client.delete_app(app)
              else
                delete_app(app, user, client)
              end
            rescue => e
              @logger.warn("CLEANUP: deleting app #{app} threw #{e.inspect}")
            end
          else
            puts "UNDONE: cleanup action #{VMC_Actions.action_to_s(act)} #{a.inspect}"
          end

        end

        @logger.warn("CLEANUP: bad accounting -- #{@cleanup_acts}") if @cleanup_acts != 0

        @logger.info("CLEANUP: done")
      end
    end

    def force_stop
      #return unless @cur_dev_cmds

      # Tell the executor and HTTP use threads that we want to stop
      @stop_run_now = true
      @http_loader.stop_test if @http_loader

      # Give everyone a chance, but only up to a certain amount of time
      20.times do
        sleep(0.5)
        return true if @test_run_done or @doing_cleanup
      end

      # The gloves come off ...
      #@cur_dev_cmds.each_with_index do |a,tx|
      #  puts("Thread #%02u is executing action #{action_to_s(a)}" % tx) if a
      #end

      false
    end

    def abort_test
      puts "Attempting to stop the test run"
      force_stop
      if not @test_run_done
        cleanup
        final_report
      end
    end
    
    def execute_action(action_item)
      action = action_item[:action]
      context = action_item[:context]
      
      act_ref = action.act_ref
      puts act_ref.description
      
      parts = act_ref.id.to_s.match(/^stac_([a-z]+[a-z0-9]*)_([a-z0-9_]+)/)
      count = context[:count_num]
      scen  = context[:global_scn_index]
      
      @logger.info("[%04u]>>#{parts[1]} \{#{ctx_mark(count, scen)}\} #{act_ref.description} #{action.act_arg.inspect}" % (Time.now - @start_time) )
      
      case act_ref.id
      when :stac_dev_add_user then dev_add_user(action_item)
      when :stac_dev_push_basic_app then dev_push_app(action_item)
      when :stac_usr_simple_sinatra then usr_http_action(action_item)
      when :stac_usr_simple_http_request then usr_http_action(action_item)
      else puts "execute_action here"
      end
      if act_ref.kind_of? Dev_Actions
        @lck_act_count.synchronize {
          @dev_act_done += 1
        }
      end
    end
    
    def dev_add_user(action_item)
      action = action_item[:action]
      context = action_item[:context]

      act_arg = action.act_arg
      email   = act_arg[:user_name]
      pass   = act_arg[:password]
      client = nil
      begin
        beg_time = Time.now
        begin
          @logger.debug("Deleting user: '#{email}'")
          delete_user_internal(@base_uri, email, auth_hdr(nil))
          @logger.debug("Deleted user: '#{email}'")
        rescue => e
          # Errors will be the common case
          @logger.debug("Error deleting user: '#{email}' error: '#{e.inspect}'")
        end
        register_internal(@base_uri, email, pass)
        rec_dev_action_result_norm(false, beg_time)
      rescue => e
        rec_dev_action_result_norm(true , beg_time)
        if e.kind_of? RuntimeError and e.to_s[0, 14] == "Invalid email:"
          fatal_error("Could not register test user #{email}: probably a turd left behind, please reset CC/HM database")
        else
          @logger.error("Could not register test user #{email}")
          raise e, e.message, e.backtrace
        end
      end
      token = login_internal(@base_uri, email, pass)
    end
    
    def dev_push_app(action_item)
      action = action_item[:action]
      context = action_item[:context]

      act_arg = action.act_arg
      app_def = AppManager.query_instance(act_arg[:app_def].to_sym)
      client = nil
      
      # Get the various arguments we need to push app bits
      app  = "#{act_arg[:app_name]}_#{context[:scn_index]}_#{context[:count_num]}"
      aurl = "#{app}.#{@config[:apps_URI]}"
      inst = act_arg[:app_insts].to_i
      
      path = app_def.app_dir
      amem = app_def.app_mem
      fmwk = app_def.app_fmwk
      exec = app_def.app_exec
      svcs = app_def.app_svcs
      awar = app_def.app_war
      crsh = app_def.app_crash
      
      # Create and record the app descriptor
      
      ainf = {
               :user         => context[:count_num],
               :inst_total   => 0,
               :inst_running => 0,
               :inst_crashed => 0,
               :crash_info   => crsh,
             }
             
      #ma_lock.synchronize { my_apps[app] = ainf }
      
      #if not dry_run
        manifest = {
          :name => "#{app}",
          :staging => {
            :framework => fmwk,#changed by jacky
            :runtime => exec#changed by jacky
          },
          :uris      => [aurl],
          :instances => 1,
          :resources => { :memory => mem_in_MB(amem) },
        }
        
        email  = context[:user_name]
        
        # Provision services if the app asked for any
        provs, hasdb = find_services(app, email, client, svcs)
      
        # Send the manifest to the cloud controller
        beg_time = Time.now
        begin
          # Create the app
          if $newgen
            client.create_app(app, manifest)
            rec_dev_action_result_norm(false, beg_time)
          else
            response = create_app_internal(@droplets_uri, manifest, auth_hdr(email))
            handle_response(response, beg_time)
          end
      
          # App created - make sure we delete it no matter what happens
          @cleanup_lock.synchronize do
            @cleanup = [ { :action => VMC_Actions::VMC_DEL_APP, :client   => client,
                                                                :user     => email,
                                                                :app_name => app } ] + @cleanup
            @cleanup_acts += 1
          end
      
          # Now upload the app bits
          pushed = push_app_bits(app, email, client, false, path, provs, awar, hasdb)
        rescue => e
          rec_dev_action_result_norm(true , beg_time)
          @logger.error("Could not create app #{app} -- #{e.inspect}")
          pushed = false
        end
      
        # If pushed OK, wait for the correct number of running instances
        if not pushed or set_instance_count(app, email, client, inst, true, ainf) == 0
          return if @stop_run_now
      
          # Zap all future actions related to this app
          orig_len = context_queue.length
          context_queue.delete_if {|a| a[:args] and a[:args][:app_name] == app and not a[:act_type].kind_of? TestDef_Usr}
          aborted = @lck_act_count.synchronize { aborted = orig_len - context_queue.length }
          @lck_act_count.synchronize {
            @dev_act_count   -= aborted
            @dev_act_done    += aborted
            @dev_act_aborted += aborted
          }
      
          # We couldn't push or get even one instance of the app running
          @logger.error("Could not get app #{app} started; aborting run and #{aborted} actions")
        end
      #end
    end
    
    def usr_http_action(action_item)
      action = action_item[:action]
      context = action_item[:context]
      scn_var = action_item[:scn_var]

      act_arg = action.act_arg if action
      if @config['http_url']
        app_url = @config['http_url']
      else
        app = "#{act_arg[:app_name]}_#{context[:scn_index]}_#{context[:count_num]}"
        app_url = "#{app}.#{@config[:apps_URI]}"
      end
      
      act_ref = action.act_ref if action
      user_actions = act_ref.usr_actions if act_ref
      
      http_load = ActionQueueManager.evaluate_value(scn_var, act_arg[:http_load]).to_i
      http_ms_pause = ActionQueueManager.evaluate_value(scn_var, act_arg[:http_ms_pause]).to_i
      http_duration = ActionQueueManager.evaluate_value(scn_var, act_arg[:duration])
      
      #Add possibility to change the value by command
      http_load = @config[:end_user_sum].to_i if @config[:end_user_sum]
      http_ms_pause = @config[:think_time].to_i if @config[:think_time]
      http_duration = @config[:http_duration].to_i if @config[:http_duration]
      
      @http_loader.run_new(app_url, user_actions, http_ms_pause, http_duration, http_load, @start_time)
      
    end

  end # class StressTestExec
end
