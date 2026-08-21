# frozen_string_literal: true

module CruFlags
  # Zero-config Rails wiring (design doc §5.1). Registration is ordering-safe
  # because Flipper's engine resolves config.adapter LAZILY on first
  # Flipper.instance access, and the last-registered adapter block wins — an
  # app's own Flipper.configure in config/initializers still overrides ours.
  class Railtie < Rails::Railtie
    # Flipper's engine assigns config.flipper.strict in before_configuration
    # (:warn in development, false elsewhere) — BEFORE any gem initializer —
    # so "did the app set it" cannot be read off the config value alone. We
    # quiet strict only when the env var is unset AND the value still equals
    # Flipper's own computed default, i.e. only when nobody chose it.
    def self.quiet_strict?(current:, env_var:, rails_env:)
      return false unless env_var.nil?
      flipper_default = (rails_env == "development") ? :warn : false
      current == flipper_default
    end

    initializer "cru_flags.flipper" do |app|
      require "flipper"
      Flipper.configure { |config| config.adapter { CruFlags.flipper_adapter } }

      if app.config.respond_to?(:flipper) &&
          Railtie.quiet_strict?(current: app.config.flipper.strict,
            env_var: ENV["FLIPPER_STRICT"], rails_env: Rails.env.to_s)
        app.config.flipper.strict = false
      end
    end
  end
end
