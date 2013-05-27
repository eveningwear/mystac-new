
module STAC
  
  class Dev_Actions < Identity
    
    attr_accessor :dev_actions
    
    def fill(data)
      super
      @dev_actions = parseArray(@dev_actions, Dev_Action)
    end
    
    '''
    def expand(data)
      @dev_actions.each do |dev_action|
        dev_action.expand(data)
      end
    end
    '''
  end
  
  class Dev_Action < Base_Model
    
    attr_accessor :dev_action
    attr_accessor :args
    
    def fill(data)
      super
      #@args = parseHash(@args, Dev_Action_Arg)
    end
    
    '''
    def expand(data)
      @args.each do |key, value|
        if value.to_s.match(/^#{ARG_SUB_PREFIX}.+$/)
          @args[key] = data[key]
        end
      end
    end
    '''
  end
  
  class Dev_Action_Arg < Base_Model
    
    attr_accessor :app_name
    attr_accessor :app_def
    attr_accessor :inst_cnt
    attr_accessor :rel_icnt
    attr_accessor :inst_num
    attr_accessor :app_insts
    attr_accessor :services
    attr_accessor :random
    attr_accessor :inst_min
    attr_accessor :inst_max
    
    def initialize()
      @inst_num = 1
      @services = []
    end
    
  end
end