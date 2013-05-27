require 'rubygems'
require 'mysql'

def self.set_root dir=nil
  if @root == nil
    @root = File.dirname(Dir.pwd)
  end
  Dir.chdir("#{@root}/#{dir}")
end

@db_config = {
  :host => '127.0.0.1',
  :port => 3306,
  :user => 'root',
  :password => 'root',
  :db_name => 'simple'
}

def self.delete_db
  db_cfg = get_db_config
  begin
    host = db_cfg[:host]
    port = db_cfg[:port]
    user = db_cfg[:user]
    password = db_cfg[:password]
    name = db_cfg[:db_name]

    puts "Deleting database: #{name}"
    connection = Mysql.real_connect(host, user, password, 'mysql', port)
    connection.query("DROP DATABASE #{name}")
    puts "Successfully deleted database: #{name}"
  rescue Mysql::Error => e
    puts "Could not delete database: [#{e.errno}] #{e.error}"
  ensure
    connection.close if connection
  end
end

def self.create_db
  db_cfg = get_db_config
  begin
    host = db_cfg[:host]
    port = db_cfg[:port]
    user = db_cfg[:user]
    password = db_cfg[:password]
    name = db_cfg[:db_name]

    puts "Creating database: #{name}"
    connection = Mysql.real_connect(host, user, password, 'mysql', port)
    connection.query("CREATE DATABASE #{name}")
    connection.query("GRANT ALL ON #{name}.* to #{user}@'%' IDENTIFIED BY '#{password}'")
    connection.query("FLUSH PRIVILEGES")
    puts "Successfully created database: #{name}"
  rescue Mysql::Error => e
    puts "Could not create database: [#{e.errno}] #{e.error}"
  ensure
    connection.close if connection
  end
end

def self.get_db_config
  @db_config
end

@db_config[:db_name] = ARGV[0] if ARGV.length > 0

delete_db
create_db
