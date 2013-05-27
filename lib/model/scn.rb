
module STAC
  class Scenario < Identity
    
    attr_accessor :scn_actions
    attr_accessor :no_stop
    attr_accessor :scn_var
    
    def initialize()
      @no_stop = false #Initilization
    end
    
    def fill(data)
      super
      @scn_actions = parseArray(@scn_actions, Scn_Action)
      #puts @actions
      #expand
    end
    
    # This is for expanding all defined variable with concrete value
    def expand(data={})
      @scn_var = data
      state = {}
      to_be_del = []
      @scn_actions.each do |scn_action|
        actRef = scn_action.act_ref #e.g, exec_def_var
        actArg = scn_action.act_arg
        
        if actRef.kind_of? Information
          # The information data has different resolve way
          pair = actRef.exec.call(actArg)
          state[pair[0].to_sym] = pair[1]
          to_be_del << scn_action
        else
          actArg.each do |key, value|
            if value.to_s.match(/^#{ARG_SUB_PREFIX}.+$/)
              actArg[key] = state[value]
            end
          end
        end
      end
      to_be_del.each do |scn_action|
        @scn_actions.delete(scn_action)
      end
      #puts @scn_actions
    end
    
'''
    # This is for expanding all defined variable with concrete value
    def expand(data)
      state = {}
      to_be_del = []
      @scn_actions.each do |scn_action|
        actRef = scn_action.act_ref #e.g, exec_def_var
        actArg = scn_action.act_arg
        
        if actRef.kind_of? Information
          # The information data has different resolve way
          pair = actRef.exec.call(actArg)
          state[pair[0].to_sym] = pair[1]
          to_be_del << scn_action
        else
          actArg.each do |key, value|
            if value.to_s.match(/^#{ARG_SUB_PREFIX}.+$/)
              actArg[key] = state[value]
            elsif value.to_s.match(/^\$.+\|.+$/)
              # The mark "|" here is to seperate the variable and default value, if no value passed, the default value will be used 
              matchTmp = value.to_s.match(/^\$(.+)\|(.+)$/)
              keyInData = matchTmp[1]
              defaultValue = matchTmp[2]
              if data[keyInData.to_sym]
                actArg[key] = data[keyInData.to_sym]
              else
                actArg[key] = matchTmp[2]
              end
              actArg[key] = state[value]
            elsif value.to_s.match(/^\$.+$/)
              matchTmp = value.to_s.match(/^\$(.+)$/)
              keyInData = matchTmp[1]
              if data[keyInData]
                actArg[key] = data[keyInData]
              else
                # If no value passed and default value existed, popup error and quit
                @@logger.error("The variable #{keyInData} is not defined in test mix level")
                exit 1
              end
            end
          end
          actRef.expand(actArg)
        end
      end
      to_be_del.each do |scn_action|
        @scn_actions.delete(scn_action)
      end
      #puts @scn_actions
    end
'''
  end
  
  class Scn_Action < Base_Model
    
    attr_accessor :act_id
    attr_accessor :act_arg
    attr_accessor :act_ref # Dev_Action or Usr_Action 
    
    def initialize()
      @act_arg = {} #Initilization
    end
    
    def fill(data)
      data.each do |key, value|
        case key
        when :act_id
          @act_id = value
          
          # Convert act_id to real action instance
          @act_ref = BaseManager.get_manager(value).query_instance(value)
        else
          @act_arg[key] = value
        end
      end
    end
  end
end