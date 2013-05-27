#!/usr/bin/ruby -w
require 'fileutils'
require 'optparse'

module LoadRunner
  @@num_users = 1
  @@instances = 1
  @@execute = false
  @@load_file = nil
  USAGE = 'usage: loaded_runner.rb [OPTIONS] loadfile.rb'
  
  class << self
    def parse_options
      options = OptionParser.new do |opts|
          opts.banner = USAGE

          opts.on("-u", "--users [ARG]", "number of users") do |opt|
            @@num_users = opt.to_i
          end
          
          opts.on("-i", "--instances [ARG]", "number of instances") do |opt|
            @@instances = opt.to_i
          end

          opts.on("-x", "--execute", "execute test plan") do 
            @@execute = true
          end

          opts.on("-h", "--help", "Help") do
            puts opts
            exit
          end
      end
      options.parse!(ARGV)
      if ARGV.length != 1
          puts "Expected one argument (loadfile.rb) but found #{ARGV.length}"
          puts USAGE
          exit
      end
      @@load_file = ARGV[0]
    end

    def do_system(command)
      puts command
      system(command) if @@execute
    end

    def register_user(email)
      puts "setting up user #{email}"
      do_system("vmc register --email #{email} --passwd test")
    end
    
    def unregister_user(email)
      puts "removing user #{email}"
      do_system("vmc unregister #{email}")
    end
    
    def user_names
      names = []
      @@num_users.times {|unum| names << "test#{unum}@test.com"}
      names
    end

    def setup_users(users)
      users.each {|name| register_user(name)}
    end

    def delete_users(users)
      users.each {|name| unregister_user(name)}
    end

    
    def lr_spawn(path)
      pid = fork do
        exec 'ruby',path
      end
      puts "started worker with pid: #{pid}"
    end
  end

  parse_options
  users = user_names
  setup_users(users)
  puts "Starting run.."
  users.each { |user|
    @@instances.times { |instance|
      ENV['LOADED_EXECUTE'] = 'TRUE' if @@execute
      ENV['LOADED_APPNAME'] = 'test_app_' + instance.to_s
      ENV['LOADED_USERNAME'] = user
      lr_spawn(@@load_file)
    }
  }
  Process.waitall
  puts "Run complete..."
  delete_users(users)
end
