#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'release_retention'

module Solco
  module ReleaseArtifactRetention
    REPOSITORY = ReleaseRetention::REPOSITORY
    SCHEMA = 1
    # Exact historical/current release package names, never a prefix match.
    TARGETS = %w[x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu x86_64-pc-windows-msvc macos-arm64].freeze
    PACKAGE_NAMES = (TARGETS + TARGETS.map { |target| "application-#{target}" } +
      %w[linux-amd64 linux-arm64 windows-amd64 macos-arm64].map { |target| "native-packages-#{target}" }).freeze
    # Only these reviewed pre-version-title runs belong to the initial migration.
    # An unknown future "Build release" run must never be guessed to be old.
    LEGACY_RUN_IDS = [34_858_839_221, 34_853_062_638, 34_851_498_920, 34_850_490_262,
                     32_178_986_210, 32_056_538_012, 32_054_802_720, 32_052_747_788].freeze

    class GitHub < ReleaseRetention::GitHub
      def artifacts
        json("repos/#{REPOSITORY}/actions/artifacts?per_page=100", paginate: true)
          .flat_map { |page| page.fetch('artifacts') }
      end

      def run(id) = json("repos/#{REPOSITORY}/actions/runs/#{positive_id(id)}")
      def artifact(id) = json("repos/#{REPOSITORY}/actions/artifacts/#{positive_id(id)}")

      # This is the only mutation. Never delete runs, logs, caches or Git refs.
      def delete_artifact(id)
        _, error, status = Open3.capture3('gh', 'api', '--method', 'DELETE',
          "repos/#{REPOSITORY}/actions/artifacts/#{positive_id(id)}")
        raise "Package artifact retirement failed: #{error.strip}" unless status.success?
      end

      private

      def positive_id(id)
        raise 'Invalid GitHub ID' unless id.is_a?(Integer) && id.positive?
        id
      end
    end

    def self.artifact_snapshot(artifact)
      artifact.slice('id', 'name', 'size_in_bytes', 'digest', 'created_at', 'updated_at', 'expires_at',
        'expired', 'url', 'archive_download_url', 'workflow_run')
    end

    def self.run_snapshot(run)
      # updated_at can move while the publishing job saves its audit artifact.
      # Attempt, status and conclusion detect historical runs being restarted.
      run.slice('id', 'workflow_id', 'path', 'display_title', 'event', 'status', 'conclusion',
        'run_attempt', 'head_sha', 'head_branch', 'created_at', 'run_started_at').merge(
          'repository' => run.fetch('repository').slice('id', 'full_name', 'private'),
          'head_repository' => run.fetch('head_repository').slice('id', 'full_name', 'private'))
    end

    def self.release_run?(run)
      run['path'] == '.github/workflows/release.yml' &&
        %w[workflow_dispatch repository_dispatch].include?(run['event']) &&
        %w[repository head_repository].all? do |key|
          run.dig(key, 'full_name') == REPOSITORY && run.dig(key, 'private') == false
        end
    end

    class Inventory
      def initialize(github) = @github = github

      def read(cutoff: nil, publishing_run: nil, tag: nil)
        runs = {}
        target = ReleaseRetention::Version.parse(tag) if tag
        retire, preserve = [], []
        artifacts = @github.artifacts
        raise 'Duplicate artifact IDs in GitHub inventory' unless artifacts.map { |a| a.fetch('id') }.uniq.size == artifacts.size
        artifacts.sort_by { |artifact| artifact.fetch('id') }.each do |artifact|
          entry = {'artifact' => ReleaseArtifactRetention.artifact_snapshot(artifact)}
          reason = if !PACKAGE_NAMES.include?(artifact.fetch('name'))
            'unrecognized artifact name'
          elsif artifact.fetch('expired')
            'already expired'
          else
            id = artifact.fetch('workflow_run').fetch('id')
            run = runs[id] ||= @github.run(id)
            entry['run'] = ReleaseArtifactRetention.run_snapshot(run)
            title = run.fetch('display_title')
            version = ReleaseRetention::Version.parse("v#{title.delete_prefix('Release ')}") if title.start_with?('Release ')
            if !ReleaseArtifactRetention.release_run?(run) || !belongs_to_run?(artifact, run)
              'not a package from this public release workflow'
            elsif version && target && version > target
              'build is for a newer application version'
            elsif !version && !(LEGACY_RUN_IDS.include?(id) && ['release', 'Build release'].include?(title))
              'unversioned run is outside the reviewed historical migration'
            elsif run.fetch('id') == publishing_run
              unless run.fetch('status') == 'in_progress' && run.fetch('display_title') == "Release #{tag.delete_prefix('v')}"
                raise 'Publishing run is not the active workflow for this version'
              end
              nil
            elsif cutoff && (Time.iso8601(run.fetch('created_at')) > cutoff || Time.iso8601(artifact.fetch('created_at')) > cutoff)
              'created after the verified release was published'
            elsif run.fetch('status') != 'completed'
              'another release run is still active'
            end
          end
          reason ? preserve << entry.merge('reason' => reason) : retire << entry
        end
        {'retire' => retire, 'preserve' => preserve}
      end

      private

      def belongs_to_run?(artifact, run)
        reference = artifact.fetch('workflow_run')
        reference.fetch('id') == run.fetch('id') &&
          reference.fetch('repository_id') == run.fetch('repository').fetch('id') &&
          reference.fetch('head_repository_id') == run.fetch('head_repository').fetch('id') &&
          reference.fetch('head_sha') == run.fetch('head_sha')
      end
    end

    class Policy
      def initialize(tag:, directory:, public_key:, publishing_run: nil, github: GitHub.new, verifier: nil)
        @tag, @publishing_run, @github = tag, publishing_run, github
        @version = ReleaseRetention::Version.parse(tag) or raise 'Invalid application release tag'
        @verifier = verifier || -> {
          ReleaseRetention::Policy.new(tag: tag, directory: directory, public_key: public_key, github: github).plan
        }
      end

      def plan
        # This is the same complete signed-download and note-link verification
        # as release retirement, not trust in an earlier success flag.
        verified = @verifier.call
        release = current_release!
        raise 'Release changed during verification' unless ReleaseRetention.snapshot(release) == verified.fetch('target')
        {'schema' => SCHEMA, 'repository' => REPOSITORY, 'target' => verified.fetch('target'),
         'verified' => verified.fetch('verified'), 'verified_at' => Time.now.utc.iso8601,
         'published_at' => release.fetch('published_at'), 'publishing_run' => @publishing_run,
         'scope' => 'release package artifacts only; runs, logs, caches and tags retained'}
          .merge(inventory(release))
      end

      def apply(manifest)
        raise 'Unexpected package retirement manifest' unless manifest.fetch('schema') == SCHEMA &&
          manifest.fetch('repository') == REPOSITORY && manifest.fetch('target').fetch('tag_name') == @tag &&
          manifest.fetch('publishing_run') == @publishing_run
        fresh = plan
        %w[target verified published_at retire].each do |key|
          raise "Package retirement #{key} changed; generate and review a new plan" unless fresh.fetch(key) == manifest.fetch(key)
        end
        removed = []
        manifest.fetch('retire').each do |entry|
          assert_release_unchanged!(manifest)
          artifact, run = entry.fetch('artifact'), entry.fetch('run')
          live_run = @github.run(run.fetch('id'))
          raise 'A release run changed or restarted during retirement' unless
            ReleaseArtifactRetention.run_snapshot(live_run) == run
          raise 'A package artifact changed during retirement' unless
            ReleaseArtifactRetention.artifact_snapshot(@github.artifact(artifact.fetch('id'))) == artifact
          @github.delete_artifact(artifact.fetch('id'))
          removed << artifact.fetch('id')
        end
        release = assert_release_unchanged!(manifest)
        raise 'Package inventory changed during retirement; review a fresh plan' unless inventory(release).fetch('retire').empty?
        {'repository' => REPOSITORY, 'kept' => @tag, 'retired_artifact_ids' => removed,
         'scope' => manifest.fetch('scope')}
      end

      private

      def inventory(release)
        Inventory.new(@github).read(cutoff: Time.iso8601(release.fetch('published_at')),
          publishing_run: @publishing_run, tag: @tag)
      end

      def current_release!
        releases = @github.releases
        ReleaseRetention.check_publication_version!(releases, @tag)
        release = releases.find { |entry| entry.fetch('tag_name') == @tag } or raise 'Verified release is missing'
        raise 'Verified release is a draft or has the wrong channel' if release.fetch('draft') ||
          release.fetch('prerelease') != !@version.alpha.nil?
        Time.iso8601(release.fetch('published_at'))
        release
      end

      def assert_release_unchanged!(manifest)
        release = current_release!
        raise 'Verified release changed during package retirement' unless
          ReleaseRetention.snapshot(release) == manifest.fetch('target') &&
          release.fetch('published_at') == manifest.fetch('published_at')
        release
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    command = ARGV.shift
    options = {}
    OptionParser.new do |parser|
      parser.banner = 'release_artifact_retention.rb inventory; plan|apply --tag TAG --directory CACHE --public-key KEY --manifest PLAN [--publishing-run ID]'
      parser.on('--tag TAG') { |v| options[:tag] = v }
      parser.on('--directory PATH') { |v| options[:directory] = v }
      parser.on('--public-key PATH') { |v| options[:public_key] = v }
      parser.on('--manifest PATH') { |v| options[:manifest] = v }
      parser.on('--publishing-run ID', Integer) { |v| options[:publishing_run] = v }
    end.parse!
    if command == 'inventory'
      raise 'Inventory does not accept options' unless ARGV.empty? && options.empty?
      puts JSON.pretty_generate(Solco::ReleaseArtifactRetention::Inventory.new(Solco::ReleaseArtifactRetention::GitHub.new).read)
      exit 0
    end
    raise 'Expected plan or apply and all four verification options' unless %w[plan apply].include?(command) &&
      ARGV.empty? && %i[tag directory public_key manifest].all? { |key| options[key] }
    if options[:publishing_run]
      raise 'Only the active public publishing workflow can include its unfinished run' unless
        ENV['GITHUB_REPOSITORY'] == Solco::ReleaseArtifactRetention::REPOSITORY &&
        ENV['GITHUB_RUN_ID'] == options[:publishing_run].to_s && options[:publishing_run].positive?
    end
    manifest_path = options.delete(:manifest)
    policy = Solco::ReleaseArtifactRetention::Policy.new(**options)
    if command == 'plan'
      result = policy.plan
      File.write(manifest_path, JSON.pretty_generate(result) + "\n", mode: File::WRONLY | File::CREAT | File::EXCL)
    else
      result = policy.apply(JSON.parse(File.read(manifest_path)))
    end
    puts JSON.pretty_generate(result)
  rescue StandardError => error
    warn "Package artifact retention: #{error.message}"
    exit 1
  end
end
