
module STAC
  class Error < StandardError; end

  class AppResponseError < Error
    def initialize(msg, response, app, user)
      @msg      = msg
      @response = response
      @app      = app
      @user     = user
    end

    def to_s
      "#{@msg} app: '#{@app}' user: '#{@user}' status: #{@response.status}"
    end
  end

  class AppInfoError < AppResponseError
    def initialize(*args)
      super("Could not get info", *args)
    end
  end

  class AppLogError < AppResponseError
    def initialize(response, app, user)
      super("Could not get log", *args)
    end
  end

  class AppCrashLogError < AppResponseError
    def initialize(*args)
      super("Could not get crash log", *args)
    end
  end

  class AppCrashesError < AppResponseError
    def initialize(*args)
      super("Could not get crashes", *args)
    end
  end
end