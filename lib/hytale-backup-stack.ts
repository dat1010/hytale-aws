import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as backup from "aws-cdk-lib/aws-backup";
import * as events from "aws-cdk-lib/aws-events";

const BACKUP_TAG_KEY = "Backup";
const BACKUP_TAG_VALUE = "Hytale";

export class HytaleBackupStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // Backups must survive `cdk destroy`, so retain the vault.
    const vault = new backup.BackupVault(this, "HytaleBackupVault", {
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // A simple daily rule. Cron is in UTC.
    const plan = new backup.BackupPlan(this, "HytaleBackupPlan", {
      backupVault: vault,
    });

    plan.addRule(
      new backup.BackupPlanRule({
        scheduleExpression: events.Schedule.cron({ minute: "0", hour: "5" }),
        deleteAfter: cdk.Duration.days(30),
      })
    );

    // Tag-based selection: any supported resource tagged Backup=Hytale will be protected.
    // In `HytaleServerStack`, we tag the EC2 instance and propagate tags to EBS volumes.
    plan.addSelection("HytaleSelectionByTag", {
      resources: [backup.BackupResource.fromTag(BACKUP_TAG_KEY, BACKUP_TAG_VALUE)],
    });

    new cdk.CfnOutput(this, "BackupVaultName", { value: vault.backupVaultName });
    new cdk.CfnOutput(this, "BackupPlanId", { value: plan.backupPlanId });
  }
}

