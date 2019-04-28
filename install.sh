#!/bin/bash
set -e
mkdir -p ~/.convox

FORMAPI_ENTERPRISE_REGISTRY="691950705664.dkr.ecr.us-east-1.amazonaws.com"

# The database is not set up before the initial deploy,
# so we use "/health/site" for the first health checks.
# This just ensures that the application can boot and render views,
# but does not test the database or redis connections.
MINIMAL_HEALTH_CHECK_PATH="/health/site"
COMPLETE_HEALTH_CHECK_PATH="/health"


if ! which convox > /dev/null 2>&1 || ! which aws > /dev/null 2>&1; then
  echo "This script requires the convox and AWS CLIs. If you are on a Mac, please run:"
  echo
  echo "    $ brew install convox awscli"
  echo
  exit 1
fi

if [ -z "$STACK_NAME" ]; then
  read -p 'Please enter a name for your convox installation (default: formapi-enterprise): ' STACK_NAME
  if [ -z "$STACK_NAME" ]; then
    STACK_NAME=formapi-enterprise
    echo "=> Using convox stack name: $STACK_NAME"
  fi
  export STACK_NAME
fi

# Create convox.yml from example
if ! [ -f convox.yml ]; then cp convox.example.yml convox.yml; fi

if [ -z "$AWS_REGION" ]; then
  read -p 'Please enter your AWS region (default: us-east-1): ' AWS_REGION
  if [ -z "$AWS_REGION" ]; then
    AWS_REGION=us-east-1
    echo "=> Using region: $AWS_REGION"
  fi
  export AWS_REGION
fi

if [ -f "~/.convox/auth" ]; then
  EXISTING_INSTALLATION="$(cat ~/.convox/auth | grep "$STACK_NAME.*$AWS_REGION" | cut -d'"' -f2)"
  if [ -n "$EXISTING_INSTALLATION" ]; then
    echo "ERROR: ~/.convox/auth already contains credentials for a convox installation named '$STACK_NAME' in the $AWS_REGION region!"
    echo "Remove the value for '$EXISTING_INSTALLATION', or run 'convox uninstall' to remove the installation."
    exit 1
  fi
fi

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  read -p 'Please enter your administrator AWS Access Key ID: ' AWS_ACCESS_KEY_ID
  read -p 'Please enter your administrator AWS Access Key secret: ' AWS_SECRET_ACCESS_KEY
  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
fi

if [ -z "$FORMAPI_ECR_ACCESS_KEY_ID" ] || [ -z "$FORMAPI_ECR_ACCESS_KEY_SECRET" ]; then
  echo
  echo "-------------------------------------------------------------------------------"
  echo "You should have received authentication details for the FormAPI Docker Registry"
  echo "via email. If not, please contact support@formapi.io."
  echo "-------------------------------------------------------------------------------"
  echo
  read -p 'Please enter your access key ID (or username) for the FormAPI Docker Registry: ' FORMAPI_ECR_ACCESS_KEY_ID
  read -p 'Please enter your access key secret (or password) for the FormAPI Docker Registry: ' FORMAPI_ECR_ACCESS_KEY_SECRET
  echo
  export FORMAPI_ECR_ACCESS_KEY_ID
  export FORMAPI_ECR_ACCESS_KEY_SECRET
fi

if [ -z "$ADMIN_EMAIL" ]; then
  read -p 'Please enter the email address you want to use for the admin user: ' ADMIN_EMAIL
  export ADMIN_EMAIL
fi

if [ -z "$ADMIN_PASSWORD" ]; then
  echo "=> Generating a strong password for the admin user..."
  export ADMIN_PASSWORD=$(openssl rand -hex 6)
fi

echo
echo "============================================"
echo "                 SUMMARY"
echo "============================================"
echo
echo "If anything goes wrong during the installation, run the following commands"
echo "to set the configuration variables before you retry the script:"
echo
echo "export STACK_NAME=\"$STACK_NAME\"   # Convox Stack Name"
echo "export AWS_REGION=\"$AWS_REGION\"   # AWS Region"
echo "export AWS_ACCESS_KEY_ID=\"$AWS_ACCESS_KEY_ID\"   # AWS Access Key ID"
echo "export AWS_SECRET_ACCESS_KEY=\"$AWS_SECRET_ACCESS_KEY\"   # AWS Secret Access Key"
echo "export FORMAPI_ECR_ACCESS_KEY_ID=\"$FORMAPI_ECR_ACCESS_KEY_ID\"   # FormAPI ECR Access Key ID"
echo "export FORMAPI_ECR_ACCESS_KEY_SECRET=\"$FORMAPI_ECR_ACCESS_KEY_SECRET\"   # FormAPI ECR Secret Access Key"
echo "export ADMIN_EMAIL=\"$ADMIN_EMAIL\"   # Admin Email"
echo "export ADMIN_PASSWORD=\"$ADMIN_PASSWORD\"   # Admin Password"
echo
echo "============================================"
echo
echo "Please double check all of these details. If anything is incorrect, \
press Ctrl+C to cancel."
echo "Otherwise, press Enter to continue with the Convox installation."
echo
read CONFIRMATION

for f in host rack; do
  if [ -f ~/.convox/$f ]; then
    echo "=> Removing existing ~/.convox/$f... (Moving to ~/.convox/$f.bak)"
    echo "(?) Restore this with: mv ~/.convox/$f.bak ~/.convox/$f"
    mv ~/.convox/$f ~/.convox/$f.bak
  fi
done

echo "=> Installing Convox ($STACK_NAME)..."
convox rack install aws \
  --name "$STACK_NAME" \
  "InstanceType=t3.medium" \
  "BuildInstance="

echo "=> Setting the default host for the convox CLI..."
CONVOX_HOST=$(cat ~/.convox/auth | grep "$STACK_NAME-\d\+\.$AWS_REGION\.elb" | cut -d'"' -f2)
echo "======> Host: $CONVOX_HOST"
echo $CONVOX_HOST > ~/.convox/host

echo "=> Running 'convox rack' to make sure that everything is working..."
convox rack

echo "=> Creating the FormAPI app..."
echo "-----> Documentation: https://docs.convox.com/deployment/creating-an-application"
convox apps create formapi --wait

# Prevents any conflicts with S3 bucket names
S3_BUCKET_SUFFIX=$(openssl rand -hex 5)
S3_RESOURCE_NAME="formapi-docs-$S3_BUCKET_SUFFIX"

echo "=> Setting up S3 bucket for file storage... (This can take a few minutes)"
convox rack resources create s3 \
  --name "$S3_RESOURCE_NAME" \
  --wait
echo "=====> S3 bucket is ready!"
echo "=====> Looking up S3 bucket URL..."

S3_URL=$(convox rack resources url "$S3_RESOURCE_NAME")
echo "=====> S3 URL: $S3_URL"

S3_AWS_ACCESS_KEY_ID=$(echo "$S3_URL" | sed -n 's/s3:\/\/\([^:]*\):\([^@]*\)@\(.*\)/\1/p')
S3_AWS_ACCESS_KEY_SECRET=$(echo "$S3_URL" | sed -n 's/s3:\/\/\([^:]*\):\([^@]*\)@\(.*\)/\2/p')
S3_AWS_UPLOADS_S3_BUCKET=$(echo "$S3_URL" | sed -n 's/s3:\/\/\([^:]*\):\([^@]*\)@\(.*\)/\3/p')
S3_AWS_UPLOADS_S3_REGION="$AWS_REGION"

echo "=> Setting CORS policy on S3 bucket..."
aws s3api put-bucket-cors \
  --bucket $S3_AWS_UPLOADS_S3_BUCKET \
  --cors-configuration file://s3_bucket_cors.json

echo "=> Generating secret keys for authentication sessions and encryption..."
SECRET_KEY_BASE=$(openssl rand -hex 64)
SUBMISSION_DATA_ENCRYPTION_KEY=$(openssl rand -hex 32)

echo "=> Finding default domain for web service..."
CONVOX_ELB_NAME_AND_REGION=$(convox rack | grep 'Router' | sed -n 's/Router[\t[:space:]]*\([^\.]*\.[^\.]*\)\..*/\1/p')
DEFAULT_DOMAIN_NAME="formapi-web.$CONVOX_ELB_NAME_AND_REGION.convox.site"
echo "======> Default domain: $DEFAULT_DOMAIN_NAME"
echo "        You can use this as a CNAME record after configuring a domain in convox.yml"
echo "        (Note: SSL will be configured automatically.)"

echo "=> Setting environment variables to configure FormAPI..."
convox env set \
  HEALTH_CHECK_PATH="$MINIMAL_HEALTH_CHECK_PATH" \
  DOMAIN_NAME="$DEFAULT_DOMAIN_NAME" \
  AWS_ACCESS_KEY_ID="$S3_AWS_ACCESS_KEY_ID" \
  AWS_ACCESS_KEY_SECRET="$S3_AWS_ACCESS_KEY_SECRET" \
  AWS_UPLOADS_S3_BUCKET="$S3_AWS_UPLOADS_S3_BUCKET" \
  AWS_UPLOADS_S3_REGION="$AWS_REGION" \
  SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  SUBMISSION_DATA_ENCRYPTION_KEY="$SUBMISSION_DATA_ENCRYPTION_KEY" \
  ADMIN_NAME="Admin" \
  ADMIN_EMAIL="$ADMIN_EMAIL" \
  ADMIN_PASSWORD="$ADMIN_PASSWORD"

echo
echo "=> Adding FormAPI ECR Docker Registry..."
echo "-----> Documentation: https://docs.convox.com/deployment/private-registries/"
convox registries add "$FORMAPI_ENTERPRISE_REGISTRY" \
  "$FORMAPI_ECR_ACCESS_KEY_ID" \
  "$FORMAPI_ECR_ACCESS_KEY_SECRET"

echo "=> Initial deploy for FormAPI Enterprise..."
echo "-----> Documentation: https://docs.convox.com/deployment/builds"
convox deploy --wait

echo "=> Setting up the database..."
convox run web rake db:create db:migrate db:seed

echo "=> Updating the health check path to include database tests..."
convox env set --promote --wait HEALTH_CHECK_PATH="$COMPLETE_HEALTH_CHECK_PATH"

echo "=> Generating and replacing EC2 keypair for SSH access..."
convox instances keyroll --wait

echo
echo "All done!"
echo
echo "You can now visit $DEFAULT_DOMAIN_NAME and sign in with:"
echo
echo "    Email:    $ADMIN_EMAIL"
echo "    Password: $ADMIN_PASSWORD"
echo
echo "You can configure a custom domain name, auto-scaling, and other options in convox.yml."
echo "To deploy your changes, run: convox deploy --wait"
echo
echo "IMPORTANT: You should be very careful with the 'resources' section in convox.yml."
echo "If you remove, rename, or change these resources, then Convox will delete"
echo "your database. This will result in downtime and a loss of data."
echo "To prevent this from happening, you can sign into your AWS account,"
echo "visit the RDS and ElastiCache services, and enable \"Termination Protection\""
echo "for your database resources."
echo
echo "To learn more about the convox CLI, run: convox --help"
echo
echo "  * View the Convox documentation:  https://docs.convox.com/"
echo "  * View the FormAPI documentation: https://formapi.io/docs/"
echo
echo
echo "To completely uninstall Convox and FormAPI from your AWS account,"
echo "run the following steps (in this order):"
echo
echo " 1) Disable \"Termination Protection\" for any resource where it was enabled."
echo
echo " 2) Delete all files from the $S3_RESOURCE_NAME S3 bucket:"
echo
echo "    export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID"
echo "    export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY"
echo "    aws s3 rm s3://$S3_AWS_UPLOADS_S3_BUCKET --recursive"
echo
echo " 3) Delete the $S3_RESOURCE_NAME S3 bucket:"
echo
echo "    convox rack resources delete $S3_RESOURCE_NAME --wait"
echo
echo " 4) Uninstall Convox (deletes all CloudFormation stacks and AWS resources):"
echo
echo "    convox rack uninstall aws $STACK_NAME"
echo
echo
echo "------------------------------------------------------------------------------------"
echo "Thank you for using FormAPI! Please contact support@formapi.io if you need any help."
echo "------------------------------------------------------------------------------------"
echo
