terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
    }
  }
}

variable "linode_token" {
  type = string
  sensitive = true
}

locals {
  root_pass = uuid()
}

provider "linode" {
  token = var.linode_token
}

resource "random_string" "build_id" {
  length  = 6
  special = false
  upper   = false
}

# FIXME remote exec is continuing if something fails

resource "linode_instance" "instance" {
  image     = "linode/debian12"
  label     = "temp-build-${random_string.build_id.result}"
  group     = "image-build"
  region    = "eu-central"
  type      = "g6-nanode-1"
  root_pass = local.root_pass

  provisioner "remote-exec" {
    inline = [
      <<-EOT
echo "Install common"

apt update > /dev/null

apt install -y \
    apt-transport-https \
    ca-certificates \
    wget \
    curl \
    gnupg \
    software-properties-common \
    build-essential \
    git \
    ufw \
    postgresql-client \
    openjdk-17-jdk-headless > /dev/null

echo 'fs.inotify.max_user_watches=524288' | tee -a /etc/sysctl.conf

sysctl -p

echo "Install docker"

curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor | tee /usr/share/keyrings/docker-archive-keyring.gpg > /dev/null

echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian bullseye stable' > /etc/apt/sources.list.d/docker.list

echo "Install compose"

curl -fsSL "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-Linux-x86_64" -o /usr/local/bin/docker-compose

chmod +x /usr/local/bin/docker-compose

curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg

chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg

echo "Install GitHub CLI"

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null

echo "Install NodeJS"

mkdir -p /etc/apt/keyrings

curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg

echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_21.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list

apt update

apt install -y docker-ce docker-ce-cli containerd.io gh nodejs > /dev/null

echo "Install global npm dependencies"

npm i --no-progress -g yarn nx

echo "Install coder"

curl -fsSL https://github.com/coder/coder/releases/download/v2.4.0/coder_2.4.0_linux_amd64.deb -o /tmp/coder.deb

dpkg -i /tmp/coder.deb > /dev/null

echo "Install code-server"

curl -fsSL https://github.com/coder/code-server/releases/download/v4.19.0/code-server_4.19.0_amd64.deb -o /tmp/code-server.deb

dpkg -i /tmp/code-server.deb > /dev/null

echo "# /etc/hosts
127.0.0.1       localhost
" > /etc/hosts
      EOT
    ]

    connection {
      type     = "ssh"
      user     = "root"
      password = local.root_pass
      host     = self.ip_address
    }
  }
}

resource "linode_image" "image" {
  label       = "developer-image-${random_string.build_id.result}"
  description = "Developer Image Build"
  disk_id     = linode_instance.instance.disk.0.id
  linode_id   = linode_instance.instance.id
}