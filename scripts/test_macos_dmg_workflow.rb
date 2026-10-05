# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
require 'open3'

class MacosDmgWorkflowTest < Minitest::Test
  WORKFLOW = YAML.load_file(File.expand_path('../.github/workflows/macos-dmg-check.yml', __dir__))
  TRIGGERS = WORKFLOW.fetch('on') { WORKFLOW.fetch(true) }
  JOB = WORKFLOW.fetch('jobs').fetch('native-image')
  STEPS = JOB.fetch('steps')

  def test_only_a_maintainer_dispatch_can_request_the_read_only_native_fixture
    assert_equal ['workflow_dispatch'], TRIGGERS.keys
    assert_equal ['source_sha'], TRIGGERS.dig('workflow_dispatch', 'inputs').keys
    assert_equal true, TRIGGERS.dig('workflow_dispatch', 'inputs', 'source_sha', 'required')
    assert_equal({'contents' => 'read'}, WORKFLOW.fetch('permissions'))
    assert_equal 'macos-latest', JOB.fetch('runs-on')
    assert_equal 10, JOB.fetch('timeout-minutes')
    assert_equal({'SOURCE_SHA' => '${{ inputs.source_sha }}'}, JOB.fetch('env'))
    refute JOB.key?('environment')
  end

  def test_input_guard_rejects_refs_and_shell_text_before_checkout
    guard = STEPS.first
    assert_equal 'Require an exact private source commit', guard.fetch('name')
    valid = '0123456789abcdef' * 2 + '01234567'
    _, error, status = Open3.capture3({'SOURCE_SHA' => valid}, 'bash', '-c', guard.fetch('run'))
    assert status.success?, error
    ['', 'master', 'v0.8.0-alpha.1', valid[0...39], valid + '0', valid.upcase, '$(exit 0)', valid + "\n"].each do |invalid|
      _, error, status = Open3.capture3({'SOURCE_SHA' => invalid}, 'bash', '-c', guard.fetch('run'))
      refute status.success?, "accepted #{invalid.inspect}"
      assert_includes error, 'source_sha must be 40 lowercase hexadecimal characters'
    end
  end

  def test_checked_out_commit_and_fixture_are_exact_without_release_credentials
    checkout = STEPS.fetch(1).fetch('with')
    assert_equal 'crmne/solco', checkout.fetch('repository')
    assert_equal '${{ inputs.source_sha }}', checkout.fetch('ref')
    assert_equal '${{ secrets.SOURCE_DEPLOY_KEY }}', checkout.fetch('ssh-key')
    assert_equal false, checkout.fetch('persist-credentials')
    assert_equal ['${{ secrets.SOURCE_DEPLOY_KEY }}'], WORKFLOW.to_s.scan(/\$\{\{ secrets\.[A-Z_]+ \}\}/)
    commands = STEPS.filter_map { |step| step['run'] }.join("\n")
    assert_includes commands, 'test "$(git rev-parse HEAD)" = "$SOURCE_SHA"'
    assert_includes commands, 'ruby scripts/test_macos_dmg.rb'
    refute_match(/cargo|SOLCO_OFFICIAL_RELEASE|notarize|gh (release|workflow)|xdg-open/, commands)
    refute STEPS.any? { |step| step.fetch('uses', '').start_with?('actions/upload-artifact') }
  end
end
