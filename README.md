**English** · [Français](README.fr.md)

# Practise security by design, on a cloud you build yourself

> The hands-on labs (TP, *travaux pratiques*) and the other documents of this repository are written
> in French. This README and the [lab index](tps/README.md) are available in English.

In many organisations, a project goes through several stages before it reaches production:

- **Design**: the architecture file is presented to the architecture and security boards.
- **Approval**: decisions are made, gaps identified, corrective measures defined.
- **Implementation and integration**: teams build the solution according to the approved requirements.
- **Verification**: you check that what was built matches what was expected.
- **Deployment**: you check that what was deployed matches what was decided.

One question remains: how confident are you at each of these stages? Do you understand the
requirements you are given, whether they come from internal standards or from regulations such as
NIS 2, DORA or the GDPR? Can you spot risks early? Can you prove that the implementation, the
integration and the deployment match the approved architecture?

## What these labs offer

20+ labs take you through these stages on an OpenStack cloud that you deploy yourself: from an empty
instance to a segmented, protected and published architecture, then described as code.

- **Design**: start from an architecture file and its security objectives (TP 13).
- **Justify**: every choice has a reason, and every lab ends with questions and a validation grid,
  to be reviewed by a tutor.
- **Build and integrate**: networks, security groups, bastion, proxy, secrets, encrypted volumes,
  hardened service (TP 01 to 13); load balancing with Octavia, HTTPS with a certificate stored in
  Barbican (TP 15).
- **Verify**: every objective is proven by an access that must succeed and an access that must fail;
  the same architecture, rebuilt as code with Heat, is compared with the manual build (TP 14).
- **Deploy**: each deployment method has its pros and cons (TP 13 and TP 14).

The goal is not to tick boxes, but to learn to anticipate risks, to justify architecture choices and
to verify the security of what is actually built. That is why projects need a reference framework,
and need to stick to it. You no longer endure the wave: you steer it and see it coming.

These labs do not replace a compliance analysis: they train you in the technical measures that these
regulations expect, such as encryption, access control, restorable backups or regular verification
of security measures.

## Before you start

- The labs, the platform and its scripts are free: content under the CC BY-SA 4.0 licence, scripts
  under the MIT licence. You can follow the labs on your own, at your own pace.
- The platform runs on an AWS instance (4 vCPU, 16 GB), **charged** while it is running. Read
  [aws/finops.md](aws/finops.md) (in French) before creating it, and stop it after each session.
- Expected level: comfortable with a Linux terminal and SSH. No prior knowledge of OpenStack is
  assumed.

## Why this project

Throughout my career, I have come across practices that puzzled me, including from experienced, even
very experienced, people. Not necessarily for lack of technical skills, but often for lack of
experience and of a security culture.

That observation is what made me want to create these labs and share them. I also thank my
"invisible assistant", who saved me a lot of time in building them.

## Contributing

A mistake, an explanation to improve, an exercise to suggest? Open an *issue* or submit a *pull
request*: contributions and feedback are welcome. If these resources are useful to you, a star on
GitHub encourages me to keep improving them.

Security is designed from the start, verified during the build and grown collectively.

Merlin Tchoffo, cybersecurity and cloud expert

---

## The platform: OpenStack All-in-One on a cloud instance (Kolla-Ansible)

This repository deploys a single-node OpenStack platform on an instance with a single network
interface (typical case: AWS EC2), and provides a series of labs.

| You are | Start with |
|---|---|
| Trainee or work-study student | [tps/README.md](tps/README.md): the labs |
| Platform administrator | This document: deployment, architecture, operations |

This document describes OpenStack and the deployment. What is specific to AWS (VPC network, instance
types, alternatives) is in [aws/aws-setup.md](aws/aws-setup.md), costs in [aws/finops.md](aws/finops.md)
(both in French).

---

## 1. Repository contents

```
openstack-lab-trainee/
├── README.md                  this document
├── README.fr.md               French version of this document
├── deploy.sh                  deployment (takes a scenario file as argument)
├── verify.sh                  end-to-end test of the deployment (acceptance criterion)
├── destroy.sh                 removes the deployment (--purge: resets the host)
├── scenarios/
│   ├── 01-aio-base.env        basic All-in-One
│   ├── 02-aio-cinder.env      + Cinder block storage (LVM)
│   ├── 03-aio-public-fip.env  + floating IPs reachable from the Internet
│   └── 04-aio-complet.env     02 + Barbican + Designate + S3 object storage (Garage) and restic
├── tools/
│   ├── openstack-lab-net.sh   host network (veth, NAT, published IPs), started at boot by systemd
│   ├── openstack-lab-cinder-loop.sh   attaches the Cinder storage (loop file) at boot
│   ├── lab-s3.sh              S3 object storage of the platform (Garage) and static restic (TP 10)
│   └── public-fip.sh          publishes a floating IP through a secondary IP (scenario 03)
├── tests/
│   └── test-public-fip.sh     host-side test of scenario 03, without AWS resources (TP 07)
├── tps/                       the labs: instructions, conventions, progress grid, sources;
│                              one tpNN/ folder per lab: instructions, verifier-entree.sh, provided files
├── VERSION                    repository version
├── LICENSE                    licence of the scripts (MIT)
├── LICENSE-CONTENU.md         licence of the educational content (CC BY-SA 4.0)
├── NOTICE.md                  third-party software used
└── aws/
    ├── aws-setup.md           AWS constraints and alternatives
    ├── finops.md              costs, CPU credits, good practices
    ├── check-cpu-credits.sh   enforces the "standard" CPU credit mode (no extra charge)
    ├── aws-public-fip.sh      AWS part of scenario 03 (simulation by default)
    └── recover-network.sh     recovers an instance that became unreachable (see aws-setup.md §6)
```

---

## 2. Scenarios

| Scenario | Contents | Extra AWS resources |
|---|---|---|
| **01 (base)** | Keystone, Glance, Nova, Neutron, Placement, Horizon. Ephemeral VM disks. | None |
| **02 (Cinder)** | 01 + persistent volumes (Cinder, LVM on a loop file) | None (option: dedicated EBS volume, charged) |
| **03 (public floating IPs)** | 01 + access to VMs from the Internet | Secondary IPs (free) + Elastic IPs (**charged**, approval required) |
| **04 (complete)** | 02 + Barbican (secrets, encrypted volumes) + Designate (DNS, Neutron integration) + S3 object storage (Garage) | None (16 GB of RAM recommended) |

Scenarios can be combined: you can deploy 01, then run `deploy.sh` again with 02 (or 04) to add
services without losing existing VMs.

---

## 3. Quick start

Prerequisites: fresh Ubuntu 24.04 instance, ≥ 8 GB RAM (16 recommended), ≥ 2 vCPU (4 recommended),
≥ 40 GB of disk (60 recommended: ~30 GB used with scenario 04), a user with passwordless `sudo`
(`ubuntu` on EC2), Internet access.

```bash
# From your workstation: check that no CPU credit charge is possible (see aws/finops.md)
./openstack-lab-trainee/aws/check-cpu-credits.sh <INSTANCE_ID>

# Copy the repository to the instance
scp -r -i ec2_key openstack-lab-trainee ubuntu@<IP_PUBLIQUE>:
ssh -i ec2_key ubuntu@<IP_PUBLIQUE>

# On the instance (tmux recommended: the deployment takes a long time)
tmux new -s deploy
./openstack-lab-trainee/deploy.sh openstack-lab-trainee/scenarios/01-aio-base.env
./openstack-lab-trainee/verify.sh
```

`<IP_PUBLIQUE>` is the public IP address of the instance.

To follow all the labs ([tps/README.md](tps/README.md)), deploy scenario 04 instead:
`./openstack-lab-trainee/deploy.sh openstack-lab-trainee/scenarios/04-aio-complet.env`.

`verify.sh` creates a test VM, checks the network and, depending on the services present, Cinder,
Barbican, volume encryption, Designate and Heat, then cleans up. It does not check Octavia: adding it
is verified in step 1 of TP 15.
It ends with `Résultat : N réussis, 0 échoués` (N passed, 0 failed) and returns an error code if a
test fails.

### Parameters

Parameters are set in the scenario file, or as environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `OPENSTACK_RELEASE` | `2025.1` | Kolla-Ansible branch / image version |
| `WORKDIR` | `~/kolla` | venv, inventory, logs |
| `MGMT_IF` / `MGMT_IP` | detected from the default route | Interface/IP of the APIs |
| `EXT_CIDR` / `EXT_GW` | `10.0.2.0/24` / `10.0.2.1` | Neutron external network |
| `EXT_POOL_START` / `EXT_POOL_END` | `10.0.2.100` / `10.0.2.200` | Floating IP range |
| `ENABLE_CINDER` | `no` | Enables Cinder (LVM backend) |
| `CINDER_DEVICE` | empty | Empty disk dedicated to Cinder; empty = loop file |
| `CINDER_LOOP_SIZE_GB` | `20` | Size of the loop file |
| `ENABLE_HEAT` | `no` | Heat orchestration (about 1 GB of extra memory, measured); TP 14 enables it |
| `ENABLE_OCTAVIA` | `no` | Octavia load balancing (0.7 to 1.2 GB of extra memory, measured; plus a 1 GB VM, the amphora, per load balancer); TP 15 enables it |
| `OCTAVIA_AMP_IMAGE_URL` | test image of the Octavia project (Ubuntu 24.04) | Amphora image, downloaded and registered once |
| `ENABLE_BARBICAN` | `no` | Secret management; required to encrypt Cinder volumes |
| `ENABLE_DESIGNATE` | `no` | DNS (bind9 backend on the host, port 53) |
| `ENABLE_LAB_BACKUP` | `no` | S3 object storage (Garage, outside Kolla), restic and s3cmd, for TP 10 |
| `DESIGNATE_NS_RECORD` | `ns1.lab.example` | Name server of the zones, without the trailing dot (Kolla adds it) |
| `NEUTRON_DNS_DOMAIN` | `lab.example.` | DNS domain of Neutron ports, with the trailing dot; never `openstacklocal.` (Neutron would then ignore port names) |

### If it fails

Read the log shown (`~/kolla/deploy-*.log`), fix the cause, then run `deploy.sh` again: it is
idempotent. Running it again on an existing deployment re-checks every service and takes longer than
the first deployment: it is not stuck (follow the log with `tail -f ~/kolla/deploy-*.log`).

To remove everything:
```bash
./openstack-lab-trainee/destroy.sh            # OpenStack containers and data
./openstack-lab-trainee/destroy.sh --purge    # + config, venv, host network, Cinder storage; then sudo reboot
```

---

## 4. What `deploy.sh` does

1. **Pre-checks**: not root, sudo OK, OS, RAM, CPU, interface/IP and KVM detection, safeguard on
   `CINDER_DEVICE`; with Barbican/Designate: warning below 16 GB of RAM, refusal if port 53 is
   already in use.
2. **System packages** (non-interactive, including `lvm2` and `dig`; `isc-dhcp-client` with Octavia),
   8 GB swap, hostname in `/etc/hosts` (required by RabbitMQ).
3. **Host network**: `tools/openstack-lab-net.sh`, installed as the systemd service `openstack-lab-net`.
4. **(Cinder)** loop file (service `openstack-lab-cinder-loop`) or disk, then the LVM volume group
   `cinder-volumes`.
5. **Kolla-Ansible** in a venv + `python-openstackclient`, `python-barbicanclient`,
   `python-designateclient`, versions pinned by the *upper-constraints*.
6. `install-deps`, then `kolla-genpwd`, which fills in missing passwords without changing existing ones.
7. **Configuration**: `/etc/kolla/globals.yml` fully rewritten + files in `/etc/kolla/config/`.
8. `bootstrap-servers` → `prechecks` → `pull` → `deploy` → `post-deploy`; with Octavia, before the
   prechecks, `octavia-certificates` (amphora certificate authority and certificates, only once).
9. **(Octavia)** amphora image downloaded and registered in the `service` project (only once).
10. **Demo resources** (`init-runonce`), only on the first deployment.

---

## 5. Network architecture

### 5.1 How OpenStack networking (Neutron) normally works

The following holds for any OpenStack deployment with ML2/Open vSwitch:

| Neutron element | Role |
|---|---|
| **Tenant network** (`demo-net`, 10.0.0.0/24, VXLAN) | Private network of a project's VMs, isolated from other projects |
| **`br-int`** (OVS integration bridge) | VMs are plugged into it; OVS enforces isolation there |
| **Neutron router** (`demo-router`, namespace `qrouter-…`) | Connects the tenant network to the external network; performs NAT (SNAT outbound, DNAT for floating IPs) |
| **External network** (`public1`, flat, `physnet1`) | Network floating IPs come from; Neutron assumes it is connected to a real network |
| **`br-ex`** (OVS external bridge) | Connects the router to the external network, through the `neutron_external_interface` interface |
| **Floating IP** | Address of the external network that the router translates to a VM's private IP |

On a typical physical server, a second network card plugged into a switch is given to `br-ex`, and
floating IPs are real LAN addresses: Neutron itself answers ARP requests for these addresses.

### 5.2 The adaptation for a cloud instance with a single interface

The network of a cloud such as AWS is not a switch: it only accepts the addresses it assigned to the
instance's interface itself (details in [aws/aws-setup.md §2.3](aws/aws-setup.md), in French).
So an external network internal to the host is created, and the host bridges it by NAT:

```
                     Internet
                        │
              ┌─────────┴──────────┐  cloud firewall (AWS Security Group)
              │  enX0 172.31.x.x   │  public IP translated by the cloud
              │                    │
   OpenStack APIs, Horizon :80     │  iptables MASQUERADE 10.0.2.0/24 -> enX0
              │                    │
              │  veth-ext 10.0.2.1/24   gateway of the external network
              │      ║ veth pair (virtual cable)
              │  veth-neutron ── br-ex (OVS) ── Neutron router ── br-int ── VM
              └────────────────────┘
   public1  : 10.0.2.0/24 (flat), floating IPs from 10.0.2.100 to 10.0.2.200
   demo-net : 10.0.0.0/24 (VXLAN), router demo-router
```

| Network | Range | Use of addresses |
|---|---|---|
| `public1` (external) | 10.0.2.0/24 | 10.0.2.1: `veth-ext`, the gateway on the host; 10.0.2.100 to 10.0.2.200: the pool Neutron draws floating IPs (101 addresses, `EXT_POOL_START` and `EXT_POOL_END`, §3) and router gateways from; the rest is unused |
| `demo-net` (project) | 10.0.0.0/24 | Private addresses of the VMs, assigned by DHCP |

The path of a packet leaving a VM:

| Step | Layer | What happens |
|---|---|---|
| VM → `br-int` → Neutron router | OpenStack | The router translates 10.0.0.x into floating IP 10.0.2.x |
| Router → `br-ex` → `veth-neutron` | OpenStack | Standard behaviour; `veth-neutron` plays the role of the "second network card" |
| `veth-ext` → `enX0` | Linux host | `veth-ext` (10.0.2.1) is the gateway; iptables replaces the source with the interface's IP |
| `enX0` → Internet | Cloud (AWS) | The packet carries the interface's IP and MAC: the cloud accepts it and translates it to the public IP |

Consequences:
- **nothing is changed on the OpenStack side**: Neutron, `br-ex` and floating IPs work as usual;
- **the adaptation is on the host** (veth + NAT, service `openstack-lab-net`);
- floating IPs are only reachable from the host (or through an SSH tunnel). To make them public:
  scenario 03, described in [aws/aws-setup.md §4](aws/aws-setup.md).

No VIP either: HAProxy/keepalived/ProxySQL are disabled and `kolla_internal_vip_address` = the host IP.

---

## 6. Deployed services

| Service | Role | Container(s) | Port(s) on the host IP |
|---|---|---|---|
| Keystone | Identity | `keystone`, `keystone_fernet`, `keystone_ssh` | 5000 |
| Glance | Images | `glance_api` | 9292 |
| Nova | Compute (libvirt) | `nova_api`, `nova_scheduler`, `nova_conductor`, `nova_novncproxy`, `nova_compute`, `nova_libvirt`, `nova_ssh` | 8774, 6080 (VNC console) |
| Placement | Resource inventory | `placement_api` | 8780 |
| Neutron (ML2/OVS) | Networking | `neutron_server`, `neutron_openvswitch_agent`, `neutron_l3_agent`, `neutron_dhcp_agent`, `neutron_metadata_agent` | 9696 |
| Open vSwitch | Virtual switch | `openvswitch_db`, `openvswitch_vswitchd` | none |
| Horizon | Web dashboard | `horizon` | 80 |
| Cinder *(scenarios 02, 04)* | Block storage | `cinder_api`, `cinder_scheduler`, `cinder_volume`, `tgtd`, `iscsid` | 8776 |
| Barbican *(scenario 04)* | Secrets, keys of encrypted volumes | `barbican_api`, `barbican_worker`, `barbican_keystone_listener` | 9311 |
| Designate *(scenario 04)* | DNS as a Service | `designate_api`, `designate_central`, `designate_worker`, `designate_producer`, `designate_mdns`, `designate_backend_bind9` | 9001 (API), 53 (DNS, bind9), 5354 (mdns), 953 (rndc) |
| Platform object storage *(scenario 04, outside Kolla)* | S3 for backups (TP 10) | `lab-s3` (Garage v2.4.1), data in `/srv/lab-s3` | 3900 (S3), 3901 and 3903 on 127.0.0.1 |
| MariaDB (single-node Galera) | Database | `mariadb` | 3306 |
| RabbitMQ | Message bus | `rabbitmq` | 5672 |
| Memcached | Cache | `memcached` | 11211 |
| Fluentd, cron, kolla_toolbox | Logs, rotation, tools | `fluentd`, `cron`, `kolla_toolbox` | none |

Not deployed:
- Heat (orchestration): disabled to save memory; TP 14 adds it (`ENABLE_HEAT=yes` in scenario 04),
  then removes it;
- Octavia (load balancing): disabled for the same reason; TP 15 adds it (`ENABLE_OCTAVIA=yes` in
  scenario 04), then removes it;
- Barbican and Designate: only in scenario 04;
- **Swift (object storage): no longer exists in Kolla-Ansible 2025.1** (no role, no `enable_swift`
  variable). The Kolla alternative, `ceph-rgw` (Swift-compatible API), requires an external Ceph
  cluster. For TP 10, the platform provides a lightweight S3 server (Garage) instead, outside Kolla;
- Cinder backup: would require Swift, Ceph or NFS;
- HAProxy, keepalived, ProxySQL: useless on a single node (see §5.2).

### Configuration files

| File | Contents |
|---|---|
| `/etc/kolla/globals.yml` | Main configuration (generated by `deploy.sh`) |
| `/etc/kolla/passwords.yml` | All the secrets (never commit it) |
| `/etc/kolla/config/galera.cnf` | `innodb_buffer_pool_size = 1G` |
| `/etc/kolla/config/nova/nova-compute.conf` | `resume_guests_state_on_host_boot`, and with QEMU `virt_type`, `cpu_mode` |
| `/etc/kolla/config/cinder.conf` (with Cinder) | `[keystone_authtoken] service_type = volumev3`: without it, Cinder rejects application credentials with access rules (TP 04 bis) |
| `/etc/kolla/<service>/` | Rendered configuration of each service (overwritten on every deployment: do not edit) |
| `/etc/kolla/admin-openrc.sh`, `/etc/kolla/clouds.yaml` | Admin CLI credentials |
| `/etc/openstack-lab/network.env` | Host network parameters (read at boot) |
| `/etc/openstack-lab/public-fip.map` | Published floating IPs (scenario 03) |
| `~/kolla/all-in-one` | Ansible inventory |
| `/var/log/kolla/<service>/` | Service logs |

To change an option: edit `globals.yml` or add a file in `/etc/kolla/config/<service>/`, then
`kolla-ansible reconfigure -i ~/kolla/all-in-one --tags <service>`.
Note: `deploy.sh` rewrites `globals.yml`; a lasting change belongs in the script or the scenario.

---

## 7. Access

| Access | How |
|---|---|
| SSH to the host | `ssh -i ec2_key ubuntu@<IP_PUBLIQUE>` |
| Horizon | `http://<IP_PUBLIQUE>/` if the Security Group opens port 80 to your IP, otherwise through an SSH tunnel (§9). The VM console always goes through the tunnel (port 6080, §9). Login form: user `admin` and its password (no domain or region to choose) |
| Admin password | `grep keystone_admin_password /etc/kolla/passwords.yml` |
| CLI | `source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh`, then `openstack ...` (repeat in every new SSH session) |
| VMs from the instance | Key `mykey` (= `~/.ssh/id_ecdsa` on the instance): `ssh cirros@<FLOATING_IP>` |
| VMs from your workstation | Create the VM with your own keypair, then jump through the instance (free): see "Connecting to a VM from your workstation" below |

Resources created on the first deployment: image `cirros`, flavors `m1.tiny` → `m1.xlarge`, networks
`public1` and `demo-net`, router `demo-router`, keypair `mykey`, ICMP + SSH rules in the `default`
group.

### Examples
```bash
# On the instance. Load the OpenStack client and the admin credentials
# (repeat in every new SSH session, otherwise: "Command 'openstack' not found")
source ~/kolla/venv/bin/activate
source /etc/kolla/admin-openrc.sh

# Start a VM and make it reachable from the host
openstack server create --image cirros --flavor m1.tiny --key-name mykey --network demo-net --wait vm1
FIP=$(openstack floating ip create public1 -f value -c floating_ip_address)
openstack server add floating ip vm1 $FIP
ssh cirros@$FIP

# Scenario 02: add a persistent disk
openstack volume create --size 1 vol1
openstack server add volume vm1 vol1        # visible in the VM as /dev/vdb
```

### Connecting to a VM from your workstation

The private key of `mykey` is on the instance, and the floating IP only exists inside the instance.
So you need to create the VM with your own keypair and jump through the instance. The possible
methods (ProxyJump, ProxyCommand, `~/.ssh/config`, agent forwarding, port tunnel…) are described and
tested in [TP 02, step 6](tps/tp02/tp02-instances-ssh.md) (in French). Direct connection from the
Internet goes through scenario 03 ([aws/aws-setup.md §4](aws/aws-setup.md)).

---

## 8. Technical choices

| Choice | Why |
|---|---|
| Kolla-Ansible `stable/2025.1` + upper-constraints | Pinned versions: reproducible deployment |
| `set -Eeuo pipefail` + trap showing the failing line | Stops at the first error, with the log |
| One script + scenario files | A single logic to maintain; variants differ only by their parameters |
| `enable_loadbalancer: "no"` (+ haproxy/keepalived/proxysql set to `no`) | Since 2024.2 this variable disables the load balancer. Otherwise ProxySQL takes port 3306 and MariaDB does not start |
| Persistent veth pair + NAT | A single network interface (see §5) |
| Interface and IP detected with `ip route` | Works whatever the interface name |
| `globals.yml` rewritten on every run | No duplicates; the scenario is authoritative |
| `/dev/kvm` detection, otherwise `qemu` + `cpu_mode=none` | Instances without hardware virtualisation |
| InnoDB limited to 1 GB | By default MariaDB reserves ~40 % of the RAM |
| `resume_guests_state_on_host_boot = true` | VMs restart after a host reboot |
| Cinder on a loop file by default | No extra disk to buy |
| Refuses a `CINDER_DEVICE` that contains data | Avoids erasing a disk by mistake |
| `destroy.sh` removes the Docker volumes left by `kolla-ansible destroy` | A redeployment really starts from scratch |
| `destroy.sh` stops the VMs before `kolla-ansible destroy` | `destroy` refuses to run while qemu processes are running |
| `kolla-genpwd` on every run | It only fills empty passwords: added services get their secrets, existing ones do not change |

---

## 9. Security

1. **Horizon uses plain HTTP**: if the cloud firewall opens port 80 to everyone (`0.0.0.0/0`), the
   admin password travels in clear text over the Internet. Two options:
   - **restrict port 80 of the Security Group to your IP** (source `<VOTRE_IP>/32`, your IP);
   - **or close port 80 and use an SSH tunnel**:
     ```bash
     ssh -i ec2_key -N -L 8080:<IP_PRIVEE>:80 -L 6080:<IP_PRIVEE>:6080 ubuntu@<IP_PUBLIQUE>
     ```
     in a dedicated terminal (`-N`: no shell; `Ctrl+C` closes the tunnel), then open
     `http://localhost:8080`. `<IP_PRIVEE>` is the private IP of the instance. Forwarding port 6080
     is used by the VM console in Horizon: it is never opened in the Security Group, even when port
     80 is.
   → Eventually, enable TLS: `kolla_enable_tls_external: "yes"` + a certificate
   (`kolla-ansible certificates` for a lab).
2. The APIs (5000, 8774, 9696…) must not be opened in the cloud firewall.
3. `passwords.yml` contains all the secrets: back it up outside the instance, do not commit it.
4. SSH keys and AWS credentials: never in clear text in a chat, an e-mail or a Git repository
   (the repository's `.gitignore` excludes keys and generated secrets).

---

## 10. Limits and possible improvements

Limits related to the infrastructure (QEMU performance, public floating IPs, storage):
see [aws/aws-setup.md](aws/aws-setup.md). Costs: [aws/finops.md](aws/finops.md).

Limits and ideas on the OpenStack side:
- **Single node, no high availability**: everything stops with the instance. Next step: a
  `multinode` inventory (controller + compute) on several instances.
- **RAM**: ~7 GB used when idle out of 16; little room for VMs.
- Monitoring (`enable_prometheus`, `enable_grafana`) and centralised logs (`enable_central_logging`)
  with ≥ 32 GB.
- MariaDB backup: `enable_mariabackup: "yes"`, then `kolla-ansible mariadb_backup`.
- More useful images (Ubuntu cloud image) and suitable quotas.
- Upgrade: change `OPENSTACK_RELEASE` and follow `kolla-ansible upgrade` (one release at a time).
- Automated deployment when the instance is created (cloud-init *user-data*, Terraform).

---

## 11. Troubleshooting

| Symptom | Lead |
|---|---|
| `Timeout when waiting for search string MariaDB` | `sudo ss -ltnp \| grep 3306`: is ProxySQL using the port? Check `enable_loadbalancer: "no"` |
| A `fatal:` in the log but the deployment goes on | Normal: some Kolla probes are `ignore_errors`; only the `PLAY RECAP` (`failed=0`) counts |
| Container restarting | `sudo docker ps -a`, `sudo docker logs <name>`, `sudo ls /var/log/kolla/<service>/` (folder reserved to root) |
| Stop / restart a service | Each container is driven by the systemd unit `kolla-<container>-container.service` (`Restart=always`): `sudo systemctl stop\|start\|restart kolla-<container>-container.service`. A `docker stop` is undone by systemd |
| `Command 'openstack' not found` | Load the environment in the session: `source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh`. Do not install Ubuntu's `snap`/`apt` client (too old) |
| `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!` when connecting to a VM over SSH | The floating IP was reused by a new VM: `ssh-keygen -R <FLOATING_IP>` |
| `Permission denied (publickey)` when connecting to a VM over SSH | The VM was created with `mykey`, whose private key is on the instance: connect from the instance, or recreate the VM with your keypair (§7, "Connecting to a VM from your workstation") |
| SSH to a VM does not answer right after its creation | The system boots in ~1 min (QEMU emulation): follow `openstack console log show <vm>` until `login:` |
| VM in ERROR | `openstack server show <vm> -c fault`, `/var/log/kolla/nova/nova-compute.log` |
| Floating IP unreachable | `ip a show veth-ext`, `systemctl status openstack-lab-net`, `sudo iptables -t nat -S POSTROUTING`, OpenStack security group of the VM (`openstack security group rule list default`) |
| Cinder volume in `error` | `sudo vgs cinder-volumes`, `systemctl status openstack-lab-cinder-loop`, `/var/log/kolla/cinder/cinder-volume.log` |
| `kolla-ansible destroy` fails: "Some qemu processes were detected" | VMs are still running: `destroy.sh` stops them (`virsh destroy`) before running `destroy`. Manually: `sudo docker exec nova_libvirt virsh list`, then `virsh destroy <name>` |
| Horizon: error 500 on the login page | `sudo grep OfflineGenerationError /var/log/kolla/horizon/horizon-error.log`: stale compression of static files (seen after adding scenario 04 to an existing deployment; `deploy.sh` now fixes it). Manually: `sudo docker exec horizon rm -f /var/lib/kolla/.settings.md5sum.txt && sudo systemctl restart kolla-horizon-container.service` |
| Out of disk space | `sudo docker system df`, `df -h` |
