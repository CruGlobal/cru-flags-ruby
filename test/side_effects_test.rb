# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "open3"
require "rbconfig"

# Subprocess proofs for guarantees that only show up in a fresh interpreter:
# requiring this library must be inert, an active poller must never keep the
# process alive past its own work, and a forked child must get its own
# poller rather than inheriting a parent thread it doesn't own (design doc
# §3, §7). Each test boots a throwaway Ruby process (the Open3 pattern from
# railtie_logic_test.rb) so these can't contaminate this test process, or
# each other, with threads or a booted client.
class SideEffectsTest < Minitest::Test
  RUBY = RbConfig.ruby
  LIB = File.expand_path("../lib", __dir__)

  def run_script(env, script)
    Open3.capture3(env, RUBY, "-I", LIB, "-e", script)
  end

  def test_require_starts_no_threads_even_with_url_set
    script = 'require "cru_flags"; ' \
      "puts Thread.list.size; " \
      "exit(Thread.list.size == 1 ? 0 : 1)"
    stdout, stderr, status = run_script({"CRU_FLAGS_URL" => "http://127.0.0.1:9/flags/x/production"}, script)
    assert status.success?,
      "require must not start threads or read the env:\nstdout: #{stdout}\nstderr: #{stderr}"
  end

  def test_active_poller_never_delays_interpreter_exit
    service = FlagService.new.start
    service.respond_with(status: 200, body: '{"Flags":{}}')
    script = 'require "cru_flags"; CruFlags.ready(timeout: 5)'
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stdout, stderr, status = run_script({"CRU_FLAGS_URL" => service.url}, script)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    assert status.success?, "subprocess failed:\nstdout: #{stdout}\nstderr: #{stderr}"
    assert_operator elapsed, :<, 5.0,
      "process must exit immediately, not wait for a 30s poll tick"
  ensure
    service&.stop
  end

  def test_child_process_after_fork_gets_its_own_poller
    skip "fork unavailable" unless Process.respond_to?(:fork)
    service = FlagService.new.start
    service.respond_with(status: 200, body: '{"Flags":{"pilot":{"Enabled":true}}}')
    script = <<~RUBY
      require "cru_flags"
      CruFlags.ready(timeout: 5) or exit 2
      pid = fork do
        exit(CruFlags.enabled?("pilot") ? 0 : 3)
      end
      _, status = Process.waitpid2(pid)
      exit(status.exitstatus)
    RUBY
    stdout, stderr, status = run_script({"CRU_FLAGS_URL" => service.url}, script)
    assert status.success?,
      "a forked child must re-arm and answer reads (exit #{status.exitstatus}):\nstdout: #{stdout}\nstderr: #{stderr}"
  ensure
    service&.stop
  end
end
