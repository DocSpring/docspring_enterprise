# Convox Configuration for DocSpring Enterprise

To clone this repo:

```
git clone https://oauth2:agYxGMgwn6VixdGuqngM@gitlab.com/docspring/docspring_enterprise_gilts.git
```

### Requirements

* MacOS
* Convox v3 CLI
  * https://docs.convox.com/installation/cli
* AWS CLI
  * https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-install.html
* Terraform
  * https://learn.hashicorp.com/tutorials/terraform/install-cli

This installation script requires the Convox and AWS CLI tools.

The Convox CLI must be version 3 or greater. Older versions of the Convox CLI had a version string like this: `20210208170413`.
You can check your Convox CLI version by running: `convox version`
Install the Convox CLI by running `brew install convox`, or by following the instructions at: https://docs.convox.com/getting-started/introduction

Follow these instructions to install the AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-install.html

_Please let us know if you need to run this script on Linux. Linux support should not be too difficult to implement, but unfortunately we probably won't be able to support Windows._

### Install Convox and set up DocSpring

Run the install script:

```
./install.rb
```
