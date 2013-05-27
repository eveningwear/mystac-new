
require 'digest/md5'

module STAC
  
  class SeedManager
    
    @@seed = nil
    
    # Generate a seed
    def self.get_seed()
      now = Time.now.to_s
      @@seed = get_random(now) unless @@seed
      @@seed
    end
    
    # Pass a static string which will be combined with seed to output a random number
    def self.get_random(data)
      data = "#{data.to_s}_#{@@seed}" if @@seed
      sMd5 = Digest::MD5.hexdigest(data)
      numStr = sMd5.gsub(/[a-zA-Z]+/, "")
      numStr = numStr.length > 8? numStr[0..7]:numStr[0..numStr.length-1]
      numStr.to_i
    end
    
    def self.factory(logger = nil)
      @@single_instance = new(logger) unless @@single_instance
      @@single_instance
    end
  end
end