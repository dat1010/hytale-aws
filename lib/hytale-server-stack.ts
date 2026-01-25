import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as iam from "aws-cdk-lib/aws-iam";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";
import * as s3 from "aws-cdk-lib/aws-s3";

import { getBooleanContext } from "./server/config";
import { createVpcAndSecurityGroup } from "./server/network";
import { createDownloaderAsset, createBootstrapAsset } from "./server/assets";
import { createInstanceRole, createInstance, DATA_VOLUME_SIZE_GIB } from "./server/instance";
import { addHytaleUserData } from "./server/userdata";
import { createDiscordNotifier } from "./server/discord";

export type HytaleServerStackProps = cdk.StackProps & {
  /**
   * S3 bucket where Hytale server backups are uploaded.
   * Create this in a dedicated stack so it can outlive the server stack.
   */
  backupBucket: s3.IBucket;
};

export class HytaleServerStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: HytaleServerStackProps) {
    super(scope, id, props);

    // Discord integration is optional. Default: enabled (recommended).
    // Disable with: `npx cdk deploy -c discordEnabled=false`
    const discordEnabled = getBooleanContext(this, "discordEnabled", true);

    // Optional: provide the webhook at deploy time.
    // NOTE: This uses a CloudFormation NoEcho parameter, so you can pass it from `.envrc` without
    // needing a post-deploy `put-secret-value` step.
    const discordWebhookUrlParam = new cdk.CfnParameter(this, "DiscordWebhookUrl", {
      type: "String",
      default: "null",
      noEcho: true,
      description:
        "Discord webhook URL for notifications/auth links. Leave as 'null' to disable Discord posting.",
    });

    const allowedCidr = new cdk.CfnParameter(this, "AllowedCidr", {
      type: "String",
      default: "0.0.0.0/0",
      description:
        "CIDR block allowed to connect to the Hytale server UDP port (e.g., your IP /32).",
    });

    const { vpc, sg } = createVpcAndSecurityGroup(this, allowedCidr.valueAsString);
    const role = createInstanceRole(this);
    const downloaderZipAsset = createDownloaderAsset(this);
    const bootstrapAsset = createBootstrapAsset(this);
    const instance = createInstance(this, vpc, sg, role);

    let discordWebhookSecretArn: string | undefined;
    if (discordEnabled) {
      // Discord webhook secret (optional).
      // If left unset, Discord notifications/auth messages are simply skipped.
      // IMPORTANT: this construct ID must not collide with the `DiscordWebhookUrl` parameter above.
      const discordWebhookSecret = new secretsmanager.Secret(this, "DiscordWebhookSecret", {
        description: "Discord webhook URL for Hytale server notifications",
        secretStringValue: cdk.SecretValue.cfnParameter(discordWebhookUrlParam),
      });
      discordWebhookSecretArn = discordWebhookSecret.secretArn;

      // Allow the instance to read the webhook so it can post auth URLs during bootstrap.
      discordWebhookSecret.grantRead(instance.role);
      instance.role.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
          resources: [discordWebhookSecret.secretArn],
        })
      );

      createDiscordNotifier(this, instance, discordWebhookSecret);
      new cdk.CfnOutput(this, "DiscordWebhookSecretArn", { value: discordWebhookSecret.secretArn });
    }

    // Allow instance to upload backups to S3.
    // `aws s3 sync` requires ListBucket + GetBucketLocation on the bucket, plus PutObject on objects.
    // Restore support also requires GetObject on objects (S3 uses HeadObject under the hood).
    props.backupBucket.grantPut(instance.role);
    props.backupBucket.grantRead(instance.role);
    instance.role.addToPrincipalPolicy(
      new iam.PolicyStatement({
        actions: ["s3:ListBucket", "s3:GetBucketLocation"],
        resources: [props.backupBucket.bucketArn],
      })
    );

    downloaderZipAsset.grantRead(instance.role);
    bootstrapAsset.grantRead(instance.role);
    addHytaleUserData(instance, {
      bootstrapAsset,
      downloaderZipAsset,
      backupBucketName: props.backupBucket.bucketName,
      discordWebhookSecretArn,
      dataVolumeSizeGib: DATA_VOLUME_SIZE_GIB,
    });

    new cdk.CfnOutput(this, "InstanceId", { value: instance.instanceId });
    new cdk.CfnOutput(this, "PublicIp", { value: instance.instancePublicIp });
    new cdk.CfnOutput(this, "BackupsBucketName", { value: props.backupBucket.bucketName });
  }
}
