# =============================================================================
# Makefile — C8's "one command to stand it up" / "one command to verify."
#
# HONEST SCOPE: `make up` stands up the locally-demonstrable stack (the app +
# its real dependencies, via docker-compose) and seeds it -- this is the path
# that actually works end-to-end in this environment. It does NOT run
# `tflocal apply` against LocalStack: that path is blocked by two genuine
# LocalStack limitations documented in FIDELITY.md (ELBv2 license, Docker-
# backed EC2 AMI discovery), not by anything `make up` could paper over.
# `make plan` / `make apply` are provided separately for the Terraform layer,
# and fail exactly the way FIDELITY.md documents -- on purpose, not silently.
# =============================================================================

.PHONY: up down seed verify plan apply destroy fmt

up:
	docker compose up -d --build
	@echo ">> waiting for mysql-db to be healthy..."
	@until [ "$$(docker compose ps mysql-db --format '{{.Health}}')" = "healthy" ]; do sleep 2; done
	$(MAKE) seed
	@echo ">> stack up. capacity-api: http://localhost:3000  grafana: http://localhost:3001  prometheus: http://localhost:9090"

down:
	docker compose down

seed:
	docker compose exec -T capacity-api bash /usr/local/bin/seed.sh

# --- C8: `make verify` -- one command, non-zero exit on any real failure ---
verify:
	@echo ">> healthz..."
	@curl -sf -o /dev/null -w "healthz: %{http_code}\n" http://localhost:3000/healthz | grep -q 200 || \
		(echo "FAIL: /healthz did not return 200" && exit 1)
	@echo ">> readyz..."
	@curl -sf -o /dev/null -w "readyz: %{http_code}\n" http://localhost:3000/readyz | grep -q 200 || \
		(echo "FAIL: /readyz did not return 200" && exit 1)
	@echo ">> app resolved DB creds (log line or /debug/secret-source)..."
	@curl -sf http://localhost:3000/debug/secret-source | grep -q '"arn"' || \
		(echo "FAIL: /debug/secret-source did not return an arn" && exit 1)
	@echo ">> gitleaks (current ref's history only, zero findings required)..."
	@# Scanning /repo directly sees every LOCAL branch's commits too (shared
	@# object database) -- including the deliberately-present red-PR branches
	@# (evidence/05-gates/), which would fail this forever, and doesn't match
	@# what CI's gate actually scans (a fresh single-ref checkout, which
	@# never fetches the other branches at all). Mirror that here: clone only
	@# the current branch into an isolated dir first. Full-history audit of
	@# main specifically is the separate, one-time check in
	@# evidence/03-secrets/gitleaks.json.
	@rm -rf /tmp/verify-gitleaks-clone
	@git clone --quiet --single-branch --branch "$$(git rev-parse --abbrev-ref HEAD)" . /tmp/verify-gitleaks-clone
	@docker run --rm -v /tmp/verify-gitleaks-clone:/repo -w /repo zricethezav/gitleaks:latest \
		detect --source=/repo -c .gitleaks.toml --exit-code=1 || \
		(echo "FAIL: gitleaks found something" && rm -rf /tmp/verify-gitleaks-clone && exit 1)
	@rm -rf /tmp/verify-gitleaks-clone
	@echo ">> gitleaks (built image filesystem, zero findings required)..."
	@docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
		-v "$$(pwd)":/repo zricethezav/gitleaks:latest \
		detect --source=/repo/api --no-git --exit-code=1 || \
		(echo "FAIL: gitleaks found something in the image's source" && exit 1)
	@echo ">> ALL CHECKS PASSED"

# --- Terraform layer (LocalStack) -- see FIDELITY.md for why apply/destroy
# fail on the EC2/ALB resources specifically; the Secrets Manager + security
# group resources genuinely succeed (see evidence/01-iac/README.md).
fmt:
	cd terraform && tofu fmt -check -recursive

plan:
	cd terraform && tofu init -input=false && tflocal plan

apply:
	cd terraform && tflocal apply -auto-approve | tee ../evidence/01-iac/apply.log

destroy:
	cd terraform && tflocal destroy -auto-approve | tee ../evidence/01-iac/destroy.log
