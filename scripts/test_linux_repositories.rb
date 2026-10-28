# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative 'linux_repositories'

class LinuxRepositoriesTest < Minitest::Test
  Repositories = Solco::LinuxRepositories
  ROOT = File.expand_path('..', __dir__)

  def release(tag, prerelease: tag.include?('-'), draft: false, missing: [], published_at: '2026-10-28T10:18:30Z')
    version = Repositories::Version.parse(tag)
    names = (version ? Repositories.linux_names(version) : []) + %w[checksums.txt checksums.txt.sig] - missing
    {'tag_name' => tag, 'prerelease' => prerelease, 'draft' => draft, 'published_at' => published_at,
     'assets' => names.map { |name| {'name' => name, 'state' => 'uploaded'} }}
  end

  def checksums(tag)
    Repositories.linux_names(Repositories::Version.parse(tag)).to_h { |name| [name, Digest::SHA256.hexdigest(name)] }
  end

  class FakeSigner
    def clearsign(input, output) = File.write(output, "SIGNED\n#{File.read(input)}")
    def detach(input, output) = File.write(output, "SIGNATURE of #{Digest::SHA256.file(input).hexdigest}\n")
  end

  class FakeTools
    def deb_control(path)
      architecture = path[/_(amd64|arm64)\.deb\z/, 1]
      version = File.basename(path)[/\Asolco_(.+)_/, 1].sub(/\.((?:alpha|beta)\.\d+)\z/, '~\1')
      "Package: solco\nVersion: #{version}\nSection: \nArchitecture: #{architecture}\nDescription: Solco\n"
    end

    def rpm_signed?(path) = File.basename(path).include?('beta')

    def createrepo(input, output, baseurl)
      names = Dir.children(input).sort
      FileUtils.mkdir_p(File.join(output, 'repodata'))
      primary = "#{Digest::SHA256.hexdigest(baseurl + names.join)}-primary.xml.gz"
      File.write(File.join(output, 'repodata', primary), "#{baseurl} #{names.join(' ')}")
      File.write(File.join(output, 'repodata', 'repomd.xml'), %(<location href="repodata/#{primary}"/>\n))
    end
  end

  class FakeDownloads
    attr_reader :fetched
    def initialize(directory) = (@directory, @fetched = directory, [])

    def fetch(version, names)
      @fetched << version.tag
      sums = Repositories.linux_names(version).to_h { |name| [name, Digest::SHA256.hexdigest(name)] }
      files = names.to_h do |name|
        path = File.join(@directory, name)
        File.write(path, name)
        [name, path]
      end
      [sums, files]
    end
  end

  def with_root
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, 'linux'))
      FileUtils.mkdir_p(File.join(root, 'nix'))
      FileUtils.cp(File.join(ROOT, Repositories::KEY), File.join(root, Repositories::KEY))
      FileUtils.cp_r(File.join(ROOT, 'packaging'), root)
      yield root
    end
  end

  def update(root, releases, downloads: nil, force: false)
    Dir.mktmpdir do |cache|
      downloads ||= FakeDownloads.new(cache)
      return Repositories.update(root:, releases:, downloads:, signer: FakeSigner.new, tools: FakeTools.new, force:)
    end
  end

  def test_beta_follows_the_newest_release_and_stable_the_newest_stable_one
    channels = Repositories.channels([
      release('v1.0.0'), release('v1.1.0-alpha.2'), release('v0.9.0'),
      release('v1.2.0-alpha.1', draft: true),
      release('v1.1.0-alpha.3', missing: ['solco_1.1.0.alpha.3_arm64.deb']),
      release('v1.1.0-alpha.4', prerelease: false), release('not-a-version')
    ])
    assert_equal 'v1.1.0-alpha.2', channels.fetch('beta').first.tag
    assert_equal 'v1.0.0', channels.fetch('stable').first.tag
    assert_equal({'beta' => 'v1.0.0'}, Repositories.channels([release('v1.0.0')]).slice('beta').transform_values { _1.first.tag })
    refute Repositories.channels([release('v1.0.0-alpha.1')]).key?('stable')
  end

  def test_beta_follows_alpha_and_precedes_the_release
    order = %w[v1.0.0-alpha.1 v1.0.0-alpha.10 v1.0.0-beta.1 v1.0.0-beta.2 v1.0.0 v1.0.1-alpha.1]
    assert_equal order, order.shuffle(random: Random.new(1)).map { Repositories::Version.parse(_1) }.sort.map(&:tag)
    assert_equal '1.0.0beta.1', Repositories.pkgver(Repositories::Version.parse('v1.0.0-beta.1'))
    channels = Repositories.channels([release('v1.0.0-alpha.1'), release('v1.0.0-beta.1')])
    assert_equal 'v1.0.0-beta.1', channels.fetch('beta').first.tag
    refute channels.key?('stable')
    assert_includes Repositories.linux_names(Repositories::Version.parse('v1.0.0-beta.1')), 'solco_1.0.0.beta.1_amd64.deb'
    with_root do |root|
      update(root, [release('v1.0.0-beta.1')])
      assert_includes File.read(File.join(root, 'linux/apt/dists/beta/main/binary-amd64/Packages')), "Version: 1.0.0~beta.1\n"
      # Signed RPMs: dnf checks each package's signature too.
      assert_includes File.read(File.join(root, 'linux/rpm/solco-beta.repo')), "gpgcheck=1\n"
    end
  end

  def test_arch_versions_sort_prereleases_before_their_release
    assert_equal '1.0.0alpha.1', Repositories.pkgver(Repositories::Version.parse('v1.0.0-alpha.1'))
    assert_equal '1.0.0', Repositories.pkgver(Repositories::Version.parse('v1.0.0'))
    assert_equal 'sha256-CZmTThsV/kRpgRT/VQWQu3LPcwpw8b2WgBKVFevuUO4=',
      Repositories.sri('0999934e1b15fe44698114ff550590bb72cf730a70f1bd9680129515ebee50ee')
  end

  def test_signed_checksums_gate_every_download
    key = OpenSSL::PKey.generate_key('ED25519')
    public_hex = key.public_to_der[-32..].unpack1('H*')
    version = Repositories::Version.parse('v1.0.0-alpha.1')
    files = Repositories.linux_names(version).to_h { |name| [name, "contents of #{name}"] }
    text = files.map { |name, body| "#{Digest::SHA256.hexdigest(body)}  #{name}\n" }.join
    network = Object.new
    served = files.merge('checksums.txt' => text, 'checksums.txt.sig' => key.sign(nil, text))
    network.define_singleton_method(:download) { |url, path| File.binwrite(path, served.fetch(File.basename(url))) }
    Dir.mktmpdir do |cache|
      downloads = Repositories::Downloads.new(cache, public_hex, network:)
      sums, paths = downloads.fetch(version, Repositories.package_names(version))
      assert_equal Digest::SHA256.hexdigest(files.fetch('solco_1.0.0.alpha.1_amd64.deb')), sums.fetch('solco_1.0.0.alpha.1_amd64.deb')
      assert_equal Repositories.package_names(version), paths.keys

      served['solco_1.0.0.alpha.1_arm64.deb'] = 'tampered'
      File.delete(paths.fetch('solco_1.0.0.alpha.1_arm64.deb'))
      error = assert_raises(RuntimeError) { downloads.fetch(version, Repositories.package_names(version)) }
      assert_match(/does not match checksums.txt/, error.message)

      served['checksums.txt'] = text.sub(/\A./, '0')
      error = assert_raises(RuntimeError) { downloads.fetch(version, []) }
      assert_equal 'Invalid publisher signature', error.message
    end
  end

  def test_apt_points_at_the_release_downloads_and_keeps_the_previous_indexes
    with_root do |root|
      assert_equal %w[beta], update(root, [release('v1.0.0-alpha.1')])
      suite = File.join(root, 'linux/apt/dists/beta')
      packages = File.read(File.join(suite, 'main/binary-amd64/Packages'))
      assert_includes packages, "Filename: ../../../../releases/download/v1.0.0-alpha.1/solco_1.0.0.alpha.1_amd64.deb\n"
      assert_includes packages, "SHA256: #{Digest::SHA256.hexdigest('solco_1.0.0.alpha.1_amd64.deb')}\n"
      refute_includes packages, 'Section:'
      # From linux/apt/ four levels up is the repository's root on github.com.
      assert_equal 'https://github.com/crmne/solco-releases/releases/download/v1',
        URI.join("#{Repositories::PUBLISHED}/apt/", "#{Repositories::APT_TO_DOWNLOADS}/v1").to_s
      release_file = File.read(File.join(suite, 'Release'))
      assert_includes release_file, "Date: Wed, 28 Oct 2026 10:18:30 UTC\n"
      assert_includes release_file, "Acquire-By-Hash: yes\n"
      assert_equal "SIGNED\n#{release_file}", File.read(File.join(suite, 'InRelease'))
      first = Dir.glob(File.join(suite, '**/by-hash/SHA256/*')).map { File.basename(_1) }
      assert_equal 4, first.size

      update(root, [release('v1.0.0-alpha.2')])
      second = Dir.glob(File.join(suite, '**/by-hash/SHA256/*')).map { File.basename(_1) }
      assert_equal 8, second.size
      assert_empty first - second
      update(root, [release('v1.0.0-alpha.3')])
      assert_empty first & Dir.glob(File.join(suite, '**/by-hash/SHA256/*')).map { File.basename(_1) }
    end
  end

  def test_rpm_metadata_names_the_release_and_keeps_the_previous_files
    with_root do |root|
      update(root, [release('v1.0.0-alpha.1')])
      repodata = File.join(root, 'linux/rpm/beta/repodata')
      first = Dir.children(repodata).grep(/primary/)
      assert_match %r{releases/download/v1.0.0-alpha.1/ }, File.read(File.join(repodata, first.first))
      assert File.exist?(File.join(repodata, 'repomd.xml.asc'))
      update(root, [release('v1.0.0-alpha.2')])
      assert_equal 2, Dir.children(repodata).grep(/primary/).size
      update(root, [release('v1.0.0-alpha.3')])
      assert_equal 2, Dir.children(repodata).grep(/primary/).size
      refute_includes Dir.children(repodata), first.first
    end
  end

  def test_sources_nix_and_state_follow_the_channels
    with_root do |root|
      update(root, [release('v1.0.0'), release('v1.1.0-alpha.1')])
      sources = File.read(File.join(root, 'linux/apt/solco-beta.sources'))
      assert_includes sources, "URIs: https://github.com/crmne/solco-releases/raw/main/linux/apt\nSuites: beta\n"
      assert_includes sources, " -----BEGIN PGP PUBLIC KEY BLOCK-----\n .\n"
      repo = File.read(File.join(root, 'linux/rpm/solco-stable.repo'))
      assert_includes repo, "baseurl=https://github.com/crmne/solco-releases/raw/main/linux/rpm/stable\n"
      assert_includes repo, "repo_gpgcheck=1\n"
      assert_includes repo, "gpgcheck=0\n"
      nix = JSON.parse(File.read(File.join(root, 'nix/release.json')))
      assert_equal '1.1.0-alpha.1', nix.fetch('version')
      assert_equal Repositories.sri(Digest::SHA256.hexdigest('solco-v1.1.0-alpha.1-aarch64-unknown-linux-gnu.tar.gz')),
        nix.dig('sources', 'aarch64-linux', 'hash')
      state = Repositories.read_state(root)
      assert_equal %w[v1.1.0-alpha.1 v1.0.0], state.fetch('channels').values_at('beta', 'stable').map { _1.fetch('tag') }

      # Nothing changed: nothing is rewritten or signed again.
      before = Dir.glob(File.join(root, '**/*')).to_h { [_1, File.file?(_1) && File.read(_1)] }
      assert_empty update(root, [release('v1.0.0'), release('v1.1.0-alpha.1')])
      assert_equal before, Dir.glob(File.join(root, '**/*')).to_h { [_1, File.file?(_1) && File.read(_1)] }
      assert_equal %w[beta stable], update(root, [release('v1.0.0'), release('v1.1.0-alpha.1')], force: true)
    end
  end

  def test_plan_compares_the_state_and_the_aur_with_the_releases
    with_root do |root|
      releases = [release('v1.0.0-alpha.1')]
      plan = Repositories.plan(root:, releases:, aur_version: nil)
      assert_equal({'channels' => %w[beta], 'aur' => true, 'beta_tag' => 'v1.0.0-alpha.1', 'needed' => true}, plan)
      update(root, releases)
      assert_equal false, Repositories.plan(root:, releases:, aur_version: '1.0.0alpha.1-2').fetch('needed')
      assert_equal true, Repositories.plan(root:, releases:, aur_version: '0.9.0-1').fetch('aur')
      assert_equal false, Repositories.plan(root:, releases: [], aur_version: nil).fetch('needed')
    end
  end

  def test_pkgbuild_installs_the_verified_debian_packages
    with_root do |root|
      version = Repositories::Version.parse('v1.0.0-alpha.1')
      sums = checksums('v1.0.0-alpha.1')
      pkgbuild = Repositories.pkgbuild(root, version, sums)
      assert_includes pkgbuild, "_tag=v1.0.0-alpha.1\npkgver=1.0.0alpha.1\npkgrel=1\n"
      assert_includes pkgbuild, 'source_x86_64=("solco-${_tag}-amd64.deb::https://github.com/crmne/solco-releases/releases/download/${_tag}/solco_1.0.0.alpha.1_amd64.deb")'
      assert_includes pkgbuild, "sha256sums_aarch64=('#{sums.fetch('solco_1.0.0.alpha.1_arm64.deb')}')"
      assert_includes pkgbuild, "options=('!debug' '!strip')"

      assert_equal pkgbuild, Repositories.pkgbuild(root, version, sums, current: pkgbuild)
      edited = pkgbuild.sub("'wayland'", "'wayland'\n  'zstd'")
      assert_includes Repositories.pkgbuild(root, version, sums, current: edited), "pkgrel=2\n"
      newer = Repositories::Version.parse('v1.0.0-alpha.2')
      assert_includes Repositories.pkgbuild(root, newer, checksums('v1.0.0-alpha.2'), current: edited), "pkgrel=1\n"
    end
  end
end
