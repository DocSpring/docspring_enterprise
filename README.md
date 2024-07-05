# Convox Configuration for DocSpring Enterprise

Please see the [Deploying DocSpring Enterprise to AWS via Convox Guide](https://guides.docspring.com/Deploying-DocSpring-Enterprise-to-AWS-via-Convox-6fb67d34d89e49f4ad15ddfc962e6b52) for more information.

### Requirements

- MacOS
- Convox v3 CLI
  - https://docs.convox.com/installation/cli
- AWS CLI
  - https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-install.html
- Terraform
  - https://learn.hashicorp.com/tutorials/terraform/install-cli

This installation script requires the Convox and AWS CLI tools.

The Convox CLI must be version 3 or greater. Older versions of the Convox CLI had a version string like this: `20210208170413`.
You can check your Convox CLI version by running: `convox version`
Install the Convox CLI by running `brew install convox`, or by following the instructions at: https://docs.convox.com/getting-started/introduction

Follow these instructions to install the AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-install.html

_Please let us know if you need to run this script on Linux. Linux support should not be too difficult to implement, but unfortunately we probably won't be able to support Windows._

# Clone this repo

```
git clone https://github.com/DocSpring/docspring_enterprise.git
```

### Install Convox and set up DocSpring Enterprise

Run the install script:

```
cd docspring_enterprise
./install.rb
```

### Deploying Updates

Run `./update.sh` to update to the latest DocSpring Enterprise image. This will perform a 'rolling deployment' with zero downtime, and it will also update your database.
