# frozen_string_literal: true

require_relative "test_helper"
# NOTE: "rails/railtie" alone triggers a require-order bug in railties >=
# 8.1.2.1 (rails/initializable.rb uses delegate_missing_to before
# active_support/core_ext/module/delegation is loaded — rails/railtie.rb
# requires "rails/initializable" before any active_support core_ext). A real
# Rails app never hits this because the full "rails" gem loads active_support
# first; requiring the full framework here reproduces that real ordering
# instead of the bare (and, on this railties version, broken) submodule.
require "rails"
require "cru_flags"
require "cru_flags/railtie"

class RailtieLogicTest < Minitest::Test
  def quiet?(current:, env_var: nil, rails_env: "development")
    CruFlags::Railtie.quiet_strict?(current:, env_var:, rails_env:)
  end

  def test_quiets_flippers_own_dev_default
    assert quiet?(current: :warn)
  end

  def test_quiets_flippers_own_prod_default
    assert quiet?(current: false, rails_env: "production")
  end

  def test_honors_explicit_env_var
    refute quiet?(current: :warn, env_var: "warn")
    refute quiet?(current: false, env_var: "false", rails_env: "production")
  end

  def test_honors_app_chosen_values_that_differ_from_the_default
    refute quiet?(current: true) # dev default is :warn; true means the app chose
    refute quiet?(current: :warn, rails_env: "production") # prod default is false
  end

  def test_railtie_is_defined_when_rails_is
    assert CruFlags::Railtie.ancestors.include?(Rails::Railtie)
  end
end
