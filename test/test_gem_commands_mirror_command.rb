require File.join(File.expand_path(File.dirname(__FILE__)), 'gemutilities')
require 'rubygems/indexer'
require 'rubygems/commands/mirror_command'

class TestGemCommandsMirrorCommand < RubyGemTestCase

  def setup
    super

    @cmd = Gem::Commands::MirrorCommand.new
  end

  def test_execute
    util_make_gems

    gems_dir = File.join @tempdir, 'gems'
    mirror = File.join @tempdir, 'mirror'

    FileUtils.mkdir_p gems_dir
    FileUtils.mkdir_p mirror

    Dir[File.join(@gemhome, 'cache', '*.gem')].each do |gem|
      FileUtils.mv gem, gems_dir
    end

    use_ui @ui do
      Gem::Indexer.new(@tempdir).generate_index
    end

    @cmd.options[:mirror_file] = File.join(@tempdir, 'gemmirrorrc')

    File.open File.join(@tempdir, 'gemmirrorrc'), 'w' do |fp|
      fp.puts "---"
      # tempdir could be a drive+path (under windows)
      if @tempdir.match(/[a-z]:/i)
        fp.puts "- from: file:///#{@tempdir}"
      else
        fp.puts "- from: file://#{@tempdir}"
      end
      fp.puts "  to: #{mirror}"
    end

    use_ui @ui do
      @cmd.execute
    end

    assert File.exist?(File.join(mirror, 'gems', "#{@a1.full_name}.gem"))
    assert File.exist?(File.join(mirror, 'gems', "#{@a2.full_name}.gem"))
    assert File.exist?(File.join(mirror, 'gems', "#{@b2.full_name}.gem"))
    assert File.exist?(File.join(mirror, 'gems', "#{@c1_2.full_name}.gem"))
    assert File.exist?(File.join(mirror, "Marshal.#{@marshal_version}"))
  end
  
  def test_it_uses_gemmirrorrc_in_home_folder_by_default
    assert_equal File.join(Gem.user_home, ".gemmirrorrc"), @cmd.send(:config_file)
  end

end if ''.respond_to? :to_xs

