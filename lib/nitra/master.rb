class Nitra::Master
  attr_reader :configuration, :files, :frameworks, :current_framework

  def initialize(configuration, files = nil)
    @configuration = configuration
    @frameworks = configuration.frameworks
    if @frameworks.any?
      load_files_from_framework_list
    else
      map_files_to_frameworks(files)
    end
    @current_framework = @frameworks.shift
    @configuration.framework = @current_framework
  end

  def run
    return if files_remaining == 0

    progress.file_count = files_remaining

    if configuration.process_count > 0
      client, runner = Nitra::Channel.pipe
      fork do
        runner.close
        Nitra::Runner.new(configuration, client, "local").run
      end
      client.close
      runners << runner
    end

    runners.concat slave.connect

    formatter.start
    burndown.start

    while runners.length > 0
      Nitra::Channel.read_select(runners).each do |channel|
        process_channel(channel)
      end
    end

    debug "waiting for all children to exit..."
    Process.waitall

    formatter.finish
    burndown.finish configuration.burndown_report if configuration.burndown_report

    !$aborted && progress.files_completed == progress.file_count && progress.failure_count.zero? && !progress.failure
  end

protected
  def say(text)
    puts "#{current_time} #{text}"
    $stdout.flush
  end

  def say_lines(text, prefix)
    text.split(/\n/).each {|line| puts "#{current_time} #{prefix}#{line}"}
    $stdout.flush
  end

  def debug(*text)
    say "master: [DEBUG] #{text.join}" if configuration.debug
  end

  def current_time
    Time.now.strftime('%Y-%m-%d %H:%M:%S')
  end

  def slave
    @slave ||= Nitra::Slave::Client.new(configuration)
  end

  def runners
    @runners ||= []
  end

  def progress
    @progress ||= Nitra::Progress.new
  end

  def formatter
    @formatter ||= Nitra::Formatter.new(progress, configuration)
  end

  def burndown
    @burndown ||= Nitra::Burndown.new
  end

  def map_files_to_frameworks(files)
    @files = files.group_by do |filename|
     framework_name, framework_class = Nitra::Workers::Worker.worker_classes.find {|framework_name, framework_class| framework_class.filename_match?(filename)}
     framework_name
    end
    @frameworks = @files.keys
  end

  def load_files_from_framework_list
    @files = frameworks.inject({}) do |result, framework_name|
      result[framework_name] = Nitra::Workers::Worker.worker_classes[framework_name].files
      result
    end
  end

  def files_remaining
    files.values.inject(0) {|sum, filenames| sum + filenames.length}
  end

  def current_framework_files
    files[current_framework]
  end

  def next_file
    raise if files_remaining == 0
    file = current_framework_files.shift
    @current_framework = frameworks.shift if current_framework_files.length == 0
    file
  end

  def process_channel(channel)
    if data = channel.read
      case data["command"]
      when "next_file"
        if files_remaining == 0
          debug "#{data["on"]} Finished with this worker"
          channel.write "command" => "drain"
        elsif data["framework"] == current_framework
          file = next_file
          burndown.next_file(data["on"], data["framework"], file)
          debug "#{data["on"]} Assigning #{file}"
          channel.write "command" => "process_file", "filename" => file
        else
          debug "#{data["on"]} Restarting worker with framework #{current_framework}"
          channel.write "command" => "framework", "framework" => current_framework
        end

      when "result"
        tests = data["test_count"] || 0
        failures = data["failure_count"] || 0
        failed = data["failed"]
        parts_to_run = data["parts_to_run"]
        duration = burndown.result(data["on"], data["framework"], data["filename"], tests, failures, failed)
        debug "#{data["on"]} took #{'%0.2f' % duration}s to #{parts_to_run ? 'split' : 'run'} #{data["filename"]}"
        progress.file_progress(tests, failures, failed, data["text"])
        formatter.print_progress

        if parts_to_run
          debug "#{data["on"]} split #{data["filename"]} into #{parts_to_run.join '+'}"
          files[data["framework"]].concat(parts_to_run) if parts_to_run
          progress.file_count += parts_to_run.size
        end

      when "retry"
        burndown.retry(data["on"], data["framework"], data["filename"])
        say "#{data["on"]} Re-running #{data["filename"]}"

      when "starting"
        debug "#{data["on"]} Starting framework #{data["framework"]}"
        burndown.next_file(data["on"], data["framework"], nil)

      when "started"
        debug "#{data["on"]} Started framework #{data["framework"]}"
        burndown.result(data["on"], data["framework"], nil, 0, 0, false)

      when "error"
        say_lines(data["text"], "#{data["on"]} [ERROR for #{data["process"]}] ")
        formatter.progress
        channel.close
        runners.delete channel

      when "debug"
        say_lines(data["text"], "#{data["on"]} [DEBUG] ") if configuration.debug

      when "stdout"
        say "#{data["on"]} [STDOUT for #{data["process"]}]"
        say data["text"]

      when "stderr"
        say "#{data["on"]} [STDERR for #{data["process"]}]"
        say data["text"]

      when "slave_configuration"
        slave_details = slave.slave_details_by_server.fetch(channel)
        slave_config = configuration.dup
        slave_config.process_count = slave_details.fetch(:cpus)

        debug "#{data["on"]} Slave runner configuration requested"
        channel.write(
          "command" => "configuration",
          "configuration" => slave_config)

      else
        say "Unrecognised nitra command to master #{data["command"]}"
      end
    else
      channel.close
      runners.delete channel
    end
  rescue Nitra::Channel::ProtocolInvalidError => e
    slave_details = slave.slave_details_by_server.fetch(channel)
    raise Nitra::Channel::ProtocolInvalidError, "Error running #{slave_details[:command]}: #{e.message}"
  end
end
