class Spooge < ActiveRecord::Base

  
  #very hacky just for test
  def name=(n)
    self[:name] = n
  end

  def name
    self[:name]
  end

  def email=(e)
    self[:email] = e
  end

  def email
    self[:email]
  end

  def touch_date=(d)
    self[:touch_date] = d
  end

  def touch_date
    self[:touch_date]
  end

  def status=(s)
    self[:status] = s
  end

  def status
    self[:status]
  end

  def redis_key(str)
    "spooge:#{self.id}:#{str.to_s}"
  end

  def [](field)
    $redis[self.redis_key(field)]
  end

  def []=(field, value)
    $redis[self.redis_key(field)] = value
  end


  def self.redis_clean_up
    Spooge.all.each do |s| 
      $redis.del(s.redis_key(:name))
      $redis.del(s.redis_key(:email))
      $redis.del(s.redis_key(:touch_date))
      $redis.del(s.redis_key(:status))
    end
  end
 
  def self.update_all_on_redis(field,value)
    result = Array.new
    Spooge.all.each do |s| 
      s[field] = value
      result << s
    end
    result
  end

  def self.find_on_redis(field,value)
    result = Array.new
    Spooge.all.each do |s| 
      result << s if s[field] == value
    end
    result
  end
    
end

