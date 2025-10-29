import boto3
import os

ec2 = boto3.client('ec2')

def lambda_handler(event, context):
    action = event.get('action', 'stop')
    tag_key = os.environ.get('TAG_KEY', 'AutoStop')
    tag_value = os.environ.get('TAG_VALUE', 'true')
    
    # Find instances with the specified tag
    response = ec2.describe_instances(
        Filters=[
            {'Name': f'tag:{tag_key}', 'Values': [tag_value]},
            {'Name': 'instance-state-name', 'Values': ['running', 'stopped']}
        ]
    )
    
    instance_ids = []
    for reservation in response['Reservations']:
        for instance in reservation['Instances']:
            instance_ids.append(instance['InstanceId'])
    
    if not instance_ids:
        print(f"No instances found with tag {tag_key}={tag_value}")
        return {
            'statusCode': 200,
            'body': f'No instances found with tag {tag_key}={tag_value}'
        }
    
    if action == 'stop':
        print(f"Stopping instances: {instance_ids}")
        ec2.stop_instances(InstanceIds=instance_ids)
        return {
            'statusCode': 200,
            'body': f'Stopped instances: {instance_ids}'
        }
    elif action == 'start':
        print(f"Starting instances: {instance_ids}")
        ec2.start_instances(InstanceIds=instance_ids)
        return {
            'statusCode': 200,
            'body': f'Started instances: {instance_ids}'
        }
    else:
        return {
            'statusCode': 400,
            'body': f'Invalid action: {action}'
        }
