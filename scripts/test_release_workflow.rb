# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'rbconfig'
require_relative 'collect_stable_packages'

class ReleaseWorkflowTest < Minitest::Test
  WORKFLOW = YAML.load_file(File.expand_path('../.github/workflows/release.yml', __dir__))
  JOB = WORKFLOW.fetch('jobs').fetch('release')
  STEPS = JOB.fetch('steps')

  def step(name) = STEPS.find { |entry| entry['name'] == name }
  def index(name) = STEPS.index(step(name))

  def test_publication_and_retirement_share_a_cross_version_lock_and_signing_gate
    assert_equal 'solco-published-releases', JOB.fetch('concurrency').fetch('group')
    assert_equal false, JOB.fetch('concurrency').fetch('cancel-in-progress')
    assert_equal 'release-signing', JOB.fetch('environment')
    assert_equal 'write', WORKFLOW.fetch('permissions').fetch('contents')
    assert_equal({'contents' => 'write', 'actions' => 'write'}, JOB.fetch('permissions'))
    refute WORKFLOW.fetch('permissions').key?('actions'), 'artifact deletion permission belongs only to the approved publishing job'
  end

  def test_early_version_guard_precedes_private_source_and_all_build_jobs
    prepare = WORKFLOW.fetch('jobs').fetch('prepare').fetch('steps')
    guard = prepare.find { |entry| entry['name'] == 'Reject superseded versions before building packages' }
    private_source = prepare.find { |entry| entry.dig('with', 'repository') == 'crmne/solco' }
    assert_operator prepare.index(guard), :<, prepare.index(private_source)
    assert_equal 'ruby .release-policy/scripts/release_retention.rb check-publication --tag "$RELEASE_TAG"', guard.fetch('run')
    %w[build macos].each { |name| assert_equal 'prepare', WORKFLOW.fetch('jobs').fetch(name).fetch('needs') }
    policy = prepare.find { |entry| entry['name'] == 'Check out public policy before building' }.fetch('with')
    assert_equal '${{ github.sha }}', policy.fetch('ref')
    assert_equal false, policy.fetch('persist-credentials')
    assert_includes step('Publish public binary release').fetch('run'), 'check-publication --tag "$RELEASE_TAG"'
  end

  def test_packages_expire_in_one_day_but_verification_manifests_are_preserved
    uploads = %w[build macos].flat_map do |name|
      WORKFLOW.fetch('jobs').fetch(name).fetch('steps').select { |entry| entry['uses'] == 'actions/upload-artifact@v7' }
    end
    assert_equal 4, uploads.size
    uploads.each { |entry| assert_equal 1, entry.fetch('with').fetch('retention-days') }
    audit = step('Save the exact package artifact retirement inventory').fetch('with')
    assert_equal 90, audit.fetch('retention-days')
    assert_equal 'package-artifact-retirement-${{ env.RELEASE_TAG }}', audit.fetch('name')
    assert_equal 'release-retirement-${{ env.RELEASE_TAG }}', step('Save the exact verified retirement inventory').fetch('with').fetch('name')
  end

  def test_macos_reclaims_only_compiler_output_before_packaging_with_pinned_public_policy
    steps = WORKFLOW.fetch('jobs').fetch('macos').fetch('steps')
    names = steps.map { |entry| entry['name'] }
    cleanup = steps.fetch(names.index('Preserve final macOS runtime and reclaim compiler space'))
    %w[alpha stable].each do |kind|
      assert_operator names.index("Build #{kind == 'alpha' ? 'private alpha' : kind} arm64"), :<, names.index(cleanup['name'])
    end
    assert_operator names.index(cleanup['name']), :<, names.index('App bundle')
    assert_includes cleanup.fetch('run'), 'ruby .release-policy/scripts/preserve_macos_runtime.rb "$GITHUB_WORKSPACE"'
    assert_equal 2, cleanup.fetch('run').scan('df -h . "$RUNNER_TEMP"').size
    assert_equal 2, cleanup.fetch('run').scan('du -sh target').size
    policy = steps.fetch(names.index('Check out macOS runner maintenance policy')).fetch('with')
    assert_equal 'crmne/solco-releases', policy.fetch('repository')
    assert_equal '${{ github.sha }}', policy.fetch('ref')
    assert_equal '.release-policy', policy.fetch('path')
    assert_equal false, policy.fetch('persist-credentials')
    refute cleanup.key?('if'), 'both stable and alpha builds need room for DMG packaging'
  end

  def test_artifact_deletion_follows_verified_publication_and_saved_exact_inventory
    names = ['Retire only the verified older application releases',
             'Verify published downloads and plan package artifact retirement',
             'Save the exact package artifact retirement inventory',
             'Retire only the verified release package artifacts']
    assert_equal names.map { |name| index(name) }.sort, names.map { |name| index(name) }
    names.drop(1).each { |name| refute step(name).key?('if'), 'a failed verification must stop deletion' }
    plan, apply = step(names[1]).fetch('run'), step(names[3]).fetch('run')
    assert_includes plan, 'release_artifact_retention.rb plan'
    assert_includes apply, 'release_artifact_retention.rb apply'
    %w[--tag --directory --public-key --manifest --publishing-run].each do |option|
      assert_equal plan[/#{option} (.*)/, 1], apply[/#{option} (.*)/, 1]
    end
    assert_includes apply, '--publishing-run "$GITHUB_RUN_ID"'
  end

  def test_all_linux_packages_are_staged_before_checksums_and_signing
    assert_operator index('Verify the complete native alpha package set'), :<, index('Checksums')
    assert_operator index('Build stable Linux packages before signing the full download set'), :<, index('Checksums')
    assert_operator index('Checksums'), :<, index('Sign checksums')
    assert_operator index('Sign checksums'), :<, index('Publish public binary release')
    stable = step('Build stable Linux packages before signing the full download set').fetch('run')
    assert_includes stable, 'build --version "$VERSION"'
    refute_includes stable, '--release'
    refute STEPS.any? { |entry| entry.fetch('run', '').include?('native-packages publish') }
  end

  def test_verification_and_saved_inventory_precede_retirement
    names = ['Publish public binary release', 'Verify published downloads and plan older release retirement',
             'Save the exact verified retirement inventory', 'Retire only the verified older application releases']
    assert_equal names.map { |name| index(name) }.sort, names.map { |name| index(name) }
    names.drop(1).each { |name| refute step(name).key?('if'), 'failure must prevent subsequent retirement steps' }
    plan = step(names[1]).fetch('run')
    apply = step(names[3]).fetch('run')
    assert_includes plan, 'release_retention.rb plan'
    assert_includes apply, 'release_retention.rb apply'
    %w[--tag --directory --public-key --manifest].each do |option|
      assert_equal plan[/#{option} (.*)/, 1], apply[/#{option} (.*)/, 1]
    end
  end

  def test_policy_source_is_the_public_workflow_revision_without_saved_credentials
    policy = step('Check out public release policy').fetch('with')
    assert_equal 'crmne/solco-releases', policy.fetch('repository')
    assert_equal '${{ github.sha }}', policy.fetch('ref')
    assert_equal '.release-policy', policy.fetch('path')
    assert_equal false, policy.fetch('persist-credentials')
  end

  def test_rebuilding_a_retired_tag_cannot_recreate_or_upload_downloads
    Dir.mktmpdir('solco-retired-publication-') do |root|
      FileUtils.mkdir_p(File.join(root, '.release-policy/scripts'))
      FileUtils.cp(File.join(__dir__, 'release_retention.rb'), File.join(root, '.release-policy/scripts'))
      bin = File.join(root, 'bin')
      Dir.mkdir(bin)
      calls = File.join(root, 'gh-calls.jsonl')
      File.write(File.join(bin, 'gh'), "#!#{RbConfig.ruby}\n" + <<~'RUBY')
        require 'json'
        File.open(ENV.fetch('QA_GH_CALLS'), 'a') { |file| file.puts(JSON.generate(ARGV)) }
        abort 'Unexpected publication mutation' unless ARGV ==
          ['api', 'repos/crmne/solco-releases/releases?per_page=100', '--paginate', '--slurp']
        puts JSON.generate([[{'tag_name' => 'v0.8.0-alpha.1', 'draft' => false}]])
      RUBY
      File.chmod(0o755, File.join(bin, 'gh'))
      command = step('Publish public binary release').fetch('run')
                    .gsub('${{ needs.prepare.outputs.private_alpha }}', 'true')
                    .gsub('${{ env.VERSION }}', '0.7.0-alpha.1')
      environment = {'RELEASE_TAG' => 'v0.7.0-alpha.1', 'VERSION' => '0.7.0-alpha.1',
                     'GITHUB_REPOSITORY' => 'crmne/solco-releases', 'QA_GH_CALLS' => calls,
                     'PATH' => "#{bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}"}
      _, error, status = Open3.capture3(environment, 'bash', '-euo', 'pipefail', '-c', command, chdir: root)
      refute status.success?
      assert_includes error, 'A newer application release exists: v0.8.0-alpha.1'
      assert_equal [['api', 'repos/crmne/solco-releases/releases?per_page=100', '--paginate', '--slurp']],
                   File.readlines(calls).map { |line| JSON.parse(line) }
    end
  end

  def test_stable_notes_are_copied_exactly_from_committed_file
    Dir.mktmpdir('solco-stable-notes-') do |root|
      FileUtils.mkdir_p(File.join(root, 'packaging/release-notes'))
      notes = "Reviewed release notes. `$(touch unwanted)` remains text.\n"
      File.write(File.join(root, 'packaging/release-notes/v0.8.0.md'), notes)
      command = step('Release notes').fetch('run').gsub('${{ needs.prepare.outputs.private_alpha }}', 'false')
      _, error, status = Open3.capture3({'RELEASE_TAG' => 'v0.8.0'}, 'bash', '-c', command, chdir: root)
      assert status.success?, error
      assert_equal notes, File.read(File.join(root, 'release-notes.md'))
      refute File.exist?(File.join(root, 'unwanted'))
      File.unlink(File.join(root, 'packaging/release-notes/v0.8.0.md'))
      _, _, status = Open3.capture3({'RELEASE_TAG' => 'v0.8.0'}, 'bash', '-c', command, chdir: root)
      refute status.success?, 'missing reviewed notes must block publication'
    end
  end

  def test_prepare_rejects_missing_stable_notes_before_builds
    prepare = WORKFLOW.fetch('jobs').fetch('prepare').fetch('steps').find { |entry| entry['id'] == 'inputs' }.fetch('run')
    assert_operator prepare.index('Missing committed stable release notes'), :<, prepare.index("File.open(ENV.fetch('GITHUB_OUTPUT')")
  end

  class VerifiedBuild
    def initialize(manifest) = @manifest = manifest
    def verify(_input, ids:)
      raise 'Expected complete Linux packages' unless ids == %w[linux-amd64 linux-arm64]
      @manifest
    end
  end

  def with_native_packages
    Dir.mktmpdir('solco-stable-packages-') do |root|
      input, destination = File.join(root, 'build'), File.join(root, 'dist')
      FileUtils.mkdir_p([input, destination])
      entries = %w[solco_0.8.0_amd64.deb solco_0.8.0_arm64.deb solco-0.8.0-1.x86_64.rpm solco-0.8.0-1.aarch64.rpm].map do |name|
        File.write(File.join(input, name), "package #{name}")
        {'path' => name, 'sha256' => Digest::SHA256.file(File.join(input, name)).hexdigest}
      end
      manifest = {'version' => '0.8.0', 'packages' => entries}
      yield input, destination, manifest, VerifiedBuild.new(manifest)
    end
  end

  def test_stable_packages_collect_only_verified_manifest_files
    with_native_packages do |input, destination, manifest, builder|
      File.write(File.join(input, 'build.json'), 'private packaging metadata must not ship')
      assert_equal 4, Solco::StablePackages.collect(input, destination, '0.8.0', builder: builder)
      assert_equal manifest.fetch('packages').map { |p| p.fetch('path') }.sort, Dir.children(destination).sort
      manifest.fetch('packages').each do |entry|
        assert_equal entry.fetch('sha256'), Digest::SHA256.file(File.join(destination, entry.fetch('path'))).hexdigest
      end
    end
  end

  def test_existing_destination_is_never_overwritten
    with_native_packages do |input, destination, manifest, builder|
      path = File.join(destination, manifest.fetch('packages').first.fetch('path'))
      File.write(path, 'keep the existing archive')
      assert_raises(Errno::EEXIST) { Solco::StablePackages.collect(input, destination, '0.8.0', builder: builder) }
      assert_equal 'keep the existing archive', File.read(path)
    end
  end

  def test_wrong_native_version_and_changed_bytes_fail
    with_native_packages do |input, destination, manifest, builder|
      assert_raises(RuntimeError) { Solco::StablePackages.collect(input, destination, '0.9.0', builder: builder) }
      assert_empty Dir.children(destination)
      File.write(File.join(input, manifest.fetch('packages').first.fetch('path')), 'changed after verification')
      error = assert_raises(RuntimeError) { Solco::StablePackages.collect(input, destination, '0.8.0', builder: builder) }
      assert_match(/checksum differs/, error.message)
    end
  end
end
