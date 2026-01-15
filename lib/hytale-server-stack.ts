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

export class HytaleServerStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const allowedCidr = new cdk.CfnParameter(this, "AllowedCidr", {
      type: "String",
      default: "0.0.0.0/0",
      description:
        "CIDR block allowed to connect to the Hytale server UDP port (e.g., your IP /32).",

    });

    const vpc = new ec2.Vpc(this, "HytaleVpc", {
      maxAzs: 2,
      natGateways: 0,
      subnetConfiguration: [
        { name: "public", subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 },
      ],
    });


    const sg = new ec2.SecurityGroup(this, "HytaleSg", {
      vpc,
      description: "Security group for Hytale dedicated server",
      allowAllOutbound: true,
    });

    // Hytale default: UDP 5520
    sg.addIngressRule(

      ec2.Peer.ipv4(allowedCidr.valueAsString),

      ec2.Port.udp(5520),
      "Hytale UDP 5520"
    );

    const role = new iam.Role(this, "HytaleInstanceRole", {
      assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
    });


    role.addManagedPolicy(
      iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonSSMManagedInstanceCore")
    );

    // Local zip -> CDK Asset (uploaded automatically during deploy)
    // Put your file at: assets/hytale-game.zip
    const downloaderZipAsset = new s3assets.Asset(this, "HytaleDownloaderZip", {
      path: path.join(__dirname, "..", "assets", "hytale-game.zip"),
    });

    const instance = new ec2.Instance(this, "HytaleInstance", {
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
      securityGroup: sg,
      role,
      instanceType: ec2.InstanceType.of(
        ec2.InstanceClass.T3A,
        ec2.InstanceSize.MEDIUM
      ), // 2 vCPU / 4 GiB
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

    downloaderZipAsset.grantRead(instance.role);

    // ----------------------------
    // UserData - full automation
    // ----------------------------
    instance.userData.addCommands(
      // Log user-data for easy debugging
      "exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1",
      "set -euxo pipefail",

      // tools
      "dnf install -y --allowerasing curl-minimal unzip tar rsync",

      // Mount /dev/xvdb at /opt/hytale
      "if ! file -s /dev/xvdb | grep -q ext4; then mkfs -t ext4 /dev/xvdb; fi",
      "mkdir -p /opt/hytale",
      "grep -q '^/dev/xvdb /opt/hytale ' /etc/fstab || echo '/dev/xvdb /opt/hytale ext4 defaults,nofail 0 2' >> /etc/fstab",
      "mount -a",

      // Java 25
      "rpm --import https://yum.corretto.aws/corretto.key",
      "curl -fsSL https://yum.corretto.aws/corretto.repo -o /etc/yum.repos.d/corretto.repo",
      "dnf clean all",

      "dnf install -y java-25-amazon-corretto-headless",


      // User + dirs
      "useradd -r -m -d /opt/hytale -s /sbin/nologin hytale || true",
      "mkdir -p /opt/hytale/downloader /opt/hytale/server /opt/hytale/game /opt/hytale/logs /opt/hytale/tmp /opt/hytale/bin",
      "chown -R hytale:hytale /opt/hytale",

      // Pull the downloader zip asset to the instance
      `aws s3 cp s3://${downloaderZipAsset.s3BucketName}/${downloaderZipAsset.s3ObjectKey} /opt/hytale/tmp/hytale-downloader.zip`,
      "unzip -o /opt/hytale/tmp/hytale-downloader.zip -d /opt/hytale/downloader",


      // Normalize linux downloader binary name + perms
      "test -f /opt/hytale/downloader/hytale-downloader-linux-amd64",
      "cp -f /opt/hytale/downloader/hytale-downloader-linux-amd64 /opt/hytale/downloader/hytale-downloader",
      "chmod +x /opt/hytale/downloader/hytale-downloader",
      "chown -R hytale:hytale /opt/hytale/downloader",

      // ---- updater script ----
      // IMPORTANT: this DOES NOT wipe /opt/hytale/server if it already exists

      "cat > /opt/hytale/bin/hytale-update.sh << 'EOF'\n" +
        "#!/usr/bin/env bash\n" +

        "set -euxo pipefail\n" +
        "\n" +
        "LOG=/opt/hytale/logs/hytale-update.log\n" +
        "exec >> \"$LOG\" 2>&1\n" +
        "\n" +
        "echo \"==== $(date -u) Starting hytale update ====\"\n" +
        "\n" +

        "# If the server is already installed, do nothing.\n" +
        "# This is the key thing that makes stop/start user-friendly.\n" +
        "if [ -f /opt/hytale/server/Server/HytaleServer.jar ] && [ -f /opt/hytale/server/Assets.zip ]; then\n" +
        "  echo \"Server already installed. Skipping update to preserve persistence/auth files.\"\n" +
        "  echo \"==== $(date -u) Update skipped ====\"\n" +
        "  exit 0\n" +
        "fi\n" +
        "\n" +
        "mkdir -p /opt/hytale/game /opt/hytale/tmp/extracted\n" +
        "chown -R hytale:hytale /opt/hytale\n" +
        "\n" +
        "# Download game.zip using the downloader.\n" +
        "# NOTE: this may require device auth the very first time.\n" +

        "# We set HOME=/opt/hytale so creds persist on disk.\n" +
        "runuser -u hytale -- env HOME=/opt/hytale bash -lc '\n" +
        "  cd /opt/hytale/downloader && ./hytale-downloader \\\n" +
        "    -skip-update-check \\\n" +
        "    -patchline release \\\n" +
        "    -download-path /opt/hytale/game/game.zip'\n" +
        "\n" +
        "test -f /opt/hytale/game/game.zip\n" +

        "\n" +
        "rm -rf /opt/hytale/tmp/extracted\n" +

        "mkdir -p /opt/hytale/tmp/extracted\n" +
        "unzip -o /opt/hytale/game/game.zip -d /opt/hytale/tmp/extracted\n" +
        "\n" +
        "test -d /opt/hytale/tmp/extracted/Server\n" +
        "test -f /opt/hytale/tmp/extracted/Assets.zip\n" +
        "\n" +
        "mkdir -p /opt/hytale/server/Server\n" +
        "rsync -a /opt/hytale/tmp/extracted/Server/ /opt/hytale/server/Server/\n" +
        "cp -f /opt/hytale/tmp/extracted/Assets.zip /opt/hytale/server/Assets.zip\n" +
        "chown -R hytale:hytale /opt/hytale/server /opt/hytale/game\n" +
        "\n" +
        "echo \"==== $(date -u) Update complete ====\"\n" +
        "EOF",

      "chmod +x /opt/hytale/bin/hytale-update.sh",

      // ---- systemd: update service ----
      // Runs on boot ONLY if server isn't installed yet
      "cat > /etc/systemd/system/hytale-update.service << 'EOF'\n" +
        "[Unit]\n" +
        "Description=Hytale Update (Downloader + Extract)\n" +
        "After=network-online.target\n" +

        "Wants=network-online.target\n" +
        "\n" +
        "# Only run update if server is NOT installed yet\n" +
        "ConditionPathExists=!/opt/hytale/server/Server/HytaleServer.jar\n" +
        "\n" +
        "[Service]\n" +
        "Type=oneshot\n" +
        "TimeoutStartSec=0\n" +
        "ExecStart=/opt/hytale/bin/hytale-update.sh\n" +
        "RemainAfterExit=yes\n" +
        "\n" +

        "[Install]\n" +
        "WantedBy=multi-user.target\n" +
        "EOF",

      // ---- systemd: server service ----
      // Starts every boot. Wants the updater to run first if needed.
      "cat > /etc/systemd/system/hytale.service << 'EOF'\n" +

        "[Unit]\n" +
        "Description=Hytale Dedicated Server\n" +
        "After=network-online.target hytale-update.service\n" +
        "Wants=network-online.target hytale-update.service\n" +
        "\n" +
        "[Service]\n" +
        "Type=simple\n" +
        "User=hytale\n" +
        "WorkingDirectory=/opt/hytale/server/Server\n" +
        "\n" +
        "# Wait until server files exist (prevents bad boots)\n" +
        "ExecStartPre=/usr/bin/test -f /opt/hytale/server/Server/HytaleServer.jar\n" +
        "ExecStartPre=/usr/bin/test -f /opt/hytale/server/Assets.zip\n" +
        "\n" +
        "ExecStart=/usr/bin/java -Xms2G -Xmx3G -jar HytaleServer.jar --assets /opt/hytale/server/Assets.zip\n" +
        "Restart=on-failure\n" +
        "RestartSec=5\n" +
        "LimitNOFILE=65535\n" +
        "\n" +
        "[Install]\n" +
        "WantedBy=multi-user.target\n" +
        "EOF",

      "systemctl daemon-reload",
      "systemctl enable hytale-update.service hytale.service",


      // Start updater (only runs if missing files), then server
      "systemctl start hytale-update.service || true",
      "systemctl start hytale.service || true"
    );

    // Discord webhook secret (optional)
    // Set its value using the `DiscordWebhookSecretArn` stack output + `aws secretsmanager put-secret-value`.
    const discordWebhookSecret = new secretsmanager.Secret(this, "DiscordWebhookUrl", {
      description: "Discord webhook URL for Hytale server notifications",
    });

    const notifyFn = new lambdaNodejs.NodejsFunction(this, "NotifyDiscordOnStart", {
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

    const rule = new events.Rule(this, "OnEc2Running", {
      description: "Notify Discord when the Hytale EC2 instance starts running",
      eventPattern: {
        source: ["aws.ec2"],
        detailType: ["EC2 Instance State-change Notification"],
        detail: { "instance-id": [instance.instanceId], state: ["running"] },
      },
    });

    rule.addTarget(new targets.LambdaFunction(notifyFn));

    new cdk.CfnOutput(this, "InstanceId", { value: instance.instanceId });
    new cdk.CfnOutput(this, "PublicIp", { value: instance.instancePublicIp });
    new cdk.CfnOutput(this, "DiscordWebhookSecretArn", { value: discordWebhookSecret.secretArn });
  }
}

