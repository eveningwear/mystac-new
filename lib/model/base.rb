
module STAC
  
  class Base_Model
    
    def self.set_logger(logger)
      @@logger = logger
    end
    
    def fill(data)
      data.each do |key, value|
        begin
          eval("@#{key} = value")
        rescue => e
          @@logger.error "ERROR: Exception from fill key #{key} #{e.to_s}"
          exit 1
        end
      end
    end
    
    '''
    def expand(data)
    end
    '''
    
    def parseArray(data, className)
      if data and (data.kind_of? Array) then
        newArray = []
        data.each do |item|
          begin
            obj = className.new
            obj.fill(item)
            newArray << obj
          rescue => e
            @@logger.error "ERROR: When passing data #{item.to_s} for class #{className}"
            exit 1
          end
        end
        newArray
      end
    end
    
    def parseHash(data, className)
      if data and (data.kind_of? Hash) then
        obj = className.new
        data.each do |key, value|
          begin
            eval("obj.#{key} = value")
          rescue => e
            @@logger.error "ERROR: When passing key #{key} with value #{value} for class #{className}"
            exit 1
          end
        end
        obj
      end
    end
  end
  
  class Identity < Base_Model
    attr_accessor :id
    attr_accessor :description
    attr_accessor :src
    
    def pull_id(value)
      # TODO: Need determine to use original id design or just keep id without artifact
      #parts = value.to_s.match(/^stac_([a-z]+[a-z0-9]*)_([a-z0-9_]+)/)
      #parts[2]
      value
    end
    
    def fill(data)
      super
      @id = pull_id(@id)
    end
  end
end