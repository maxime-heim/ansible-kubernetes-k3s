# kubernetes-on-proxmox

Déploiement d'un cluster k3s sur Proxmox avec Terraform (VMs), Ansible (k3s + ArgoCD) et ArgoCD (applications, en GitOps).

## Stack

| Couche | Composant | Version |
|--------|-----------|---------|
| Hyperviseur | Proxmox VE | 9.1 |
| OS VMs | Debian | 13 (Trixie) |
| Provisioning infra | Terraform | >= 1.6 |
| Provider Proxmox | bpg/proxmox | non épinglée |
| Configuration | ansible-core | >= 2.16 |
| Collections Ansible | kubernetes.core | >= 6.6.0 |
| | ansible.posix | >= 2.2.0 |
| Orchestration | k3s | canal `stable`, non épinglée |
| GitOps | ArgoCD (chart Helm `argo-cd`) | 7.8.26 (ArgoCD 2.14.10) |
| Stockage | Longhorn | 1.13.0 |
| Certificats | cert-manager | 1.21.3 |

Ingress : Traefik, fourni par défaut avec k3s.

## Topologie

| VM | Rôle | ID Proxmox | CPU | RAM | Disque |
|----|------|------------|-----|-----|--------|
| k8s-cp-01 | control-plane | 200 | 2 | 8 Go | 20 Go |
| k8s-worker-01 | worker | 201 | 1 | 4 Go | 20 Go |
| k8s-worker-02 | worker | 202 | 1 | 4 Go | 20 Go |

- IP des VMs : DHCP. Réserver les adresses dans le routeur pour qu'elles ne changent pas.
- Réseau pods : `10.42.0.0/16` (défaut k3s).
- Réseau services : `10.43.0.0/16` (défaut k3s).

## Prérequis

### Poste local

- Terraform, Ansible et `make`
- Une clé SSH `~/.ssh/id_ed25519` (chemin fixé dans `terraform/inventory.tpl`)

### Proxmox (une seule fois, depuis le shell web)

Créer le template Debian 13. L'ID `9004` et le stockage `local-lvm` sont les valeurs par défaut de `terraform/variables.tf`.

`qemu-guest-agent` doit être installé dans le template : Terraform s'en sert pour lire l'IP des VMs et générer l'inventaire Ansible.

```bash
apt update && apt install -y libguestfs-tools

IMG=/var/lib/vz/template/iso/debian-13.qcow2
curl -L -o $IMG https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2

# machine-id vidé pour que chaque clone obtienne sa propre IP en DHCP
virt-customize -a $IMG --install qemu-guest-agent --truncate /etc/machine-id

qm create 9004 --name debian-13-template --memory 1024 --cores 1 --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci --agent enabled=1
qm set 9004 --scsi0 local-lvm:0,import-from=$IMG,discard=on
qm set 9004 --ide2 local-lvm:cloudinit --boot order=scsi0 --serial0 socket --vga serial0
qm template 9004
```

Créer un token API pour Terraform (le secret n'est affiché qu'une fois) :

```bash
pveum user token add root@pam terraform --privsep 0
```

## Utilisation

Les commandes se lancent depuis la racine du dépôt. `make help` liste toutes les cibles.

### 1. Configurer Terraform

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

| Variable | Description | Défaut |
|----------|-------------|--------|
| `proxmox_api_token` | Token API, format `user@realm!tokenid=secret` | obligatoire |
| `ssh_public_key` | Clé publique injectée dans les VMs | obligatoire |
| `proxmox_endpoint` | URL de l'API Proxmox | `https://192.168.1.12:8006` |
| `proxmox_node` | Nom du nœud Proxmox | `pve` |
| `template_id` | ID du template Debian 13 | `9004` |
| `datastore_id` | Stockage des VMs | `local-lvm` |
| `network_bridge` | Bridge réseau des VMs | `vmbr0` |

### 2. Installer les dépendances

```bash
make setup   # providers Terraform + collections Ansible
```

### 3. Déployer

```bash
make up      # apply + wait + deploy
```

Ou étape par étape :

```bash
make apply    # crée les VMs et génère ansible/inventory.yml
make wait     # attend que les nœuds répondent (5 min max)
make deploy   # lance ansible/site.yml : k3s, puis ArgoCD
```

Options supplémentaires : `make apply TF_ARGS="-auto-approve"`, `make deploy ANSIBLE_ARGS="-v"`.

### 4. Accéder au cluster

Depuis `k8s-cp-01` (`ssh debian@<ip-cp>`) :

```bash
sudo kubectl get nodes
sudo kubectl get applications -n argocd
```

### 5. Accéder à ArgoCD

Interface : `https://<ip-cp>:30443` (ou `http://<ip-cp>:30080`), utilisateur `admin`. Mot de passe initial, depuis `k8s-cp-01` :

```bash
sudo kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d; echo
```

### Détruire les VMs

```bash
make destroy
```

## GitOps

Ansible crée une application `app-of-apps` qui déploie tout le contenu de `gitops/apps/` :

| Application | Rôle | Namespace | Sync wave |
|-------------|------|-----------|-----------|
| `longhorn` | Stockage distribué, 2 réplicas par volume | `longhorn-system` | 0 |
| `cert-manager` | Gestion des certificats | `cert-manager` | 1 |
| `cert-manager-config` | ClusterIssuers `letsencrypt-staging` et `letsencrypt-prod` (HTTP-01 via Traefik) | `cert-manager` | 2 |

ArgoCD lit la branche par défaut (`dev`) du dépôt GitHub, pas les fichiers locaux : un changement dans `gitops/` n'est appliqué qu'une fois poussé.

Pour utiliser un fork, adapter :

- `argocd_repo_url` dans `ansible/roles/argocd/defaults/main.yml`
- `repoURL` dans `gitops/apps/cert-manager-config.yaml`
- l'e-mail ACME dans `gitops/config/cert-manager/cluster-issuers.yaml`

La validation HTTP-01 exige que le domaine soit joignable depuis Internet sur le port 80.

## Structure

```
.
├── Makefile                   # commandes Terraform et Ansible
├── terraform/
│   ├── main.tf                # VMs Proxmox + génération de l'inventaire
│   ├── inventory.tpl          # modèle de ansible/inventory.yml
│   ├── variables.tf
│   ├── outputs.tf
│   ├── providers.tf
│   ├── versions.tf
│   └── terraform.tfvars.example
├── ansible/
│   ├── site.yml               # playbook unique (k3s + ArgoCD)
│   ├── ansible.cfg
│   ├── inventory.yml          # généré par Terraform, non versionné
│   ├── requirements.yml       # collections Ansible
│   ├── group_vars/all.yml
│   └── roles/
│       ├── common/            # mises à jour, swap, modules kernel, sysctl, pré-requis Longhorn
│       ├── k3s_server/        # k3s control-plane + kubeconfig
│       ├── k3s_agent/         # k3s workers
│       └── argocd/            # Helm, ArgoCD, App of Apps
└── gitops/
    ├── apps/                  # Applications ArgoCD
    └── config/cert-manager/   # ClusterIssuers Let's Encrypt
```
