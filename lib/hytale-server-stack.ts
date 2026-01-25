import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as path from "path";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as iam from "aws-cdk-lib/aws-iam";
import * as events from "aws-cdk-lib/aws-events";
import * as targets from "aws-cdk-lib/aws-events-targets";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as lambdaNodejs from "aws-cdk-lib/aws-lambda-nodejs";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";
import * as s3assets from "aws-cdk-lib/aws-s3-assets";
import * as s3 from "aws-cdk-lib/aws-s3";

const HYTALE_UDP_PORT = 5520;

type NetworkResources = {
  vpc: ec2.Vpc;
  sg: ec2.SecurityGroup;
};

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
    });

    new cdk.CfnOutput(this, "InstanceId", { value: instance.instanceId });
    new cdk.CfnOutput(this, "PublicIp", { value: instance.instancePublicIp });
    new cdk.CfnOutput(this, "BackupsBucketName", { value: props.backupBucket.bucketName });
  }
}

function createVpcAndSecurityGroup(scope: Construct, allowedCidr: string): NetworkResources {
  const vpc = new ec2.Vpc(scope, "HytaleVpc", {
    maxAzs: 2,
    natGateways: 0,
    subnetConfiguration: [{ name: "public", subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 }],
  });

  const sg = new ec2.SecurityGroup(scope, "HytaleSg", {
    vpc,
    description: "Security group for Hytale dedicated server",
    allowAllOutbound: true,
  });

  // Hytale default: UDP 5520
  sg.addIngressRule(ec2.Peer.ipv4(allowedCidr), ec2.Port.udp(HYTALE_UDP_PORT), "Hytale UDP 5520");

  return { vpc, sg };
}

function createInstanceRole(scope: Construct): iam.Role {
  const role = new iam.Role(scope, "HytaleInstanceRole", {
    assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
  });

  role.addManagedPolicy(
    iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonSSMManagedInstanceCore")
  );

  return role;
}

function createDownloaderAsset(scope: Construct): s3assets.Asset {
  // Local zip -> CDK Asset (uploaded automatically during deploy)
  // Put your file at: assets/hytale-game.zip
  return new s3assets.Asset(scope, "HytaleDownloaderZip", {
    path: path.join(__dirname, "..", "assets", "hytale-game.zip"),
  });
}

function createBootstrapAsset(scope: Construct): s3assets.Asset {
  // This directory is uploaded as a zip asset during deploy.
  // We keep EC2 UserData tiny to avoid the EC2 user-data size limit.
  return new s3assets.Asset(scope, "HytaleBootstrap", {
    path: path.join(__dirname, "..", "assets", "bootstrap"),
  });
}

function createInstance(
  scope: Construct,
  vpc: ec2.Vpc,
  sg: ec2.SecurityGroup,
  role: iam.Role
): ec2.Instance {
  return new ec2.Instance(scope, "HytaleInstance", {
    vpc,
    vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
    securityGroup: sg,
    role,
    instanceType: ec2.InstanceType.of(ec2.InstanceClass.T3A, ec2.InstanceSize.LARGE), // 2 vCPU / 8 GiB
    machineImage: ec2.MachineImage.latestAmazonLinux2023({
      cpuType: ec2.AmazonLinuxCpuType.X86_64,
    }),
    blockDevices: [
      {
        deviceName: "/dev/xvda",
        volume: ec2.BlockDeviceVolume.ebs(16, {
          encrypted: true,
          volumeType: ec2.EbsDeviceVolumeType.GP3,
        }),
      },
      {
        deviceName: "/dev/xvdb",
        volume: ec2.BlockDeviceVolume.ebs(30, {
          encrypted: true,
          volumeType: ec2.EbsDeviceVolumeType.GP3,
        }),
      },
    ],
  });
}

function addHytaleUserData(
  instance: ec2.Instance,
  opts: {
    bootstrapAsset: s3assets.Asset;
    downloaderZipAsset: s3assets.Asset;
    backupBucketName: string;
    discordWebhookSecretArn?: string;
  }
) {
  // Keep EC2 user-data tiny (EC2 has a small size limit for user-data).
  const commands = [
    "exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1",
    "set -euxo pipefail",
    "dnf install -y --allowerasing awscli unzip",
    "mkdir -p /var/tmp/hytale-bootstrap",
    `aws s3 cp s3://${opts.bootstrapAsset.s3BucketName}/${opts.bootstrapAsset.s3ObjectKey} /var/tmp/hytale-bootstrap/bootstrap.zip`,
    "unzip -o /var/tmp/hytale-bootstrap/bootstrap.zip -d /var/tmp/hytale-bootstrap",
    "chmod +x /var/tmp/hytale-bootstrap/bootstrap.sh",
    [
      `DOWNLOADER_ASSET_BUCKET="${opts.downloaderZipAsset.s3BucketName}"`,
      `DOWNLOADER_ASSET_KEY="${opts.downloaderZipAsset.s3ObjectKey}"`,
      `BACKUP_BUCKET_NAME="${opts.backupBucketName}"`,
      `DISCORD_WEBHOOK_SECRET_ARN="${opts.discordWebhookSecretArn ?? ""}"`,
      "bash /var/tmp/hytale-bootstrap/bootstrap.sh",
    ].join(" "),
  ];

  instance.userData.addCommands(...commands);
}

function createDiscordNotifier(
  scope: Construct,
  instance: ec2.Instance,
  discordWebhookSecret: secretsmanager.ISecret
) {
  const notifyFn = new lambdaNodejs.NodejsFunction(scope, "NotifyDiscordOnStart", {
    runtime: lambda.Runtime.NODEJS_20_X,
    entry: path.join(__dirname, "lambda", "notify-discord.ts"),
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

function getBooleanContext(scope: Construct, key: string, defaultValue: boolean): boolean {
  const raw = scope.node.tryGetContext(key);
  if (raw === undefined || raw === null) return defaultValue;
  if (typeof raw === "boolean") return raw;
  if (typeof raw === "string") {
    const s = raw.trim().toLowerCase();
    if (["1", "true", "yes", "y", "on"].includes(s)) return true;
    if (["0", "false", "no", "n", "off"].includes(s)) return false;
  }
  // Fall back to default to avoid surprising synth errors.
  return defaultValue;
}

