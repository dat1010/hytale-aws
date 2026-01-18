import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as s3 from "aws-cdk-lib/aws-s3";

export class HytaleDataStack extends cdk.Stack {
  public readonly backupBucket: s3.Bucket;

  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // Backups should survive `cdk destroy` of the server stack, so keep these in a dedicated stack.
    this.backupBucket = new s3.Bucket(this, "HytaleBackupsBucket", {
      // Keep bucket and its contents by default.
      removalPolicy: cdk.RemovalPolicy.RETAIN,

      // Security defaults.
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      encryption: s3.BucketEncryption.S3_MANAGED,

      // Safety: avoid accidental deletes from CDK.
      autoDeleteObjects: false,

      // NOTE: S3 lifecycle rules can't keep "last N backups by count".
      // We prune to the latest N backups via the instance sync job instead.
    });

    new cdk.CfnOutput(this, "BackupsBucketName", { value: this.backupBucket.bucketName });
  }
}
