#!/bin/bash
set -e
echo 'formapi-enterprise-1683696213.us-east-2.elb.amazonaws.com' > ~/.convox/host
rm -f ~/.convox/rack
convox rack
