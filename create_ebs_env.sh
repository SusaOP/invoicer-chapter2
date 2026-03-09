#!/usr/bin/env bash

# requires: pip install awscli awsebcli

# uncomment to debug
#set -x

fail() {
    echo configuration failed
    exit 1
}

export AWS_DEFAULT_REGION=${AWS_REGION:-us-east-1}

datetag=$(date +%Y%m%d%H%M)
identifier=$(whoami)ivcr$datetag
mkdir -p tmp/$identifier

echo "Creating EBS application $identifier"

# Find the ID of the default VPC
aws ec2 describe-vpcs --filters Name=isDefault,Values=true > tmp/$identifier/defaultvpc.json || fail
vpcid=$(jq -r '.Vpcs[0].VpcId' tmp/$identifier/defaultvpc.json)
echo "default vpc is $vpcid"

# Create a security group for the database
aws ec2 create-security-group \
    --group-name $identifier \
    --description "access control to Invoicer Postgres DB" \
    --vpc-id $vpcid > tmp/$identifier/dbsg.json || fail
dbsg=$(jq -r '.GroupId' tmp/$identifier/dbsg.json)
echo "DB security group is $dbsg"

# Create a parameter group that disables forced SSL (PG 16 forces SSL by default,
# but the invoicer container doesn't support SSL connections)
aws rds create-db-parameter-group \
    --db-parameter-group-name invoicer-pg16-no-ssl \
    --db-parameter-group-family postgres16 \
    --description "Invoicer PG16 - SSL not forced" > /dev/null 2>&1 || true
aws rds modify-db-parameter-group \
    --db-parameter-group-name invoicer-pg16-no-ssl \
    --parameters \
    "ParameterName=rds.force_ssl,ParameterValue=0,ApplyMethod=pending-reboot" \
    "ParameterName=password_encryption,ParameterValue=md5,ApplyMethod=immediate" > /dev/null 2>&1 || true

# Create the database
dbinstclass="db.t3.micro"
dbstorage=20
dbpass=$(dd if=/dev/urandom bs=128 count=1 2>/dev/null| tr -dc _A-Z-a-z-0-9)
aws rds create-db-instance \
    --db-name invoicer \
    --db-instance-identifier "$identifier" \
    --vpc-security-group-ids "$dbsg" \
    --allocated-storage "$dbstorage" \
    --db-instance-class "$dbinstclass" \
    --engine postgres \
    --engine-version 16.13 \
    --auto-minor-version-upgrade \
    --publicly-accessible \
    --master-username invoicer \
    --master-user-password "$dbpass" \
    --db-parameter-group-name invoicer-pg16-no-ssl \
    --no-multi-az > tmp/$identifier/rds.json || fail
echo "RDS Postgres database is being created. username=invoicer; password='$dbpass'"

# Retrieve the database hostname
while true;
do
    aws rds describe-db-instances --db-instance-identifier $identifier > tmp/$identifier/rds.json
    dbhost=$(jq -r '.DBInstances[0].Endpoint.Address' tmp/$identifier/rds.json)
    if [ "$dbhost" != "null" ]; then break; fi
    echo -n '.'
    sleep 10
done
echo "dbhost=$dbhost"

# Reset the master password so it's stored as md5 (not scram-sha-256)
aws rds wait db-instance-available --db-instance-identifier "$identifier"
aws rds modify-db-instance \
    --db-instance-identifier "$identifier" \
    --master-user-password "$dbpass" \
    --apply-immediately > /dev/null || fail
aws rds wait db-instance-available --db-instance-identifier "$identifier"
echo "Master password re-encoded as md5"

# tagging rds instance
aws rds add-tags-to-resource \
    --resource-name $(jq -r '.DBInstances[0].DBInstanceArn' tmp/$identifier/rds.json) \
    --tags "Key=environment-name,Value=invoicer-api"
aws rds add-tags-to-resource \
    --resource-name $(jq -r '.DBInstances[0].DBInstanceArn' tmp/$identifier/rds.json) \
    --tags "Key=Owner,Value=$(whoami)"

# Ensure the EB instance profile exists
aws iam create-role --role-name aws-elasticbeanstalk-ec2-role \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' 2>/dev/null || true
aws iam attach-role-policy --role-name aws-elasticbeanstalk-ec2-role \
    --policy-arn arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier 2>/dev/null || true
aws iam create-instance-profile --instance-profile-name aws-elasticbeanstalk-ec2-role 2>/dev/null || true
aws iam add-role-to-instance-profile --instance-profile-name aws-elasticbeanstalk-ec2-role \
    --role-name aws-elasticbeanstalk-ec2-role 2>/dev/null || true
echo "Instance profile aws-elasticbeanstalk-ec2-role is ready"

# Create an elasticbeantalk application
aws elasticbeanstalk create-application \
    --application-name $identifier \
    --description "Invoicer $env $datetag" > tmp/$identifier/ebcreateapp.json || fail
echo "ElasticBeanTalk application created"

# Get the name of the latest Docker solution stack
dockerstack="$(aws elasticbeanstalk list-available-solution-stacks | \
    jq -r '.SolutionStacks[]' | grep -P '.+Amazon Linux.+running Docker' | head -1)"

# Create the EB API environment
sed "s/POSTGRESPASSREPLACEME/$dbpass/" ebs-options.json > tmp/$identifier/ebs-options.json || fail
sed -i "s/POSTGRESHOSTREPLACEME/$dbhost/" tmp/$identifier/ebs-options.json || fail
aws elasticbeanstalk create-environment \
    --application-name $identifier \
    --environment-name $identifier-invoicer-api \
    --description "Invoicer API environment" \
    --tags "Key=Owner,Value=$(whoami)" \
    --solution-stack-name "$dockerstack" \
    --option-settings file://tmp/$identifier/ebs-options.json \
    --tier "Name=WebServer,Type=Standard,Version=''" > tmp/$identifier/ebcreateapienv.json || fail
apieid=$(jq -r '.EnvironmentId' tmp/$identifier/ebcreateapienv.json)
echo "API environment $apieid is being created"

# grab the instance ID of the API environment, then its security group, and add that to the RDS security group
while true;
do
    # Check if the environment has failed
    envstatus=$(aws elasticbeanstalk describe-environments --environment-id $apieid \
        | jq -r '.Environments[0].Status')
    if [ "$envstatus" == "Terminated" ] || [ "$envstatus" == "Terminating" ]; then
        echo "Environment failed to launch"
        fail
    fi
    aws elasticbeanstalk describe-environment-resources --environment-id $apieid > tmp/$identifier/ebapidesc.json 2>/dev/null
    ec2id=$(jq -r '.EnvironmentResources.Instances[0].Id' tmp/$identifier/ebapidesc.json)
    if [ -n "$ec2id" ] && [ "$ec2id" != "null" ]; then break; fi
    echo -n '.'
    sleep 10
done
echo
aws ec2 wait instance-running --instance-ids $ec2id
aws ec2 describe-instances --instance-ids $ec2id > tmp/$identifier/${ec2id}.json || fail
sgid=$(jq -r '.Reservations[0].Instances[0].SecurityGroups[0].GroupId' tmp/$identifier/${ec2id}.json)
aws ec2 authorize-security-group-ingress --group-id $dbsg --source-group $sgid --protocol tcp --port 5432 || fail
echo "API security group $sgid authorized to connect to database security group $dbsg"

# Upload the application version
aws s3 mb s3://$identifier
aws s3 cp app-version.json s3://$identifier/
aws elasticbeanstalk create-application-version \
    --application-name "$identifier" \
    --version-label invoicer-api \
    --source-bundle "S3Bucket=$identifier,S3Key=app-version.json" > tmp/$identifier/app-version-s3.json

# Wait for the environment to be ready (green)
echo -n "waiting for environment"
while true; do
    aws elasticbeanstalk describe-environments --environment-id $apieid > tmp/$identifier/$apieid.json
    health="$(jq -r '.Environments[0].Health' tmp/$identifier/$apieid.json)"
    status="$(jq -r '.Environments[0].Status' tmp/$identifier/$apieid.json)"
    if [ "$health" == "Green" ] && [ "$status" == "Ready" ]; then break; fi
    echo -n '.'
    sleep 10
done
echo

# Deploy the docker container to the instances
aws elasticbeanstalk update-environment \
    --application-name $identifier \
    --environment-id $apieid \
    --version-label invoicer-api > tmp/$identifier/$apieid.json

url="$(jq -r '.CNAME' tmp/$identifier/$apieid.json)"
echo "Environment is being deployed. Public endpoint is http://$url"