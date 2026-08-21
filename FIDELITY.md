# FIDELITY.md — where the emulator lied to you

Two caveats below, each one genuinely hit and root-caused during this project
(not copied from the starter list) — see `evidence/01-iac/README.md` and
`evidence/01-iac/apply-output.txt` for the raw apply output behind both.

## ELBv2 is not included in the free Hobby tier at all — not just "unfaithful," entirely absent

- **What LocalStack did:** `tofu apply` failed outright trying to *create*
  `aws_lb`, `aws_lb_target_group`, and `aws_lb_listener` — not "created but
  behaves oddly," genuinely refused:
  ```
  Error: reading ELBv2 Load Balancer (devops-g1-ls-rigbe-alb): operation
  error Elastic Load Balancing v2: DescribeLoadBalancers, https response
  error StatusCode: 501 ... api error InternalFailure: Sorry, the elbv2
  service is not included within your LocalStack license, but is available
  in an upgraded license.
  ```
- **How I detected it:** the error is explicit about the cause (license
  tier, not a bug) — confirmed against LocalStack's own service-coverage
  docs, which list ELBv2 as Pro-tier-only, contradicting the assignment
  brief's own claim that "everything this lab uses ... is included in
  LocalStack's free Hobby tier." `modules/service`'s design already
  anticipated ALB might not be *health-check*-able on LocalStack (nginx
  carries real traffic instead) — but the actual failure mode is stronger
  than that: the resource can't even be *created*, so the ALB exists only
  as scanned, ungraded-at-runtime IaC in this lab, not as a real object at
  any point.
- **What I'd verify on real AWS:** that `aws_lb`/`aws_lb_target_group`/
  `aws_lb_listener` apply cleanly (expected — ELBv2 is a core, universally
  available AWS service), and separately, that the target group's health
  check against `/readyz` actually gates traffic the way LocalStack's ALB
  never got to prove — i.e., kill the instance's readiness and confirm the
  ALB stops routing to it, which is exactly the C4 behavior this repo can
  currently only demonstrate at the nginx layer, not the ALB layer.

## Docker-backed EC2 AMI discovery doesn't register the image, despite following the documented convention exactly

- **What LocalStack did:** following LocalStack's own documented
  Docker-backed-EC2 convention
  (https://docs.localstack.cloud/aws/services/ec2/) — build the app image,
  tag it `localstack-ec2/capacity-api:ami-<sha12>`, reference the bare
  `ami-<sha12>` id in `aws_instance.ami` — `tofu apply` still can't find the
  image:
  ```
  Error: collecting instance settings: couldn't find resource
  ```
  (An earlier, separate bug of mine — `modules/service` passing the full
  `localstack-ec2/<name>:ami-<sha12>` docker-tag string through unmodified
  instead of stripping to the bare id — produced a *different*,
  self-explanatory error, `InvalidAMIID.Malformed`; fixed in
  regional-health-platform#8. This caveat is what's left *after* that fix,
  with a correctly-formatted bare `ami-<sha12>` id.)
- **How I detected it:** ruled out every cause I could think of before
  concluding this is an emulator gap, not a mistake on my end:
  - `docker images` confirms the tagged image genuinely exists locally
  - `docker ps` confirms the LocalStack container has `/var/run/docker.sock`
    mounted (required for Docker-backed EC2 to see local images at all)
  - `aws ec2 describe-images --filters Name=tag:ec2_vm_manager,Values=docker`
    against the running LocalStack returns empty — the image was never
    registered as a discoverable AMI in the first place
  - Restarted LocalStack fresh *after* the image already existed (rules out
    a startup-ordering/timing race)
  - Set `EC2_VM_MANAGER=docker` explicitly (rules out a wrong default)
  None of these changed the result. This looks like a genuine gap between
  LocalStack's documented behavior and its actual behavior in this specific
  version (`2026.7.1`)/environment.
- **What I'd verify on real AWS:** that a real AMI (built via Packer or a
  registered EC2 Image Builder pipeline, not a Docker-backed emulation
  shortcut) launches an instance the normal way — this whole caveat is
  specific to LocalStack's Docker-backed EC2 substitution for a real AMI
  and has no equivalent failure mode on real AWS at all.
