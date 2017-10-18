require 'active_model'

class UpdatedCartItemQuantity
  include ActiveModel::Model

  attr_accessor :product_id, :cart_id, :quantity, :timestamp

  def self.topic
    'carts'
  end
end
