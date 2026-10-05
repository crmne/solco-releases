# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'pathname'
require 'tmpdir'

module Solco
  # Only the disposable release runner calls this. A developer's target may be
  # an mbx link or shared cache and must never be pruned by this helper.
  module MacosRuntimeStaging
    module_function

    RELEASE = 'aarch64-apple-darwin/release'

    def real_directory!(path)
      raise "Expected an owned directory: #{path}" unless path.directory? && !path.symlink?
    end

    def fingerprint(path)
      stat = path.stat
      raise "Expected a nonempty runtime file: #{path}" unless stat.file? && stat.size.positive?
      {sha256: Digest::SHA256.file(path).hexdigest, mode: stat.mode & 0o7777, size: stat.size}
    end

    def copy(source, destination)
      # Resolve runtime links before any compiler directories can be removed.
      FileUtils.copy_file(source.realpath, destination, true)
    end

    def verify!(directory, manifest, regular: false)
      manifest.each do |name, expected|
        path = directory.join(name)
        raise "Runtime copy is still a symlink: #{name}" if regular && path.symlink?
        raise "Runtime bytes or mode changed: #{name}" unless fingerprint(path) == expected
      end
    end

    def preserve(workspace, environment: ENV)
      raise 'Only a GitHub Actions release runner may prune build output' unless environment['GITHUB_ACTIONS'] == 'true'
      workspace = Pathname.new(workspace).expand_path
      raise 'Workspace must match GITHUB_WORKSPACE' unless workspace.to_s == environment['GITHUB_WORKSPACE']
      real_directory!(workspace)
      raise 'Workspace must have no symlink parents' unless workspace.realpath == workspace
      target = workspace.join('target')
      release = target.join(RELEASE)
      [target, target.join('aarch64-apple-darwin'), release].each { |path| real_directory!(path) }
      names = ['solco', *release.children.select { |path| path.basename.to_s.end_with?('.dylib') }.map { |path| path.basename.to_s }].sort
      manifest = names.to_h { |name| [name, fingerprint(release.join(name))] }
      raise 'The final Solco executable is not executable' if (manifest.fetch('solco').fetch(:mode) & 0o111).zero?

      stage = Pathname.new(Dir.mktmpdir('.solco-macos-runtime-', workspace.to_s))
      staged_target = stage.join('target')
      staged_release = staged_target.join(RELEASE)
      original = stage.join('cargo-intermediates')
      begin
        FileUtils.mkdir_p(staged_release)
        names.each { |name| copy(release.join(name), staged_release.join(name)) }
        verify!(staged_release, manifest, regular: true)
        verify!(release, manifest)

        # Keep the entire original tree until the replacement is in place and
        # verified at the exact paths used by both app and portable packaging.
        File.rename(target, original)
        begin
          File.rename(staged_target, target)
          verify!(release, manifest, regular: true)
        rescue StandardError
          FileUtils.remove_entry_secure(target.to_s) if target.exist?
          File.rename(original, target)
          raise
        end
        manifest.each do |name, entry|
          puts "Preserved #{name}: SHA256 #{entry.fetch(:sha256)}, mode #{entry.fetch(:mode).to_s(8)}, #{entry.fetch(:size)} bytes"
        end
        FileUtils.remove_entry_secure(original.to_s)
      ensure
        # A deletion/rollback error retains remaining originals for inspection.
        FileUtils.remove_entry_secure(stage.to_s) if stage.exist? && !original.exist?
      end
      manifest
    end
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: ruby preserve_macos_runtime.rb WORKSPACE' unless ARGV.length == 1
  Solco::MacosRuntimeStaging.preserve(ARGV.fetch(0))
end
