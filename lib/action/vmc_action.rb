module STAC

  class VMC_Actions
    # The following actions map directly onto AC commands
    VMC_ADD_USER  =  1
    VMC_DEL_USER  =  2
    VMC_PUSH_APP  =  3
    VMC_DEL_APP   =  4
    VMC_UPD_APP   =  5
    VMC_INSTCNT   =  6
    VMC_CRASHES   =  7
    VMC_CRSLOGS   =  8
    VMC_APPLOGS   =  9
    VMC_ADD_SVC   = 10
    VMC_DEL_SVC   = 11

    # The following are pseudo-actions (more complex that one AC command)
    VMC_CHK_APP   = 50

    def self.set_logger(logger)
      @@logger = logger
    end

    def self.action_to_s(act)
      case act
      when VMC_ADD_USER then return "register"
      when VMC_DEL_USER then return "unregister"
      when VMC_PUSH_APP then return "push"
      when VMC_DEL_APP  then return "delete"
      when VMC_UPD_APP  then return "update"
      when VMC_INSTCNT  then return "instances"
      when VMC_CRASHES  then return "crashes"
      when VMC_CRSLOGS  then return "crashlogs"
      when VMC_APPLOGS  then return "logs"
      when VMC_ADD_SVC  then return "bind-service"
      when VMC_DEL_SVC  then return "unbind-service"
      when VMC_CHK_APP  then return "-check-app-"
      else                   return "unknown#{act}"
      end
    end
    
    def self.execute_action(action, config)
      act_ref = action.act_ref
      case act_ref.id
      when :stac_dev_add_user then vmc_add_user(action, config)
      when :stac_dev_push_basic_app then vmc_push_app(action, config)
      else puts "test"
      end
    end
    
    def self.get_admin_token(config)
      base_uri = "http://" + config[:target_AC]
      admin_token = login_internal(base_uri, config['ac_admin_user'],
                                             config['ac_admin_pass'])
      admin_token
    end
    
    def self.vmc_add_user(action, config)
      base_uri = "http://" + config[:target_AC]
      act_arg = action.act_arg
      mail   = "#{act_arg[:user_name]}@vmware.com"
      pass   = act_arg[:password]
      client = nil
      begin
        beg_time = Time.now
        begin
          @@logger.debug("Deleting user: '#{mail}'")
          delete_user_internal(base_uri, mail, auth_hdr(nil, config))
          @@logger.debug("Deleted user: '#{mail}'")
        rescue => e
          # Errors will be the common case
          @@logger.debug("Error deleting user: '#{mail}' error: '#{e.inspect}'")
        end
        register_internal(base_uri, mail, pass)
        rec_dev_action_result_norm(false, beg_time)
      rescue => e
        rec_dev_action_result_norm(true , beg_time)
        if e.kind_of? RuntimeError and e.to_s[0, 14] == "Invalid email:"
          fatal_error("Could not register test user #{mail}: probably a turd left behind, please reset CC/HM database")
        else
          @@logger.error("Could not register test user #{mail}")
          raise e, e.message, e.backtrace
        end
      end
      token = login_internal(base_uri, mail, pass)
    end
    
    def self.vmc_push_app(action, config)
      base_uri = "http://" + config[:target_AC]
      act_arg = action.act_arg
    end
    
  end
end
