require 'yaml'
require 'zlib'

require 'rubygems/command'
require 'open-uri'
require 'tempfile'
require 'fileutils'
require 'timeout'
require 'thread'

class Gem::Commands::MirrorCommand < Gem::Command
  DEFAULT_WORKER_THREADS = 10
  
  def initialize
    super 'mirror', 'Mirror a gem repository'
    
    add_option '-m', '--mirror-file=FILENAME',
               'File to use in place of ~/.gemmirrorrc' do |filename, options|
      options[:mirror_file] = File.expand_path(filename)
    end
    
    add_option '-w', '--worker-threads=N',
               "Number of threads to use for downloading. Default: #{DEFAULT_WORKER_THREADS}" do |n, options|
      options[:worker_threads] = n.to_i if n.to_i > 0
    end
  end

  def description # :nodoc:
    <<-EOF
The mirror command uses the ~/.gemmirrorrc config file (or a different
file, if specified) to mirror remote gem repositories to a local path.
The config file is a YAML document that looks like this:

  ---
  - from: http://gems.example.com # source repository URI
    to: /path/to/mirror           # destination directory

Multiple sources and destinations may be specified.
    EOF
  end

  def execute
    raise "Config file #{config_file} not found" unless File.exist? config_file

    mirrors = YAML.load_file config_file

    raise "Invalid config file #{config_file}" unless mirrors.respond_to? :each

    mirrors.each do |mir|
      raise "mirror missing 'from' field" unless mir.has_key? 'from'
      raise "mirror missing 'to' field" unless mir.has_key? 'to'

      get_from = mir['from']
      save_to = File.expand_path mir['to']

      raise "Directory not found: #{save_to}" unless File.exist? save_to
      raise "Not a directory: #{save_to}" unless File.directory? save_to

      gems_dir = File.join save_to, "gems"

      if File.exist? gems_dir then
        raise "Not a directory: #{gems_dir}" unless File.directory? gems_dir
      else
        Dir.mkdir gems_dir
      end

      sourceindex_data = ''

      say "fetching: #{get_from}/Marshal.#{Gem.marshal_version}.Z"

      get_from = URI.parse get_from

      if get_from.scheme.nil? then
        get_from = get_from.to_s
      elsif get_from.scheme == 'file' then
        # check if specified URI contains a drive letter (file:/D:/Temp)
        get_from = get_from.to_s
        get_from = if get_from =~ /^file:.*[a-z]:/i then
                     get_from[6..-1]
                   else
                     get_from[5..-1]
                   end
      end

      open File.join(get_from.to_s, "Marshal.#{Gem.marshal_version}.Z"), "rb" do |y|
        data = y.read
        sourceindex_data = Zlib::Inflate.inflate(data)
        data.replace("")    # Free up memory.
        open File.join(save_to, "Marshal.#{Gem.marshal_version}"), "wb" do |out|
          out.write sourceindex_data
        end
      end

      sourceindex = Marshal.load(sourceindex_data)
      sourceindex_data.replace("")  # Free up memory.
      
      progress = ui.progress_reporter sourceindex.size,
                                      "Fetching #{sourceindex.size} gems"
      begin
        download_gem_files(get_from, sourceindex, progress, gems_dir)
      rescue => e
        alert_error("*** #{e.class}: #{e}\n    " + e.backtrace.join("\n    "))
        raise
      end
      progress.done
    end
  end

  private
    BATCH_SIZE = 30
    SIGINT = Signal.list['INT']
    
    def config_file
      options[:mirror_file] || File.join(Gem.user_home, '.gemmirrorrc')
    end
    
    def download_gem_files(get_from, source_index, progress, gems_dir)
      tmpdir = File.join(gems_dir, "gem_mirror.#{Process.pid}")
      input_list = Tempfile.new("gem_mirror")
      FileUtils.mkdir_p(tmpdir)
      begin
        files_to_download = []
        source_index.each do |fullname, gem_spec|
          gem_file = "#{fullname}.gem"
          gem_dest = File.join(gems_dir, gem_file)
          if !File.exist?(gem_dest)
            files_to_download << "#{get_from}/gems/#{fullname}.gem"
          end
        end
        
        say "#{files_to_download.size} new gems"
        
        i = 0
        while i < files_to_download.size
          input_list.rewind
          input_list.truncate(0)
          
          j = i
          while j < files_to_download.size
            input_list.puts("-O")
            input_list.puts("url = \"#{files_to_download[j]}\"")
            j += 1
          end
          i = j
          input_list.flush
          
          old_dir = Dir.getwd
          begin
            Dir.chdir(tmpdir)
            if !run_curl(input_list.path)
              alert_error "One or more downloads failed"
            end
            Dir["*.gem"].each do |filename|
              File.rename(filename, "../#{filename}")
              say "Downloaded #{filename}"
            end
            say "#{files_to_download.size - i} gems left"
          ensure
            Dir.chdir(old_dir)
          end
        end
      ensure
        FileUtils.rm_rf(tmpdir)
        input_list.close!
      end
    end
    
    def run_curl(input_list_path)
      result = system("curl", "--progress-bar", "--config", input_list_path)
      if !result && $?.signaled? && $?.termsig == SIGINT
        puts "\n"
        raise Interrupt, "Interrupt"
      else
        result
      end
    end
end

