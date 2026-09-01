# A fixed CDN origin header value, so the rendered environment is comparable
# between runs. This is the one value in the whole module that Terraform
# generates; modules/aws/cdn.tf explains why that is acceptable for this one
# value and nothing else.

mock_resource "random_id" {
  defaults = {
    b64_url = "test-origin-secret-value-not-a-real-one--"
    b64_std = "test-origin-secret-value-not-a-real-one--"
    hex     = "00000000000000000000000000000000"
    dec     = "0"
  }
}
