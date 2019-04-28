# This file is a DRY way to set all of the requirements
# that our tests will need, as well as a before statement
# that purges the database and creates fixtures before every test

ENV['APP_ENV'] = 'test'
require 'simplecov'
SimpleCov.start
require 'minitest/autorun'
require './app'
require 'pry-byebug'

def app
  Sinatra::Application
end

def publish_tweet(tweet)
  RABBIT_EXCHANGE.publish(tweet, routing_key: 'new_tweet.tweet_data')
  sleep 3
end

describe 'NanoTwitter' do
  include Rack::Test::Methods
  before do
    REDIS_EVEN.flushall
    REDIS_ODD.flushall
    @tweet_id = 1
    @tweet_body = 'Scalability is the best'
    @author_handle = 'Ari'
    @tweet_created = DateTime.now
    @tweet = { tweet_id: @tweet_id, tweet_body: @tweet_body, author_handle: @author_handle, tweet_created: @tweet_created }.to_json
    @expected_html = "<li>#{@tweet_body}<br>- #{@author_handle} #{@tweet_created}</li>"
  end

  it 'can render a tweet as HTML' do
    render_html(JSON.parse(@tweet)).must_equal @expected_html
  end

  it 'can get a tweet from a queue' do
    publish_tweet(@tweet)
    REDIS_EVEN.keys.count.must_equal 0
    REDIS_ODD.keys.count.must_equal 1
    REDIS_ODD.get('1').must_equal @expected_html
  end

  it 'can shard caches properly' do
    publish_tweet(@tweet)
    tweet2 = JSON.parse @tweet
    tweet2['tweet_id'] = '2'
    tweet2['tweet_body'] = @tweet_body + '!'
    publish_tweet(tweet2.to_json)
    REDIS_EVEN.keys.count.must_equal 1
    REDIS_ODD.keys.count.must_equal 1
    REDIS_ODD.get('1').must_equal @expected_html
    REDIS_EVEN.get('2').must_equal "<li>#{@tweet_body}!<br>- #{@author_handle} #{@tweet_created}</li>"
  end

  it 'can fan out a tweet to followers' do
    publish_tweet @tweet
    follow_payload = {
      'tweet_id': '1',
      'follower_ids': %w[2 3 4]
    }.to_json
    fanout_to_html JSON.parse(follow_payload)
    msg_json = JSON.parse HTML_FANOUT.pop.last
    msg_json['tweet_html'].must_equal @expected_html
    msg_json['user_ids'].must_equal %w[2 3 4]
  end

  it 'can fan out a tweet from a queue' do
    publish_tweet @tweet
    follow_payload = {
      'tweet_id': '1',
      'follower_ids': %w[2 3 4]
    }.to_json
    RABBIT_EXCHANGE.publish(follow_payload, routing_key: 'new_tweet.follower_ids')
    sleep 3
    msg_json = JSON.parse HTML_FANOUT.pop.last
    msg_json['tweet_html'].must_equal @expected_html
    msg_json['user_ids'].must_equal %w[2 3 4]
  end

  it 'can seed tweets' do
    tweet2 = JSON.parse @tweet
    tweet2['tweet_id'] = '2'
    tweet2['tweet_body'] = @tweet_body + '!'
    expected_html2 = "<li>#{@tweet_body}!<br>- #{@author_handle} #{@tweet_created}</li>"
    payload = [{ owner_id: 2,
                 sorted_tweets: [JSON.parse(@tweet), tweet2] }].to_json
    seed_tweets(JSON.parse(payload))
    REDIS_EVEN.keys.count.must_equal 1
    REDIS_ODD.keys.count.must_equal 1
    REDIS_ODD.get('1').must_equal @expected_html
    REDIS_EVEN.get('2').must_equal expected_html2
    expected_json = [{ owner_id: 2,
                       sorted_tweets: [@expected_html, expected_html2] }].to_json
    msg_json = JSON.parse(TIMELINE_SEED.pop.last)
    JSON.parse(expected_json).must_equal msg_json
  end

  it 'can seed tweets from the seed queue' do
    tweet2 = JSON.parse @tweet
    tweet2['tweet_id'] = '2'
    tweet2['tweet_body'] = @tweet_body + '!'
    expected_html2 = "<li>#{@tweet_body}!<br>- #{@author_handle} #{@tweet_created}</li>"
    payload = [{ owner_id: 2,
                 sorted_tweets: [JSON.parse(@tweet), tweet2] }].to_json
    RABBIT_EXCHANGE.publish(payload, routing_key: 'tweet.data.seed')
    sleep 3
    REDIS_EVEN.keys.count.must_equal 1
    REDIS_ODD.keys.count.must_equal 1
    REDIS_ODD.get('1').must_equal @expected_html
    REDIS_EVEN.get('2').must_equal expected_html2
    expected_json = [{ owner_id: 2,
                       sorted_tweets: [@expected_html, expected_html2] }].to_json
    msg_json = JSON.parse(TIMELINE_SEED.pop.last)
    JSON.parse(expected_json).must_equal msg_json
  end
end