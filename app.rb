require 'web_task_runner'

# Require the crawler
Dir[File.dirname(__FILE__) + '/crawler/*.rb'].each { |file| require file }

class CrawlWorker < WebTaskRunner::TaskWorker
  def exec
    puts "Starting crawler for apexbooks ..."

    crawler = ApexBookCrawler.new(
      update_progress: proc { |payload| WebTaskRunner.job_1_progress = payload[:progress] },
      after_each: proc do |payload|
        book = payload[:book]
        print "Saving book #{book[:isbn]} ...\n"
        RestClient.put("#{ENV['DATA_MANAGEMENT_API_ENDPOINT']}/#{book[:isbn]}?key=#{ENV['DATA_MANAGEMENT_API_KEY']}",
          { ENV['DATA_NAME'] => book }
        )
        WebTaskRunner.job_1_progress = payload[:progress]
      end
    )

    books = crawler.books()

    # TODO: delete the courses which book code not present in th list
  end
end

WebTaskRunner.jobs << CrawlWorker
