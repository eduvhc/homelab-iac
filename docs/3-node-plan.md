# Plano de migração para 3-node

Documento vivo. Atualizar à medida que os specs reais das 2 novas máquinas forem conhecidos.

## Estado atual (1 node)

| Componente | Onde | Notas |
|---|---|---|
| PVE 9.2.3 | Beelink N100, 16 GB, SSD M.2 512 GB | OK, hardened |
| Coolify LXC 200 | local-lvm, 4c/6G/60G | tunnel CF ativo |
| Ops LXC 101 | local-lvm, 2c/512M/10G | tofu + sops + git |
| Backups | HDD USB 2 TB SMR, vzdump diário | SMR é o teto; OK para dev/lab |
| Tunnel CF | 1 réplica no LXC 200 | 4 conns ao edge |

## Pressupostos das 2 novas máquinas

Spec mínimo desejável (ajusta após compra):

- CPU x86_64 com VT-x/VT-d (Intel iGPU N-series, AMD Ryzen 5000+, ou Xeon-D)
- RAM ≥ 32 GB cada (idealmente 64 GB para ter folga)
- 1 NVMe ≥ 1 TB para sistema + workloads
- 1 SATA/NVMe extra para ZFS / dados separados
- 2.5 GbE mínimo, 10 GbE ideal se vais usar Ceph
- IPMI/BMC ou IP KVM seria útil mas raro nesta classe

## Decisões arquitecturais

### A. Cluster sim ou não?

**Recomendação: cluster de 3 nodes.**

- ✅ Quórum natural (precisas 2/3 nodes up; aguenta perda de 1)
- ✅ Live migration entre nodes (mover Coolify sem downtime)
- ✅ Datacenter view única
- ✅ HA opcional, ativável por VM/CT
- ❌ Pega: corosync exige rede estável; latência <2 ms entre nodes; **adicionar/remover nodes mais tarde é frágil** (especialmente remover)

Alternativa "3 standalone": só vale se quiseres isolamento absoluto. Perdes live migration e tens de coordenar manualmente.

### B. Storage strategy

Quatro opções, em ordem de complexidade:

| Opção | Prós | Contras | Veredito |
|---|---|---|---|
| **Local-only (LVM/ZFS por node) + PBS para backup** | Simples, performante, sem rede a depender | Sem live migration de discos. Para migrar VM = stop + replicate + start | **Recomendado para começar** |
| **ZFS + pve-zsync** (replicação async) | Adiciona DR. Migration "quente" para nodes com cópia | Cada réplica = +1 GB por GB; janela de RPO | **Opção 2** quando quiseres HA |
| **NFS shared de 1 node** | Live migration "barata" | SPOF: o NFS-host morre = todos param | Evita |
| **Ceph (3-node mínimo)** | Replicação real, scale-out | Quer **10 GbE dedicada**, ~30% overhead RAM/CPU, complexidade operacional alta | **Não** sem 10 GbE |

### C. Backup target

**Recomendação: PBS 4.2 dedicado num dos 3 nodes (LXC ou VM).**

- Substitui o vzdump-para-USB. Dedupe ~10-20× em VMs parecidas.
- LXC simples (oficialmente VM mas a comunidade usa LXC em homelab há anos)
- Datastore num SSD/NVMe (não no HDD SMR que tens!)
- O HDD USB sobrevive como **cópia secundária offline** (sync periódico do PBS para lá)

PBS num **4º** dispositivo seria mais correcto (sobrevive à perda do host onde corre), mas tu ainda tens o Beelink + USB como "off-site improvisado".

**Novidades PBS 4.2 (Abr 2026) que mudam o desenho:**

- **Native S3 object storage backend**: o datastore pode ser um bucket S3-compat (MinIO local, Wasabi, Backblaze B2). Reduz a dependência do disco local do node onde PBS corre — se esse node morrer, o backup sobrevive no S3.
- **Server-side encryption em push sync jobs**: ao replicar para um segundo PBS (ou para o HDD USB como datastore secundário), os snapshots são encriptados antes do envio. Útil para o teu "off-site improvisado" sem confiar no destino.
- **Improved multi-datastore sync**: configurar PBS-no-LXC + cópia para HDD USB como segundo datastore com sync agendado fica nativo, sem rsync à parte.

**Plano revisto**: PBS num LXC em `pve01` com datastore principal num bucket MinIO (correr MinIO noutro LXC ou usar o do Coolify), e cópia secundária para o HDD USB com server-side encryption.

### D. Roles dos nodes

Proposta:

| Node | Papel | Workloads |
|---|---|---|
| **pve01** (nova máquina forte) | Compute primário | Coolify, apps de produção, PBS-datastore |
| **pve02** (nova máquina forte) | Compute secundário | Workloads dev/lab, k8s nodes, NixOS VMs |
| **pve03** (Beelink) | Compute light + serviços de infra leves | DNS interno, Adguard, ops LXC, segunda réplica cloudflared para tunnel HA |

O Beelink fica útil mas não-crítico. Quando morrer, basta tirá-lo do cluster.

## Plano de execução

### Fase 0 — Antes das máquinas chegarem (faz agora)

- [ ] Hostnames decididos: **pve01** (nova), **pve02** (nova), **pve03** (Beelink)
- [ ] IPs estáticos reservados no router: **pve01=192.168.50.51**, **pve02=192.168.50.52**, **pve03=192.168.50.53** (Beelink mantém-se)
- [ ] Definir VLANs (mesmo só uma, marca como tagged em vmbr0 para futuro)
- [ ] Confirmar que router tem DHCP fora do range planeado
- [ ] Backup verificado da config actual do Beelink: `/etc/pve` + `vzdump` de 200 e 101
- [ ] Anotar o tunnel ID actual (`tofu output tunnel_id`) - vai sobreviver à migração

### Fase 1 — Day 0: chegada das máquinas

- [ ] Instalar PVE 9.x em ambas (mesma versão que o Beelink)
- [ ] Hardening idêntico ao que fizemos: `pve-no-subscription`, `apt full-upgrade`, SSH key-only, root@pam key-only, `eduvhc@pve` + TFA, locale, kernel cleanup
- [ ] Adicionar a SSH key do Mac e da ops-lxc a `/etc/pve/priv/authorized_keys` em cada
- [ ] Configurar NTP (chrony) - **clock skew entre nodes mata corosync**
- [ ] Network: bridge `vmbr0` igual, IP fixo, `nofail` em fstabs USB se houver

### Fase 2 — Day 1: cluster

Esta é a fase frágil. **Não há rollback fácil. Fazer com tempo.**

```bash
# No node mais limpo (uma das máquinas novas), criar cluster
pvecm create homelab

# Nos outros dois
pvecm add <IP_do_primeiro> --link0 <ip_local>
```

- [ ] Verificar quorum: `pvecm status` mostra `Total votes: 3`
- [ ] Verificar pmxcfs sincronizado: `/etc/pve/.members` em todos os nodes mostra os 3
- [ ] Decidir se quero **dedicated corosync link**: cabo ethernet direto (`vmbr1`) entre os 3 numa rede /24 isolada, para não competir com tráfego LAN. Recomendado se tiveres NICs spare; ignora se for só 1 NIC por node.

⚠️ Adicionar o Beelink AO cluster é opcional. Se o adicionares, tens de o **wipe-reinstall** ou usar `pvecm add` com `--use_ssh` — a primeira é mais fiável. Antes disso: vzdump dos 200/101, restore depois noutro node.

### Fase 3 — Day 2: storage

- [ ] Em cada node novo, criar pool ZFS no 2º disco: `zpool create -o ashift=12 tank /dev/nvme1n1`
- [ ] Em PVE: Datacenter → Storage → Add ZFS → pool `tank`, content `images, rootdir`
- [ ] Optional: enable replication entre nodes (Datacenter → Replication) - async, RPO 15 min default
- [ ] Setup PBS:
  - Cria LXC `pbs` em `pve01`, Debian 13, 2c/4G/100G (ou maior)
  - Datastore num dataset ZFS dedicado: `zfs create tank/pbs-store`
  - `apt install proxmox-backup-server`, configura datastore via UI
  - Adiciona como storage `pbs-main` no datacenter PVE
  - Migra job `daily-all` do vzdump-para-HDD para PBS

### Fase 4 — Day 3: migrar Coolify + ops

Opções:

**4a) Live migration** (se os 3 nodes estão no cluster e Coolify está em ZFS replicado):
```bash
pct migrate 200 pve01 --online --with-local-disks --target-storage local-zfs
pct migrate 101 pve03 --online --with-local-disks --target-storage local-zfs
```

**4b) Stop+backup+restore** (mais seguro, downtime ~10 min):
```bash
# No Beelink
vzdump 200 --storage pbs-main --mode stop
vzdump 101 --storage pbs-main --mode stop
# No node de destino
pct restore 200 pbs-main:backup/vzdump-lxc-200-...
```

Recomendação: **4b primeiro** (testa o pipeline PBS), depois 4a para o dia-a-dia.

### Fase 5 — Day 4: tunnel + Coolify retoma

Após o LXC 200 estar no novo node:
- Verifica que `cloudflared` arrancou (`systemctl status`)
- Verifica que `https://coolify.<homelab_domain>` ainda responde
- Verifica que as apps (se já tiveres deployed) seguem em `<x>.<homelab_domain>`

**Tunnel HA**: o mesmo tunnel pode correr em vários LXCs (4 conns por instância). Para redundância:
```bash
# Instalar cloudflared num 2º LXC noutro node, com o MESMO token
cloudflared service install <SAME_TUNNEL_TOKEN>
```
Agora se um node cair, o outro continua a servir. Custo: 0 (CF não cobra por conns extra).

## Updates ao homelab-iac

O repo OpenTofu vai precisar de pouco:

1. **Variáveis em `variables.tf`**: adicionar `cloudflared_replicas = 1` (futuro multi-node)
2. **Outputs**: já temos `tunnel_token` - reutilizável
3. **Novo módulo** (opcional, futuro): `modules/pve-host/` que descreve um node PVE como recurso (mas o provider Proxmox é frágil; talvez não valha)
4. **Repo paralelo** sugestão: `homelab-pve` com a config dos nodes (LXCs, VMs, storages) via provider `bpg/proxmox` - **só** quando o cluster estiver estável; tentar antes é dor.

## Riscos e mitigações

| Risco | Mitigação |
|---|---|
| Cluster split-brain por falha de corosync | Dedicated link OU redundant rings em vmbr0 |
| Beelink no cluster com hardware diferente | Não dar HA workloads ao Beelink |
| PBS no host onde corre = SPOF | Sync periódico para HDD USB (off-site improvisado) |
| Tunnel token leak | Rodar via `tofu apply` (random_id recria) |
| Clock skew | chrony obrigatório em todos os nodes, mesma fonte NTP |
| Storage migration sem replication | Stop+backup+restore (Fase 4b) é sempre OK |

## Checklist "ready to migrate"

Antes de tocares na produção (Coolify) com o cluster:

- [ ] 3 nodes em `pvecm status` com `Total votes: 3`
- [ ] PBS up + 1 backup test do LXC 200 corre OK + restore test passa
- [ ] cloudflared num 2º node a servir o mesmo tunnel (validado com `cloudflared tunnel info`)
- [ ] DNS interno (se vais ter) a resolver para os 3 nodes
- [ ] Documentação deste plano atualizada com specs reais e datas

## Pós-migração (1 mês depois)

Coisas para considerar depois de tudo estável:

- [ ] Avaliar se queres HA para o Coolify (precisa replication + cluster stable)
- [ ] Avaliar Ceph se acrescentares 10 GbE (raro em homelab)
- [ ] Configurar `homelab-pve` IaC (LXCs declarativos)
- [ ] Adicionar monitoring (Prometheus + Grafana ou Netdata Cloud)
- [ ] Adicionar 1 VM NixOS para experimentação contínua
