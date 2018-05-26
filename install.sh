#!/bin/bash
set -e

# Create convox.yml from example
if ! [ -f convox.yml ]; then cp convox.example.yml convox.yml; fi

if [ -z "$AWS_REGION" ]; then
  read -p 'Please enter your AWS region (leave blank for us-east-1): ' AWS_REGION
  if [ -z "$AWS_REGION" ]; then
    export AWS_REGION=us-east-1
    echo "=> Using region: $AWS_REGION"
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
fi

if [ -z "$ADMIN_EMAIL" ]; then
  read -p 'Please enter the email address you want to use for the admin user: ' ADMIN_EMAIL
fi

if [ -z "$ADMIN_PASSWORD" ]; then
  echo "=> Generating a strong password for the admin user..."
  ADMIN_PASSWORD=$(openssl rand -hex 6)
fi

echo "When setup is finished, you will be able to sign in with the following credentials:"
echo
echo "Email:    $ADMIN_EMAIL"
echo "Password: $ADMIN_PASSWORD"
echo

echo "=> Installing Convox..."
convox install \
  --instance-type t2.medium \
  --build-instance "" \
  --stack-name formapi-enterprise

echo "=> Setting the default host for the convox CLI..."
CONVOX_HOST=$(cat ~/.convox/auth | grep formapi-enterprise | cut -d'"' -f2)
echo $CONVOX_HOST > ~/.convox/host

echo "=> Running 'convox rack' to ensure that everything is working..."
convox rack

echo "=> Creating the FormAPI app..."
convox apps create formapi --wait

# Prevents conflicts with S3 bucket names
S3_BUCKET_SUFFIX=$(openssl rand -hex 5)

echo "=> Setting up Postgres, Redis, and S3 bucket..."
echo "   (This can take around 5-10 minutes.)"
(convox resources create postgres \
  --database=formapi_enterprise \
  --instance-type=db.t2.medium \
  --wait \
  && echo "=====> Postgres is ready") &
sleep 5
(convox resources create redis \
  --instance-type=cache.t2.medium \
  --wait \
  && echo "=====> Redis is ready") &
sleep 5
(convox resources create s3 \
  --name="formapi-docs-$S3_BUCKET_SUFFIX" \
  --wait \
  && echo "=====> S3 bucket is ready") &

wait
echo "=> All resources are ready!"
echo

echo "=> Fetching resource URLs to configure app..."

RESOURCES=$(convox resources)
REDIS_RESOURCE=$(echo "$RESOURCES" | grep " redis " | cut -d' ' -f1)
POSTGRES_RESOURCE=$(echo "$RESOURCES" | grep " postgres " | cut -d' ' -f1)
S3_RESOURCE=$(echo "$RESOURCES" | grep " s3 " | cut -d' ' -f1)

REDIS_URL=$(convox resources url "$REDIS_RESOURCE")
POSTGRES_URL=$(convox resources url "$POSTGRES_RESOURCE")
S3_URL=$(convox resources url "$S3_RESOURCE")

echo "====> Postgres: $POSTGRES_URL"
echo "====> Redis: $REDIS_URL"
echo "====> S3: $S3_URL"

S3_AWS_ACCESS_KEY_ID=$(echo "$S3_URL" | sed -n 's/s3:\/\/\([^:]*\):\([^@]*\)@\(.*\)/\1/p')
S3_AWS_ACCESS_KEY_SECRET=$(echo "$S3_URL" | sed -n 's/s3:\/\/\([^:]*\):\([^@]*\)@\(.*\)/\2/p')
S3_AWS_UPLOADS_S3_BUCKET=$(echo "$S3_URL" | sed -n 's/s3:\/\/\([^:]*\):\([^@]*\)@\(.*\)/\3/p')
S3_AWS_UPLOADS_S3_REGION=$AWS_REGION

echo "=> Setting CORS policy on S3 bucket..."
aws s3api put-bucket-cors \
  --bucket $S3_AWS_UPLOADS_S3_BUCKET \
  --cors-configuration file://s3_bucket_cors.json


echo "=> Generating secret keys for authentication sessions and encryption..."
SECRET_KEY_BASE=$(openssl rand -hex 64)
SUBMISSION_DATA_ENCRYPTION_KEY=$(openssl rand -hex 32)

echo "=> Finding default domain for web service..."
CONVOX_ELB_NAME_AND_REGION=$(convox rack | grep 'Domain' | sed -n 's/Domain\s*\([^\.]*\.[^\.]*\)\..*/\1/p')
DEFAULT_DOMAIN_NAME="formapi-web.$CONVOX_ELB_NAME_AND_REGION.convox.site"
echo "======> Default domain: $DEFAULT_DOMAIN_NAME"
echo "        (You can use this as a CNAME record, but"
echo "        make sure you set the domain in convox.yml)"

echo "=> Setting environment variables to configure FormAPI..."
convox env set \
  DOMAIN_NAME="$DEFAULT_DOMAIN_NAME" \
  DATABASE_URL="$POSTGRES_URL" \
  REDIS_URL="$REDIS_URL" \
  AWS_ACCESS_KEY_ID="$S3_AWS_ACCESS_KEY_ID" \
  AWS_ACCESS_KEY_SECRET="$S3_AWS_ACCESS_KEY_SECRET" \
  AWS_UPLOADS_S3_BUCKET="$S3_AWS_UPLOADS_S3_BUCKET" \
  AWS_UPLOADS_S3_REGION="$AWS_REGION" \
  SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  SUBMISSION_DATA_ENCRYPTION_KEY="$SUBMISSION_DATA_ENCRYPTION_KEY" \
  ADMIN_NAME="Admin" \
  ADMIN_EMAIL="$ADMIN_EMAIL" \
  ADMIN_PASSWORD="$ADMIN_PASSWORD" \

echo
echo "=> Adding FormAPI ECR Docker Registry..."
convox registries add 691950705664.dkr.ecr.us-east-1.amazonaws.com \
  --username "$FORMAPI_ECR_ACCESS_KEY_ID" \
  --password "$FORMAPI_ECR_ACCESS_KEY_SECRET" \

echo "=> Creating a build for FormAPI Enterprise..."
RELEASE_ID=$(convox deploy --id)

echo "=> Have to wait a long time for convox to get into a steady state..."
sleep 180
echo "=> Setting up the database..."
convox run web rake db:create db:migrate

sleep 60
convox run web rake db:seed

echo
echo "All done!"
echo
echo "In a few moments, you should be able to visit: $DEFAULT_DOMAIN_NAME"
echo "and sign in with:"
echo
echo "    Email:    $ADMIN_EMAIL"
echo "    Password: $ADMIN_PASSWORD"
echo
echo "You can configure a custom domain name, auto-scaling options,"
echo "and other options in convox.yml"
echo "To deploy your changes, run: convox deploy"
echo
echo "To learn more about the convox CLI, run: convox --help"
echo
echo "  * View the Convox documentation: https://convox.com/docs/"
echo "  * View the FormAPI documentation: https://formapi.io/docs/"
echo
echo
echo "-----------------------------------------------"
echo "Thank you for using FormAPI, and please contact"
echo "support@formapi.io if you need any help!"
echo "-----------------------------------------------"
echo
