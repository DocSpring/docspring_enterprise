#!/usr/bin/env ruby
# frozen_string_literal: true

# Run `export DSE_DEVELOPMENT=1` to require local convox_installer repo
if ENV['DSE_DEVELOPMENT']
  $LOAD_PATH << File.expand_path('../convox_installer/lib', __dir__)
  require 'pry-byebug'
else
  require 'bundler/inline'

  gemfile do
    source 'https://rubygems.org'
    gem 'convox_installer', '3.2.1'
  end
end

require 'English'
require 'convox_installer'
include ConvoxInstaller

require 'fileutils'
FileUtils.cp('convox.example.yml', 'convox.yml') unless File.exist?('convox.yml')

@log_level = Logger::DEBUG

MINIMAL_HEALTH_CHECK_PATH = '/health/site'
COMPLETE_HEALTH_CHECK_PATH = '/health'

S3_BUCKET_CORS_RULE = <<-TERRAFORM
  cors_rule {
    allowed_headers = ["Authorization", "cache-control", "x-requested-with"]
    allowed_methods = ["PUT", "POST", "GET"]
    allowed_origins = ["*"]
    expose_headers  = []
    max_age_seconds = 3000
  }
TERRAFORM

default_prompts = ConvoxInstaller::Config::DEFAULT_PROMPTS
                  .reject { |p| p[:key] == :stack_name }

@prompts = default_prompts + [
  {
    key: :stack_name,
    title: 'Convox Stack Name',
    prompt: 'Please enter a name for your Convox installation',
    default: 'docspring-enterprise'
  },
  {
    section: 'ECR Authentication',
    info: "You should have received authentication details for the Docker Registry\n" \
          'via email. If not, please contact support@example.com'
  },
  {
    key: :docker_registry_url,
    title: 'Docker Registry URL',
    value: '691950705664.dkr.ecr.us-east-1.amazonaws.com'
  },
  {
    key: :docker_registry_username,
    title: 'Docker Registry Username (Access Key ID)'
  },
  {
    key: :docker_registry_password,
    title: 'Docker Registry Password (Secret access key)'
  },
  {
    key: :docspring_license,
    title: 'DocSpring License'
  },
  {
    key: :convox_app_name,
    title: 'Convox App Name',
    value: 'docspring'
  },
  {
    key: :default_service,
    title: 'Default Convox Service (for domain)',
    value: 'web',
    hidden: true
  },
  {
    key: :admin_email,
    title: 'Admin User Email',
    prompt: 'Please enter the email address you would like to use ' \
            'for the default admin user',
    default: 'admin@example.com'
  },
  {
    key: :admin_password,
    title: 'Admin User Password',
    value: -> { SecureRandom.hex(8) }
  },
  {
    key: :s3_bucket_name,
    title: 'S3 Bucket for templates and generated PDFs',
    value: -> { "docspring-docs-#{SecureRandom.hex(4)}" }
  },
  {
    key: :s3_bucket_cors_rule,
    value: S3_BUCKET_CORS_RULE,
    hidden: true
  },
  {
    key: :secret_key_base,
    value: -> { SecureRandom.hex(64) },
    hidden: true
  },
  {
    key: :data_encryption_key,
    value: -> { SecureRandom.hex(32) },
    hidden: true
  },
  {
    key: :database_username,
    value: 'docspring',
    hidden: true
  },
  {
    key: :database_password,
    value: -> { SecureRandom.hex(16) },
    hidden: true
  }
]

ensure_requirements!
config = prompt_for_config

backup_convox_host_and_rack

rack_name_file = File.join(__dir__, '.rack_name')
logger.info "Writing rack name (#{config.fetch(:stack_name)}) to #{rack_name_file}"

File.write(rack_name_file, config.fetch(:stack_name))

install_convox

validate_convox_rack_and_write_current!
validate_convox_rack_api!

create_convox_app!
set_default_app_for_directory!
add_docker_registry!

add_s3_bucket
add_rds_database
add_elasticache_cluster

apply_terraform_update!

logger.info "======> Default domain: #{default_service_domain_name}"

logger.info 'Checking convox env...'
convox_env_output = `convox env --rack #{config.fetch(:stack_name)}`
raise 'Error running convox env' unless $CHILD_STATUS.success?

convox_env = begin
  convox_env_output.split("\n").map { |s| s.split('=', 2) }.to_h
rescue StandardError
  {}
end

# Add database and redis
desired_env = {
  'DATABASE_URL' => rds_details[:postgres_url],
  'REDIS_URL' => elasticache_details[:redis_url],
  'AWS_ACCESS_KEY_ID' => s3_bucket_details.fetch(:access_key_id),
  'AWS_ACCESS_KEY_SECRET' => s3_bucket_details.fetch(:secret_access_key),
  'AWS_UPLOADS_S3_BUCKET' => s3_bucket_details.fetch(:name),
  'AWS_UPLOADS_S3_REGION' => config.fetch(:aws_region),
  'SECRET_KEY_BASE' => config.fetch(:secret_key_base),
  'SUBMISSION_DATA_ENCRYPTION_KEY' => config.fetch(:data_encryption_key),
  'ADMIN_NAME' => 'Admin',
  'ADMIN_EMAIL' => config.fetch(:admin_email),
  'ADMIN_PASSWORD' => config.fetch(:admin_password),
  'DOCSPRING_LICENSE' => config.fetch(:docspring_license),
  'DISABLE_EMAILS' => 'true'
}

# Only set health check path and domain if it's not already present.
desired_env['HEALTH_CHECK_PATH'] = MINIMAL_HEALTH_CHECK_PATH if convox_env['HEALTH_CHECK_PATH'].nil?
desired_env['DOMAIN_NAME'] = default_service_domain_name if convox_env['DOMAIN_NAME'].nil?

updated_keys = []
desired_env.each_key do |key|
  updated_keys << key if convox_env[key] != desired_env[key]
end

if updated_keys.none?
  logger.info '=> Convox env has already been configured.'
  logger.info '   You can update this by running: convox env set ...'
else
  logger.info "=> Setting environment variables to configure DocSpring: #{updated_keys.join(', ')}"
  env_command_params = desired_env.map { |k, v| "#{k}=\"#{v}\"" }.join(' ')
  run_convox_command! "env set #{env_command_params}"
end

# If we are already using the complete health check path, then we can skip the rest.
if convox_env['HEALTH_CHECK_PATH'] == COMPLETE_HEALTH_CHECK_PATH
  logger.info 'DocSpring is already set up and running.'
else
  logger.info 'Checking convox processes...'
  convox_processes = `convox ps --rack #{config.fetch(:stack_name)}`
  if convox_processes.include?('web') && convox_processes.include?('worker')
    logger.info '=> Initial deploy for DocSpring Enterprise is already done.'
  else
    logger.info '=> Initial deploy for DocSpring Enterprise...'
    logger.info '-----> Documentation: https://docs.convox.com/deployment/deploying-changes/'
    run_convox_command! 'deploy'
  end

  logger.info '=> Ensuring the DocSpring application container can boot successfully...'
  run_convox_command! 'run command ./bin/smoke_test'

  logger.info '=> Setting up the DocSpring database...'
  run_convox_command! 'run command rake db:prepare'

  logger.info '=> Checking Postgres, Redis, Rails cache, S3 uploads, Sidekiq job processing...'
  run_convox_command! 'run command rake tests:health_check'

  logger.info '=> Updating the health check path to include database tests...'
  run_convox_command! "env set --promote HEALTH_CHECK_PATH=#{COMPLETE_HEALTH_CHECK_PATH}"
end

puts
logger.info 'All done!'
puts
puts "You can now visit #{default_service_domain_name} and sign in with:"
puts
puts "    Email:    #{config.fetch(:admin_email)}"
puts "    Password: #{config.fetch(:admin_password)}"
puts
puts 'You can configure a custom domain name, auto-scaling, and other options in convox.yml.'
puts 'To deploy your changes, run: convox deploy --wait'
puts
puts "IMPORTANT: We recommend manually enabling \"Termination Protection\""
puts 'for your RDS (Postgres) and ElastiCache (Redis) resources.'
puts 'This will help to prevent accidental data loss.'
puts
puts 'To learn more about the convox CLI, run: convox --help'
puts
puts '  * View the Convox documentation:  https://docs.convox.com/'
puts '  * View the DocSpring documentation: https://docspring.com/docs/'
puts
puts
puts 'To completely uninstall Convox and DocSpring from your AWS account,'
puts 'run the following steps (in this order):'
puts
puts ' 1) Disable "Termination Protection" for any resources where it was enabled.'
puts
puts " 2) Use the AWS CLI to delete all files from your #{s3_bucket_details.fetch(:name)} S3 bucket:"
puts
puts "    export AWS_ACCESS_KEY_ID=#{config.fetch(:aws_access_key_id)}"
puts "    export AWS_SECRET_ACCESS_KEY=#{config.fetch(:aws_secret_access_key)}"
puts "    aws s3 rm s3://#{s3_bucket_details.fetch(:name)} --recursive"
puts
puts ' 3) Delete the "docspring" Convox app:'
puts
puts "    convox apps delete docspring"
puts
puts ' 4) Uninstall Convox (deletes all AWS resources via Terraform):'
puts
puts "    convox rack uninstall #{config.fetch(:stack_name)}"
puts
puts
puts '------------------------------------------------------------------------------------'
puts 'Thank you for using DocSpring! Please contact support@docspring.com if you need any help.'
puts '------------------------------------------------------------------------------------'
puts
