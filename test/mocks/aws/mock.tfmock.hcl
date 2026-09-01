# Fixed values for the AWS data sources the module reads, so assertions can name
# whole ARNs rather than pattern-matching around a randomly generated account id.

mock_data "aws_caller_identity" {
  defaults = {
    account_id = "000000000000"
    arn        = "arn:aws:iam::000000000000:user/terraform-test"
    user_id    = "AIDATESTTESTTESTTEST"
  }
}

mock_data "aws_partition" {
  defaults = {
    partition          = "aws"
    dns_suffix         = "amazonaws.com"
    reverse_dns_prefix = "com.amazonaws"
  }
}

mock_data "aws_route53_zone" {
  defaults = {
    zone_id = "ZTESTTESTTESTTESTTEST"
  }
}

# Deliberately empty: the default state of a brand-new instance is that no
# secret has been set yet, which is the case worth having the tests default to.
# render.tftest.hcl's fixtures turn the gate off; discipline.tftest.hcl asserts
# on exactly this emptiness.
mock_data "aws_ssm_parameters_by_path" {
  defaults = {
    names  = []
    arns   = []
    types  = []
    values = []
  }
}

# The AWS provider validates `assume_role_policy` and `policy` as JSON at plan
# time, so a generated mock string fails the plan before any assertion runs.
# The document's real contents are not what these tests check - the plan diff
# and the live deployment cover that - but it does have to parse.
mock_data "aws_iam_policy_document" {
  defaults = {
    json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}
