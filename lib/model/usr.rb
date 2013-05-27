
module STAC
  class Usr_Actions < Identity
    
    attr_accessor :usr_actions
    
    def fill(data)
      super
      @usr_actions = parseArray(@usr_actions, Usr_Action)
      
      percentageSum = 0
      @usr_actions.each do |usr_actions|
        percentageSum += usr_actions.fraction
      end
      if percentageSum != 100
        @@logger.error("FATAL: sum of :fraction values is #{percentageSum} instead of 100")
        exit 1
      end
    end
  end
  
  class Usr_Action < Base_Model
    
    attr_accessor :fraction
    attr_accessor :usr_action
    attr_accessor :url
    attr_accessor :duration
    attr_accessor :value
    attr_accessor :rndval_min
    attr_accessor :rndval_max
    attr_accessor :rnddsz_min
    attr_accessor :rnddsz_max
    attr_accessor :data_size
    
    def initialize()
      @fraction = 100 #Initilization
    end
  end
end