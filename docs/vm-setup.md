# VM Setup

Use a VM that can run `git`, `gh`, `jq`, `flock`, `timeout`, Node/npm, and Gemini CLI. Ubuntu LTS is the easiest default.

## Google Compute Engine Example

Google documents VM creation through the console and the `gcloud compute instances create` command:

- https://cloud.google.com/compute/docs/instances/create-start-instance
- https://cloud.google.com/sdk/gcloud/reference/compute/instances/create

Example:

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud compute instances create goobreview-1 \
  --zone=us-central1-a \
  --machine-type=e2-small \
  --boot-disk-size=20GB \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --tags=ssh
gcloud compute ssh goobreview-1 --zone=us-central1-a
```

Keep firewall exposure minimal. The reviewer needs outbound HTTPS and inbound SSH only.

## Base Packages

On Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y git jq curl wget ca-certificates gnupg lsb-release util-linux coreutils nodejs npm
```

`flock` comes from `util-linux`; `timeout` comes from `coreutils`.

## Install GitHub CLI

GitHub CLI's official install docs live in the `cli/cli` repository and GitHub Docs:

- https://github.com/cli/cli/blob/trunk/docs/install_linux.md
- https://docs.github.com/github-cli/github-cli/quickstart

For Ubuntu, follow the current official apt instructions from the GitHub CLI docs. After installing:

```bash
gh --version
gh auth login
gh auth status
```

Authenticate as the account that should post reviews.

## Install Gemini CLI

The Gemini CLI project documents npm installation:

- https://github.com/google-gemini/gemini-cli
- https://github.com/google-gemini/gemini-cli/blob/main/docs/get-started/index.md

Current documented install path:

```bash
sudo npm install -g @google/gemini-cli
gemini --version
```

Then authenticate and trust the daemon checkout:

```bash
cd /opt/goobreview/example
gemini
```

The Gemini CLI authentication docs describe individual Google account login and note that Google AI Pro or Google AI Ultra subscribers should use the Google account associated with that subscription.

Exit Gemini with:

```text
/quit
```

Verify headless mode from the same checkout:

```bash
printf 'say hi in three words' | timeout 60s gemini -m auto -p ""
```

If this prompts for authorization, reports an untrusted workspace, or times out, run `gemini` interactively again from the exact checkout path cron will use.

## Dedicated User Option

For a durable setup, create one Unix user per reviewer identity:

```bash
sudo useradd --system --create-home --shell /bin/bash goobreview
sudo mkdir -p /opt/goobreview/example /var/lib/goobreview/example
sudo chown -R goobreview:goobreview /opt/goobreview /var/lib/goobreview
```

Then perform clone, `gh auth login`, and `gemini` trust as that user.
