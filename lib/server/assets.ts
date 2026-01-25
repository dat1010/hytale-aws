import { Construct } from "constructs";
import * as path from "path";
import * as s3assets from "aws-cdk-lib/aws-s3-assets";

export function createDownloaderAsset(scope: Construct): s3assets.Asset {
  // Local zip -> CDK Asset (uploaded automatically during deploy)
  // Put your file at: assets/hytale-game.zip
  return new s3assets.Asset(scope, "HytaleDownloaderZip", {
    path: path.join(__dirname, "..", "..", "assets", "hytale-game.zip"),
  });
}

export function createBootstrapAsset(scope: Construct): s3assets.Asset {
  // This directory is uploaded as a zip asset during deploy.
  // We keep EC2 UserData tiny to avoid the EC2 user-data size limit.
  return new s3assets.Asset(scope, "HytaleBootstrap", {
    path: path.join(__dirname, "..", "..", "assets", "bootstrap"),
  });
}

