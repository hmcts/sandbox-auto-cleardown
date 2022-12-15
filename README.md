# sandbox-auto-cleardown

### What is this for?

This repo contains pipelines and scripts to remove resources from the sandbox environment based on resource tags in Azure.

All resources in the sandbox environment will have an `expiresAfter` tag with a date value.

Any resources that have an `expiresAfter` tag value dated in the past, based on the script runtime, will be deleted.

This ensures resources that are not required long term are removed.