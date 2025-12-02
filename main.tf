terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
  required_version = ">= 0.13"
}

provider "yandex" {
  zone = "ru-central1-a"
}

resource "yandex_compute_disk" "boot-disk-1" {
  name     = "boot-disk-1"
  type     = "network-hdd"
  zone     = "ru-central1-a"
  size     = "20"
  image_id = "fd83j4siasgfq4pi1qif"
}

resource "yandex_compute_instance" "vm-1" {
  name = "terraform1"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    disk_id = yandex_compute_disk.boot-disk-1.id
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet-1.id
    nat       = true
  }

  metadata = {
    user-data = "${file("meta.txt")}"
    ssh-keys = "debian:${file("~/.ssh/id_ed25519.pub")}"
  }

  scheduling_policy {
    preemptible = true
  }
}

resource "yandex_vpc_network" "network-1" {
  name = "network1"
}

resource "yandex_vpc_subnet" "subnet-1" {
  name           = "subnet1"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network-1.id
  v4_cidr_blocks = ["192.168.10.0/24"]
}

output "internal_ip_address_vm_1" {
  value = yandex_compute_instance.vm-1.network_interface.0.ip_address
}

output "external_ip_address_vm_1" {
  value = yandex_compute_instance.vm-1.network_interface.0.nat_ip_address
}

resource "null_resource" "baz" {
  connection {
    type = "ssh"
    user = "debian"
    host = yandex_compute_instance.vm-1.network_interface.0.nat_ip_address
    # если нужен кастомный ключ:
    # private_key = file("~/.ssh/id_ed25519")
  }

  provisioner "remote-exec" {
    inline = [
      # Обновление системы и базовые пакеты
      "sudo apt update",
      "sudo apt -y install ca-certificates curl git",

      # Установка Docker
      "sudo install -m 0755 -d /etc/apt/keyrings",
      "sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc",
      "sudo chmod a+r /etc/apt/keyrings/docker.asc",
      "echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable' | sudo tee /etc/apt/sources.list.d/docker.list",
      "sudo apt update",
      "sudo apt -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin",

      # Установка kubectl
      "curl -LO https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl",
      "chmod +x kubectl",
      "sudo mv kubectl /usr/local/bin/kubectl",

      # Установка kind
      "curl -Lo kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64",
      "chmod +x kind",
      "sudo mv kind /usr/local/bin/kind",

      # Конфиг для kind-кластера
      "printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes:\n- role: control-plane\n- role: worker\n' > kind-config.yaml",

      # Создание кластера kind ОТ root
      "sudo kind create cluster --name secure-lab --config kind-config.yaml",

      # Перенос kubeconfig в домашнюю директорию пользователя debian
      "sudo mkdir -p /home/debian/.kube",
      "sudo cp /root/.kube/config /home/debian/.kube/config",
      "sudo chown -R debian:debian /home/debian/.kube",

      # Установка Helm (надёжный бинарный способ)
      "curl -fsSL https://get.helm.sh/helm-v3.14.4-linux-amd64.tar.gz -o helm.tar.gz",
      "tar -xzf helm.tar.gz",
      "sudo mv linux-amd64/helm /usr/local/bin/helm",
      "rm -rf linux-amd64 helm.tar.gz",
      "helm version",

      # Скачиваем Gatekeeper из Yandex Container Registry
      "helm pull oci://cr.yandex/yc-marketplace/yandex-cloud/gatekeeper/gatekeeper --version 3.20.1 --untar",

      # Устанавливаем Gatekeeper через локальный чарт
      "helm install gatekeeper ./gatekeeper/ --namespace gatekeeper-system --create-namespace",
    ]
  }

  triggers = {
    always_run = timestamp()
  }
}
