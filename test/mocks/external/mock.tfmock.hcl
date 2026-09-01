# scripts/fetch-release.mjs and scripts/bundle-worker.mjs, mocked.
#
# The point of mocking these is that `terraform test` must not touch the
# network, run wrangler, or need a GitHub token: what the tests are checking is
# the resource set and the rendered environment, neither of which depends on
# which release resolved.

# `path` is a real file, relative to this directory, because the Cloudflare
# provider reads `content_file` and hashes it during plan - a mocked path that
# does not exist fails the plan before any assertion runs.
mock_data "external" {
  defaults = {
    result = {
      tag          = "v0.0.0-test"
      name         = "v0.0.0-test"
      commit       = "000000000000"
      source       = "github:RESOAuth/smart-access-gateway@000000000000"
      work_dir     = "/tmp/sag-test"
      package_dir  = "/tmp/sag-test/package"
      archive_path = "/tmp/sag-test/package.zip"
      path         = "mocks/bundle.js"
      sha256       = "12b7cb2b6946ce8aa06513d364aab8ef06c3b38a6de9e8b0b0115dacecfb3e70"
    }
  }
}
