# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'preserve_macos_runtime'

class PreserveMacosRuntimeTest < Minitest::Test
  STAGING = Solco::MacosRuntimeStaging

  def replace_method(name, replacement)
    original = STAGING.method(name)
    STAGING.define_singleton_method(name, replacement)
    yield
  ensure
    STAGING.define_singleton_method(name, original)
  end

  def with_build
    Dir.mktmpdir('solco-macos-build-') do |directory|
      workspace = Pathname.new(directory).realpath
      release = workspace.join('target', STAGING::RELEASE)
      FileUtils.mkdir_p(release.join('build/dawn/out'))
      FileUtils.mkdir_p(workspace.join('target/release/build/host-macro'))
      release.join('solco').write('final executable')
      release.join('solco').chmod(0o755)
      release.join('libdirect.dylib').write('direct runtime')
      release.join('libdirect.dylib').chmod(0o644)
      release.join('build/dawn/out/libdawn.dylib').write('linked runtime')
      release.join('build/dawn/out/libdawn.dylib').chmod(0o755)
      File.symlink('build/dawn/out/libdawn.dylib', release.join('libdawn.dylib'))
      workspace.join('target/release/build/host-macro/intermediate').write('discard me')
      workspace.join('keep-source').write('untouched source')
      environment = {'GITHUB_ACTIONS' => 'true', 'GITHUB_WORKSPACE' => workspace.to_s}
      yield workspace, release, environment
    end
  end

  def test_symlinked_and_regular_runtimes_keep_bytes_modes_and_exact_packaging_paths
    with_build do |workspace, release, environment|
      before = %w[solco libdirect.dylib libdawn.dylib].to_h { |name| [name, STAGING.fingerprint(release.join(name))] }
      capture_io { assert_equal before, STAGING.preserve(workspace, environment: environment) }
      assert_equal before.keys.sort, release.children.map { |path| path.basename.to_s }.sort
      before.each do |name, expected|
        refute release.join(name).symlink?
        assert_equal expected, STAGING.fingerprint(release.join(name))
      end
      refute workspace.join('target/release').exist?
      assert_equal 'untouched source', workspace.join('keep-source').read
      assert_empty workspace.glob('.solco-macos-runtime-*')
    end
  end

  def test_failed_copy_keeps_all_originals_and_does_not_remove_symlink_target
    with_build do |workspace, release, environment|
      replace_method(:copy, ->(*) { raise Errno::ENOSPC, 'simulated full staging disk' }) do
        assert_raises(Errno::ENOSPC) { STAGING.preserve(workspace, environment: environment) }
      end
      assert_originals(workspace, release)
      assert_empty workspace.glob('.solco-macos-runtime-*')
    end
  end

  def test_bad_copied_bytes_or_modes_keep_all_originals
    [:bytes, :mode].each do |change|
      with_build do |workspace, release, environment|
        copy = lambda do |source, destination|
          FileUtils.copy_file(source.realpath, destination, true)
          change == :bytes ? destination.write('corrupted') : destination.chmod(0o600)
        end
        replace_method(:copy, copy) do
          error = assert_raises(RuntimeError) { STAGING.preserve(workspace, environment: environment) }
          assert_match(/Runtime bytes or mode changed/, error.message)
        end
        assert_originals(workspace, release)
      end
    end
  end

  def test_failure_after_installing_replacement_rolls_back_original_tree
    with_build do |workspace, release, environment|
      original_verify = STAGING.method(:verify!)
      verify = lambda do |directory, manifest, regular: false|
        raise 'simulated final verification failure' if regular && directory == release
        original_verify.call(directory, manifest, regular: regular)
      end
      replace_method(:verify!, verify) do
        assert_raises(RuntimeError) { STAGING.preserve(workspace, environment: environment) }
      end
      assert_originals(workspace, release)
      assert_empty workspace.glob('.solco-macos-runtime-*')
    end
  end

  def test_linked_or_non_runner_target_is_never_pruned
    with_build do |workspace, release, environment|
      assert_raises(RuntimeError) { STAGING.preserve(workspace, environment: {}) }
      assert_raises(RuntimeError) { STAGING.preserve(workspace, environment: environment.merge('GITHUB_WORKSPACE' => '/elsewhere')) }
      File.rename(workspace.join('target'), workspace.join('shared-target'))
      File.symlink('shared-target', workspace.join('target'))
      assert_raises(RuntimeError) { STAGING.preserve(workspace, environment: environment) }
      assert_originals(workspace, release)
    end
  end

  def test_missing_or_broken_runtime_stops_before_deletion
    with_build do |workspace, release, environment|
      File.symlink('missing', release.join('libbroken.dylib'))
      assert_raises(Errno::ENOENT) { STAGING.preserve(workspace, environment: environment) }
      assert_originals(workspace, release)
    end
  end

  def assert_originals(workspace, release)
    assert_equal 'final executable', release.join('solco').read
    assert_equal 0o755, release.join('solco').stat.mode & 0o777
    assert release.join('libdawn.dylib').symlink?
    assert_equal 'linked runtime', release.join('libdawn.dylib').read
    assert_equal 'discard me', workspace.join('target/release/build/host-macro/intermediate').read
  end
end
