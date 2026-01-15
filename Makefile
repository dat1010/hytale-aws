SHELL := /bin/bash

AWS_REGION ?= us-east-1
INSTANCE_ID ?= i-09c7146fcc5e940cb
PORT ?= 5520

.PHONY: up down status ip ssm check logs port service-restart

up:
	@echo "Starting $(INSTANCE_ID) in $(AWS_REGION)..."
	@aws ec2 start-instances --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) --output table

down:
	@echo "Stopping $(INSTANCE_ID) in $(AWS_REGION)..."
	@aws ec2 stop-instances --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) --output table

status:
	@aws ec2 describe-instances --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--query 'Reservations[0].Instances[0].{State:State.Name,PublicIp:PublicIpAddress,PrivateIp:PrivateIpAddress,Type:InstanceType}' \
		--output table

ip:
	@IP=$$(aws ec2 describe-instances --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--query 'Reservations[0].Instances[0].PublicIpAddress' --output text); \
	if [ "$$IP" = "None" ] || [ -z "$$IP" ]; then \
		echo "No public IP (instance may be stopped). Run 'make status'."; \
		exit 1; \
	fi; \
	echo "$$IP:$(PORT)"

# NOTE: This requires the Session Manager plugin locally.
ssm:
	@echo "Opening SSM session to $(INSTANCE_ID)..."

	@aws ssm start-session --region $(AWS_REGION) --target $(INSTANCE_ID)

check:
	@CMD_ID=$$(aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Check hytale status" \
		--parameters '{"commands":["sudo systemctl is-active hytale || true; sudo systemctl status hytale --no-pager -l || true"]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 2; \
	aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \
	echo "---- STDERR ----"; \

	aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text

logs:
	@CMD_ID=$$(aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Show last 200 hytale logs" \
		--parameters '{"commands":["sudo journalctl -u hytale -n 200 --no-pager || true"]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 2; \
	aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \
	echo "---- STDERR ----"; \
	aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text


port:
	@CMD_ID=$$(aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Check UDP 5520 listener" \
		--parameters '{"commands":["sudo ss -lunp | grep 5520 || echo \"Nothing listening on UDP 5520\""]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 2; \
	aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \

	echo "---- STDERR ----"; \
	aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text

service-restart:
	@CMD_ID=$$(aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Restart hytale service" \
		--parameters '{"commands":["sudo systemctl daemon-reload; sudo systemctl restart hytale; sudo systemctl --no-pager -l status hytale || true"]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 2; \
	aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \

	echo "---- STDERR ----"; \
	aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text


update-logs:
	@CMD_ID=$$(aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Show last 200 hytale-update logs" \
		--parameters '{"commands":["sudo journalctl -u hytale-update -n 200 --no-pager || true"]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 2; \
	aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \
	echo "---- STDERR ----"; \

	aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text

units:
	@CMD_ID=$$(aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Show systemd units" \
		--parameters '{"commands":["ls -la /etc/systemd/system/hytale*.service || true; sudo systemctl status hytale-update --no-pager -l || true; sudo systemctl status hytale --no-pager -l || true"]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 2; \
	aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \
	echo "---- STDERR ----"; \

	aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text

diag:
	@CMD_ID=$$(aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Hytale bootstrap diagnostics" \
		--parameters '{"commands":["set -euxo pipefail; echo INSTANCE:; curl -s http://169.254.169.254/latest/meta-data/instance-id || true; echo; echo SERVICES FILES:; ls -la /etc/systemd/system/hytale*.service || true; echo; echo UNIT FILES:; systemctl list-unit-files | grep -i hytale || true; echo; echo STATUS hytale-update:; systemctl status hytale-update --no-pager -l || true; echo; echo STATUS hytale:; systemctl status hytale --no-pager -l || true; echo; echo JOURNAL hytale-update (this boot):; journalctl -u hytale-update -b -n 200 --no-pager || true; echo; echo JOURNAL hytale (this boot):; journalctl -u hytale -b -n 200 --no-pager || true; echo; echo CLOUD-INIT OUTPUT (tail):; tail -n 200 /var/log/cloud-init-output.log || true; echo; echo CLOUD-INIT LOG (tail):; tail -n 200 /var/log/cloud-init.log || true"]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 3; \
	aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \
	echo "---- STDERR ----"; \
	aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text

