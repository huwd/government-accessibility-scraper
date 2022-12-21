require "mechanize"
require "csv"
require "pry"

CDDO_DATA_DUMP_FILE = "CDDO List of 75 services and Engagement Tracker - Review - Nov 2022 - 75 services review - Oct 2022.csv"
EMAIL = "gds-cddo-accessibility-scraper@digital.cabinet-office.gov.uk"

def get_with_redirects(url, agent)
  page = agent.get(url)
  status_code = page.code

  while page.code[/30[123]/]
    puts "Status: #{page.code} for #{url}"
    location_header = page.header['location']
    puts "Redirecting based on location header: #{location_header}"
    begin
      page = agent.get(location_header)
    rescue Addressable::URI::InvalidURIError
      binding.pry
    end
  end
  return page
end

def node_after_header(element)
  return nil if element.nil?
  begin
    next_element = element.next
    until next_element.is_a?(Nokogiri::XML::Element)
      next_element = next_element.next
    end
    return next_element
  rescue => err
    binding.pry
  end
end

def scrape_accessibility_statement(agent, accessibility_statment_url)
  return {} if accessibility_statment_url.nil?

  begin
    puts "Scraping: #{accessibility_statment_url}"
    accessibility_page = get_with_redirects(accessibility_statment_url, agent)
  rescue Mechanize::ResponseCodeError => error
    return {
      "Accessibility Statement Scraped" => false,
      "Accessibility Statement Error Message" => error,
    }
  end

  headings_to_search = "h1, h2, h3, h4, h5, h6"

  compliance_status_heading = accessibility_page.search(headings_to_search).find do |element|
    element&.text&.strip&.downcase&.gsub(" ","-") == "compliance-status"
  end

  if !compliance_status_heading.nil?
    compliance_status = node_after_header(compliance_status_heading)

    compliance_status_category = [
      ("partially-compliant" if compliance_status.text.downcase.include?("partially compliant")),
      ("fully-compliant" if compliance_status.text.downcase.include?("fully compliant")),
      ("not-compliant" if compliance_status.text.downcase.include?("not compliant"))
    ].compact.first

    compliance_status_category = "non-standard-compliance-declaration" if compliance_status_category.nil?
  else
    puts "Compliance heading not found on: #{accessibility_statment_url}"
  end

  accesibility_data = {
    "Accessibility Statement Scraped" => true,
    "Accessibility Statement Compliance Status Found" => !compliance_status.nil? || nil ,
    "Accessibility Statement Compliance Status Text" => compliance_status&.text&.strip || nil,
    "Accessibility Statement Compliance link" => compliance_status&.at("a")&.attr("href") || nil,
    "Accessibility Statement Compliance category" => compliance_status_category || nil
  }

  puts accesibility_data
  return accesibility_data
end

def scrape_for_data(agent, service_url)
  puts "Skipping: No Service URL present" if service_url.nil?
  return {} if service_url.nil?

  scraped_data = {}
  begin
    puts "Getting page"
    service_page = get_with_redirects(service_url, agent)
    scraped_data["Service Scraped"] = true
  rescue Mechanize::ResponseCodeError => error
    puts "Scraping failed for: #{service_url}"
    puts "#{error.message}"
    return {
      "Service Scraped" => false,
      "Service Page Error Message" => error.message
    }
  end

  # Normalise the accesibility link text, downcase and control for whitespace
  # Then search for the first link on the page with that text. Most often it
  # Appears to be "Accessibility statement"
  accessibility_statement_link = service_page.css("a").find do |link|
    link.text.strip.downcase.gsub(" ","-") == "accessibility-statement" ||
    link.text.strip.downcase.gsub(" ","-") == "accessibility"
  end

  begin
    accessibility_statement_link.text
  rescue NoMethodError => error
    puts "No link found with text 'Accessibility statement' on: #{service_url}"
    return {
      "Service Scraped" => true,
      "Accessibility Statement Scraped" => false,
      "Accessibility Statement Error Message" => "No Link found",
    }
  end

  # Normalise the URI a bit, we want the full one
  accessiblity_statement_uri = Addressable::URI.parse(accessibility_statement_link.attr("href"))

  unless accessiblity_statement_uri.scheme == "javascript"
    begin
      accessiblity_statement_uri.path = "/" +  accessiblity_statement_uri.path if accessiblity_statement_uri.path[0] != "/"
      accessiblity_statement_uri.host = Addressable::URI.parse(service_url).host if accessiblity_statement_uri.host.nil?
      accessiblity_statement_uri.scheme = "https" if accessiblity_statement_uri.scheme.nil?
    rescue Addressable::URI::InvalidURIError
      binding.pry
    end
  else
    puts "Javascript URL detected, needs to be manually checked"
    return {
      "Service Scraped" => true,
      "Accessibility Statement Scraped" => false,
      "Accessibility Statement Error Message" => "Accessibility statement is a javascript link, needs headless scraper upgrade",
    }
  end


  scraped_data["Accessibility Statement Link URL"] = accessiblity_statement_uri.to_s

  puts "Scraping #{accessiblity_statement_uri.to_s}"
  accessibility_statement_data = scrape_accessibility_statement(agent, accessiblity_statement_uri.to_s)

  returning_data = {
    **scraped_data,
    **accessibility_statement_data
  }

  puts returning_data
  return returning_data
end

# The CSV doesn't start with usable heders, chop off the first line
file_text_data = File.readlines("data/#{CDDO_DATA_DUMP_FILE}")[1..-1].join

# Parse the CSV into an object with key / values based on column headers
csv_data = CSV.parse(file_text_data, headers:true)

# Configure the scraper user agent and be explicit about this being an audit
# Most likely no-one will see, but if we accidentially trigger some cyber investigation
# best to let them know who we are and what we're up to
agent = Mechanize.new { |agent|
  agent.user_agent = "GDS / CDDO Accessibility scraper, Audit: #{EMAIL}"
  agent.redirect_ok = false
}

total_count = csv_data.count
urls_to_scrape_count = csv_data.map { |row| row['Service URL'] }.compact.uniq.count
puts "================================="
puts "Scraping #{total_count} rows"
puts "Scraping #{urls_to_scrape_count} urls"
puts "================================="
puts ""

# Iterate over the CSV, grabbing data and appending it to the existing CSV structure
updated_data = csv_data.each_with_object([]).with_index do |(row, array), index|
  puts "Scraping #{index + 1}/#{total_count}: #{row['Service URL']}"
  # Go scrape data based on the service URL
  scraped_data = scrape_for_data(agent, row["Service URL"])
  puts ""

  # spread the existing row data into an object and append the scraped data
  # shove that into an array that gets returned
  array << {
    **scraped_data,
    **row,
  }
end

# Normalise the headers, as they vary based on what path they ended up going down
# collect all possible headers and insert the rest as nil
headers = updated_data.inject([]) {|res, h| h.keys | res} #all possible headers
rows = updated_data.map {|h| h.values_at(*headers)}
CSV.open("data/output_scrape.csv", "w") do |csv|
  csv << headers
  rows.each do |row|
    csv << row
  end
end
