require 'yaml'
require 'zlib'

require 'rubygems/command'
require 'open-uri'
require 'thread'

class Gem::Commands::MirrorCommand < Gem::Command
  MAX_WORKERS = 15

  def initialize
    super 'mirror', 'Mirror a gem repository'
    add_option '-m', '--mirror-file=FILENAME',
               'File to use in place of ~/.gemmirrorrc' do |filename, options|
      options[:mirror_file] = File.expand_path(filename)
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
        sourceindex_data = Zlib::Inflate.inflate y.read
        open File.join(save_to, "Marshal.#{Gem.marshal_version}"), "wb" do |out|
          out.write sourceindex_data
        end
      end

      sourceindex = Marshal.load(sourceindex_data)
      sourceindex_data.replace("")  # Free up memory.
      
      progress = ui.progress_reporter sourceindex.size,
                                      "Fetching #{sourceindex.size} gems"
      download_gem_files(get_from, sourceindex, progress, gems_dir)
      progress.done
    end
  end

  private
    def config_file
      options[:mirror_file] || File.join(Gem.user_home, '.gemmirrorrc')
    end
    
    def download_gem_files(get_from, source_index, progress, gems_dir)
      queue = SizedQueue.new(MAX_WORKERS)
      mutex = Mutex.new
      
      threads = []
      MAX_WORKERS.times do
        thread = Thread.new do
          while (item = queue.pop)
            fullname, gem = item
            gem_file = "#{fullname}.gem"
            gem_dest = File.join(gems_dir, gem_file)

            unless File.exist?(gem_dest) then
              begin
                open("#{get_from}/gems/#{gem_file}", "rb") do |g|
                  contents = g.read
                  open(gem_dest, "wb") do |out|
                    out.write(contents)
                  end
                end
              rescue
                old_gf = gem_file
                gem_file = gem_file.downcase
                retry if old_gf != gem_file
                mutex.synchronize do
                  alert_error $!
                end
              end
            end

            mutex.synchronize do
              progress.updated(gem_file)
            end
          end
        end
        
        threads << thread
      end
      
      source_index.each do |fullname, gem|
        queue.push([fullname, gem])
      end
      threads.size.times do
        queue.push(nil)
      end
      threads.each do |thread|
        thread.join
      end
    end
end

