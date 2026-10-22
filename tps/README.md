**English** · [Français](README.fr.md)

# Lab path: OpenStack on AWS

> Audience: trainees and work-study students. No prior knowledge of OpenStack is assumed; you need to
> be comfortable with a Linux terminal and SSH.
>
> Each lab (TP, *travaux pratiques*) states its objectives, its prerequisites, the guided steps,
> comprehension questions and validation criteria. Sources and references are in
> [sources.md](sources.md).
>
> **The labs are written in French.** This page is their English index.

---

## 1. Progression

The labs follow the life of the project: you discover the infrastructure, deploy, use, then operate
and extend the platform.

| TP | Title | Project phase | Scenario | Status |
|---|---|---|---|---|
| [00](tp00/tp00-preparer-instance.md) | Prepare and discover the AWS instance | Before deployment | none | Ready |
| [01](tp01/tp01-deployer.md) | Deploy OpenStack and verify the deployment | Deployment | 01 | Ready |
| [02](tp02/tp02-instances-ssh.md) | Launch instances from the host and connect to them over SSH | Use | 01 | Ready |
| [03](tp03/tp03-reseau-neutron.md) | Understand Neutron networking | Use | 01 | Ready |
| [04](tp04/tp04-volumes-cinder.md) | Persistent storage: volumes, mounting, snapshots | Use | 02 | Ready |
| [04 bis](tp04-bis/tp04-bis-revenir-en-arriere.md) | Going back: snapshots, revert, re-image | Use | 02 | Ready |
| [05](tp05/tp05-exploitation.md) | Operate the platform: logs, failures, reconfiguration | Operations | 01 or 02 | Ready |
| [05 bis](tp05-bis/tp05-bis-qui-a-fait-quoi.md) | Who did what? Tracing API calls (after TP 06 bis) | Operations | 01 or 02 | Ready |
| [06](tp06/tp06-projets-quotas.md) | Projects, users, roles and quotas | Operations | 01 or 02 | Ready |
| [06 bis](tp06-bis/tp06-bis-identites-automates.md) | Identities for automation: tokens, application credentials, access rules | Operations | 01 or 02 | Ready |
| [07](tp07/tp07-reseau-aws.md) | Public floating IPs and AWS networking | Extension | 03 | Ready (no cost) |
| [08](tp08/tp08-secrets-barbican.md) | Manage secrets with Barbican | Extension | 04 | Ready |
| [08 bis](tp08-bis/tp08-bis-faire-vivre-secrets.md) | The life of a secret: renew, share, group | Extension | 04 | Ready |
| [09](tp09/tp09-volumes-chiffres.md) | Encrypt Cinder volumes | Extension | 04 | Ready |
| [10](tp10/tp10-sauvegardes-restic.md) | Back up a VM: local repository, object storage, copy outside the host | Extension | 04 | Ready (no cost) |
| [11](tp11/tp11-dns-designate.md) | DNS as a Service with Designate | Extension | 04 | Ready |
| [12](tp12/tp12-cloud-init.md) | Configure VMs at boot with cloud-init | Extension | 02 or 04 | Ready |
| [12 bis](tp12-bis/tp12-bis-depanner-vm.md) | Troubleshoot a VM: regain control with rescue mode, resume a failed cloud-init configuration | Extension | 02 or 04 | Ready |
| [13](tp13/tp13-deploiement.md) | Final lab: deploy a secure architecture on OpenStack ([architecture](tp13/tp13-architecture.md)) | Synthesis | 04 | Ready (step 15 optional and charged) |
| [13 bis](tp13-bis/tp13-bis-administrer-base.md) | Administer the database without opening a port: dedicated role, least privilege, tunnel, audit trail | Synthesis (after step 14 of TP 13) | 04 | Ready |
| [14](tp14/tp14-heat.md) | Bonus lab: redeploy the same architecture with Heat, infrastructure described as code | Bonus | 04, Heat added by the lab | Ready |
| [15](tp15/tp15-octavia.md) | Bonus lab: load balancing with Octavia, HTTPS with a certificate stored in Barbican, failover, least-privilege access | Bonus | 04, Octavia added by the lab | Ready |

Not tested on the platform, and flagged as such in the instructions: the AWS part of scenario 03 and
the "cloud" level 3 of TP 10 (charged).

### TP 13 then TP 14 (bonus): the same architecture, two methods

TP 13, the final lab of the path, builds the architecture resource by resource, on the command line.
TP 14, as a bonus, rebuilds it with Heat, from a template that describes it. Both builds pass the
same checks: that is what makes them comparable.

| | TP 13: command by command | TP 14: Heat template |
|---|---|---|
| What you write | One command per resource, in the right order | A file that describes the desired state; Heat works out the order from the dependencies |
| Build, destroy | Every step; cleanup in reverse order, step by step | One command: `openstack stack create`, `openstack stack delete` |
| Change | A targeted command; nothing keeps the desired state | `openstack stack update`: Heat only changes what differs (observed: a rule changed in place, the VM kept) |
| Reproduce identically | Replay every command without error | Replay the same template; the file goes into git |
| What you learn | The role of each building block, layer-by-layer diagnosis | Describe, parameterise, version an infrastructure |
| What remains manual | Everything | The route, the firewall, the proxy and the host clock; the database secret, which a template must never contain |
| Observed limits | Omissions and typing errors; duration | Heat puts no tag on security groups or on the FIP, nor the FIP description; a group with no egress at all needs one more rule; the service uses about 1 GB of memory (measured) |

Resources created by Heat: their name starts with `ht-` (for example `ht-tp13-vm-web-haproxy-demo`),
to tell them apart at a glance from those created by hand.

---

## 2. Conventions

**Entry conditions.** A lab starts from the state left by the previous one. Each lab provides the
script `tps/tpNN/verifier-entree.sh`, which its step 0 runs: it checks, without changing anything,
that the platform is ready, and says what to do for each gap. Do not start until its last line is
`Lab prêt pour le TP NN.` (platform ready for TP NN).

Each command block states where to run it:

| Marker | Where | How to get there |
|---|---|---|
| `# [poste]` | Your computer (workstation) | you are there |
| `# [instance]` | The EC2 instance (the OpenStack host) | `ssh -i ec2_key ubuntu@<IP_PUBLIQUE>` |
| `# [VM]` | An OpenStack VM (CirrOS; Debian in TP 12 and 13) | `ssh cirros@<FLOATING_IP>` from the instance (in TP 12: `ssh -i ~/.ssh/tp12-key stack@<FLOATING_IP>`; in TP 13: `ssh -F ~/.ssh/tp13_config <VM>` from the workstation, through the bastion) |

```
Your workstation
   │  ssh -i ec2_key ubuntu@<IP_PUBLIQUE>
   ▼
┌─────────────────────────────────────────────────────────┐
│ The "instance": a virtual machine rented from AWS       │
│ (t2.xlarge). OpenStack is installed on it.              │
│                                                         │
│   ┌──────────────┐  ┌──────────────┐                    │
│   │ VM tp02-vm-1 │  │ VM tp02-vm-2 │  ← the "VMs":      │
│   │ (CirrOS)     │  │ (CirrOS)     │    created BY      │
│   └──────────────┘  └──────────────┘    OpenStack       │
└─────────────────────────────────────────────────────────┘
```

AWS and OpenStack both call their virtual machines "instances". In this path, *instance* always
means the AWS machine, and *VM* the machines created by OpenStack.

- Values between angle brackets are to be replaced: `<IP_PUBLIQUE>` (public IP of the instance,
  shown in the AWS console), `<FLOATING_IP>`, `<INSTANCE_ID>`…
- Before any `openstack` command, in every new SSH session on the instance:
  ```bash
  # [instance]
  source ~/kolla/venv/bin/activate
  source /etc/kolla/admin-openrc.sh
  ```
  Without it: `Command 'openstack' not found`. Do not install the client offered by Ubuntu
  (`snap`/`apt`): its version is too old.
- Resources created in a lab carry its prefix (`tp02-…`, `tp03-…`): you know what you can delete
  without touching anything else. Every lab ends with a cleanup.
- Floating IPs are reused: a new VM can receive the address of a deleted VM. SSH then refuses the
  connection (`WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`), because the VM's fingerprint has
  changed. This is expected on the platform: forget the old fingerprint with
  `ssh-keygen -R <FLOATING_IP>`, then reconnect.
- CirrOS, the image of the test VMs, is a minimal distribution: its commands are those of BusyBox
  (for example `ip addr` works, `ip -br addr` does not).

---

## 3. Platform rules

1. **No charged AWS resource without the tutor's approval** (Elastic IP, EBS volume, extra
   instance…). See [../aws/finops.md](../aws/finops.md) (in French).
2. **Never change the network of the `enX0` interface** of the instance (addresses, netplan,
   networkd): it is how the instance is administered, and a mistake makes it unreachable
   (see [../aws/aws-setup.md §6](../aws/aws-setup.md)).
3. **Stop the instance at the end of the day** (AWS console, *Stop*, never *Terminate*). OpenStack
   restarts on its own; the public IP changes.
4. No secret (SSH key, password, AWS key) in a chat, an e-mail or a Git repository.

---

## 4. Progress grid

Ticked by the trainee, validated by the tutor.

| TP | I can… | Trainee | Tutor |
|---|---|---|---|
| 00 | explain why OpenStack VMs run in emulation on this instance |  |  |
| 00 | tell apart public IP, private IP and AWS Security Group |  |  |
| 01 | deploy OpenStack, read the log and interpret `verify.sh` |  |  |
| 01 | state the role of Keystone, Nova, Neutron, Glance, Placement, Horizon |  |  |
| 02 | launch a VM, give it a floating IP and connect to it over SSH |  |  |
| 02 | explain what a keypair is and where the private key is |  |  |
| 02 | reach a VM from my workstation in several ways, and choose the safest |  |  |
| 03 | create a network, subnet, router and security group |  |  |
| 03 | follow the path of a packet from the VM to the Internet |  |  |
| 04 | create, attach, format, mount and detach a volume |  |  |
| 04 | explain the difference between an ephemeral disk and a volume |  |  |
| 04 bis | bring a volume back to an earlier state and rebuild a volume-backed VM without losing its data |  |  |
| 05 | find a service's log and diagnose a simple failure |  |  |
| 05 | change a configuration option durably |  |  |
| 05 bis | find who performed an action and follow a request through the logs, and say what they do not prove |  |  |
| 06 | create a project and a user, give them a role and quotas |  |  |
| 06 bis | say what a revoked token is worth, and give an automated process a credential limited by role, access rules and expiry |  |  |
| 07 | explain why a floating IP cannot be reached from the Internet on AWS |  |  |
| 08 | store, generate and protect a secret; explain the Barbican roles |  |  |
| 08 bis | renew a secret, share it through an ACL, group an application's secrets; say who a private secret protects against |  |  |
| 09 | encrypt a volume and say what this encryption protects against |  |  |
| 09 | protect the key of an encrypted volume against deletion |  |  |
| 10 | back up and restore a VM, and explain the 3-2-1 rule and the escrow of the password |  |  |
| 11 | publish DNS names, by hand and automatically through Neutron |  |  |
| 11 | restrict an automated process to the records of a single DNS zone |  |  |
| 12 | describe a VM's configuration in a cloud-init user-data, validate it and check it |  |  |
| 12 | say why a secret never goes into a user-data, and apply immutability |  |  |
| 12 bis | repair a VM's disk through rescue mode, and recognise a rescue that boots on the wrong disk |  |  |
| 12 bis | say what a VM's console allows and exposes, and why the "GRUB, `init=/bin/bash`" method does not apply to a cloud image |  |  |
| 12 bis | find why a cloud-init configuration failed, resume it without recreating the VM, and say what resuming changes |  |  |
| 13 | segment a network and write least-privilege security groups, for ingress and egress |  |  |
| 13 | administer VMs through a bastion, and control their outbound traffic through a proxy |  |  |
| 13 | diagnose asymmetric routing with `tcpdump`, and prove each refusal with a test |  |  |
| 13 bis | administer a database through an SSH tunnel without an open port, under a dedicated role, and review the trail of each action |  |  |
| 14 | add a service to a running cloud, then remove it cleanly |  |  |
| 14 | describe an infrastructure in a Heat template, create it, change it and destroy it |  |  |
| 14 | compare a manual build with a template build, and say what stays outside the template |  |  |
| 15 | put servers behind a load balancer and observe the failover when one goes down |  |  |
| 15 | terminate HTTPS with a certificate stored in Barbican, renew it and remove the accesses no longer needed |  |  |
| 15 | restrict the clients of a published service, and say what the project sees of the operator's infrastructure |  |  |
