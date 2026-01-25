import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as path from "path";
import * as events from "aws-cdk-lib/aws-events";
import * as targets from "aws-cdk-lib/aws-events-targets";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as iam from "aws-cdk-lib/aws-iam";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as lambdaNodejs from "aws-cdk-lib/aws-lambda-nodejs";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";

export function createDiscordNotifier(
  scope: Construct,
  instance: ec2.Instance,
  discordWebhookSecret: secretsmanager.ISecret
) {
  const notifyFn = new lambdaNodejs.NodejsFunction(scope, "NotifyDiscordOnStart", {
    runtime: lambda.Runtime.NODEJS_20_X,
    entry: path.join(__dirname, "..", "lambda", "notify-discord.ts"),
    handler: "handler",
    timeout: cdk.Duration.seconds(90),
    environment: {
      DISCORD_WEBHOOK_SECRET_ARN: discordWebhookSecret.secretArn,
      INSTANCE_ID: instance.instanceId,
      SERVER_PORT: "5520",
      MAX_WAIT_SECONDS: "45",
      POLL_SECONDS: "5",
    },
  });

  // Allow the notifier to look up the instance's public IP and status checks.
  // These "Describe*" actions do not support resource-level permissions, so resource must be "*".
  notifyFn.addToRolePolicy(
    new iam.PolicyStatement({
      actions: ["ec2:DescribeInstances", "ec2:DescribeInstanceStatus"],
      resources: ["*"],
    })
  );

  discordWebhookSecret.grantRead(notifyFn);

  const rule = new events.Rule(scope, "OnEc2Running", {
    description: "Notify Discord when the Hytale EC2 instance starts running",
    eventPattern: {
      source: ["aws.ec2"],
      detailType: ["EC2 Instance State-change Notification"],
      detail: { "instance-id": [instance.instanceId], state: ["running"] },
    },
  });

  rule.addTarget(new targets.LambdaFunction(notifyFn));
}

