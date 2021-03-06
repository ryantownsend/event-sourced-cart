require 'sinatra'
require 'logger'
require 'securerandom'
require 'rack/ssl'
require 'rack-flash'
require 'kafka'

require_relative 'models/cart'
require_relative 'models/product'

require_relative 'lib/event_stream'

require_relative 'commands/add_item_to_cart'
require_relative 'commands/place_order'
require_relative 'commands/remove_item_from_cart'
require_relative 'commands/update_cart_item_quantity'

enable :sessions
use Rack::Flash

configure :production do
  use Rack::SSL

  # cache static files for a long time
  set :static_cache_control, [:public, max_age: 60 * 60 * 24]
end

configure do
  set :server, :puma

  set :session_secret, ENV.fetch('SECRET_KEY_BASE') { SecureRandom.hex(64) }

  if ENV['KAFKA_URL']
    $kafka = Kafka.new(
      client_id: "#{ENV['KAFKA_PREFIX']}carts",
      seed_brokers: ENV.fetch('KAFKA_URL','').split(','),
      ssl_ca_cert: ENV['KAFKA_TRUSTED_CERT'],
      ssl_client_cert: ENV['KAFKA_CLIENT_CERT'],
      ssl_client_cert_key: ENV['KAFKA_CLIENT_CERT_KEY'],
      logger: Logger.new($stdout)
    )

    $kafka_producer = $kafka.async_producer(
      delivery_interval: 1
    )

    at_exit { $kafka_producer.shutdown }

    kafka_topic = ENV.fetch('KAFKA_TOPIC') { 'ecommerce' }

    set :event_stream, EventStream.new(producer: $kafka_producer, topic_prefix: ENV['KAFKA_PREFIX'])
  else
    set :event_stream, []
  end
end

get '/' do
  erb :product_index, layout: :layout, locals: { products: Product.all, cart: Cart.new(session) }
end

get '/cart' do
  erb :cart, layout: :layout, locals: {
    cart: Cart.new(session)
  }
end

post '/add_item_to_cart' do
  command = AddItemToCart.new(
    session: session,
    product_id: params['product_id'],
    quantity: params['quantity']
  )

  if command.execute(settings.event_stream)
    flash[:notice] = "Added #{command.quantity} x #{command.product.title} to your cart"
    [302, { 'Location' => '/cart' }, '']
  else
    [200, {}, command.errors.full_messages.join("\n")]
  end
end

post '/remove_item_from_cart' do
  command = RemoveItemFromCart.new(
    session: session,
    product_id: params['product_id']
  )

  if command.execute(settings.event_stream)
    flash[:notice] = "Removed #{command.product.title} from your cart"
    [302, { 'Location' => '/cart' }, '']
  else
    [200, {}, command.errors.full_messages.join("\n")]
  end
end

post '/update_cart_item_quantity' do
  command = UpdateCartItemQuantity.new(
    session: session,
    product_id: params['product_id'],
    quantity: params['quantity']
  )

  if command.execute(settings.event_stream)
    if Integer(command.quantity) > 0
      flash[:notice] = "Updated #{command.product.title} to a quantity of #{command.quantity}"
    end
    [302, { 'Location' => '/cart' }, '']
  else
    [200, {}, command.errors.full_messages.join("\n")]
  end
end

post '/place_order' do
  line_items = Cart.new(session).line_items

  command = PlaceOrder.new(
    session: session
  )

  if command.execute(settings.event_stream)
    erb :order_confirmation, layout: :layout, locals: { line_items: line_items, order_id: command.order_id }
  else
    [200, {}, command.errors.full_messages.join("\n")]
  end
end

helpers do
  def integer_to_currency(number, unit: '$')
    "#{ unit }#{ "%.2f" % (BigDecimal.new(number) / 100).round(2) }"
  end
end
