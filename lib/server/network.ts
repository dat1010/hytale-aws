import { Construct } from "constructs";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import { HYTALE_UDP_PORT } from "./config";

export type NetworkResources = {
  vpc: ec2.Vpc;
  sg: ec2.SecurityGroup;
};

export function createVpcAndSecurityGroup(scope: Construct, allowedCidr: string): NetworkResources {
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

