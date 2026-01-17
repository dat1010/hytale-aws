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
const HYTALE_BACKUP_DIR = "/opt/hytale/backups";
const HYTALE_BACKUP_FREQUENCY_MINUTES = 30;
const S3_SYNC_FREQUENCY_MINUTES = 30;
const S3_KEEP_LATEST_BACKUPS = 5;
const S3_BACKUP_PREFIX = "hytale/backups/";

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

    const allowedCidr = new cdk.CfnParameter(this, "AllowedCidr", {
      type: "String",
      default: "0.0.0.0/0",
      description:
        "CIDR block allowed to connect to the Hytale server UDP port (e.g., your IP /32).",
    });

    const { vpc, sg } = createVpcAndSecurityGroup(this, allowedCidr.valueAsString);
    const role = createInstanceRole(this);
    const downloaderZipAsset = createDownloaderAsset(this);
    const instance = createInstance(this, vpc, sg, role);

    // Allow instance to upload backups to S3.
    // `aws s3 sync` requires ListBucket + GetBucketLocation on the bucket, plus PutObject on objects.
    props.backupBucket.grantPut(instance.role);
    instance.role.addToPrincipalPolicy(
      new iam.PolicyStatement({
        actions: ["s3:ListBucket", "s3:GetBucketLocation"],
        resources: [props.backupBucket.bucketArn],
      })
    );

    downloaderZipAsset.grantRead(instance.role);
    addHytaleUserData(instance, downloaderZipAsset, props.backupBucket.bucketName);
    createDiscordNotifier(this, instance);

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
    instanceType: ec2.InstanceType.of(ec2.InstanceClass.T3A, ec2.InstanceSize.LARGE), // 2 vCPU / 4 GiB
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
  downloaderZipAsset: s3assets.Asset,
  backupBucketName: string
) {
  // ----------------------------
  // UserData - full automation
  // ----------------------------
  // Split into logical groups for readability. Keep command strings and ordering identical.
  const loggingAndSafety = [
    // Log user-data for easy debugging
    "exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1",
    "set -euxo pipefail",
  ];

  const tools = [
    // tools
    "dnf install -y --allowerasing curl-minimal unzip tar rsync awscli python3",
  ];

  const mountDataVolume = [
    // Mount /dev/xvdb at /opt/hytale
    "if ! file -s /dev/xvdb | grep -q ext4; then mkfs -t ext4 /dev/xvdb; fi",
    "mkdir -p /opt/hytale",
    "grep -q '^/dev/xvdb /opt/hytale ' /etc/fstab || echo '/dev/xvdb /opt/hytale ext4 defaults,nofail 0 2' >> /etc/fstab",
    "mount -a",
  ];

  const java = [
    // Java 25
    "rpm --import https://yum.corretto.aws/corretto.key",
    "curl -fsSL https://yum.corretto.aws/corretto.repo -o /etc/yum.repos.d/corretto.repo",
    "dnf clean all",
    "dnf install -y java-25-amazon-corretto-headless",
  ];

  const userAndDirs = [
    // User + dirs
    "useradd -r -m -d /opt/hytale -s /sbin/nologin hytale || true",
    `mkdir -p /opt/hytale/downloader /opt/hytale/server /opt/hytale/game /opt/hytale/logs /opt/hytale/tmp /opt/hytale/bin ${HYTALE_BACKUP_DIR}`,
    "chown -R hytale:hytale /opt/hytale",
  ];

  const downloadAndInstallDownloader = [
    // Pull the downloader zip asset to the instance
    `aws s3 cp s3://${downloaderZipAsset.s3BucketName}/${downloaderZipAsset.s3ObjectKey} /opt/hytale/tmp/hytale-downloader.zip`,
    "unzip -o /opt/hytale/tmp/hytale-downloader.zip -d /opt/hytale/downloader",

    // Normalize linux downloader binary name + perms
    "test -f /opt/hytale/downloader/hytale-downloader-linux-amd64",
    "cp -f /opt/hytale/downloader/hytale-downloader-linux-amd64 /opt/hytale/downloader/hytale-downloader",
    "chmod +x /opt/hytale/downloader/hytale-downloader",
    "chown -R hytale:hytale /opt/hytale/downloader",
  ];

  const updaterScript = [
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
  ];

  const systemdUnitsAndStart = [
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
      "ExecStart=/usr/bin/java -Xms2G -Xmx3G -jar HytaleServer.jar --assets /opt/hytale/server/Assets.zip --backup --backup-dir " +
      HYTALE_BACKUP_DIR +
      " --backup-frequency " +
      HYTALE_BACKUP_FREQUENCY_MINUTES +
      "\n" +
      "Restart=on-failure\n" +
      "RestartSec=5\n" +
      "LimitNOFILE=65535\n" +
      "\n" +
      "[Install]\n" +
      "WantedBy=multi-user.target\n" +
      "EOF",

    // ---- backup sync script + timer ----
    "cat > /opt/hytale/bin/hytale-backup-sync.sh << 'EOF'\n" +
      "#!/usr/bin/env bash\n" +
      "set -euo pipefail\n" +
      "\n" +
      "SRC=\"" +
      HYTALE_BACKUP_DIR +
      "\"\n" +
      "DEST_BUCKET=\"" +
      backupBucketName +
      "\"\n" +
      "DEST_PREFIX=\"" +
      S3_BACKUP_PREFIX +
      "\"\n" +
      "KEEP_LATEST=" +
      S3_KEEP_LATEST_BACKUPS +
      "\n" +
      "\n" +
      "if [ ! -d \"$SRC\" ]; then\n" +
      "  exit 0\n" +
      "fi\n" +
      "\n" +
      "# Determine region via IMDSv2 (no local aws config needed)\n" +
      "TOKEN=$(curl -sS -X PUT \"http://169.254.169.254/latest/api/token\" -H \"X-aws-ec2-metadata-token-ttl-seconds: 21600\")\n" +
      "DOC=$(curl -sS -H \"X-aws-ec2-metadata-token: $TOKEN\" \"http://169.254.169.254/latest/dynamic/instance-identity/document\")\n" +
      "REGION=$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())[\"region\"])' <<<\"$DOC\")\n" +
      "export DEST_BUCKET DEST_PREFIX KEEP_LATEST REGION\n" +
      "\n" +
      "# Upload backups (no --delete: keep historical backups in S3)\n" +
      "aws --region \"$REGION\" s3 sync \"$SRC\" \"s3://$DEST_BUCKET/$DEST_PREFIX\" --only-show-errors\n" +
      "\n" +
      "# Prune S3 to keep only the latest N backups by *backup name*.\n" +
      "# We group objects by the first path component after DEST_PREFIX (handles backups as files or folders).\n" +
      "python3 - <<'PY'\n" +
      "import json\n" +
      "import os\n" +
      "import subprocess\n" +
      "from collections import defaultdict\n" +
      "\n" +
      "bucket = os.environ.get('DEST_BUCKET')\n" +
      "prefix = os.environ.get('DEST_PREFIX', '')\n" +
      "keep = int(os.environ.get('KEEP_LATEST', '5'))\n" +
      "region = os.environ.get('REGION')\n" +
      "\n" +
      "if not bucket or keep <= 0:\n" +
      "    raise SystemExit(0)\n" +
      "\n" +
      "cmd = ['aws', '--region', region, 's3api', 'list-objects-v2', '--bucket', bucket, '--prefix', prefix, '--output', 'json']\n" +
      "raw = subprocess.check_output(cmd)\n" +
      "data = json.loads(raw)\n" +
      "objs = data.get('Contents', []) or []\n" +
      "if not objs:\n" +
      "    raise SystemExit(0)\n" +
      "\n" +
      "groups = defaultdict(list)\n" +
      "for o in objs:\n" +
      "    key = o.get('Key', '')\n" +
      "    if not key or not key.startswith(prefix):\n" +
      "        continue\n" +
      "    rest = key[len(prefix):]\n" +
      "    if not rest:\n" +
      "        continue\n" +
      "    group = rest.split('/', 1)[0]\n" +
      "    if not group:\n" +
      "        continue\n" +
      "    groups[group].append(o)\n" +
      "\n" +
      "ranked = []\n" +
      "for group, items in groups.items():\n" +
      "    # LastModified is ISO8601-ish; lexicographic compare works.\n" +
      "    latest = max(i.get('LastModified', '') for i in items)\n" +
      "    ranked.append((latest, group))\n" +
      "ranked.sort(reverse=True)\n" +
      "\n" +
      "keep_groups = {g for _, g in ranked[:keep]}\n" +
      "delete_keys = []\n" +
      "for group, items in groups.items():\n" +
      "    if group in keep_groups:\n" +
      "        continue\n" +
      "    for i in items:\n" +
      "        k = i.get('Key')\n" +
      "        if k:\n" +
      "            delete_keys.append(k)\n" +
      "\n" +
      "if not delete_keys:\n" +
      "    raise SystemExit(0)\n" +
      "\n" +
      "# delete-objects supports up to 1000 keys per request\n" +
      "for start in range(0, len(delete_keys), 1000):\n" +
      "    chunk = delete_keys[start:start+1000]\n" +
      "    payload = {'Objects': [{'Key': k} for k in chunk], 'Quiet': True}\n" +
      "    subprocess.check_call([\n" +
      "        'aws', '--region', region, 's3api', 'delete-objects', '--bucket', bucket, '--delete', json.dumps(payload)\n" +
      "    ])\n" +
      "PY\n" +
      "EOF",
    "chmod +x /opt/hytale/bin/hytale-backup-sync.sh",

    "cat > /etc/systemd/system/hytale-backup-sync.service << 'EOF'\n" +
      "[Unit]\n" +
      "Description=Sync Hytale backups to S3\n" +
      "After=network-online.target\n" +
      "Wants=network-online.target\n" +
      "\n" +
      "[Service]\n" +
      "Type=oneshot\n" +
      "ExecStart=/opt/hytale/bin/hytale-backup-sync.sh\n" +
      "EOF",

    "cat > /etc/systemd/system/hytale-backup-sync.timer << 'EOF'\n" +
      "[Unit]\n" +
      "Description=Periodic Hytale backup upload to S3\n" +
      "\n" +
      "[Timer]\n" +
      "OnBootSec=10min\n" +
      "OnUnitActiveSec=" +
      S3_SYNC_FREQUENCY_MINUTES +
      "min\n" +
      "Persistent=true\n" +
      "\n" +
      "[Install]\n" +
      "WantedBy=timers.target\n" +
      "EOF",

    "systemctl daemon-reload",
    "systemctl enable hytale-update.service hytale.service hytale-backup-sync.timer",

    // Start updater (only runs if missing files), then server
    "systemctl start hytale-update.service || true",
    "systemctl start hytale.service || true",
    "systemctl start hytale-backup-sync.timer || true",
  ];

  const commands = [
    ...loggingAndSafety,
    ...tools,
    ...mountDataVolume,
    ...java,
    ...userAndDirs,
    ...downloadAndInstallDownloader,
    ...updaterScript,
    ...systemdUnitsAndStart,
  ];

  instance.userData.addCommands(...commands);
}

function createDiscordNotifier(scope: Construct, instance: ec2.Instance) {
  // Discord webhook secret (optional)
  // Set its value using the `DiscordWebhookSecretArn` stack output + `aws secretsmanager put-secret-value`.
  const discordWebhookSecret = new secretsmanager.Secret(scope, "DiscordWebhookUrl", {
    description: "Discord webhook URL for Hytale server notifications",
  });

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

  new cdk.CfnOutput(scope, "InstanceId", { value: instance.instanceId });
  new cdk.CfnOutput(scope, "PublicIp", { value: instance.instancePublicIp });
  new cdk.CfnOutput(scope, "DiscordWebhookSecretArn", { value: discordWebhookSecret.secretArn });
}

