#!/usr/bin/env ruby
# frozen_string_literal: true

# Keeps Solco's Linux package repositories in step with the published
# releases: the signed apt and dnf repositories and the Nix flake's sources
# in this repository (linux/ and nix/), and the AUR's solco-bin recipe.
#
# Nothing here rebuilds or repackages Solco. Every repository serves the
# official .deb, .rpm and .tar.gz downloads of a release, after checking them
# against its checksums.txt and the publisher signature. See
# docs/linux-repositories.md.

require 'digest'
require 'erb'
require 'fileutils'
require 'json'
require 'open3'
require 'openssl'
require 'optparse'
require 'stringio'
require 'time'
require 'tmpdir'
require 'zlib'
require_relative 'release_retention'

module Solco
  module LinuxRepositories
    Version = ReleaseRetention::Version
    REPOSITORY = ReleaseRetention::REPOSITORY
    DOWNLOADS = "https://github.com/#{REPOSITORY}/releases/download".freeze
    # GitHub serves this repository's files at /raw/main/ (a redirect to
    # raw.githubusercontent.com) and release downloads at
    # /releases/download/, on the same host. apt resolves a package's
    # Filename against the repository URL, so the index can name a release
    # download relative to linux/apt/ (four levels below the repository).
    PUBLISHED = "https://github.com/#{REPOSITORY}/raw/main/linux".freeze
    APT_TO_DOWNLOADS = '../../../../releases/download'
    # beta follows the newest release of any kind, stable the newest stable
    # one. A channel appears once it has a release.
    CHANNELS = %w[beta stable].freeze
    STATE = 'linux/state.json'
    KEY = 'linux/solco-packages.asc'

    Architecture = Struct.new(:deb, :rpm, :nix, :arch, :target, keyword_init: true) do
      def deb_name(version) = "solco_#{native(version)}_#{deb}.deb"
      def rpm_name(version) = "solco-#{native(version)}-1.#{rpm}.rpm"
      def archive_name(version) = "solco-#{version.tag}-#{target}.tar.gz"

      private

      # The release job renames DEB and RPM files from 1.2.3~alpha.1 to
      # 1.2.3.alpha.1, as GitHub does with tildes in asset names.
      def native(version) = version.tag.delete_prefix('v').tr('-', '.')
    end

    ARCHITECTURES = [
      Architecture.new(deb: 'amd64', rpm: 'x86_64', nix: 'x86_64-linux', arch: 'x86_64',
                       target: 'x86_64-unknown-linux-gnu'),
      Architecture.new(deb: 'arm64', rpm: 'aarch64', nix: 'aarch64-linux', arch: 'aarch64',
                       target: 'aarch64-unknown-linux-gnu')
    ].freeze

    def self.linux_names(version)
      ARCHITECTURES.flat_map { |a| [a.deb_name(version), a.rpm_name(version), a.archive_name(version)] }.sort
    end

    # The packages a repository downloads to index: DEB and RPM files.
    def self.package_names(version)
      ARCHITECTURES.flat_map { |a| [a.deb_name(version), a.rpm_name(version)] }.sort
    end

    # A release counts once it is published, its channel matches its tag and
    # every Linux download, checksums.txt and its signature are uploaded.
    def self.complete?(release, version)
      return false if release.fetch('draft')
      return false unless release.fetch('prerelease') == !version.alpha.nil?

      uploaded = release.fetch('assets').select { |a| a.fetch('state', 'uploaded') == 'uploaded' }.map { |a| a.fetch('name') }
      (linux_names(version) + %w[checksums.txt checksums.txt.sig] - uploaded).empty?
    end

    # {channel => [Version, release]} for the channels that have a release.
    def self.channels(releases)
      published = releases.filter_map do |release|
        version = Version.parse(release.fetch('tag_name'))
        [version, release] if version && complete?(release, version)
      end
      {
        'beta' => published.max_by(&:first),
        'stable' => published.reject { |version, _| version.alpha }.max_by(&:first)
      }.compact
    end

    # Arch pkgver: no hyphens. 1.2.3-alpha.1 becomes 1.2.3alpha.1, which
    # vercmp orders before 1.2.3 and after 1.2.3alpha.0.
    def self.pkgver(version) = version.tag.delete_prefix('v').delete('-')

    def self.sri(hex) = "sha256-#{[[hex].pack('H*')].pack('m0')}"

    def self.read_state(root)
      path = File.join(root, STATE)
      File.exist?(path) ? JSON.parse(File.read(path)) : {'channels' => {}}
    end

    # What a channel's repositories publish, compared to decide whether a run
    # has anything to do.
    def self.channel_state(version, checksums)
      {'tag' => version.tag, 'sha256' => linux_names(version).to_h { |name| [name, checksums.fetch(name)] }}
    end

    def self.checksums(text)
      text.each_line.to_h do |line|
        match = /\A([0-9a-f]{64})  ([A-Za-z0-9._-]+)\n?\z/.match(line) or raise 'Malformed checksums.txt'
        [match[2], match[1]]
      end
    end

    def self.verify_signature(checksums, signature, public_key_hex)
      key = OpenSSL::PKey.read(["302a300506032b6570032100#{public_key_hex.strip}"].pack('H*'))
      raise 'Invalid publisher signature' unless signature.bytesize == 64 && key.verify(nil, signature, checksums)
    end

    class Network
      def download(url, path)
        _output, error, status = Open3.capture3('curl', '--fail', '--silent', '--show-error', '--location',
          '--proto', '=https', '--proto-redir', '=https', '--retry', '3', '--output', path, url)
        raise "Download failed: #{url}: #{error.strip}" unless status.success?
      end
    end

    # Downloads a release's checksums and the packages to index, and checks
    # every file against the signed checksums before anything uses it.
    class Downloads
      def initialize(directory, public_key_hex, network: Network.new)
        @directory, @public_key_hex, @network = directory, public_key_hex, network
      end

      # [checksums, {name => path}]
      def fetch(version, names)
        directory = File.join(@directory, version.tag)
        FileUtils.mkdir_p(directory)
        %w[checksums.txt checksums.txt.sig].each { |name| get(version, name, directory) }
        text = File.binread(File.join(directory, 'checksums.txt'))
        LinuxRepositories.verify_signature(text, File.binread(File.join(directory, 'checksums.txt.sig')), @public_key_hex)
        checksums = LinuxRepositories.checksums(text)
        missing = LinuxRepositories.linux_names(version) - checksums.keys
        raise "checksums.txt does not list #{missing.join(', ')}" unless missing.empty?
        files = names.to_h do |name|
          path = File.join(directory, name)
          get(version, name, directory) unless File.file?(path) && Digest::SHA256.file(path).hexdigest == checksums.fetch(name)
          raise "#{name} does not match checksums.txt" unless Digest::SHA256.file(path).hexdigest == checksums.fetch(name)

          [name, path]
        end
        [checksums, files]
      end

      private

      def get(version, name, directory)
        @network.download("#{DOWNLOADS}/#{version.tag}/#{name}", File.join(directory, name))
      end
    end

    # Signs with the repository key, which the caller imported into gpg.
    class Signer
      def initialize(fingerprint)
        raise 'Expected a full key fingerprint' unless fingerprint.match?(/\A[0-9A-F]{40}\z/)

        @fingerprint = fingerprint
      end

      def clearsign(input, output) = gpg('--clearsign', '--output', output, input)
      def detach(input, output) = gpg('--detach-sign', '--armor', '--output', output, input)

      private

      def gpg(*arguments)
        _output, error, status = Open3.capture3('gpg', '--batch', '--yes', '--quiet', '--pinentry-mode', 'loopback',
          '--digest-algo', 'SHA512', '--local-user', "#{@fingerprint}!", *arguments)
        raise "Signing failed: #{error.strip}" unless status.success?
      end
    end

    class Tools
      def deb_control(path)
        output, error, status = Open3.capture3('dpkg-deb', '--field', path)
        raise "Cannot read #{File.basename(path)}: #{error.strip}" unless status.success?

        output
      end

      def createrepo(input, output, baseurl)
        _output, error, status = Open3.capture3('createrepo_c', '--quiet', '--no-database', '--checksum', 'sha256',
          '--general-compress-type', 'gz', '--baseurl', baseurl, '--outputdir', output, input)
        raise "createrepo_c failed: #{error.strip}" unless status.success?
      end
    end

    # Writes one channel's apt suite: linux/apt/dists/<channel>/.
    class Apt
      def initialize(root, signer, tools: Tools.new)
        @root, @signer, @tools = root, signer, tools
      end

      def write(channel, version, files, checksums, date)
        suite = File.join(@root, 'linux', 'apt', 'dists', channel)
        release_path = File.join(suite, 'Release')
        keep = File.exist?(release_path) ? hashes(File.read(release_path)) : []
        indexes = ARCHITECTURES.flat_map do |architecture|
          name = architecture.deb_name(version)
          control = @tools.deb_control(files.fetch(name))
          fields = control.scan(/^([A-Za-z-]+): (.*)$/).to_h
          raise "#{name} is not Solco's #{architecture.deb} package" unless
            fields['Package'] == 'solco' && fields['Architecture'] == architecture.deb
          raise "#{name} has the wrong version" unless
            fields['Version'] == version.tag.delete_prefix('v').sub('-', '~')

          # nfpm writes an empty Section field; the index leaves it out.
          control = control.gsub(/^[A-Za-z-]+:[ \t]*\n(?![ \t])/, '')
          stanza = control.chomp + "\n" \
            "Filename: #{APT_TO_DOWNLOADS}/#{version.tag}/#{name}\n" \
            "Size: #{File.size(files.fetch(name))}\n" \
            "SHA256: #{checksums.fetch(name)}\n"
          index(suite, "main/binary-#{architecture.deb}", stanza)
        end
        release = <<~RELEASE
          Origin: Solco
          Label: Solco
          Suite: #{channel}
          Codename: #{channel}
          Date: #{date.utc.strftime('%a, %d %b %Y %H:%M:%S UTC')}
          Architectures: #{ARCHITECTURES.map(&:deb).join(' ')}
          Components: main
          Description: Solco #{channel} builds, from https://github.com/#{REPOSITORY}/releases
          Acquire-By-Hash: yes
          SHA256:
        RELEASE
        release += indexes.map { |path, content| " #{Digest::SHA256.hexdigest(content)} #{content.bytesize} #{path}\n" }.join
        File.write(release_path, release)
        @signer.clearsign(release_path, File.join(suite, 'InRelease'))
        @signer.detach(release_path, File.join(suite, 'Release.gpg'))
        prune(suite, keep + hashes(release))
      end

      private

      def index(suite, directory, packages)
        compressed = StringIO.new(+'', 'wb')
        gzip = Zlib::GzipWriter.new(compressed, Zlib::BEST_COMPRESSION)
        gzip.mtime = 0
        gzip.write(packages)
        gzip.close
        [['Packages', packages], ['Packages.gz', compressed.string]].map do |name, content|
          path = File.join(suite, directory, name)
          FileUtils.mkdir_p(File.dirname(path))
          File.binwrite(path, content)
          # Immutable copies: a client holding the previous InRelease still
          # finds the indexes it names while caches catch up.
          by_hash = File.join(suite, directory, 'by-hash', 'SHA256', Digest::SHA256.hexdigest(content))
          FileUtils.mkdir_p(File.dirname(by_hash))
          File.binwrite(by_hash, content)
          ["#{directory}/#{name}", content]
        end
      end

      def hashes(release) = release.scan(/^ ([0-9a-f]{64}) \d+ \S+$/).flatten

      def prune(suite, keep)
        Dir.glob(File.join(suite, '**', 'by-hash', 'SHA256', '*')).each do |path|
          File.delete(path) unless keep.include?(File.basename(path))
        end
      end
    end

    # Writes one channel's dnf repository: linux/rpm/<channel>/repodata/.
    # The packages stay on the release; xml:base points dnf at them.
    class Rpm
      def initialize(root, signer, tools: Tools.new)
        @root, @signer, @tools = root, signer, tools
      end

      def write(channel, version, files)
        repodata = File.join(@root, 'linux', 'rpm', channel, 'repodata')
        repomd = File.join(repodata, 'repomd.xml')
        keep = File.exist?(repomd) ? locations(File.read(repomd)) : []
        Dir.mktmpdir('solco-rpm') do |work|
          input = File.join(work, 'input')
          output = File.join(work, 'output')
          FileUtils.mkdir_p([input, output])
          ARCHITECTURES.each do |architecture|
            name = architecture.rpm_name(version)
            FileUtils.ln_s(File.expand_path(files.fetch(name)), File.join(input, name))
          end
          @tools.createrepo(input, output, "#{DOWNLOADS}/#{version.tag}/")
          FileUtils.mkdir_p(repodata)
          Dir.children(File.join(output, 'repodata')).each do |name|
            FileUtils.cp(File.join(output, 'repodata', name), File.join(repodata, name))
          end
        end
        @signer.detach(repomd, "#{repomd}.asc")
        keep += locations(File.read(repomd))
        Dir.children(repodata).each do |name|
          next if %w[repomd.xml repomd.xml.asc].include?(name) || keep.include?(name)

          File.delete(File.join(repodata, name))
        end
      end

      private

      def locations(repomd) = repomd.scan(%r{<location href="repodata/([^"]+)"}).flatten
    end

    # Writes nix/release.json, which flake.nix reads.
    def self.nix(root, version, checksums)
      sources = ARCHITECTURES.to_h do |architecture|
        name = architecture.archive_name(version)
        [architecture.nix, {'url' => "#{DOWNLOADS}/#{version.tag}/#{name}", 'hash' => sri(checksums.fetch(name))}]
      end
      release = {'version' => version.tag.delete_prefix('v'), 'tag' => version.tag, 'sources' => sources}
      File.write(File.join(root, 'nix', 'release.json'), JSON.pretty_generate(release) + "\n")
    end

    # Renders the AUR's PKGBUILD. pkgrel restarts at 1 for a new version and
    # goes up when only the recipe changes.
    def self.pkgbuild(root, version, checksums, current: nil)
      template = File.read(File.join(root, 'packaging', 'aur', 'solco-bin', 'PKGBUILD.erb'))
      render = lambda do |pkgrel|
        ERB.new(template, trim_mode: '-').result_with_hash(
          tag: version.tag, pkgver: pkgver(version), pkgrel: pkgrel,
          sources: ARCHITECTURES.map do |architecture|
            name = architecture.deb_name(version)
            {arch: architecture.arch, deb: architecture.deb, url: "#{DOWNLOADS}/#{version.tag}/#{name}",
             sha256: checksums.fetch(name)}
          end
        )
      end
      return render.call(1) unless current

      current_pkgver = current[/^pkgver=(\S+)$/, 1]
      current_pkgrel = current[/^pkgrel=(\d+)$/, 1].to_i
      return render.call(1) unless current_pkgver == pkgver(version)

      same = render.call(current_pkgrel)
      same == current ? same : render.call(current_pkgrel + 1)
    end

    # Writes linux/apt/solco.sources and linux/rpm/solco.repo, the files users
    # download to add a channel, with the public key from linux/.
    def self.sources(root, channel)
      key = File.read(File.join(root, KEY))
      inline = key.lines.map { |line| line.strip.empty? ? " .\n" : " #{line}" }.join
      File.write(File.join(root, 'linux', 'apt', "solco-#{channel}.sources"), <<~SOURCES + inline)
        # Solco #{channel} builds. Docs: https://github.com/#{REPOSITORY}#linux
        Types: deb
        URIs: #{PUBLISHED}/apt
        Suites: #{channel}
        Components: main
        Signed-By:
      SOURCES
      File.write(File.join(root, 'linux', 'rpm', "solco-#{channel}.repo"), <<~REPO)
        # Solco #{channel} builds. Docs: https://github.com/#{REPOSITORY}#linux
        [solco-#{channel}]
        name=Solco (#{channel})
        baseurl=#{PUBLISHED}/rpm/#{channel}
        enabled=1
        # The repository metadata is signed and lists each package's SHA-256.
        repo_gpgcheck=1
        gpgcheck=0
        gpgkey=#{PUBLISHED}/solco-packages.asc
        metadata_expire=6h
      REPO
    end

    # Brings every repository up to date with the published releases.
    # Returns the channels that changed.
    def self.update(root:, releases:, downloads:, signer:, tools: Tools.new, force: false)
      state = read_state(root)
      changed = []
      channels(releases).each do |channel, (version, release)|
        checksums, files = downloads.fetch(version, package_names(version))
        published = channel_state(version, checksums)
        next if !force && state.dig('channels', channel) == published

        date = Time.iso8601(release.fetch('published_at'))
        Apt.new(root, signer, tools:).write(channel, version, files, checksums, date)
        Rpm.new(root, signer, tools:).write(channel, version, files)
        sources(root, channel)
        nix(root, version, checksums) if channel == 'beta'
        state['channels'][channel] = published
        changed << channel
      end
      File.write(File.join(root, STATE), JSON.pretty_generate(state) + "\n") unless changed.empty?
      changed
    end

    # Whether the repositories or the AUR lag behind the releases, without
    # downloading anything: the state file and the AUR's version against the
    # release list.
    def self.plan(root:, releases:, aur_version:)
      state = read_state(root)
      current = channels(releases)
      lagging = current.reject { |channel, (version, _)| state.dig('channels', channel, 'tag') == version.tag }.keys
      beta = current['beta']&.first
      aur = beta && aur_version&.sub(/-\d+\z/, '') != pkgver(beta)
      {'channels' => lagging, 'aur' => aur ? true : false, 'beta_tag' => beta&.tag,
       'needed' => !lagging.empty? || aur ? true : false}
    end

    class GitHub
      def releases
        output, error, status = Open3.capture3('gh', 'api', '--paginate', '--slurp',
          "repos/#{REPOSITORY}/releases?per_page=100")
        raise "Cannot list releases: #{error.strip}" unless status.success?

        JSON.parse(output).flatten(1)
      end

      def api(method, path, body = nil)
        output, error, status = Open3.capture3('gh', 'api', '--method', method, path,
          *(body ? ['--input', '-'] : []), stdin_data: body ? JSON.generate(body) : '')
        raise "GitHub #{method} #{path} failed: #{error.strip}" unless status.success?

        JSON.parse(output)
      end

      # Commits the working tree's changes under paths to main through the
      # API, so GitHub signs the commit. Refuses if main moved since the
      # checkout; the next run starts again from the new main.
      def commit(root, paths, message)
        changes, error, status = Open3.capture3('git', '-C', root, 'status', '--porcelain=v1', '-z',
          '--untracked-files=all', '--', *paths)
        raise "git status failed: #{error.strip}" unless status.success?
        return nil if changes.empty?

        head, = Open3.capture2('git', '-C', root, 'rev-parse', 'HEAD')
        head = head.strip
        remote = api('GET', "repos/#{REPOSITORY}/git/ref/heads/main").dig('object', 'sha')
        raise 'main moved since the checkout; the next run updates from the new main' unless remote == head

        tree = changes.split("\0").map do |entry|
          path = entry[3..]
          file = File.join(root, path)
          if File.file?(file)
            blob = api('POST', "repos/#{REPOSITORY}/git/blobs",
              {'content' => [File.binread(file)].pack('m0'), 'encoding' => 'base64'})
            {'path' => path, 'mode' => '100644', 'type' => 'blob', 'sha' => blob.fetch('sha')}
          else
            {'path' => path, 'mode' => '100644', 'type' => 'blob', 'sha' => nil}
          end
        end
        base = api('GET', "repos/#{REPOSITORY}/git/commits/#{head}").dig('tree', 'sha')
        new_tree = api('POST', "repos/#{REPOSITORY}/git/trees", {'base_tree' => base, 'tree' => tree})
        commit = api('POST', "repos/#{REPOSITORY}/git/commits",
          {'message' => message, 'tree' => new_tree.fetch('sha'), 'parents' => [head]})
        api('PATCH', "repos/#{REPOSITORY}/git/refs/heads/main", {'sha' => commit.fetch('sha'), 'force' => false})
        commit.fetch('sha')
      end
    end

    def self.aur_version(name)
      output, error, status = Open3.capture3('curl', '--fail', '--silent', '--show-error', '--retry', '3',
        "https://aur.archlinux.org/rpc/v5/info?arg[]=#{name}")
      raise "AUR lookup failed: #{error.strip}" unless status.success?

      JSON.parse(output).fetch('results').first&.fetch('Version')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    command = ARGV.shift
    options = {root: Dir.pwd}
    OptionParser.new do |parser|
      parser.banner = <<~USAGE
        linux_repositories.rb plan [--output PATH]
        linux_repositories.rb update --public-key HEX_FILE --key-fingerprint FPR --cache DIR [--force]
        linux_repositories.rb pkgbuild --public-key HEX_FILE --cache DIR --output PATH [--current PATH]
        linux_repositories.rb commit --message TEXT
      USAGE
      parser.on('--root PATH') { |v| options[:root] = File.expand_path(v) }
      parser.on('--output PATH') { |v| options[:output] = v }
      parser.on('--public-key PATH') { |v| options[:public_key] = v }
      parser.on('--key-fingerprint FPR') { |v| options[:fingerprint] = v }
      parser.on('--cache PATH') { |v| options[:cache] = v }
      parser.on('--current PATH') { |v| options[:current] = v }
      parser.on('--message TEXT') { |v| options[:message] = v }
      parser.on('--force') { options[:force] = true }
      # A saved copy of the releases API's list, for checks without gh.
      parser.on('--releases PATH') { |v| options[:releases] = v }
    end.parse!
    raise "Unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?

    repositories = Solco::LinuxRepositories
    github = repositories::GitHub.new
    releases = -> { options[:releases] ? JSON.parse(File.read(options[:releases])) : github.releases }
    case command
    when 'plan'
      result = repositories.plan(root: options[:root], releases: releases.call,
                                 aur_version: repositories.aur_version('solco-bin'))
      # Appends, as GitHub's step output file expects.
      File.write(options[:output], result.map { |key, value| "#{key}=#{value.is_a?(Array) ? value.join(',') : value}\n" }.join, mode: 'a') if options[:output]
      puts JSON.pretty_generate(result)
    when 'update'
      downloads = repositories::Downloads.new(options.fetch(:cache), File.read(options.fetch(:public_key)))
      changed = repositories.update(root: options[:root], releases: releases.call, downloads:,
        signer: repositories::Signer.new(options.fetch(:fingerprint)), force: options[:force])
      puts changed.empty? ? 'Repositories already match the releases' : "Updated: #{changed.join(', ')}"
    when 'pkgbuild'
      version, = repositories.channels(releases.call).fetch('beta') { raise 'No published release' }
      downloads = repositories::Downloads.new(options.fetch(:cache), File.read(options.fetch(:public_key)))
      checksums, = downloads.fetch(version, [])
      current = options[:current] && File.exist?(options[:current]) ? File.read(options[:current]) : nil
      File.write(options.fetch(:output), repositories.pkgbuild(options[:root], version, checksums, current:))
      puts "PKGBUILD for #{version.tag}"
    when 'commit'
      sha = github.commit(options[:root], %w[linux nix], options.fetch(:message))
      puts sha ? "Committed #{sha}" : 'Nothing to commit'
    else
      raise 'Expected plan, update, pkgbuild or commit'
    end
  rescue StandardError => error
    warn "Linux repositories: #{error.message}"
    exit 1
  end
end
