class Spooge
  include MongoMapper::Document

  key :name, :type => String
  key :email, :type => String
  key :touch_date, :type => Time
  key :status, :type => String
  
end
