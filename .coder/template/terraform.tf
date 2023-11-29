terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    linode = {
      source = "linode/linode"
    }
  }
}

variable "linode_token" {
  type      = string
  sensitive = true
}

variable "agent_url" {
  type = string
}

provider "linode" {
  token = var.linode_token
}

data "coder_provisioner" "me" {
}

data "coder_workspace" "me" {
}

data "coder_external_auth" "github" {
  id = "primary-github"
}

resource "random_string" "build_id" {
  length  = 6
  special = false
  upper   = false
}

resource "random_uuid" "root_pass" {
}

data "linode_images" "images" {
  filter {
    name   = "is_public"
    values = ["false"]
  }
}

data "coder_parameter" "gh_repo" {
  name         = "gh_repo"
  display_name = "GitHub Repo"
}

locals {
  username = data.coder_workspace.me.owner
  gh_token = data.coder_external_auth.github.access_token
  images   = data.linode_images.images.images
  build_id = random_string.build_id.result
  gh_repo  = data.coder_parameter.gh_repo.value
  region   = "eu-central"
}

data "coder_parameter" "linode_image" {
  name         = "linode_image"
  display_name = "Linode Image"

  dynamic "option" {
    for_each = local.images

    content {
      name  = option.value.label
      value = option.value.id
    }
  }
}

data "coder_parameter" "linode_instance" {
  name         = "linode_instance"
  display_name = "Linode Instance"

  option {
    name  = "Nano"
    value = "g6-nanode-1"
  }

  option {
    name  = "Small"
    value = "g6-standard-1"
  }

  option {
    name  = "Standard"
    value = "g6-standard-2"
  }
}

resource "coder_agent" "main" {
  arch                   = data.coder_provisioner.me.arch
  os                     = "linux"
  startup_script_timeout = 180
  startup_script         = <<-EOT
until [ -e /dev/sdc ]
do
     sleep 1
done

mount /dev/sdc /home

if [ $? -ne 0 ]; then
  mkfs.ext4 /dev/sdc
  mount /dev/sdc /home
fi

if [ ! -d /home/developer ]; then
  useradd -s /bin/bash --create-home -d /home/developer -U -G docker developer

  mkdir -p /home/developer/.config/code-server

  echo "bind-addr: 127.0.0.1:13337
auth: none
cert: false
" > /home/developer/.config/code-server/config.yaml

  GITHUB_TOKEN=${local.gh_token} gh repo clone ${local.gh_repo} /home/developer/workspace

  chown -R developer:developer /home/developer

  echo "
export GITHUB_TOKEN=${local.gh_token}

gh auth setup-git
" >> /home/developer/.bashrc
else
  useradd -s /bin/bash --no-create-home -d /home/developer -U -G docker developer
fi

usermod -aG sudo developer

echo "developer ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/developer

chmod 0440 /etc/sudoers.d/developer

systemctl enable code-server@developer --now

echo "
git config --global pull.rebase false

git config --global user.email ${data.coder_workspace.me.owner_email}

git config --global user.name "${data.coder_workspace.me.owner}"

code-server --install-extension nrwl.angular-console
" | su - developer
  EOT

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path /home"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "Root Disk"
    key          = "4_root_disk"
    script       = "coder stat disk"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "Swap Usage"
    key          = "5_swap_host"
    script       = <<EOT
      free -b | awk '/^Swap/ { printf("%.1f/%.1f", $3/1024.0/1024.0/1024.0, $2/1024.0/1024.0/1024.0) }'
    EOT
    interval     = 10
    timeout      = 1
  }
}

resource "coder_app" "code-server" {
  agent_id  = coder_agent.main.id
  slug      = "code-server"
  url       = "http://localhost:13337/?folder=/home/developer/workspace"
  icon      = "/icon/code.svg"
  subdomain = true
  share     = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 5
    threshold = 10
  }
}

resource "linode_instance" "node" {
  count     = data.coder_workspace.me.start_count
  image     = data.coder_parameter.linode_image.value
  label     = "coder-${data.coder_workspace.me.owner}-${random_string.build_id.result}"
  group     = "developer-instances"
  region    = local.region
  type      = data.coder_parameter.linode_instance.value
  root_pass = random_uuid.root_pass.result
  swap_size = 8192

  provisioner "remote-exec" {
    inline = [
      <<-EOT
echo "[Unit]
Description=Coder Agent

[Service]
ExecStart=coder agent
Environment="HOME=/root"
Environment="CODER_AGENT_TOKEN=${nonsensitive(coder_agent.main.token)}"
Environment="CODER_AGENT_AUTH=token"
Environment="CODER_AGENT_URL=${var.agent_url}"
Restart=always

[Install]
WantedBy=multi-user.target
" > /etc/systemd/system/coder-agent.service

systemctl enable coder-agent.service --now
      EOT
    ]

    connection {
      type     = "ssh"
      user     = "root"
      password = random_uuid.root_pass.result
      host     = self.ip_address
    }
  }
}

resource "linode_volume" "volume" {
  label     = "coder-${data.coder_workspace.me.owner}-${random_string.build_id.result}"
  region    = local.region
  linode_id = length(linode_instance.node) > 0 ? linode_instance.node[0].id : null
  size      = 10
}
