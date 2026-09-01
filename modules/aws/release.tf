# Resolving and packaging the SAG source.
#
# Terraform is not a build tool and should not become one, but the version this
# instance runs is part of its desired state, so resolving it belongs inside
# Terraform's own graph rather than in a build step beside it. `external` keeps
# the resolution honest in both directions: `terraform plan` reports the tag and
# commit it resolved, and a `version: latest` that resolves newer code than last
# time shows up as a code change in the plan rather than as a silent one.

data "external" "release" {
  program = ["node", "${path.module}/../../scripts/fetch-release.mjs"]

  query = {
    version = var.common.sag_version
    # SAG has no runtime dependencies of its own, so the extracted tree is
    # itself the deployable artefact and these three paths are the whole
    # package.
    include  = "package.json,src,adapters"
    platform = "aws-lambda"
  }
}

data "archive_file" "package" {
  type        = "zip"
  source_dir  = data.external.release.result.package_dir
  output_path = data.external.release.result.archive_path

  # fetch-release.mjs normalises every extracted file's mtime to a fixed epoch,
  # so identical source produces a byte-identical archive and a redeploy of an
  # unchanged pinned version is genuinely a no-op rather than a code update
  # Terraform cannot explain.
}
