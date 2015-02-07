require 'yajl'
require "csv"

namespace :github_archive_crawler do
  desc "Parse all github archive users"
  task parse_users: :environment do
    event_stream = File.read("ressources/users.json"); 0
    
    puts "Start parsing"
    
    time = DateTime.now
    i = 0
    Yajl::Parser.parse(event_stream) do |event|
      UserWorker.perform_async(event)
      i+=1
      puts "created #{i} users" if i%1000==0
    end
    
    puts "Done : #{DateTime.now - time}"
  end
  
  task crawl_users: :environment do
    client = Octokit::Client.new(:access_token => ENV["GITHUB_TOKEN"])
    puts "Start crawling"
    since = User.last.try(:github_id).try(:to_s) || "0"
    
    loop do
      begin
        found_users = client.all_users(:since => since)
        puts "found #{found_users.size} users starting at #{since}"
        found_users.each do |user|
          UserWorker.perform_async(user.to_hash)
        end
        since = found_users.last.id
        break if found_users.size < 100
      rescue Octokit::TooManyRequests => e
        puts e
        sleep 10
      rescue Errno::ETIMEDOUT => e
        puts e
        sleep 1
      rescue Errno::ENETDOWN => e
        puts e
        sleep 1
      end
    end
  end
  
  
  task crawl_repos: :environment do
    client = Octokit::Client.new(:access_token => ENV["GITHUB_TOKEN"])
    puts "Start crawling repos"
    start_id = 27941122#Repository.maximum(:github_id)
    since = start_id
    
    loop do
      begin
        found_repos = client.all_repositories(:since => since)
        puts "found #{found_repos.size} repos starting at #{since}"
        found_repos.each do |repo|
          RepositoryWorker.perform_async(repo.to_hash.to_json)
        end
        since = found_repos.last.id
        break if found_repos.size < 100 || since >= 28709353
        #sleep 0.25
      rescue Errno::ETIMEDOUT => e
        puts e
        sleep 1
      rescue Errno::ENETDOWN => e
        puts e
        sleep 1
      end
    end
  end
  
  task crawl_repos2: :environment do
    client = Octokit::Client.new(:access_token => ENV["GITHUB_TOKEN2"])
    puts "Start crawling repos"
    start_id = 29492537#Repository.maximum(:github_id)+1000000
    since = start_id
    
    loop do
      begin
        found_repos = client.all_repositories(:since => since)
        puts "found #{found_repos.size} repos starting at #{since}"
        found_repos.each do |repo|
          RepositoryWorker.perform_async(repo.to_hash.to_json)
        end
        since = found_repos.last.id
        break if found_repos.size < 100 || since >= 29992178
        #sleep 0.25
      rescue Errno::ETIMEDOUT => e
        puts e
        sleep 1
      rescue Errno::ENETDOWN => e
        puts e
        sleep 1
      end
    end
  end
  
  # task parse_repos: :environment do
  #   event_stream = File.read("ressources/repos.json"); 0
    
  #   puts "Start parsing"
    
  #   time = DateTime.now
  #   i = 0
  #   Yajl::Parser.parse(event_stream) do |event|
  #     RepositoryWorker.perform_async(event)
  #     i+=1
  #     puts "created #{i} repositories" if i%1000==0
  #   end
    
  #   puts "Done : #{DateTime.now - time}"
  # end
  
  # task import_avatars: :environment do
  #   not_found = File.readlines("tmp/errors.txt").each {|l| l.chomp!}
  #   client = Octokit::Client.new(:access_token => ENV["GITHUB_TOKEN"])
  #   User.where("gravatar_url IS NULL OR gravatar_url = ''").where("login NOT IN (?)", not_found).find_each do |user|
  #     begin
  #       github_user = client.user user.login
  #       user.update_attributes(:gravatar_url => github_user.avatar_url)
  #       puts "updated #{user.login} with avatar_url : #{github_user.avatar_url}"
  #     rescue Octokit::NotFound => e
  #       puts e
  #       File.open("tmp/errors.txt", "a+") do |f|
  #         f.puts user.login
  #       end
  #     end
  #   end
  # end
  
  task create_location_db: :environment do
    file = File.read("ressources/worldcitiespop.txt", encoding: "ISO8859-1"); 0
    city_array = file.split("\n")[1..-1]; 0
    
    puts "start parsing"
    i = 0
    cities = city_array.map do |city| 
      attributes = city.split(",")
      CityWorker.perform_async(attributes)
      
      i+=1
      puts "created #{i} cities" if i%1000==0
      
    end; 0
  end
  
  task create_country_db: :environment do
    file = File.read("ressources/country.txt", encoding: "ISO8859-1"); 0
    country_array = file.split("\n")[1..-1]; 0
    
    cities = country_array.map do |country| 
      attributes = country.delete("\r").split("\t")
      puts "set #{attributes[1].downcase} = #{attributes[3].downcase}"
      City.where(:country => attributes[1].downcase).update_all(:country_full_name => attributes[3].downcase)
    end; 0
  end
  
  
  task search_not_found_location: :environment do
    require 'net/telnet'
    require 'socksify'
    
    class GoogleMapRateLimitExceeded < Exception 
    end
    
    original_ip = HTTParty.get("http://bot.whatismyipaddress.com").body
    puts "original IP is : #{original_ip}"

    # socksify will forward traffic to Tor so you dont need to set a proxy for Mechanize from there
    TCPSocket::socks_server = "127.0.0.1"
    TCPSocket::socks_port = "50001"
    tor_port = 9050
    
    new_ip = HTTParty.get("http://bot.whatismyipaddress.com").body
    puts "new IP is #{new_ip}"
    
    not_found = $redis.smembers("location_error")
    not_found.each do |location|
      
      begin
        $redis.srem("location_error", location)
        result = get_address_from_googlemap(location) 
        
        if result
          User.where("LOWER(location) = '#{location.downcase.gsub("'", "''")}'").update_all(:city => result[:city], :country => result[:country])
          puts "updating users with location #{location} to city : #{result[:city]} , country : #{result[:country]}"
        else
          puts "No city found for #{location}"
          $redis.sadd("location_error_google", location)
        end
      rescue GoogleMapRateLimitExceeded => e
        puts e
        #Switch IP
        localhost = Net::Telnet::new("Host" => "localhost", "Port" => "#{tor_port}", "Timeout" => 10, "Prompt" => /250 OK\n/)
        localhost.cmd('AUTHENTICATE ""') { |c| print c; throw "Cannot authenticate to Tor" if c != "250 OK\n" }
        localhost.cmd('signal NEWNYM') { |c| print c; throw "Cannot switch Tor to new route" if c != "250 OK\n" }
        localhost.close      
        sleep 10

        new_ip = HTTParty.get("http://bot.whatismyipaddress.com").body
        puts "new IP is #{new_ip}"
      rescue JSON::ParserError => e
        puts e
        $redis.sadd("location_error_google", location)
      rescue OpenSSL::SSL::SSLError => e
        puts e
        $redis.sadd("location_error_google", location)
      end
    end
  end
  
  
  task set_country_city_from_location: :environment do
    not_found = $redis.smembers("location_error")
    not_found_google = $redis.smembers("location_error_google")
      
    User.select(:location).where("location IS NOT NULL AND (CITY IS NULL AND COUNTRY IS NULL)").group(:location).each do |user|
      location = user.location
      
      next if not_found.include?(location) || not_found_google.include?(location)
      
      begin 
        result = get_address_from_openstreepmap(location)
        #result = get_address_from_googlemap(location) if result.nil?
        if result
          User.where("LOWER(location) = '#{location.downcase.gsub("'", "''")}'").update_all(:city => result[:city], :country => result[:country])
          puts "updating users with location #{location} to city : #{result[:city]} , country : #{result[:country]}"
        else
          puts "No city found for #{location}"
          $redis.sadd("location_error", location)
        end
      rescue Errno::ECONNRESET => e
        puts e
        sleep 1
      rescue JSON::ParserError => e
        puts e
        sleep 1
      end
    end
  end
  
  def get_address_from_openstreepmap(location)
    response = HTTParty.get("http://nominatim.openstreetmap.org/search?q=#{URI.encode(location)}&format=json&accept-language=en-US&addressdetails=1")
    return if response.nil?
    
    result = JSON.parse(response.body)
    place = result.select {|r| ["suburb", "residential", "city", "town", "village"].include?(r["type"]) }.first
    if place
      return {:city => place["address"]["city"], :country => place["address"]["country"]}
    else
      return nil
    end
  end
  
  def get_address_from_googlemap(location)
    response = HTTParty.get("https://maps.googleapis.com/maps/api/geocode/json?address=#{URI.encode(location)}")
    result = JSON.parse(response.body)
    raise GoogleMapRateLimitExceeded if result["status"]=="OVER_QUERY_LIMIT"
    
    address_components = result.try(:[], "results").try(:first).try(:[], "address_components")
    return if address_components.nil?
      
    city = address_components.select { |r| r["types"].include?("locality")}.first
    country = address_components.select { |r| r["types"].include?("country")}.first
    if city && country
      return {:city => city["long_name"], :country => country["long_name"]}
    else
      return
    end
  end
  
  task get_organization: :environment do
    client = Octokit::Client.new(:access_token => ENV["GITHUB_TOKEN2"])
    $redis.smembers("user_update_error").each do |user_login|
      event = client.user user_login
      User.create(:github_id => event["id"],
        :login => event["login"], 
        :name => event["name"], 
        :mail => event["mail"], 
        :company => event["company"], 
        :blog => event["blog"], 
        :gravatar_url => event["avatar_url"], 
        :location => event["location"],
        :organization => event["type"]=="Organization")
      $redis.srem("user_update_error", user_login)
    end
    
    
    start_date=DateTime.parse("2008-01-01")
    loop do
      search_date = Time.at(start_date.to_i).strftime("%Y-%m-%d")
      puts "searching organization created #{search_date}"
      
      i=0
      loop do
        response = HTTParty.get("https://api.github.com/search/users?access_token=#{ENV["GITHUB_TOKEN"]}&page=#{i}&per_page=100&q=type:Organization+created:#{search_date}")
        results = JSON.parse(response.body)["items"]
        break if results.nil?
        
        results.each do |user|
          UserUpdateWorker.perform_async(user["login"], {"organization" => (user["type"]=="Organization")}.to_json)
        end
        i+=1
        break if results.count < 100
      end
      
      break if start_date >= Time.now
      start_date+=1.day
    end
  end
end