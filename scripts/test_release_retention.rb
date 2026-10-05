# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative 'release_retention'

class ReleaseRetentionTest < Minitest::Test
  Retention = Solco::ReleaseRetention
  TAG = 'v0.8.0-alpha.1'

  class FakeGitHub
    attr_reader :deleted
    attr_accessor :inventory, :before_read, :after_delete
    def initialize(inventory)
      @inventory, @deleted, @reads = inventory, [], 0
    end
    def releases
      @reads += 1
      before_read&.call(self, @reads)
      Marshal.load(Marshal.dump(inventory))
    end
    def delete_release(id)
      raise 'Unexpected deletion' unless inventory.any? { |release| release.fetch('id') == id }
      @deleted << id
      inventory.reject! { |release| release.fetch('id') == id }
      after_delete&.call(self)
    end
  end

  class FakeNetwork
    attr_reader :links, :downloads
    attr_accessor :broken_link
    def initialize(files)
      @files, @links, @downloads = files, [], []
    end
    def download(url, path)
      @downloads << url
      File.binwrite(path, @files.fetch(url))
    end
    def link(url)
      raise 'Broken release note link' if broken_link == url
      raise 'Not HTTPS' unless URI.parse(url).is_a?(URI::HTTPS)
      @links << url
    end
  end

  def setup
    @scratch = Dir.mktmpdir('solco-retention-test-')
    @key = OpenSSL::PKey.generate_key('ED25519')
    @public_key = File.join(@scratch, 'public-key.hex')
    File.write(@public_key, @key.public_to_der.byteslice(-32, 32).unpack1('H*'))
    @files = {}
    @new = release(TAG, 500)
    @old = release('v0.7.0-alpha.1', 402_724_739)
    @github = FakeGitHub.new([@new, @old])
    @network = FakeNetwork.new(@files)
    @directory = File.join(@scratch, 'downloads')
  end

  def teardown
    FileUtils.remove_entry(@scratch)
  end

  def release(tag, id)
    version = Retention::Version.parse(tag)
    bytes = version.package_names.to_h { |name| [name, "package #{name}\n"] }
    checksums = bytes.sort.map { |name, body| "#{Digest::SHA256.hexdigest(body)}  #{name}\n" }.join
    bytes['checksums.txt'] = checksums
    bytes['checksums.txt.sig'] = @key.sign(nil, checksums)
    {'id' => id, 'tag_name' => tag, 'prerelease' => !version.alpha.nil?, 'draft' => false,
     'body' => "A release. [Download](https://github.com/#{Retention::REPOSITORY}/releases/download/#{tag}/#{version.package_names.first})\n![Preview](https://example.test/preview.webp)\nhttps://github.com/user-attachments/assets/video\n",
     'assets' => bytes.sort.map.with_index do |(name, body), index|
       url = "https://github.com/#{Retention::REPOSITORY}/releases/download/#{tag}/#{name}"
       @files[url] = body
       {'id' => id * 100 + index, 'name' => name, 'state' => 'uploaded', 'size' => body.bytesize,
        'digest' => "sha256:#{Digest::SHA256.hexdigest(body)}", 'updated_at' => '2026-10-05T10:00:00Z', 'browser_download_url' => url}
     end}
  end

  def policy(tag = TAG, directory: @directory)
    Retention::Policy.new(tag: tag, directory: directory, public_key: @public_key, github: @github, network: @network)
  end

  def replace_bytes(name, bytes)
    asset = @new.fetch('assets').find { |item| item.fetch('name') == name }
    @files[asset.fetch('browser_download_url')] = bytes
    asset['size'] = bytes.bytesize
    asset['digest'] = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
  end

  def signed_manifest(bytes)
    replace_bytes('checksums.txt', bytes)
    replace_bytes('checksums.txt.sig', @key.sign(nil, bytes))
  end

  def assert_blocked(message)
    error = assert_raises(RuntimeError) { yield }
    assert_match(message, error.message)
    assert_empty @github.deleted
  end

  def test_plan_verifies_every_download_and_link_without_deleting
    manifest = policy.plan
    assert_equal [402_724_739], manifest.fetch('retire').map { |r| r.fetch('id') }
    assert_equal 12, manifest.fetch('verified').fetch('asset_sha256').size
    assert_equal 12, @network.downloads.size
    assert_includes @network.links, 'https://example.test/preview.webp'
    assert_includes @network.links, 'https://github.com/user-attachments/assets/video'
    assert_equal 'all retained', manifest.fetch('tags')
    assert_empty @github.deleted
  end

  def test_apply_only_deletes_recorded_old_application_release
    manifest = policy.plan
    result = policy.apply(manifest)
    assert_equal [402_724_739], result.fetch('retired_release_ids')
    assert_equal [500], @github.inventory.map { |r| r.fetch('id') }
    assert_equal 12, @network.downloads.size, 'unchanged GitHub-digest cache is reused'
  end

  def test_alpha_preserves_stable_draft_and_model_release
    stable = release('v0.6.0', 20)
    draft = release('v0.9.0-alpha.1', 30).merge('draft' => true)
    model = {'id' => 40, 'tag_name' => 'models-v1', 'draft' => false}
    @github.inventory += [stable, draft, model]
    manifest = policy.plan
    assert_equal [20, 30, 40], manifest.fetch('preserve').map { |r| r.fetch('id') }
    policy.apply(manifest)
    assert_equal [500, 20, 30, 40], @github.inventory.map { |r| r.fetch('id') }
  end

  def test_stable_retires_older_stable_and_alpha
    stable = release('v0.8.0', 600)
    @github.inventory += [stable, release('v0.6.0', 20)]
    manifest = policy('v0.8.0').plan
    assert_equal [20, 402_724_739, 500], manifest.fetch('retire').map { |r| r.fetch('id') }
    policy('v0.8.0').apply(manifest)
    assert_equal [600], @github.inventory.map { |r| r.fetch('id') }
  end

  def test_version_ordering_and_strict_application_tags
    tags = %w[v0.9.0-alpha.1 v0.8.0 v0.8.0-alpha.10 v0.8.0-alpha.2]
    assert_equal tags.reverse, tags.map { |tag| Retention::Version.parse(tag) }.sort.map(&:tag)
    %w[models-v1 v01.2.3 v0.8.0-beta.1 v0.8.0-alpha.0 0.8.0-alpha.1].each do |tag|
      assert_nil Retention::Version.parse(tag)
    end
  end

  def test_missing_new_release_and_draft_new_release_block
    @github.inventory.delete(@new)
    assert_blocked(/missing/) { policy.plan }
    @github.inventory << @new.merge('draft' => true)
    assert_blocked(/draft/) { policy.plan }
  end

  def test_newer_release_already_published_blocks
    @github.inventory << release('v0.9.0-alpha.1', 600)
    assert_blocked(/newer application release/) { policy.plan }
  end

  def test_newer_release_published_after_plan_blocks
    manifest = policy.plan
    @github.inventory << release('v0.9.0-alpha.1', 600)
    assert_blocked(/newer application release/) { policy.apply(manifest) }
  end

  def test_newer_release_between_verification_and_deletion_blocks
    manifest = policy.plan
    @github.before_read = lambda do |github, reads|
      github.inventory << release('v0.9.0-alpha.1', 600) if reads == 3
    end
    assert_blocked(/newer application release/) { policy.apply(manifest) }
  end

  def test_newer_release_during_multiple_retirements_stops_remaining_deletions
    @github.inventory << release('v0.6.0-alpha.1', 40)
    manifest = policy.plan
    @github.after_delete = ->(github) { github.inventory << release('v0.9.0-alpha.1', 600) }
    assert_raises(RuntimeError) { policy.apply(manifest) }
    assert_equal [40], @github.deleted
    assert @github.inventory.any? { |r| r['id'] == 402_724_739 }
  end

  def test_changed_old_asset_metadata_blocks
    manifest = policy.plan
    @old['assets'].first['id'] += 1
    assert_blocked(/inventory changed/) { policy.apply(manifest) }
  end

  def test_changed_new_notes_block
    manifest = policy.plan
    @new['body'] += 'Edited after verification.'
    assert_blocked(/New release changed/) { policy.apply(manifest) }
  end

  def test_unexpected_older_release_asset_requires_review
    @old['assets'].first['name'] = 'private-model.onnx'
    assert_blocked(/Unrecognized assets/) { policy.plan }
  end

  def test_unexpected_new_assets_block
    @new['assets'] << @new['assets'].first.merge('name' => 'model.onnx')
    assert_blocked(/ten platform packages/) { policy.plan }
  end

  def test_every_platform_package_is_required
    @new['assets'].reject! { |a| a['name'].end_with?('aarch64.rpm') }
    assert_blocked(/ten platform packages/) { policy.plan }
  end

  def test_new_release_channel_must_match
    @new['prerelease'] = false
    assert_blocked(/channel/) { policy.plan }
  end

  def test_old_release_channel_must_match
    @old['prerelease'] = false
    assert_blocked(/channel/) { policy.plan }
  end

  def test_download_size_mismatch_blocks
    @new['assets'].first['size'] += 1
    assert_blocked(/Wrong download size/) { policy.plan }
  end

  def test_github_digest_mismatch_blocks
    @new['assets'].first['digest'] = "sha256:#{'0' * 64}"
    assert_blocked(/GitHub digest mismatch/) { policy.plan }
  end

  def test_invalid_signature_blocks_even_when_github_digest_matches
    replace_bytes('checksums.txt.sig', 'x' * 64)
    assert_blocked(/Invalid publisher signature/) { policy.plan }
  end

  def test_invalid_public_key_blocks
    File.write(@public_key, 'not a key')
    assert_blocked(/Invalid committed publisher public key/) { policy.plan }
  end

  def test_signed_checksum_tamper_blocks
    name = Retention::Version.parse(TAG).package_names.first
    replace_bytes(name, 'modified package')
    assert_blocked(/Signed checksum mismatch/) { policy.plan }
  end

  def test_missing_signed_package_blocks
    asset = @new['assets'].find { |a| a['name'] == 'checksums.txt' }
    signed_manifest(@files.fetch(asset.fetch('browser_download_url')).lines.drop(1).join)
    assert_blocked(/cover exactly/) { policy.plan }
  end

  def test_duplicate_signed_package_blocks
    asset = @new['assets'].find { |a| a['name'] == 'checksums.txt' }
    lines = @files.fetch(asset.fetch('browser_download_url')).lines
    lines[0] = lines[1]
    signed_manifest(lines.join)
    assert_blocked(/cover exactly/) { policy.plan }
  end

  def test_signed_path_traversal_blocks
    signed_manifest("#{'0' * 64}  ../secret\n")
    assert_blocked(/Malformed/) { policy.plan }
  end

  def test_broken_screenshot_link_blocks_retirement
    @network.broken_link = 'https://example.test/preview.webp'
    assert_blocked(/Broken release note link/) { policy.plan }
  end

  def test_empty_notes_block
    @new['body'] = ''
    assert_blocked(/notes are empty/) { policy.plan }
  end

  def test_unexpected_download_host_blocks
    @new['assets'].first['browser_download_url'] = 'https://example.test/file'
    assert_blocked(/Unexpected download URL/) { policy.plan }
  end

  def test_existing_unowned_directory_is_untouched
    Dir.mkdir(@directory)
    File.write(File.join(@directory, 'important'), 'keep')
    assert_blocked(/not owned/) { policy.plan }
    assert_equal ['important'], Dir.children(@directory)
  end

  def test_symlink_download_directory_is_rejected
    File.symlink(@scratch, @directory)
    assert_blocked(/symlink/) { policy.plan }
  end

  def test_symlink_cached_asset_is_rejected
    policy.plan
    name = @new['assets'].first['name']
    File.unlink(File.join(@directory, name))
    File.symlink(@public_key, File.join(@directory, name))
    assert_blocked(/not a regular file/) { policy.plan }
    assert_equal 64, File.size(@public_key)
  end

  def test_retired_download_link_in_new_notes_blocks
    @new['body'] += "[Earlier download](#{@old.fetch('assets').first.fetch('browser_download_url')}?download=1)\n"
    assert_blocked(/being retired/) { policy.plan }
  end

  def test_deletion_must_be_confirmed_by_fresh_inventory
    manifest = policy.plan
    @github.after_delete = ->(github) { github.inventory << @old }
    assert_raises(RuntimeError) { policy.apply(manifest) }
    assert_equal [402_724_739], @github.deleted
  end

  def test_non_https_notes_link_blocks
    @new['body'] += "http://example.test/insecure\n"
    assert_blocked(/HTTPS/) { policy.plan }
  end

  def test_real_github_adapter_only_addresses_public_release_objects
    bin = File.join(@scratch, 'bin')
    Dir.mkdir(bin)
    calls = File.join(@scratch, 'api-calls.jsonl')
    File.write(File.join(bin, 'gh'), "#!#{RbConfig.ruby}\n" + <<~'SCRIPT')
      require 'json'
      File.open(ENV.fetch('SOLCO_RETENTION_TEST_CALLS'), 'a') { |file| file.puts(JSON.generate(ARGV)) }
      puts '[]' unless ARGV.include?('DELETE')
    SCRIPT
    File.chmod(0o755, File.join(bin, 'gh'))
    previous = ENV.to_h.slice('PATH', 'SOLCO_RETENTION_TEST_CALLS')
    begin
      ENV['PATH'] = bin + File::PATH_SEPARATOR + ENV.fetch('PATH')
      ENV['SOLCO_RETENTION_TEST_CALLS'] = calls
      client = Retention::GitHub.new
      assert_empty client.releases
      client.delete_release(402_724_739)
      [nil, 0, -1, '402724739', '1; unexpected'].each do |id|
        assert_raises(RuntimeError) { client.delete_release(id) }
      end
      commands = File.readlines(calls).map { |line| JSON.parse(line) }
      assert_equal [
        ['api', 'repos/crmne/solco-releases/releases?per_page=100', '--paginate', '--slurp'],
        ['api', '--method', 'DELETE', 'repos/crmne/solco-releases/releases/402724739']
      ], commands
    ensure
      %w[PATH SOLCO_RETENTION_TEST_CALLS].each { |key| ENV[key] = previous[key] }
    end
  end

  def test_manifest_cannot_switch_to_private_repository
    manifest = policy.plan
    manifest['repository'] = 'crmne/solco'
    assert_blocked(/Unexpected retirement manifest/) { policy.apply(manifest) }
  end

  def test_manifest_cannot_add_arbitrary_deletion
    manifest = policy.plan
    manifest['retire'] << {'id' => 999}
    assert_blocked(/inventory changed/) { policy.apply(manifest) }
  end
end
