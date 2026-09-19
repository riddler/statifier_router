import Config

# This package carries no runtime app-env configuration of its own. The only
# thing config/ configures is the test harness's own repo, so only :test has
# an env-specific file to import.
if config_env() == :test do
  import_config "test.exs"
end
