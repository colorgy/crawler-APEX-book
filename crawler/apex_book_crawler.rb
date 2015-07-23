require 'crawler_rocks'
require 'pry'
require 'json'
require 'iconv'
require 'book_toolkit'

require 'thread'
require 'thwait'

class ApexBookCrawler
  include CrawlerRocks::DSL

  ATTR_HASH = {
    "ISBN-13" => :isbn,
    "出版商" => :publisher,
  }

  def initialize update_progress: nil, after_each: nil
    @update_progress_proc = update_progress
    @after_each_proc = after_each

    @index_url = "http://www.apexbook.tw/index.php"
    @ic = Iconv.new("utf-8//translit//IGNORE","utf-8")
  end

  def books
    @books = {}
    threads = []
    @after_each_threads = []
    @cookies = nil

    r = RestClient.get("#{@index_url}?php_mode=advancesearch") do |response, request, result, &block|
      if [301, 302, 307].include? response.code
        @cookies = response.cookies
        response.follow_redirection(request, result, &block)
      else
        response.return!(request, result, &block)
      end
    end

    doc = Nokogiri::HTML(@ic.iconv(r))

    page_num = doc.xpath('//span[@class="CO FB"]/ancestor::*[1]').text.match(/共(\d+)頁/)[1].to_s.to_i

    # skip first page
    # 2.times do |i|
    (page_num).times do |i|
      sleep(1) until (
        threads.delete_if { |t| !t.status };  # remove dead (ended) threads
        threads.count < (ENV['MAX_THREADS'] || 3)
      )
      threads << Thread.new do
        start_book_id = 30 * i

        r = RestClient.get("#{@index_url}?#{{
          "php_mode" => "booklist",
          "StartBookId" => start_book_id,
          "keyword_value" => ""
        }.map{|k,v| "#{k}=#{v}"}.join('&')}", cookies: @cookies)
        doc = Nokogiri::HTML(@ic.iconv(r))

        parse_books(doc)

        print "page: #{i+1} / #{page_num}\n"
      end # end thread
    end
    ThreadsWait.all_waits(*threads)
    ThreadsWait.all_waits(*@after_each_threads)

    @books.values
  end

  def parse_books(doc)

    detail_threads = []

    doc.xpath('//form[@action="index.php"][@name="form"]/ancestor::tr[1]/following-sibling::tr[position()>1][@onmouseover]').each do |row|
      datas = row.css('td')

      name_datas = datas[2].text.gsub(/\s{4,}/, "\n").strip
      name = name_datas.rpartition("\n")[0].gsub(/\w+/, &:capitalize)

      isbn = nil; invalid_isbn = nil;
      begin
        isbn = BookToolkit.to_isbn13(name_datas.rpartition("\n")[-1].rpartition(':')[-1])
      rescue Exception => e
        invalid_isbn = name_datas.rpartition("\n")[-1].rpartition(':')[-1]
      end

      url = nil || datas[2].xpath('a/@href').to_s.strip
      url = URI.join(@index_url, url).to_s unless url.empty?

      author = datas[3] && datas[3].text.gsub(/\w+/, &:capitalize)
      price = datas[4] && datas[4].text.gsub(/[^\d]/, '').to_i

      @books[isbn] = {
        name: name,
        url: url,
        author: author,
        isbn: isbn,
        invalid_isbn: invalid_isbn,
        original_price: price,
        known_supplier: 'apex'
      }

      sleep(1) until (
        detail_threads.delete_if { |t| !t.status };  # remove dead (ended) threads
        detail_threads.count < (ENV['MAX_THREADS'] || 10)
      )
      detail_threads << Thread.new do
        r = RestClient.get url
        doc = Nokogiri::HTML(@ic.iconv(r))

        doc.xpath('//span[@class="book_name"]/ancestor::td[1]').text.split("\n").each {
          |attr_data|
          key, colon, value = attr_data.rpartition(/[：:]/)
          @books[isbn][ATTR_HASH[key]] = value.strip unless key.nil? || ATTR_HASH[key].nil?
        }

        sleep(1) until (
          @after_each_threads.delete_if { |t| !t.status };  # remove dead (ended) threads
          @after_each_threads.count < (ENV['MAX_THREADS'] || 30)
        )
        @after_each_threads << Thread.new do
          @after_each_proc.call(book: @books[isbn]) if @after_each_proc
        end
        # print "|"
      end # end detail_thread
    end # end each row

    ThreadsWait.all_waits(*detail_threads)
  end

end

# cc = ApexBookCrawler.new
# File.write('apex_books.json', JSON.pretty_generate(cc.books))
