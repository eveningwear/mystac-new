
module STAC
  
  class Test_Mixes < Identity
    
    attr_accessor :test_mix
    
    def fill(data)
      super
      @test_mix = parseArray(@test_mix, Test_Mix)
    end
  end
  
  class Test_Mix < Base_Model
    attr_accessor :count # That determine how many parrel with same scenario, if Dev Action defined in the scenario, there will create Dev User correspondently
    attr_accessor :fraction # No useful now, I don't want to support to use that here
    attr_accessor :scn_mix
    attr_accessor :scn_var # This is to provide chance to change the default value in the scenario
    
    def initialize()
      @fraction = 100 #Initilization
    end
    
    def fill(data)
      super
      @scn_mix = parseArray(@scn_mix, Scn)
    end
    
    # This is for expanding all defined variable with concrete value
    def expand()
      state = {}
      to_be_del = []
      @scn_mix.each do |scn|
        scnRef = scn.scn_ref
        
        # Make sure all the variable has a value
        #scnRef.expand(@scn_var)
        scnRef.expand(@scn_var)
      end
    end
  end
  
  class Scn < Base_Model
    
    SCN_REF_PREFIX = "USR_SCN_"
    SCN_REF_PREFIX_INSTEAD = "stac_scn_" 
    
    attr_accessor :scn_ref
    attr_accessor :app_ref
    
    def fill(data)
      matchArray = data.match(/^(\$#{SCN_REF_PREFIX}[a-z]+[a-z0-9_]*)[\(]:{0,1}([a-z0-9_]*)[\)]$/)
      if not matchArray
        @@logger.error("The data #{data} does not match expected format")
        exit
      end
      
      # Grab Scenario id
      scnId = matchArray[1].gsub(/^\$#{SCN_REF_PREFIX}([a-z]+[a-z0-9_]*)/, "#{SCN_REF_PREFIX_INSTEAD}\\1")
      @scn_ref = ScnManager.query_instance(scnId.to_sym)
      
      # Grab Application id
      appId = matchArray[2]
      @app_ref = AppManager.query_instance(appId.to_sym)
    end
  end
end
