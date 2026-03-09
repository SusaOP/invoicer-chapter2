#!/usr/bin/env bash

# Usage: ./cleanup_ebs_env.sh <identifier>
# Example: ./cleanup_ebs_env.sh wivcr202603072012

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <identifier>"
    exit 1
fi

id="$1"
export AWS_DEFAULT_REGION=${AWS_REGION:-us-east-1}

echo "Cleaning up resources for $id"

# Delete EB application (terminates environments too)
echo "Deleting ElasticBeanstalk application..."
aws elasticbeanstalk delete-application \
    --application-name "$id" \
    --terminate-env-by-force 2>/dev/null && echo "  done" || echo "  not found, skipping"

# Delete S3 bucket
echo "Deleting S3 bucket..."
aws s3 rb s3://"$id" --force 2>/dev/null && echo "  done" || echo "  not found, skipping"

# Delete RDS instance
echo "Deleting RDS instance..."
aws rds delete-db-instance \
    --db-instance-identifier "$id" \
    --skip-final-snapshot 2>/dev/null && echo "  done, waiting for deletion..." || echo "  not found, skipping"

# Wait for RDS to finish deleting before removing the security group
aws rds wait db-instance-deleted --db-instance-identifier "$id" 2>/dev/null || true

# Delete security group
if [ -f "tmp/$id/dbsg.json" ]; then
    dbsg=$(jq -r '.GroupId' "tmp/$id/dbsg.json")
    echo "Deleting security group $dbsg..."
    aws ec2 delete-security-group --group-id "$dbsg" 2>/dev/null && echo "  done" || echo "  failed (may still be in use, retry later)"
else
    echo "No dbsg.json found, skipping security group deletion"
fi

# Delete custom RDS parameter group (if it exists)
echo "Deleting RDS parameter group..."
aws rds delete-db-parameter-group \
    --db-parameter-group-name invoicer-pg16-no-ssl 2>/dev/null && echo "  done" || echo "  not found, skipping"

echo "Cleanup complete for $id"
