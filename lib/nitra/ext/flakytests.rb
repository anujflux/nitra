module FlakyTests
  class FlakyTestsTracker < Nitra::Workers::Worker
    def initialize(step_mother, io, options)
      #do nothing
    end

    def before_tags(tags)

      @feature_tags = [] unless @feature_tags
      for tag in tags.tags
        @feature_tags.push(tag.name)
      end
    end


    def after_step_result(keyword, step_match, multiline_arg, status, exception, source_indent, background, file_colon_line)
      if @feature_tags.include?("@flaky") && status == :failed
        # step_definition = step_match.step_definition
        # file_name = file_colon_line.split(":")[0]
        # line_number = file_colon_line.split(":")[1]
        # output_failed_step(step_definition, file_name, line_number)
        raise RetryException
      end
    end

    def output_failed_step(step_definition_source, file_name, line_number)
      require 'csv'
      CSV.open("failed_tests_new.csv","a") do |csv|
        csv << ["#{Time.now}","#{file_name}","#{line_number}"]
      end
    end
  end
end
