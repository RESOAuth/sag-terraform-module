# `archive_file` zips a directory that does not exist during a test run, so its
# outputs are fixed here rather than computed.

mock_data "archive_file" {
  defaults = {
    output_path         = "/tmp/sag-test/package.zip"
    output_base64sha256 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    output_size         = 1024
  }
}
