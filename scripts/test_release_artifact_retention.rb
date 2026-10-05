# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require_relative 'release_artifact_retention'

class ReleaseArtifactRetentionTest < Minitest::Test
  Retention = Solco::ReleaseArtifactRetention
  TAG = 'v0.8.0-alpha.1'

  class FakeGitHub
    attr_accessor :items, :runs, :release_items, :before_artifact, :after_delete, :before_run
    attr_reader :deleted
    def initialize(items, runs, releases)
      @items, @runs, @release_items, @deleted = items, runs, releases, []
    end
    def copy(value) = Marshal.load(Marshal.dump(value))
    def artifacts = copy(items)
    def releases = copy(release_items)
    def run(id)
      before_run&.call(self, id)
      copy(runs.fetch(id))
    end
    def artifact(id)
      before_artifact&.call(self, id)
      copy(items.find { |item| item.fetch('id') == id } || raise('Missing artifact'))
    end
    def delete_artifact(id)
      raise 'Unexpected artifact ID' unless items.any? { |item| item.fetch('id') == id }
      @deleted << id
      items.reject! { |item| item.fetch('id') == id }
      after_delete&.call(self)
    end
  end

  def setup
    @release = {'id' => 100, 'tag_name' => TAG, 'draft' => false, 'prerelease' => true,
      'published_at' => '2026-10-05T12:00:00Z', 'assets' => [], 'body' => 'Reviewed notes'}
    @github = FakeGitHub.new([artifact(1), artifact(2, name: 'x86_64-pc-windows-msvc')], {10 => release_run(10)}, [@release])
    @verified = {'target' => Solco::ReleaseRetention.snapshot(@release), 'verified' => {'signed_sha256' => 'fixture'}}
    @verification_calls = 0
    @verifier = -> { @verification_calls += 1; Marshal.load(Marshal.dump(@verified)) }
  end

  def release_run(id, status: 'completed', created: '2026-10-03T12:00:00Z')
    {'id' => id, 'path' => '.github/workflows/release.yml', 'workflow_id' => 123,
     'display_title' => 'Release 0.8.0-alpha.1', 'event' => 'workflow_dispatch',
     'status' => status, 'conclusion' => status == 'completed' ? 'success' : nil,
     'run_attempt' => 1, 'head_sha' => 'a' * 40, 'head_branch' => 'main',
     'created_at' => created, 'run_started_at' => created,
     'repository' => {'id' => 1, 'full_name' => Retention::REPOSITORY, 'private' => false},
     'head_repository' => {'id' => 1, 'full_name' => Retention::REPOSITORY, 'private' => false}}
  end

  def artifact(id, name: 'application-macos-arm64', run_id: 10, created: '2026-10-03T13:00:00Z')
    {'id' => id, 'name' => name, 'size_in_bytes' => 1234, 'digest' => "sha256:#{'b' * 64}",
     'created_at' => created, 'updated_at' => created, 'expires_at' => '2027-01-01T00:00:00Z', 'expired' => false,
     'url' => "https://api.github.com/repos/#{Retention::REPOSITORY}/actions/artifacts/#{id}",
     'workflow_run' => {'id' => run_id, 'repository_id' => 1, 'head_repository_id' => 1, 'head_sha' => 'a' * 40}}
  end

  def policy(publishing_run: nil, verifier: @verifier)
    Retention::Policy.new(tag: TAG, directory: 'unused', public_key: 'unused', publishing_run: publishing_run,
      github: @github, verifier: verifier)
  end

  def test_read_only_inventory_lists_exact_package_ids_and_never_deletes
    result = Retention::Inventory.new(@github).read
    assert_equal [1, 2], result.fetch('retire').map { |entry| entry.fetch('artifact').fetch('id') }
    assert_equal 'completed', result.fetch('retire').first.fetch('run').fetch('status')
    assert_empty @github.deleted
  end

  def test_all_twelve_historical_and_current_exact_names_are_recognized
    assert_equal 12, Retention::PACKAGE_NAMES.size
    @github.items = Retention::PACKAGE_NAMES.map.with_index { |name, i| artifact(i + 1, name: name) }
    assert_equal 12, policy.plan.fetch('retire').size
  end

  def test_preserves_audit_manifests_similar_names_and_unrelated_artifacts
    names = %w[release-retirement-v0.8.0-alpha.1 package-artifact-retirement-v0.8.0-alpha.1 application-secret
               native-packages-unknown x86_64-build-logs model-sources]
    @github.items += names.map.with_index { |name, i| artifact(i + 3, name: name) }
    plan = policy.plan
    assert_equal names, plan.fetch('preserve').map { |entry| entry.fetch('artifact').fetch('name') }
    policy.apply(plan)
    assert_equal [1, 2], @github.deleted
    assert_equal names, @github.items.map { |entry| entry.fetch('name') }
  end

  def test_same_name_in_another_workflow_or_repository_is_preserved
    %w[path repository head_repository event].each do |field|
      original = Marshal.load(Marshal.dump(@github.runs[10]))
      if field.end_with?('repository')
        @github.runs[10][field]['full_name'] = 'crmne/solco'
        @github.runs[10][field]['private'] = true
      else
        @github.runs[10][field] = 'unrelated'
      end
      assert_empty policy.plan.fetch('retire'), field
      @github.runs[10] = original
    end
    @github.items.first['workflow_run']['head_sha'] = 'c' * 40
    assert_equal [2], policy.plan.fetch('retire').map { |entry| entry.fetch('artifact').fetch('id') }
  end

  def test_failed_and_cancelled_completed_package_runs_are_eligible
    %w[failure cancelled success].each do |conclusion|
      @github.runs[10]['conclusion'] = conclusion
      assert_equal 2, policy.plan.fetch('retire').size
    end
  end

  def test_completed_future_version_is_preserved_even_when_it_predates_publication
    @github.runs[10]['display_title'] = 'Release 0.9.0-alpha.1'
    assert_empty policy.plan.fetch('retire')
    @github.runs[10]['display_title'] = 'Release 0.8.0'
    assert_empty policy.plan.fetch('retire'), 'a stable release is newer than the same version alpha'
    @github.runs[10]['display_title'] = 'Release 0.8.0-alpha.1'
    assert_equal 2, policy.plan.fetch('retire').size, 'verified current-version duplicate builds can retire'
  end

  def test_only_reviewed_historical_unversioned_runs_are_eligible
    @github.runs[10]['display_title'] = 'Build release'
    assert_empty policy.plan.fetch('retire')
    reviewed = Retention::LEGACY_RUN_IDS.first
    @github.runs = {reviewed => @github.runs.fetch(10).merge('id' => reviewed)}
    @github.items.each { |entry| entry.fetch('workflow_run')['id'] = reviewed }
    assert_equal 2, policy.plan.fetch('retire').size
    @github.runs[reviewed]['display_title'] = 'Release invalid-version'
    assert_empty policy.plan.fetch('retire')
  end

  def test_other_active_runs_and_newer_artifacts_are_preserved
    @github.runs[10]['status'] = 'in_progress'
    assert_empty policy.plan.fetch('retire')
    @github.runs[10]['status'] = 'completed'
    @github.items.first['created_at'] = '2026-10-05T12:00:01Z'
    assert_equal [2], policy.plan.fetch('retire').map { |entry| entry.fetch('artifact').fetch('id') }
    @github.runs[10]['created_at'] = '2026-10-05T12:00:01Z'
    assert_empty policy.plan.fetch('retire')
  end

  def test_own_publishing_run_cleans_packages_even_when_rerunning_current_version
    @github.runs[10] = release_run(10, status: 'in_progress', created: '2026-10-06T12:00:00Z')
    @github.items.each { |entry| entry['created_at'] = '2026-10-06T12:01:00Z' }
    plan = policy(publishing_run: 10).plan
    assert_equal 2, plan.fetch('retire').size
    policy(publishing_run: 10).apply(plan)
    assert_equal [1, 2], @github.deleted
  end

  def test_own_run_must_match_the_active_publishing_version
    @github.runs[10]['status'] = 'in_progress'
    @github.runs[10]['display_title'] = 'Release 0.7.0-alpha.1'
    assert_raises(RuntimeError) { policy(publishing_run: 10).plan }
  end

  def test_signed_download_verification_is_required_again_at_apply
    plan = policy.plan
    failing = policy(verifier: -> { raise 'Invalid publisher signature' })
    assert_match(/signature/, assert_raises(RuntimeError) { failing.apply(plan) }.message)
    assert_empty @github.deleted
    policy.apply(plan)
    assert_equal 2, @verification_calls
  end

  def test_changed_inventory_or_tampered_saved_ids_blocks_before_deletion
    plan = policy.plan
    plan.fetch('retire').first.fetch('artifact')['id'] = 999
    assert_raises(RuntimeError) { policy.apply(plan) }
    assert_empty @github.deleted
  end

  def test_newer_release_or_changed_verified_download_blocks
    plan = policy.plan
    @github.release_items << @release.merge('id' => 200, 'tag_name' => 'v0.9.0-alpha.1')
    assert_match(/newer application/, assert_raises(RuntimeError) { policy.apply(plan) }.message)
    assert_empty @github.deleted
    @github.release_items.pop
    @release['body'] += ' changed'
    assert_raises(RuntimeError) { policy.apply(plan) }
    assert_empty @github.deleted
  end

  def test_expired_artifacts_and_duplicate_api_ids_do_not_enter_retirement
    @github.items.first['expired'] = true
    assert_equal [2], policy.plan.fetch('retire').map { |entry| entry.fetch('artifact').fetch('id') }
    @github.items << @github.items.last.dup
    assert_raises(RuntimeError) { policy.plan }
  end

  def test_metadata_changed_at_deletion_boundary_stops_without_deleting
    plan = policy.plan
    @github.before_artifact = ->(github, id) { github.items.find { |item| item['id'] == id }['digest'] = 'changed' }
    assert_raises(RuntimeError) { policy.apply(plan) }
    assert_empty @github.deleted
  end

  def test_restarted_run_stops_remaining_deletions
    plan = policy.plan
    @github.after_delete = lambda do |github|
      github.runs[10]['run_attempt'] += 1
      github.runs[10]['status'] = 'in_progress'
    end
    assert_match(/restarted/, assert_raises(RuntimeError) { policy.apply(plan) }.message)
    assert_equal [1], @github.deleted
    assert_equal [2], @github.items.map { |entry| entry['id'] }
  end

  def test_newer_release_during_retirement_stops_remaining_deletions
    plan = policy.plan
    @github.after_delete = ->(github) { github.release_items << @release.merge('id' => 200, 'tag_name' => 'v0.9.0-alpha.1') }
    assert_match(/newer application/, assert_raises(RuntimeError) { policy.apply(plan) }.message)
    assert_equal [1], @github.deleted
  end

  def test_new_artifact_is_never_silently_added_to_saved_plan
    plan = policy.plan
    @github.after_delete = lambda do |github|
      github.after_delete = nil
      github.items << artifact(3)
    end
    assert_match(/inventory changed/, assert_raises(RuntimeError) { policy.apply(plan) }.message)
    assert_equal [1, 2], @github.deleted
    assert_equal [3], @github.items.map { |entry| entry['id'] }
  end

  def test_cli_cannot_claim_another_unfinished_run
    script = File.expand_path('release_artifact_retention.rb', __dir__)
    _, error, status = Open3.capture3({'GITHUB_RUN_ID' => nil, 'GITHUB_REPOSITORY' => nil}, RbConfig.ruby,
      script, 'apply', '--tag', TAG, '--directory', 'unused', '--public-key', 'unused',
      '--manifest', 'unused', '--publishing-run', '10')
    refute status.success?
    assert_includes error, 'Only the active public publishing workflow'
  end
end
