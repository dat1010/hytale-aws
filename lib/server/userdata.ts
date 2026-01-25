import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as s3assets from "aws-cdk-lib/aws-s3-assets";

export function addHytaleUserData(
  instance: ec2.Instance,
  opts: {
    bootstrapAsset: s3assets.Asset;
    downloaderZipAsset: s3assets.Asset;
    backupBucketName: string;
    discordWebhookSecretArn?: string;
    dataVolumeSizeGib?: number;
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
      `DATA_VOLUME_SIZE_GIB="${opts.dataVolumeSizeGib ?? ""}"`,
      "bash /var/tmp/hytale-bootstrap/bootstrap.sh",
    ].join(" "),
  ];

  instance.userData.addCommands(...commands);
}

