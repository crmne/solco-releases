#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'openssl'
require 'optparse'
require 'tempfile'
require 'time'
require 'uri'

module Solco
  module ReleaseRetention
    REPOSITORY = 'crmne/solco-releases'
    SCHEMA = 1

    class Version
      include Comparable
      attr_reader :tag, :alpha

      def self.parse(tag)
        match = /\Av(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-alpha\.([1-9]\d*))?\z/.match(tag.to_s)
        new(tag, match.captures) if match
      end

      def initialize(tag, components)
        @tag = tag
        @numbers = components.take(3).map(&:to_i)
        @alpha = components[3]&.to_i
      end

      def <=>(other)
        [*@numbers, alpha ? 0 : 1, alpha || 0] <=>
          [*other.instance_variable_get(:@numbers), other.alpha ? 0 : 1, other.alpha || 0]
      end

      def package_names
        native = tag.delete_prefix('v').tr('-', '.')
        ["solco-#{tag}-x86_64-unknown-linux-gnu.tar.gz",
         "solco-#{tag}-aarch64-unknown-linux-gnu.tar.gz",
         "solco-#{tag}-x86_64-pc-windows-msvc.zip",
         "solco-#{tag}-x86_64-pc-windows-msvc-setup.exe",
         "solco-#{tag}-macos-arm64.dmg", "solco-#{tag}-macos-arm64.tar.gz",
         "solco_#{native}_amd64.deb", "solco_#{native}_arm64.deb",
         "solco-#{native}-1.x86_64.rpm", "solco-#{native}-1.aarch64.rpm"].sort
      end

      def asset_names = (package_names + %w[checksums.txt checksums.txt.sig]).sort
    end

    def self.snapshot(release)
      {
        'id' => release.fetch('id'), 'tag_name' => release.fetch('tag_name'),
        'draft' => release.fetch('draft'), 'prerelease' => release.fetch('prerelease'),
        'body_sha256' => Digest::SHA256.hexdigest(release.fetch('body', '').to_s),
        'assets' => release.fetch('assets').map do |asset|
          asset.slice('id', 'name', 'size', 'digest', 'updated_at', 'state', 'browser_download_url')
        end.sort_by { |asset| asset.fetch('name') }
      }
    end

    def self.candidates(releases, tag)
      target = Version.parse(tag) or raise 'Expected a stable or alpha application version'
      selected = releases.find { |r| r.fetch('tag_name') == tag } or raise 'New release is missing'
      raise 'New release is still a draft' if selected.fetch('draft')
      raise 'Release channel does not match its tag' unless selected.fetch('prerelease') == !target.alpha.nil?
      retired = []
      preserved = []
      releases.each do |release|
        next if release.fetch('id') == selected.fetch('id')
        version = Version.parse(release.fetch('tag_name'))
        reason = if release.fetch('draft')
          'draft'
        elsif !version
          'not an application version'
        elsif version > target
          raise "A newer application release exists: #{version.tag}"
        elsif target.alpha && !version.alpha
          'stable channel retained while publishing an alpha'
        elsif version == target
          raise 'Duplicate application version'
        end
        if reason
          preserved << {'id' => release.fetch('id'), 'tag_name' => release.fetch('tag_name'), 'reason' => reason}
          next
        end
        raise "Release channel mismatch: #{version.tag}" unless release.fetch('prerelease') == !version.alpha.nil?
        names = release.fetch('assets').map { |a| a.fetch('name') }
        unknown = names - version.asset_names
        raise "Unrecognized assets on #{version.tag}: #{unknown.join(', ')}; review them before retirement" unless unknown.empty?
        raise "Duplicate assets on #{version.tag}" unless names.uniq == names
        retired << snapshot(release)
      end
      [selected, retired.sort_by { |r| Version.parse(r.fetch('tag_name')) }, preserved]
    end

    class GitHub
      def json(path, paginate: false)
        command = ['gh', 'api', path]
        command += %w[--paginate --slurp] if paginate
        output, error, status = Open3.capture3(*command)
        raise "GitHub inventory failed: #{error.strip}" unless status.success?
        JSON.parse(output)
      end

      def releases = json("repos/#{REPOSITORY}/releases?per_page=100", paginate: true).flatten(1)

      # Deleting the release object removes its attached downloads. It never
      # calls a git-ref/tag endpoint and cannot address the private source repo.
      def delete_release(id)
        raise 'Invalid release ID' unless id.is_a?(Integer) && id.positive?
        _output, error, status = Open3.capture3('gh', 'api', '--method', 'DELETE',
                                               "repos/#{REPOSITORY}/releases/#{id}")
        raise "Release retirement failed: #{error.strip}" unless status.success?
      end
    end

    class Network
      def download(url, path)
        run('--output', path, url)
      end

      def link(url)
        uri = URI.parse(url)
        raise "Release note link must use HTTPS: #{url}" unless uri.is_a?(URI::HTTPS)
        run('--range', '0-0', '--output', File::NULL, url)
      end

      private

      def run(*arguments)
        _output, error, status = Open3.capture3('curl', '--fail', '--silent', '--show-error',
          '--location', '--proto', '=https', '--proto-redir', '=https', '--retry', '3', *arguments)
        raise "Release download or link verification failed: #{error.strip}" unless status.success?
      end
    end

    class Policy
      def initialize(tag:, directory:, public_key:, github: GitHub.new, network: Network.new)
        @tag, @directory, @public_key, @github, @network = tag, File.expand_path(directory), public_key, github, network
        @version = Version.parse(tag) or raise 'Invalid application release tag'
      end

      def plan
        selected, retired, preserved = ReleaseRetention.candidates(@github.releases, @tag)
        verified = verify(selected)
        reject_retired_links(verified, retired)
        {'schema' => SCHEMA, 'repository' => REPOSITORY, 'target' => ReleaseRetention.snapshot(selected),
         'verified_at' => Time.now.utc.iso8601, 'verified' => verified,
         'retire' => retired, 'preserve' => preserved, 'tags' => 'all retained'}
      end

      def apply(manifest)
        raise 'Unexpected retirement manifest' unless manifest.fetch('schema') == SCHEMA &&
          manifest.fetch('repository') == REPOSITORY && manifest.fetch('tags') == 'all retained' &&
          manifest.fetch('target').fetch('tag_name') == @tag
        selected, current, = ReleaseRetention.candidates(@github.releases, @tag)
        raise 'New release changed after verification' unless ReleaseRetention.snapshot(selected) == manifest.fetch('target')
        raise 'Retirement inventory changed; generate and review a new plan' unless current == manifest.fetch('retire')
        raise 'Verification changed; generate a new plan' unless verify(selected) == manifest.fetch('verified')
        remaining = manifest.fetch('retire').dup
        removed = []
        until remaining.empty?
          # Re-read immediately before every deletion. A concurrently published
          # version or changed asset aborts; no new IDs can enter the saved plan.
          latest, old, = ReleaseRetention.candidates(@github.releases, @tag)
          raise 'New release changed during retirement' unless ReleaseRetention.snapshot(latest) == manifest.fetch('target')
          raise 'Retirement inventory changed during retirement' unless old == remaining
          candidate = remaining.shift
          @github.delete_release(candidate.fetch('id'))
          removed << candidate.fetch('id')
        end
        latest, old, = ReleaseRetention.candidates(@github.releases, @tag)
        raise 'Release inventory did not confirm retirement' unless old.empty? &&
          ReleaseRetention.snapshot(latest) == manifest.fetch('target')
        {'repository' => REPOSITORY, 'kept' => @tag, 'retired_release_ids' => removed, 'tags' => 'all retained'}
      end

      private

      def reject_retired_links(verified, retired)
        retired_urls = retired.flat_map do |release|
          release.fetch('assets').map { |asset| asset.fetch('browser_download_url') } +
            ["https://github.com/#{REPOSITORY}/releases/tag/#{release.fetch('tag_name')}"]
        end
        verified.fetch('note_links').each do |url|
          uri = URI.parse(url)
          uri.query = uri.fragment = nil
          raise 'New release notes link to a download or release being retired' if retired_urls.include?(uri.to_s)
        end
      end

      def prepare_directory
        marker = File.join(@directory, '.solco-release-verification.json')
        expected = JSON.generate('repository' => REPOSITORY, 'tag' => @tag, 'schema' => SCHEMA)
        if File.exist?(@directory)
          raise 'Download directory must not be a symlink' if File.symlink?(@directory)
          raise 'Download directory is not owned by this verification' unless File.file?(marker) &&
            !File.symlink?(marker) && File.read(marker) == expected
        else
          FileUtils.mkdir_p(@directory)
          File.write(marker, expected, mode: File::WRONLY | File::CREAT | File::EXCL)
        end
      end

      def verified_asset(asset)
        name = asset.fetch('name')
        url = "https://github.com/#{REPOSITORY}/releases/download/#{@tag}/#{name}"
        raise "Unexpected download URL for #{name}" unless asset.fetch('browser_download_url') == url
        raise "Upload is incomplete: #{name}" unless asset.fetch('state') == 'uploaded' && asset.fetch('size').positive?
        destination = File.join(@directory, name)
        raise "Existing download is not a regular file: #{name}" if File.symlink?(destination) ||
          (File.exist?(destination) && !File.file?(destination))
        # Reuse only bytes whose current GitHub digest still matches. A missing
        # digest means a fresh download, never assumed proof from a prior run.
        reusable = File.file?(destination) && File.size(destination) == asset.fetch('size') &&
          asset['digest'] == "sha256:#{Digest::SHA256.file(destination).hexdigest}"
        unless reusable
          Tempfile.create(['.download-', '.part'], @directory) do |file|
            @network.download(url, file.path)
            file.close
            raise "Wrong download size: #{name}" unless File.size(file.path) == asset.fetch('size')
            File.rename(file.path, destination)
          end
        end
        digest = Digest::SHA256.file(destination).hexdigest
        if asset['digest'] && asset['digest'] != "sha256:#{digest}"
          raise "GitHub digest mismatch: #{name}"
        end
        [name, digest]
      end

      def verify(release)
        names = release.fetch('assets').map { |asset| asset.fetch('name') }
        raise 'Release must contain all ten platform packages and the signed checksums, with no other assets' unless names.sort == @version.asset_names
        prepare_directory
        hashes = release.fetch('assets').sort_by { |a| a.fetch('name') }.to_h { |a| verified_asset(a) }
        checksums = File.binread(File.join(@directory, 'checksums.txt'))
        signature = File.binread(File.join(@directory, 'checksums.txt.sig'))
        key = File.read(@public_key).strip
        raise 'Invalid committed publisher public key' unless key.match?(/\A[0-9a-fA-F]{64}\z/)
        # RFC 8410 SubjectPublicKeyInfo wraps the existing raw Ed25519 public key.
        public_key = OpenSSL::PKey.read(["302a300506032b6570032100#{key}"].pack('H*'))
        raise 'Invalid publisher signature' unless signature.bytesize == 64 && public_key.verify(nil, signature, checksums)
        entries = checksums.lines.map do |line|
          match = /\A([0-9a-f]{64})  ([A-Za-z0-9._-]+)\n\z/.match(line) or raise 'Malformed signed checksum manifest'
          [match[2], match[1]]
        end
        raise 'Signed manifest does not cover exactly the ten platform packages' unless entries.map(&:first).sort == @version.package_names
        entries.each { |name, digest| raise "Signed checksum mismatch: #{name}" unless hashes.fetch(name) == digest }
        body = release.fetch('body').to_s
        raise 'Published release notes are empty' if body.strip.empty?
        markdown_links = body.scan(/\]\(([^\s)]+)(?:\s+"[^"]*")?\)/).flatten
        urls = (markdown_links + body.scan(%r{https?://[^\s<>"')]+})).uniq.sort
        raise 'Release notes have no verifiable links' if urls.empty?
        asset_urls = release.fetch('assets').map { |asset| asset.fetch('browser_download_url') }
        urls.each { |url| @network.link(url) unless asset_urls.include?(url) }
        @network.link("https://github.com/#{REPOSITORY}/releases/tag/#{@tag}")
        {'asset_sha256' => hashes, 'note_links' => urls, 'public_key_sha256' => Digest::SHA256.hexdigest([key].pack('H*'))}
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    command = ARGV.shift
    options = {}
    OptionParser.new do |parser|
      parser.banner = 'release_retention.rb plan|apply --tag TAG --directory CACHE --public-key KEY --manifest PLAN'
      parser.on('--tag TAG') { |v| options[:tag] = v }
      parser.on('--directory PATH') { |v| options[:directory] = v }
      parser.on('--public-key PATH') { |v| options[:public_key] = v }
      parser.on('--manifest PATH') { |v| options[:manifest] = v }
    end.parse!
    raise 'Expected plan or apply and all four options' unless %w[plan apply].include?(command) &&
      ARGV.empty? && %i[tag directory public_key manifest].all? { |key| options[key] }
    manifest_path = options.delete(:manifest)
    policy = Solco::ReleaseRetention::Policy.new(**options)
    if command == 'plan'
      result = policy.plan
      File.write(manifest_path, JSON.pretty_generate(result) + "\n", mode: File::WRONLY | File::CREAT | File::EXCL)
      puts JSON.pretty_generate(result)
    else
      result = policy.apply(JSON.parse(File.read(manifest_path)))
      puts JSON.pretty_generate(result)
    end
  rescue StandardError => error
    warn "Release retention: #{error.message}"
    exit 1
  end
end
