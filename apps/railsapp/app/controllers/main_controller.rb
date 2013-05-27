class MainController < ApplicationController

  def index
    render :text => 'rails app'
  end

  def hello
    render :text => "hello, world"
  end

  def get_data
    render :text => 'x' * params[:size].to_i
  end

  def put_data
    data = request.body.read.to_s
    render :text => "received #{data.length} bytes"
  end

end
