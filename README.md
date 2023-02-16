# sandbox-auto-cleardown

### What is this for?

This repo contains pipelines and scripts to remove resources from the sandbox environment based on resource tags in Azure.

All resources in the sandbox environment will have an `expiresAfter` tag with a date value.

Any resources that have an `expiresAfter` tag value dated in the past, based on the script runtime, will be deleted.

This ensures resources that are not required long term are removed.

### `expiresAfter`

In the Sandbox environment resources must be tagged with an end date after which they are no longer needed.
They will then be automatically deleted after this date.

By default a tag will be added as `now() + 30 days`.

You can customise this by setting an explicit date:

```terraform
module "tags" {
  source      = "git::https://github.com/hmcts/terraform-module-common-tags.git?ref=master"
  environment = var.env
  product     = var.product
  builtFrom   = var.builtFrom
  expiresAfter = "2023-01-01" # YYYY-MM-DD
}
```

Or by setting it to never expire with a date far into the future:

```terraform
module "tags" {
  source      = "git::https://github.com/hmcts/terraform-module-common-tags.git?ref=master"
  environment = var.env
  product     = var.product
  builtFrom   = var.builtFrom
  expiresAfter = "3000-01-01" # never expire
}
```
