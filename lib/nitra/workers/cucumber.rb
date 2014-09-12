module Nitra::Workers
  class Cucumber < Worker
    def self.files
      Dir["features/**/*.feature"].sort_by {|f| File.size(f)}.reverse
    end

    def self.filename_match?(filename)
      filename =~ /\.feature/
    end

    def initialize(runner_id, worker_number, configuration)
      super(runner_id, worker_number, configuration)
    end

    def load_environment
      require 'cucumber'
      require 'nitra/ext/cucumber'
    end

    def minimal_file
      <<-EOS
      Feature: cucumber preloading
        Scenario: a fake scenario
          Given every step is unimplemented
          When we run this file
          Then Cucumber will load it's environment
      EOS
    end

    def cuke_runtime
      @cuke_runtime ||= ::Cucumber::ResetableRuntime.new  # This runtime gets reused, this is important as it's the part that loads the steps...
    end

    ##
    # Run a Cucumber file.
    #
    def run_file(filename, preloading = false)
      if configuration.split_files && !preloading && !filename.include?(':')
        run_with_arguments("--no-color", "--require", "features", "--dry-run", filename)
        scenarios = cuke_runtime.scenarios.collect {|scenario| "#{scenario.location.file}:#{scenario.location.line}"}

        {
          "failed"        => false,
          "test_count"    => 0,
          "failure_count" => 0,
          "parts_to_run"  => scenarios,
        }
      else
        run_with_arguments("--no-color", "--require", "features", filename)

        if cuke_runtime.results.failure? && @configuration.exceptions_to_retry && @attempt < @configuration.max_attempts &&
           cuke_runtime.results.scenarios(:failed).any? {|scenario| scenario.exception.to_s =~ @configuration.exceptions_to_retry}
          raise RetryException
        end

        if m = io.string.match(/(\d+) scenarios?.+$/)
          test_count = m[1].to_i
          if m = io.string.match(/\d+ scenarios? \(.*(\d+) [failed|undefined].*\)/)
            failure_count = m[1].to_i
          else
            failure_count = 0
          end
        else
          test_count = failure_count = 0
        end

        {
          "failed"        => cuke_runtime.results.failure?,
          "test_count"    => test_count,
          "failure_count" => failure_count,
        }
      end
    end

    def clean_up
      super

      cuke_runtime.reset
    end

    def run_with_arguments(*args)
      cuke_config = ::Cucumber::Cli::Configuration.new(io, io)
      cuke_config.parse!(args)
      cuke_runtime.configure(cuke_config)
      cuke_runtime.run!
    end
  end
end
