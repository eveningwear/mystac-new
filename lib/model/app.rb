
module STAC
'''
Example Application
{
    :id => :stac_app_sinatra,
    :description => "sinatra app designed for STAC testing",

    :app_dir  => "apps/sinapp",
    :app_fmwk => "http://b20nine.com/unknown",
    :app_exec => "ruby simple.rb",
    :app_mem  => "64M",
    :app_crash => :random
    :app_svcs => [
                   { :svc_type => "key-value", :svc_vendor => "redis" }
                 ]
}
'''
  class Application < Identity
    
    attr_accessor :app_name
    attr_accessor :app_dir
    attr_accessor :app_fmwk
    attr_accessor :app_exec
    attr_accessor :app_mem
    attr_accessor :app_war
    attr_accessor :app_crash
    attr_accessor :app_svcs
    
    def initialize()
      @app_mem   = "128M"
      @app_war   = nil
      @app_svcs  = []
      @app_crash = :never
    end
    
    def fill(data)
      super
      @app_svcs = parseArray(@app_svcs, Service)
    end
  end
  
  class Service < Base_Model
    
    attr_accessor :svcType
    attr_accessor :svcVendor
    attr_accessor :svcVersion
  end
end