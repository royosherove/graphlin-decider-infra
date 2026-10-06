# graphlin-decider-infra

Status: experimental.

This repository contains the tools that run a
[Strands Decider](https://github.com/strands-labs/strands-decider) server on one Amazon EC2 GPU
instance in your AWS account. [Graphlin](https://github.com/royosherove/graphlin) can send its
decision requests to this server through an experimental decider provider. This provider is not
on the Graphlin `main` branch and not in a Graphlin release yet.

The server listens only on the loopback interface of the instance. You get access to it through
an AWS Systems Manager (SSM) port forward. The instance has no inbound port and no SSH access.
The server has no public endpoint.

## What the repository does

- `bin/decider-aws up` deploys two CloudFormation stacks and starts one GPU instance
  (`g6.xlarge` or `g5.xlarge`). It tries spot first, then on-demand, in a list of regions and
  Availability Zones.
- At the first boot, the instance installs Strands Decider v19 at pinned versions. It checks the
  model files. Then it starts `decider.service` on `127.0.0.1:8000`.
- `bin/decider-aws tunnel start` forwards `127.0.0.1:8099` on your computer to
  `127.0.0.1:8000` on the instance.
- Three guards stop an instance that you forget. `bin/decider-aws down` removes all resources of
  the tool.

## Graphlin and Strands Decider

- Graphlin: <https://github.com/royosherove/graphlin>. The experimental decider provider sends
  the decision requests to `http://127.0.0.1:8099/v1/systemone`. This provider is not on the
  Graphlin `main` branch and not in a Graphlin release yet. The command
  `graphlin provider decider` selects the provider. This command is available only in a Graphlin
  version that has this provider.
- Strands Decider (upstream): <https://github.com/strands-labs/strands-decider>. The boot script
  installs it from a pinned commit.
- The model files come from Hugging Face: `StrandsAgents/strands-decider-2B-hobson-v19` and the
  base model `Qwen/Qwen3.5-2B-Base`, at pinned revisions.

## Architecture

```text
Your computer                                AWS account (one region)

Graphlin --HTTP--> 127.0.0.1:8099            EC2 GPU instance (default VPC)
                   Session Manager plugin    decider.service on 127.0.0.1:8000
                          |                          ^
                          +---- SSM port forward ----+
                          (TLS, AWS-StartPortForwardingSession)
```

- No inbound port. The security group has no inbound rule. The instance has no key pair, and
  the install disables sshd.
- SSM port forward. The tunnel uses the SSM document `AWS-StartPortForwardingSession`. The
  traffic between your computer and the instance goes through the TLS channel of Session
  Manager.
- Loopback only. The server binds to `127.0.0.1`. systemd allows only loopback traffic for the
  service (`IPAddressDeny=any`, `IPAddressAllow=localhost`). The server accepts only the `Host`
  values `127.0.0.1` and `localhost`.
- Outbound traffic: TCP 443 and TCP 80 only, for SSM, PyPI, the PyTorch index, Hugging Face,
  GitHub and the Ubuntu package mirrors. The default subnet gives the instance a public IPv4
  address for this outbound traffic.
- Two CloudFormation stacks:
  - `graphlin-decider-global` (in `DECIDER_GLOBAL_REGION`): the instance role, the instance
    profile and the EventBridge Scheduler role.
  - `graphlin-decider-<region>`, one in each region that `up` uses: the security group, the
    launch template and the schedule group.
- The instance is not in a stack. `bin/decider-aws` starts it from the launch template. Thus a
  capacity error takes only seconds, and the tool tries the next candidate.
- The boot bundle is a gzip shell archive in the EC2 user data (16 KB maximum). It contains the
  files in `bootstrap/`. cloud-init runs `install-decider.sh` one time.
- The resources have the tags `Project=graphlin-decider` and `ManagedBy=decider-aws`.

## Prerequisites

- An AWS account and credentials for the AWS CLI. The credentials must allow CloudFormation,
  EC2, IAM (the global stack makes two roles and an instance profile, and the tool passes these
  roles), SSM, EventBridge Scheduler and the Resource Groups Tagging API.
- A default VPC with default subnets in each region that you use. `up` skips a region that has
  no default VPC.
- An EC2 vCPU quota for G and VT instances in the region: 4 vCPUs or more, for spot or for
  on-demand.
- On your computer: bash 3.2 or later (macOS or Linux), the AWS CLI v2, the Session Manager
  plugin, `curl`, `gzip`, `lsof` and `ps`. `bin/decider-aws` needs no python3 and no jq.
- Optional: git (the boot bundle records the commit), and Python 3.9 or later (for `tools/`
  and `bin/ssm-run.sh`).
- If you cannot install the Session Manager plugin on your `PATH`, put the
  `session-manager-plugin` binary in `.tools/bin/` in the repository. `bin/decider-aws` adds
  that directory to `PATH`.

## Quick start

```bash
bin/decider-aws up             # deploy the stacks and start one host: spot first, then on-demand
bin/decider-aws wait           # wait until /ready answers (install, model download, warm-up)
bin/decider-aws tunnel start   # 127.0.0.1:8099 -> host 127.0.0.1:8000
bin/decider-aws smoke          # all checks must show PASS
# ... use http://127.0.0.1:8099/v1/systemone ...
bin/decider-aws tunnel stop    # always close the tunnel after use
bin/decider-aws stop           # on-demand: stop; spot: terminate
bin/decider-aws down           # remove all resources of the tool
```

Run `bin/decider-aws` with no command to see the usage.

## Commands

| Command | What it does |
| --- | --- |
| `up` | Deploys the stacks, then starts one host in the launch order. Writes `.state/decider-aws.env` and makes the backstop schedule. Refuses when a managed host exists. |
| `up --replace` | Terminates the managed host, then does `up`. |
| `status` | Shows the host, its state, its backstop schedule and the tunnel. |
| `wait [--timeout S]` | Waits until `/ready` answers on the host (default 1500 s). When the install fails, it shows the logs. |
| `tunnel start` | Opens the port forward from `127.0.0.1:8099` to the host. When the local port is in use, it stops with an error. Find the process with `lsof -nP -iTCP:8099 -sTCP:LISTEN`. |
| `tunnel stop` | Closes the port forward. It stops the `aws` and `session-manager-plugin` processes that `tunnel start` started, and only these. Then it checks that the port is free. |
| `tunnel status` | Shows the tunnel process, the plugin processes, the port listeners and `/health`. |
| `smoke` | Through the tunnel: checks `/ready` (identity and warm-up gate), one request, and the HTTP 422 `context_window_exceeded` answer. |
| `stop` | On-demand: stops the host (the volume stays). Spot: terminates the host (the volume is deleted). |
| `start` | On-demand only: starts the stopped host and makes a new backstop schedule. On a capacity error, it runs `up --replace`. |
| `logs [LINES]` | Bounded logs through SSM Run Command (default 80 lines). Fallback: the console output. |
| `down --dry-run` | Shows the resources of the tool and the removal order. Changes nothing. |
| `down` | Removes all resources of the tool in all candidate regions. Then it shows the tagged resources that stay. |

Other tools:

- `bin/ssm-run.sh 'COMMAND' [TIMEOUT_SECONDS]` runs one shell command as root on the host
  through SSM Run Command. It reads the host from `.state/decider-aws.env`. It needs python3.
- `python3 tools/decider-probe.py --base http://127.0.0.1:8099` checks the server through the
  tunnel: health, ready, smoke, latency, window and concurrency. Use `--tests` to select checks.
  The concurrency check sends parallel requests. Thus HTTP 503 `busy` answers are correct there.

Environment variables (all optional):

| Variable | Default | Use |
| --- | --- | --- |
| `DECIDER_TYPES` | `g6.xlarge g5.xlarge` | The instance types, in order. |
| `DECIDER_REGIONS` | `us-east-2 us-east-1 us-west-2 eu-central-1` | The candidate regions, in order. |
| `DECIDER_MARKETS` | `spot on-demand` | The markets, in order. |
| `DECIDER_GLOBAL_REGION` | `us-east-2` | The region of the global (IAM) stack. |
| `DECIDER_IDLE_STOP_MINUTES` | `60` | The idle stop on the host. `0` disables it. Set it before `up`. |
| `DECIDER_STOP_WAIT_SECONDS` | `1200` | The maximum time that `stop` waits for the state `stopped`. |
| `DECIDER_LOCAL_PORT` | `8099` | The local port of the tunnel. |
| `DECIDER_STATE_DIR` | `.state` in the repository | The local state: `decider-aws.env`, `launch.log`, the tunnel files and the user data. |

Do not commit the local state. `.gitignore` contains `.state/`.

## Launch order

`up` tries the candidates in this order. It stops at the first host that runs.

1. Instance type: `DECIDER_TYPES`.
2. Region: `DECIDER_REGIONS`.
3. Market: one-time spot, then on-demand (`DECIDER_MARKETS`).
4. Availability Zone: each zone that has the instance type, in name order.

Errors:

- Capacity error (for example `InsufficientInstanceCapacity`): go to the next zone.
- Quota error (for example `VcpuLimitExceeded`): go to the next market or region.
- Region error (for example `OptInRequired`, or no default VPC): go to the next region.
- Throttling: try again after a delay.
- All other errors: stop.

`up` writes each try to `.state/launch.log`.

## Automatic stop

Three guards stop a host that you forget:

| Guard | When | Result |
| --- | --- | --- |
| Idle stop (`decider-idle.timer`, every 5 minutes) | No `POST /v1/systemone` for `DECIDER_IDLE_STOP_MINUTES` minutes (default 60), and the uptime is more than that time. | Poweroff. |
| Maximum run time (`decider-maxrun.timer`) | 8 hours after each boot. | Poweroff. |
| Backstop (EventBridge Scheduler, one-time schedule) | 8 h 15 min after `up` or `start`. | Stop (on-demand) or terminate (spot). |

A poweroff stops an on-demand host, and the volume stays. A poweroff terminates a spot host, and
the volume is deleted.

## Server contract

- The served model name is `strands-decider-2B-hobson-v19-bb282d7-b1485b2` (Strands Decider v19
  at revision `bb282d7`, base model revision `b1485b2`). The `model` field of each response is
  this name. This name check is a label check. It is not authentication.
- The server listens on `127.0.0.1:8000` on the host. Through the tunnel, the endpoint is
  `http://127.0.0.1:8099/v1/systemone`.

| Request | Status | Body |
| --- | --- | --- |
| `GET /health` | 200 | The process runs. The body has `status`, `model` and other fields from Strands Decider. |
| `GET /ready` | 200 | After the warm-up: `ready`, `model`, `v19_revision`, `base_revision`, `gate`, `warmup_ms`, `gpu` and `gpu_memory_mib`. |
| `GET /ready` | 503 | `{"ready": false}`: the server is not ready. |
| `POST /v1/systemone` | 200 | The Strands Decider System One answer. The question types are `noul`, `choice` and `score`. |
| `POST /v1/systemone` | 422 | The state is longer than the context window (4096 tokens): `{"detail": "...", "code": "context_window_exceeded"}`. The server does not cut the state. |
| `POST /v1/systemone` | 400 or 422 | Other request errors: `{"detail": ...}`, with no `code` field. |
| `POST /v1/systemone` | 503 | The server is busy. Header `Retry-After: 1`. Body `{"detail": "busy", "code": "busy"}`. |

- One evaluation at a time, and 1 waiter. The waiter gets the lock in 1.5 s or less. If not, and
  for each request after the waiter, the server returns 503 `busy`.
- The port opens after the warm-up. Before that, the port does not answer.
- A `Host` header that is not `127.0.0.1` or `localhost` gets HTTP 400.
- `/ready` has the warm-up gate in `gate.pass`. The value is true when each warm shape answers
  in less than 1.5 times its reference time. `smoke` requires `gate.pass: true`.

## Security model

- The server has no authentication. Your IAM permissions control the access:
  `ssm:StartSession` (the tunnel) and `ssm:SendCommand` (`logs`, `wait`, `bin/ssm-run.sh`). A
  principal with `ssm:SendCommand` on the instance can run commands as root on it.
- On your computer, each local process can connect to the tunnel port. When the tunnel is down,
  a different local process can listen on port 8099 and get the requests. Stop Graphlin before
  you stop the tunnel.
- With source consent, Graphlin sends filtered source excerpts to the server in your AWS
  account. The server keeps no request data. The access log has the method, the path, the
  status and the time only.
- The instance role has only the managed policy `AmazonSSMManagedInstanceCore`, and a Deny for
  `ssm:GetParameter*`. The Scheduler role can only stop or terminate the instances that have
  both tags.
- IMDSv2 is required, with a hop limit of 1. The root volume is gp3 and encrypted.
  `decider.service` runs as the user `decider`, with systemd sandbox options.
- Supply chain: the uv download has a pinned SHA-256. The Python packages come from a hashed
  lock (`--require-hashes --only-binary :all:`). strands-decider comes from a pinned git commit,
  with `--no-deps`. The model files come from pinned revisions. The install checks them with
  `bootstrap/models.sha256` and `hf_export verify`. At each start, the service checks the
  revisions and the served name again.

## Limits

- The AMI is the latest "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04)" from the
  public SSM parameter. It is not pinned.
- The outbound rules allow TCP 443 and TCP 80 to all addresses. There is no domain filter.
- One host at a time. `up` refuses to start a second host.
- More than 16 open connections at the same time get HTTP 503 from uvicorn, without the `busy`
  body.
- The boot bundle must fit in the 16 KB user data limit after gzip. `up` stops with an error
  when the bundle is too large. The comment lines of the shell files and of the systemd units
  are not in the bundle.
- The warm-up runs at each start, because Triton does not keep its autotune results on disk.
  Thus `/ready` answers some minutes after each boot.
- Spot capacity is not always available. Then `up` uses on-demand, at the on-demand price.
- `start` does not change the instance type. On a capacity error, it replaces the host
  (`up --replace`), and the new host does a full install.
- `down` removes resources only in `DECIDER_REGIONS` and `DECIDER_GLOBAL_REGION`. Use the same
  values as for `up`.
- The host must be Linux x86_64 (the AMI and the lock file).
- The service is for one client on a loopback endpoint. It is not a shared or public service.

## Cost

The tool starts resources that cost money in your AWS account:

- The GPU instance, for each hour that it runs (the on-demand price or the spot price).
- The EBS gp3 root volume (80 GiB by default), also when an on-demand host is stopped.
- The public IPv4 address of a running instance, and the data transfer.

For the prices, see [Amazon EC2 pricing](https://aws.amazon.com/ec2/pricing/). For an estimate,
use the [AWS Pricing Calculator](https://calculator.aws/). A stopped on-demand host costs only
its volume. `bin/decider-aws down` removes all resources of the tool.

## Change the pins

- The versions are in `bootstrap/install-decider.sh`: uv, Python, the strands-decider commit and
  the model revisions. The served name and the revisions are also in `bin/decider-aws` and
  `tools/decider-probe.py`.
- The model manifest is `bootstrap/models.sha256`.
- To make a new `bootstrap/requirements.lock`, edit `tools/lock-input.txt`. Then do the
  procedure at the top of `tools/make-lock.py`.
- Then run `bin/decider-aws _user-data`. It makes the boot bundle in the state directory. It
  stops with an error when the bundle is larger than 16384 bytes after gzip.
- Test a new pin on a GPU host before you use it.

## Tests

The offline tests make no AWS call and no network call. They use a stub AWS CLI.

```bash
tests/test-launch-tags.sh      # tags of the one-time spot request, fallback to on-demand
tests/test-gpu-boot-order.sh   # nvidia-uvm loads before decider.service starts
tests/test-ssm-run.sh          # bin/ssm-run.sh reads the host only from decider-aws.env
tests/test-stop-wait.sh        # stop waits up to 20 minutes, then gives a clear message
tests/test-tunnel-stop.sh      # tunnel stop stops only the tunnel processes
tests/test-tunnel-start.sh     # tunnel start accepts only a recorded tunnel on the port
```

`tests/test-tunnel-start.sh` needs python3 and lsof.

Set `TEST_BASH` to run the tools with a different bash, for example bash 3.2:

```bash
TEST_BASH=/path/to/bash-3.2 tests/test-launch-tags.sh
```

Also run `bash -n` and `shellcheck` on the shell scripts, and `cfn-lint` on
`cloudformation/*.yaml`.

## Repository layout

| Path | Contents |
| --- | --- |
| `bin/decider-aws` | The operator tool. |
| `bin/ssm-run.sh` | Runs one command on the host through SSM Run Command. |
| `bootstrap/` | The boot bundle: `install-decider.sh`, `decider-serve`, `decider-idle-check`, the lock file, the model manifest and the systemd units. |
| `cloudformation/` | `global.yaml` (IAM) and `regional.yaml` (the security group, the launch template and the schedule group). |
| `tests/` | The offline tests and the stub AWS CLI. |
| `tools/` | `decider-probe.py` (checks the server) and the lock file tools. |

## Status

Experimental. The commands, the defaults and the server contract can change.

The documents and the code comments use ASD-STE100 Simplified Technical English.

## License

MIT. See [LICENSE](LICENSE).
