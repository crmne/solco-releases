# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
require 'tmpdir'
require 'json'
require 'open3'
require 'rbconfig'

class CiPollTest < Minitest::Test
  WORKFLOW = YAML.load_file(File.expand_path('../.github/workflows/ci.yml', __dir__))
  STEPS = WORKFLOW.fetch('jobs').fetch('poll').fetch('steps')
  COMMAND = STEPS.find { |step| step['name'] == 'Test it unless a run already has' }.fetch('run')
  SHA = 'a' * 40

  def run_poll(runs)
    Dir.mktmpdir('solco-ci-poll-test-') do |directory|
      bin = File.join(directory, 'bin')
      Dir.mkdir(bin)
      calls = File.join(directory, 'calls.jsonl')
      fixture = File.join(directory, 'runs.json')
      summary = File.join(directory, 'summary')
      File.write(fixture, JSON.generate(runs))
      File.write(File.join(bin, 'git'), "#!#{RbConfig.ruby}\n" + <<~RUBY)
        abort 'Unexpected git operation' unless ARGV == ['rev-parse', 'HEAD']
        puts '#{SHA}'
      RUBY
      File.write(File.join(bin, 'gh'), "#!#{RbConfig.ruby}\n" + <<~'RUBY')
        require 'json'
        require 'open3'
        File.open(ENV.fetch('QA_CALLS'), 'a') { |file| file.puts(JSON.generate(ARGV)) }
        abort 'Unexpected repository' unless ARGV[ARGV.index('--repo') + 1] == 'crmne/solco-releases'
        if ARGV.take(2) == ['run', 'list']
          abort 'Unexpected workflow' unless ARGV[ARGV.index('--workflow') + 1] == 'ci.yml'
          # Evaluate the extracted workflow's real query, not a hardcoded count.
          query = ARGV.fetch(ARGV.index('-q') + 1)
          output, error, status = Open3.capture3('jq', '-r', query, stdin_data: File.read(ENV.fetch('QA_RUNS')))
          abort error unless status.success?
          print output
        elsif ARGV.take(3) != ['workflow', 'run', 'ci.yml']
          abort 'Unexpected GitHub operation'
        end
      RUBY
      %w[git gh].each { |name| File.chmod(0o755, File.join(bin, name)) }
      env = {'PATH' => "#{bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}",
        'QA_CALLS' => calls, 'QA_RUNS' => fixture, 'GITHUB_STEP_SUMMARY' => summary,
        'GITHUB_REPOSITORY' => 'crmne/solco-releases'}
      _, error, status = Open3.capture3(env, 'bash', '-euo', 'pipefail', '-c', COMMAND)
      assert status.success?, error
      yield File.readlines(calls).map { |line| JSON.parse(line) }, File.read(summary)
    end
  end

  def test_active_non_scheduled_states_defer_without_dispatching
    %w[queued in_progress waiting pending requested].each do |status|
      run_poll([{'event' => 'workflow_dispatch', 'status' => status, 'displayTitle' => "CI #{'b' * 40}"}]) do |calls, summary|
        assert_equal 2, calls.size
        assert calls.all? { |call| call.take(2) == ['run', 'list'] }
        assert_includes summary, "defer #{SHA} until the next poll"
      end
    end
  end

  def test_active_repository_dispatch_is_also_preserved
    run_poll([{'event' => 'repository_dispatch', 'status' => 'in_progress', 'displayTitle' => 'CI earlier'}]) do |calls, _|
      refute calls.any? { |call| call.take(2) == ['workflow', 'run'] }
    end
  end

  def test_no_active_ci_dispatches_once_and_does_not_count_the_scheduled_poll
    run_poll([{'event' => 'schedule', 'status' => 'in_progress', 'displayTitle' => 'check for new commits'},
              {'event' => 'workflow_dispatch', 'status' => 'completed', 'displayTitle' => 'CI earlier'}]) do |calls, summary|
      assert_equal [['workflow', 'run', 'ci.yml', '--repo', 'crmne/solco-releases', '-f', "source_sha=#{SHA}"]],
        calls.select { |call| call.take(2) == ['workflow', 'run'] }
      assert_includes summary, "Started a test run for #{SHA}"
    end
  end

  def test_already_tested_sha_never_dispatches_another_run
    run_poll([{'event' => 'workflow_dispatch', 'status' => 'completed', 'displayTitle' => "CI #{SHA}"}]) do |calls, summary|
      assert_equal 1, calls.size
      assert_includes summary, "#{SHA} is already tested"
    end
  end

  def test_manual_superseding_and_subsequent_tag_discovery_are_preserved
    assert_equal '${{ github.event_name != \'schedule\' }}', WORKFLOW.fetch('concurrency').fetch('cancel-in-progress')
    assert_equal 'ci-${{ github.event_name == \'schedule\' && \'poll\' || \'test\' }}', WORKFLOW.fetch('concurrency').fetch('group')
    assert_equal "github.event_name == 'schedule'", WORKFLOW.fetch('jobs').fetch('poll').fetch('if')
    tag_step = STEPS.find { |step| step['name'] == 'Build the newest version tag unless a release run exists' }
    refute_nil tag_step
    refute tag_step.key?('if'), 'deferring CI must not suppress later tag discovery'
    assert_operator STEPS.index(tag_step), :>, STEPS.index(STEPS.find { |step| step['run'] == COMMAND })
    assert_includes tag_step.fetch('run'), '-f version="$version" -f source_ref="$tag"'
  end
end
