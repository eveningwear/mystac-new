#!/usr/bin/env ruby

module STAC
  ############################################################################
  #
  #   The 'StressTestRunner' class loads up the app / dev / etc. definitions,
  #   and then executes the test mix(es) selected on the command line.
  #
  ############################################################################
  
  ARG_SUB_PREFIX = "__STAC_ARG_"    # marks arg substitutions

  SCN_REF_PREFIX = "USR_SCN_"       # scenarios are referenced via this string
  class StressTestRunner

    attr_accessor :logger
    attr_accessor :config

    AC_HOMEDIR = File.join(File.dirname(__FILE__), '..')

    def initialize(_config, _logger)
      @config = _config
      @logger = _logger

      # Lock and counter for inventing unique index values
      @@index_lock = Mutex.new
      @@index_next = 0

      # Lock for max. clock value
      @maxclk_lock = Mutex.new
      
      InfManager.factory(_logger)
      AppManager.factory(_logger)
      DevManager.factory(_logger)
      ScnManager.factory(_logger)
      MixManager.factory(_logger)
      UsrManager.factory(_logger)
      
      Base_Model.set_logger(_logger)
      ActionQueueManager.set_logger(_logger)
      PriorityQueueManager.set_logger(_logger)
      VMC_Actions.set_logger(_logger)
    end

    def self.new_unique_index
      @@index_lock.synchronize do
        ret = @@index_next ; @@index_next += 1
        return ret
      end
    end

    def self.max_unique_index
      @@index_next
    end

    # Load all definition files in the given directory
    def load_def_dir_new(dir)
      Dir.glob(File.join(dir, "*.stac")).each { |f| load_def_file_new(f)}
    end

    # Collect an argument string passed to a scenario reference
    def grab_scn_arg(str, pos)
      return 0 unless str[pos, 1] == "("

      # Ready to collect the (argument) string
      beg = pos
      lps = lbs = lcs = 0

      # Simple scan: note pair nesting and strings, nothing else
      while pos < str.length
        case str[pos,1]
        when ')'
          # Return the length of the matched string to the caller
          return pos + 1 - beg if lps == 1 and lbs == 0 and lcs == 0
          lps -= 1
        when '('
          lps += 1

        when '['
          lbs += 1
        when ']'
          lbs -= 1

        when '{'
          lcs += 1
        when '}'
          lcs -= 1

        end
        pos += 1
      end
    end

    # A little helper that expands any references to built-in functions
    def replace_builtins(str)
      vpos = 0
      while fpos = str.index("&", vpos)
        # Check for names of the built-in functions
        repl = nil

        # Check for a scenario reference
        if str[fpos+1, SCN_REF_PREFIX.length] == SCN_REF_PREFIX
          # First grab the scenario name
          m = str.match(/\w+\s*/, fpos + 9)
          if m
            sn = m[0]
            bp = fpos + 9 + sn.length
            # We have the scenario name, now collect the argument string (if any)
            as = grab_scn_arg(str, bp)
            # Wrap the "&USR_SCN_xxxx(arg)" thing in quotes
            olen = SCN_REF_PREFIX.length + 1 + sn.length + as
            str[fpos, olen] = '"$' + str[fpos+1, olen - 1] + '"'
############puts "Scenario argument replaced: #{str[fpos, olen+10]}"
          end
        else
          # For now we just hard-wire some names here (because we're lazy)
          repl = "&instance_count",9 if str[fpos+1,9] == "INST_CNT("
          repl = "&random"        ,4 if str[fpos+1,4] == "RND("

          # Did we have a match?
          if repl
            # Replace the "&name(" part with the new name
            str[fpos, repl[1]] = repl[0]
          end
        end

        # Continue looking for more replacements in the rest of the string
        vpos = fpos + 1
      end
      str
    end

    def __builtin(name, *args)
      name + args.to_s
    end

    def verify_target_URL(host)
      begin
        resp = HTTPClient.send("get", host + "/info")

        # Make sure the reply looks reasonable
        if not resp or resp.status >= 400
          puts "FATAL: response from #{host}/info had status #{resp.status}"
          return true
        end

        # Try to JSON the response
        info = JSON.parse(resp.content)

        # Anything else we should check here?
        if info['name'] != "vcap"
          puts "FATAL: response from #{host}/info doesn't look right: #{resp.content[0..30]} ..."
          return true
        end

        return false
      rescue => e
        puts "FATAL: could not get response from #{host}/info - error #{e.inspect}"
        return true
      end
    end

    def log_health(which, comp, lastx, status, resp="")
      if status.to_i >= 400 or resp.chomp == ""
        # ISSUE: should we log failures?
        return
      end

      # Ignore useless reports (/healthz says nothing useful right now)
      return if resp.chomp == "ok"

      # The response should be in JSON, but be careful
      begin
        resp = JSON.parse(resp)
      rescue => e
        @logger.warn("The #{which} value was not JSON or something: #{resp}")
        return
      end

      # Get hold of the last set of values we logged (if any)
      last = comp[:last][lastx] || {}

      # Collect the status into a single string to log all at once
      rep = ""
      resp.each do |key,val|
        next if key == "uptime" and not $xdetail
        if last[key] != val
          rep += "    %-24s -> #{val.inspect}\n" % key
          last[key] = val
        end
      end
      comp[:last][lastx] = last
      @logger.info("/#{which} status for #{comp[:type]} #{comp[:host]}:\n" + rep) if rep != ""
    end

    def components_poll
      return if @components.empty?

      @logger.info("Updating health status for all components ...")

      @components.each_value do |component|
        mtch = component[:host].match(/(.*):(.*)/)
        host = mtch[1]
        port = mtch[2].to_i

        cred = component[:credentials]

        begin
          if false
            url = "http://#{component[:host]}/healthz"
            http_hltz = EM::HttpRequest.new(url).get :head => { "authorization" => component[:credentials] }
            http_hltz.callback { log_health("healthz", component, 0, http_hltz.response_header.status, http_hltz.response) }
            http_hltz.errback  { log_health("healthz", component, 0, 503) }
          else
            resp = nil
            Net::HTTP.start(host, port) {|http|
              req = Net::HTTP::Get.new('/healthz')
              req.basic_auth cred[0], cred[1] if cred
              resp = http.request(req)
            }
            log_health("healthz", component, 0, 200, resp.body)
          end
        rescue => e
          log_health("healthz", component, 0, 503, e.inspect)
        end

        begin
          if false
            url = "http://#{component[:host]}/varz"
            http_varz = EM::HttpRequest.new(url).get :head => { "authorization" => component[:credentials] }
            http_varz.callback { log_health("varz", component, 1, http_varz.response_header.status, http_varz.response) }
            http_varz.errback  { log_health("varz", component, 1, 503) }
          else
            resp = nil
            Net::HTTP.start(host, port) {|http|
              req = Net::HTTP::Get.new('/varz')
              req.basic_auth cred[0], cred[1] if cred
              resp = http.request(req)
            }
            log_health("varz", component, 1, 200, resp.body)
          end
        rescue => e
          log_health("varz", component, 1, 503, e.inspect)
        end

      end
    end

    def component_discover(msg)
      begin
        info = Yajl::Parser.parse(msg, :symbolize_keys => true)
      rescue
        info = nil
      end

      # If we have nothing or are missing type/uuid/host, it's no good
      if not info or not info[:type] or not info[:uuid] or not info[:host]
        @logger.error("Received non-comformant reply for component discover: #{msg}")
        return
      end

      # Have we seen this component already?
      old = @components[info[:uuid]]
      if old
        # This is old news - just make sure we copy over any :last values
        last = old[:last]
      else
        # Log the discovery of this component
        @logger.info("Component #{info[:host]} #{info[:type]}")
        # We don't have any :last values yet
        last = [nil,nil]
      end

      # Use the new info while making sure we preserve any 'last' values
      info[:last] = last
      @components[info[:uuid]] = info
    end
    
    # Load a definition file contents and record it in the appropriate table
    def load_def_file_new(file)
      ex_proc = lambda do |msg|
        puts "ERROR: Problem reading definition file #{file}: #{msg}"
        exit
      end

      @logger.debug("Loading definition file #{file}")

      # Try to load and evaluate the contents of the file
      data = nil
      begin
        # Read the file into a variable
        cont = File.read(file)
        # Process any built-in function calls
        cont = replace_builtins(cont)
        # Process any argument substitutions
        cont = cont.gsub(/&([A-Z_]+)/, ":#{ARG_SUB_PREFIX}\\1")
        data = eval(cont)
      rescue Exception => err
        ex_proc.call("#{err}")
      end

      @logger.debug("Loaded  definition file #{file} ...")

      # The result better be a hash
      ex_proc.call("contents is not a hash") unless data.kind_of? Hash

      # Get hold of the "id" value
      id = data[:id].to_s
      
      #@appManager.parse_data(data)
      #eval("@#{BaseManager.parse_prefix(data[:id])}Manager.parse_data(data, file)")
      BaseManager.get_manager(id).parse_data(data, file)

      # Check the id prefix to determine the type of definition
      #idef, id = TestDef_Base.parse_def_id(id)

      # Fail if the id didn't parse OK
      #ex_proc.call(id) unless idef

      # Replace the id with the "naked" id in the hash
      #data[:id] = id

      # Check and record the data in the appropriate table
      #err = idef.record_def(file, data)
      #ex_proc.call(err) if err
    end

    # Main entry point: load definitions and run a test mix (or mixes)
    def run_test
      logger.info("Starting stress test run")

      # Create the pre-defined "info" actions
      #FactInst_Inf.create_predefs

      # Get hold of the URL for the target AC
      target = @config[:target_AC]

  ##  puts
  ##  puts "Cmdline: #{ARGV.inspect}"
  ##  puts "Config : #{@config.inspect}"
  ##  puts

      # Load all definitions (given by config file and command line)
      #@config['def_dirs' ].each { |d| load_def_dir(d)  } if @config['def_dirs' ]
      #@config['def_files'].each { |f| load_def_file(f) } if @config['def_files']
      
      @config['def_dirs3' ].each { |d| load_def_dir_new(d)  } if @config['def_dirs3' ]

  ##  puts "AppDefs 1: #{$app_defs.inspect}"
  ##  puts "DevDefs 1: #{$dev_defs.inspect}"
  ##  puts "UseDefs 1: #{$usr_defs.inspect}"
  ##  puts "ScnDefs 1: #{$scn_defs.inspect}"
  ##  puts "MixDefs 1: #{$mix_defs.inspect}"
  ##  puts

      # Verify that the data looks reasonable and hook up refs
      # Actually, y = TestDef_App.find_inst(x) # Add by Jacky
      #$app_defs.each { |x,y| TestDef_App.find_inst(x).makeup_def() }
      #$dev_defs.each { |x,y| TestDef_Dev.find_inst(x).makeup_def() }
      #$usr_defs.each { |x,y| TestDef_Usr.find_inst(x).makeup_def() }
      #$scn_defs.each { |x,y| TestDef_Scn.find_inst(x).makeup_def() }
      #$mix_defs.each { |x,y| TestDef_Mix.find_inst(x).makeup_def() }
      #$inf_defs.each { |x,y| TestDef_Inf.find_inst(x).makeup_def() }

  ##  puts "AppDefs 2: #{$app_defs.inspect}"
  ##  puts "DevDefs 2: #{$dev_defs.inspect}"
  ##  puts "UseDefs 2: #{$usr_defs.inspect}"
  ##  puts "ScnDefs 2: #{$scn_defs.inspect}"
  ##  puts "MixDefs 2: #{$mix_defs.inspect}"
  ##  puts

      # Create an instance of the executor class
      @executor = StressTestExec.new(config, logger, target)

      # Enable tracing if desired
      #@executor.trace = $verbose ? true : false

      # Do a quick sanity check on the target URL (unless this is a dry run)
      if not @config['dry_run_plan'] and not @config['http_url']
        turl = "http://" + target
        if verify_target_URL(turl)
          puts "Please check your target URL and Cloud Foundry setup"
          exit 1
        end

        # Make sure we can login using the supplied creds
        au = @config['ac_admin_user']
        ap = @config['ac_admin_pass']

        begin
          begin
            @executor.register_internal(turl, au, ap)
          rescue
          end
          atok = @executor.login_internal(turl, au, ap)
        rescue => e
          if not e.kind_of? RuntimeError or e.to_s != "login failed"
            puts "ERROR: Exception from login: #{e.to_s}"
          end
          puts "ERROR: could not login as admin user \'#{au}\', please check the creds"
          exit 1
        end

        # Create the basic authorization header
        auth = { 'AUTHORIZATION' => atok.to_s }

        # Verify that we can create a user, then login and and proxy that user
        test_user = (@config['unique_stacid'] || "") + "ac-test-probe-user@vmware.com"
        test_pass = "random"
        have_user = false

        begin
          # Create a user account with a name that hopefully is unique to us
          begin
            @executor.register_internal(turl, test_user, test_pass)
          rescue => e
            @logger.error("Could not register a test user, please check remote admin: #{e.inspect}")
            exit 1
          end

          # Make sure we delete this user no matter what happens below
          have_user = true

          # Login the user we just created
          begin
            @executor.login_internal(turl, test_user, test_pass)
          rescue => e
            @logger.error("Could not login a test user, please check remote admin: #{e.inspect}")
            exit 1
          end

          # Create an auth header with the user as being proxied
          aprx = auth.dup
          aprx['PROXY-USER'] = test_user

          # Try to do something (anything) with the user proxied
          begin
            alst = @executor.get_apps_internal(turl + "/apps", aprx)
            # get_apps_internal() returns an array when things work correctly
            throw "bad response" unless alst and alst.kind_of? Array
          rescue => e
            @logger.error("Could not proxy a test user, please make sure #{au} is an admin: #{e.inspect}")
            exit 1
          end

          # Done with the test user - the 'ensure' clause below will clean up
        ensure
          begin
            @executor.delete_user_internal(turl, test_user, auth) if have_user
          rescue => e
            puts "WARNING: could not delete test user account #{test_user} - #{e.inspect}"
          end
        end
      end

      # Figure out which test mix we're supposed to run
      if @config['http_url']
        ActionQueueManager.assemble_action_queue(:stac_mix_simple_http_load)
      else
        #ActionQueueManager.assemble_action_queue(@config['what_to_run'])
        ActionQueueManager.assemble_action_queue(:stac_mix_simple_sinatra)
      end
      PriorityQueueManager.prioritize(ActionQueueManager.get_queue)
      @executor.simulate
      exit
    end

    def abort_test
      @executor.abort_test
    end
  end
end
