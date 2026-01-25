SHELL := /bin/bash

AWS_REGION ?= us-east-1
# Prevent AWS CLI from opening a pager (e.g. less) which can hang `make` at "(END)".
AWS_PAGER ?=
# Prefer setting this via `.envrc` (direnv) or environment variables.
INSTANCE_ID ?=
PORT ?= 5520
STACK ?= HytaleServerStack
ENVRC ?= .envrc

# Defensive: if env/direnv injects a trailing CR (Windows/CRLF), strip it so AWS CLI doesn't reject values.
AWS_REGION := $(strip $(AWS_REGION))
INSTANCE_ID := $(strip $(INSTANCE_ID))

.PHONY: up down status ip ssm check logs update-logs units diag port service-restart envrc-update list-backups restore restore-latest backup-create backup-sync backup-now auth-url auth-reset auth-scan-now

ifndef INSTANCE_ID
  $(error INSTANCE_ID is not set. Set it in .envrc (direnv) or pass INSTANCE_ID=... to make)
endif

up:
	@echo "Starting $(INSTANCE_ID) in $(AWS_REGION)..."
	@AWS_PAGER="$(AWS_PAGER)" aws ec2 start-instances --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) --output table

down:
	@echo "Stopping $(INSTANCE_ID) in $(AWS_REGION)..."
	@AWS_PAGER="$(AWS_PAGER)" aws ec2 stop-instances --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) --output table

status:
	@AWS_PAGER="$(AWS_PAGER)" aws ec2 describe-instances --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--query 'Reservations[0].Instances[0].{State:State.Name,PublicIp:PublicIpAddress,PrivateIp:PrivateIpAddress,Type:InstanceType}' \
		--output table

ip:
	@IP=$$(AWS_PAGER="$(AWS_PAGER)" aws ec2 describe-instances --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--query 'Reservations[0].Instances[0].PublicIpAddress' --output text); \
	if [ "$$IP" = "None" ] || [ -z "$$IP" ]; then \
		echo "No public IP (instance may be stopped). Run 'make status'."; \
		exit 1; \
	fi; \
	echo "$$IP:$(PORT)"

# NOTE: This requires the Session Manager plugin locally.
ssm:
	@echo "Opening SSM session to $(INSTANCE_ID)..."

	@AWS_PAGER="$(AWS_PAGER)" aws ssm start-session --region $(AWS_REGION) --target $(INSTANCE_ID)

check:
	@CMD_ID=$$(AWS_PAGER="$(AWS_PAGER)" aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Check hytale status" \
		--parameters '{"commands":["sudo systemctl is-active hytale || true; sudo systemctl status hytale --no-pager -l || true"]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 2; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \
	echo "---- STDERR ----"; \

	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text

logs:
	@CMD_ID=$$(AWS_PAGER="$(AWS_PAGER)" aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Show last 200 hytale logs" \
		--parameters '{"commands":["echo \"== /opt/hytale/logs/hytale-server.log (tail) ==\"; sudo tail -n 200 /opt/hytale/logs/hytale-server.log || true; echo; echo \"== journalctl -u hytale (systemd only) ==\"; sudo journalctl -u hytale -n 200 --no-pager || true"]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 2; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \
	echo "---- STDERR ----"; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text


port:
	@CMD_ID=$$(AWS_PAGER="$(AWS_PAGER)" aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Check UDP 5520 listener" \
		--parameters '{"commands":["sudo ss -lunp | grep 5520 || echo \"Nothing listening on UDP 5520\""]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 2; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \

	echo "---- STDERR ----"; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text

service-restart:
	@CMD_ID=$$(AWS_PAGER="$(AWS_PAGER)" aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Restart hytale service" \
		--parameters '{"commands":["sudo systemctl daemon-reload; sudo systemctl restart hytale; sudo systemctl --no-pager -l status hytale || true"]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 2; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \

	echo "---- STDERR ----"; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text


update-logs:
	@CMD_ID=$$(AWS_PAGER="$(AWS_PAGER)" aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Show last 200 hytale-update logs" \
		--parameters '{"commands":["sudo journalctl -u hytale-update -n 200 --no-pager || true"]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 2; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \
	echo "---- STDERR ----"; \

	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text

units:
	@CMD_ID=$$(AWS_PAGER="$(AWS_PAGER)" aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Show systemd units" \
		--parameters '{"commands":["ls -la /etc/systemd/system/hytale*.service || true; sudo systemctl status hytale-update --no-pager -l || true; sudo systemctl status hytale --no-pager -l || true"]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 2; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \
	echo "---- STDERR ----"; \

	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text

diag:
	@CMD_ID=$$(AWS_PAGER="$(AWS_PAGER)" aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Hytale bootstrap diagnostics" \
		--parameters '{"commands":["set -euxo pipefail; echo INSTANCE:; curl -s http://169.254.169.254/latest/meta-data/instance-id || true; echo; echo SERVICES FILES:; ls -la /etc/systemd/system/hytale*.service || true; echo; echo UNIT FILES:; systemctl list-unit-files | grep -i hytale || true; echo; echo STATUS hytale-update:; systemctl status hytale-update --no-pager -l || true; echo; echo STATUS hytale:; systemctl status hytale --no-pager -l || true; echo; echo JOURNAL hytale-update (this boot):; journalctl -u hytale-update -b -n 200 --no-pager || true; echo; echo JOURNAL hytale (this boot):; journalctl -u hytale -b -n 200 --no-pager || true; echo; echo CLOUD-INIT OUTPUT (tail):; tail -n 200 /var/log/cloud-init-output.log || true; echo; echo CLOUD-INIT LOG (tail):; tail -n 200 /var/log/cloud-init.log || true"]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 3; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \
	echo "---- STDERR ----"; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text

list-backups:
	@CMD_ID=$$(AWS_PAGER="$(AWS_PAGER)" aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "List Hytale backups in S3 (latest kept)" \
		--parameters '{"commands":["set -euo pipefail; source /etc/hytale/hytale.env || true; echo Bucket=$${BACKUP_BUCKET_NAME:-}; echo Prefix=$${S3_BACKUP_PREFIX:-hytale/backups/}; if [ -z \"$${BACKUP_BUCKET_NAME:-}\" ]; then echo \"BACKUP_BUCKET_NAME is empty\"; exit 1; fi; TOKEN=$$(curl -sS -X PUT \"http://169.254.169.254/latest/api/token\" -H \"X-aws-ec2-metadata-token-ttl-seconds: 60\"); DOC=$$(curl -sS -H \"X-aws-ec2-metadata-token: $$TOKEN\" \"http://169.254.169.254/latest/dynamic/instance-identity/document\"); REGION=$$(echo \"$$DOC\" | python3 -c \"import json,sys; print(json.loads(sys.stdin.read())[\\\"region\\\"])\" ); aws --region \"$$REGION\" s3 ls \"s3://$$BACKUP_BUCKET_NAME/$${S3_BACKUP_PREFIX:-hytale/backups/}\" || true"]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 2; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \
	echo "---- STDERR ----"; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text

# Trigger an immediate in-server backup (writes a new zip under /opt/hytale/backups).
# NOTE: This uses the server console FIFO, so the `hytale` service must be running.
backup-create:
	@CMD_ID=$$(AWS_PAGER="$(AWS_PAGER)" aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Trigger Hytale /backup (create a backup zip locally)" \
		--parameters '{"commands":["set -euxo pipefail; sudo systemctl is-active --quiet hytale; test -p /opt/hytale/tmp/hytale-console.fifo; echo \"/backup\" | sudo tee /opt/hytale/tmp/hytale-console.fifo >/dev/null; echo \"Waiting for backup zip to appear...\"; for i in $$(seq 1 30); do newest=$$(sudo ls -1t /opt/hytale/backups/*.zip 2>/dev/null | head -n 1 || true); if [ -n \"$$newest\" ]; then echo \"Newest: $$newest\"; break; fi; sleep 2; done; sudo ls -1t /opt/hytale/backups/*.zip 2>/dev/null | head -n 10 || true"]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 2; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \
	echo "---- STDERR ----"; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text

# Upload local backups (/opt/hytale/backups) to S3 immediately (does not create a new backup by itself).
backup-sync:
	@CMD_ID=$$(AWS_PAGER="$(AWS_PAGER)" aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Sync Hytale backups to S3 now" \
		--parameters '{"commands":["set -euxo pipefail; sudo /opt/hytale/bin/hytale-backup-sync.sh; echo \"---- S3 listing (tail) ----\"; source /etc/hytale/hytale.env || true; if [ -z \"$${BACKUP_BUCKET_NAME:-}\" ]; then echo \"BACKUP_BUCKET_NAME is empty\"; exit 1; fi; TOKEN=$$(curl -sS -X PUT \"http://169.254.169.254/latest/api/token\" -H \"X-aws-ec2-metadata-token-ttl-seconds: 60\"); DOC=$$(curl -sS -H \"X-aws-ec2-metadata-token: $$TOKEN\" \"http://169.254.169.254/latest/dynamic/instance-identity/document\"); REGION=$$(echo \"$$DOC\" | python3 -c \"import json,sys; print(json.loads(sys.stdin.read())[\\\"region\\\"])\" ); aws --region \"$$REGION\" s3 ls \"s3://$$BACKUP_BUCKET_NAME/$${S3_BACKUP_PREFIX:-hytale/backups/}\" | tail -n 20 || true"]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 2; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \
	echo "---- STDERR ----"; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text

# Convenience: create a backup now, then sync to S3.
backup-now:
	@$(MAKE) backup-create
	@$(MAKE) backup-sync

# Print latest auth URL/device info without an interactive SSM session.
auth-url:
	@CMD_ID=$$(AWS_PAGER="$(AWS_PAGER)" aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Print latest Hytale auth URL (downloader/server)" \
		--parameters '{"commands":["set -euo pipefail; echo \"== Downloader auth (step 1) ==\"; f=/opt/hytale/logs/hytale-downloader.log; if [ -f \"$$f\" ]; then url=$$(grep -Eo \"https?://[^[:space:]]+\" \"$$f\" | tr -d \"\\r\" | grep \"oauth.accounts.hytale.com/oauth2/device/verify\" | grep \"user_code=\" | tail -n 1 || true); if [ -n \"$$url\" ]; then echo \"URL: $$url\"; else echo \"No oauth device URL found in $$f\"; fi; echo \"-- context --\"; grep -Ei \"oauth|device|verify|user_code|code|auth\" \"$$f\" | tail -n 80 || true; else echo \"Missing $$f\"; fi; echo; echo \"== Server/provider auth (step 2) ==\"; f=/opt/hytale/logs/hytale-server.log; if [ -f \"$$f\" ]; then url=$$(grep -Eo \"https?://[^[:space:]]+\" \"$$f\" | tr -d \"\\r\" | grep \"oauth.accounts.hytale.com/oauth2/device/verify\" | grep \"user_code=\" | tail -n 1 || true); if [ -n \"$$url\" ]; then echo \"URL: $$url\"; else echo \"No oauth device URL found in $$f\"; fi; echo \"-- context --\"; grep -Ei \"No server tokens configured|oauth|device|verify|user_code|code|/auth\" \"$$f\" | tail -n 120 || true; else echo \"Missing $$f\"; fi; echo; echo \"== Token file ==\"; ls -la /opt/hytale/auth.enc 2>/dev/null || echo \"No /opt/hytale/auth.enc yet\";"]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 2; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \
	echo "---- STDERR ----"; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text

# Reset server auth cooldown/flags and restart the server (useful while iterating).
auth-reset:
	@CMD_ID=$$(AWS_PAGER="$(AWS_PAGER)" aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Reset server auth trigger and restart hytale" \
		--parameters '{"commands":["set -euxo pipefail; sudo rm -f /opt/hytale/tmp/hytale-server-auth.started /opt/hytale/tmp/hytale-server-auth.last; sudo systemctl restart hytale; sudo tail -n 120 /opt/hytale/logs/hytale-server.log || true;"]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 2; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \
	echo "---- STDERR ----"; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text

# Run the auth scan script immediately (tries to post to Discord; prints recent scan inputs).
auth-scan-now:
	@CMD_ID=$$(AWS_PAGER="$(AWS_PAGER)" aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Run hytale-auth-scan now" \
		--parameters '{"commands":["set -euxo pipefail; sudo /opt/hytale/bin/hytale-auth-scan.sh || true; echo \"== recent discord post log ==\"; sudo tail -n 120 /opt/hytale/logs/hytale-discord-post.log || true; echo \"== recent server log urls ==\"; sudo grep -Eo \"https?://[^[:space:]]+\" /opt/hytale/logs/hytale-server.log 2>/dev/null | tail -n 20 || true;"]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 2; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \
	echo "---- STDERR ----"; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text

restore-latest:
	@$(MAKE) restore BACKUP=latest

# Usage:
# - make restore-latest
# - make restore BACKUP=2026-01-15_14-30-00.zip
restore:
	@CMD_ID=$$(AWS_PAGER="$(AWS_PAGER)" aws ssm send-command --region $(AWS_REGION) --instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--comment "Restore Hytale universe from S3 backup" \
		--parameters '{"commands":["set -euxo pipefail; sudo /opt/hytale/bin/hytale-restore.sh \"$(BACKUP)\"; rc=$$?; echo \"==== hytale-restore exit $$rc ====\"; echo \"==== tail /opt/hytale/logs/hytale-restore.log ====\"; sudo tail -n 120 /opt/hytale/logs/hytale-restore.log || true; exit $$rc"]}' \
		--query 'Command.CommandId' --output text); \
	echo "CommandId=$$CMD_ID"; \
	sleep 2; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardOutputContent' --output text; \
	echo "---- STDERR ----"; \
	AWS_PAGER="$(AWS_PAGER)" aws ssm get-command-invocation --region $(AWS_REGION) --command-id $$CMD_ID --instance-id $(INSTANCE_ID) --query 'StandardErrorContent' --output text

envrc-update:
	@set -euo pipefail; \
	if [ ! -f "$(ENVRC)" ] && [ -f ".envrc.example" ]; then \
		echo "Creating $(ENVRC) from .envrc.example"; \
		cp .envrc.example "$(ENVRC)"; \
	fi; \
	NEW_ID=$$(AWS_PAGER="$(AWS_PAGER)" aws cloudformation describe-stacks --region "$(AWS_REGION)" --stack-name "$(STACK)" --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text); \
	if [ -z "$$NEW_ID" ] || [ "$$NEW_ID" = "None" ]; then \
		echo "Could not read InstanceId output from stack $(STACK) in $(AWS_REGION)"; \
		exit 1; \
	fi; \
		ENVRC="$(ENVRC)" NEW_ID="$$NEW_ID" python3 scripts/update-envrc.py

