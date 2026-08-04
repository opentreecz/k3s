# K3s Vysoce dostupná platforma pro nasazení na baremetal serverech

## Technický referenční dokument

**Verze:** 1.0.0  
**Poslední aktualizace:** Srpen 2026  
**Repozitář:** [github.com/opentreecz/k3s](https://github.com/opentreecz/k3s)  
**Webový generátor:** [opentreecz.github.io/k3s](https://opentreecz.github.io/k3s/)

---

## Obsah

1. [Shrnutí](#1-shrnutí)
2. [Přehled projektu](#2-přehled-projektu)
3. [Architektura](#3-architektura)
4. [Podrobný popis komponent](#4-podrobný-popis-komponent)
   - [4.1 Vrstva operačního systému](#41-vrstva-operačního-systému)
   - [4.2 Distribuce K3s Kubernetes](#42-distribuce-k3s-kubernetes)
   - [4.3 Load balancer HAProxy](#43-load-balancer-haproxy)
   - [4.4 Keepalived a virtuální IP](#44-keepalived-a-virtuální-ip)
   - [4.5 Distribuované úložiště Longhorn](#45-distribuované-úložiště-longhorn)
   - [4.6 Síťová architektura (DHCPv4/DHCPv6)](#46-síťová-architektura-dhcpv4dhcpv6)
5. [Postup nasazení](#5-postup-nasazení)
6. [Systém generování konfigurace](#6-systém-generování-konfigurace)
7. [Strategie dělení disků](#7-strategie-dělení-disků)
8. [Model zabezpečení](#8-model-zabezpečení)
9. [Architektura perzistentního úložiště](#9-architektura-perzistentního-úložiště)
10. [Kontinuální integrace a zajištění kvality](#10-kontinuální-integrace-a-zajištění-kvality)
11. [Webový generátor konfigurace](#11-webový-generátor-konfigurace)
12. [Souhrn](#12-souhrn)

---

## 1. Shrnutí

Tento projekt poskytuje kompletní automatizovanou platformu pro nasazení **vysoce dostupného clusteru K3s Kubernetes** na baremetal serverech. Platforma cílí na prostředí běžící na **SUSE Linux Enterprise Micro (SLE Micro)** nebo **openSUSE MicroOS** — neměnných, pro kontejnery optimalizovaných operačních systémech navržených speciálně pro edge a Kubernetes workloady.

Platforma pro nasazení pokrývá celý životní cyklus provisioningu clusteru:

- Instalace a konfigurace operačního systému
- Plánování sítě se správou statických pronájmů DHCPv4/DHCPv6
- Vysoká dostupnost API serveru prostřednictvím HAProxy a Keepalived
- Automatizovaný bootstrap clusteru K3s s vestavěným etcd
- Registrace worker uzlů
- Provisioning perzistentního úložiště (Longhorn nebo local-path)
- Správa SSH klíčů s importem klíčů z GitHubu

Veškerá konfigurace je řízena **jediným souborem proměnných** a vykreslována přes **šablony Jinja2**, což zajišťuje konzistenci, opakovatelnost a auditovatelnost napříč prostředími.

---

## 2. Přehled projektu

### 2.1 Definice problému

Nasazení produkčního clusteru Kubernetes na baremetal serverech přináší řadu výzev, které spravovaná cloudová prostředí abstrahují:

- Žádný automatizovaný provisioning infrastruktury (žádné Terraform/cloudové API)
- Žádný vestavěný load balancer pro API server
- Žádný spravovaný úložný backend
- Síťové adresování je třeba plánovat a koordinovat se stávající DHCP infrastrukturou
- Instalace a zabezpečení operačního systému probíhá manuálně
- Správa certifikátů vyžaduje pečlivé plánování IP adres a hostnames

### 2.2 Architektura řešení

Tato platforma řeší výše uvedené výzvy prostřednictvím vrstveného přístupu:

```
┌─────────────────────────────────────────────────────────────────────┐
│                   Vrstva generování konfigurace                      │
│                                                                       │
│   variables.yaml ──► Šablony Jinja2 ──► Vygenerované konfigurace     │
│   (jediný zdroj)     (18 šablon)        (19+ výstupních souborů)     │
│                                                                       │
│   Webové rozhraní (GitHub Pages) ──► Nunjucks v prohlížeči ──► ZIP   │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     Vrstva automatizace nasazení                      │
│                                                                       │
│   00-validate-environment.sh    Předběžné kontroly                   │
│   01-configure-os.sh            Zabezpečení OS, SSH klíče, sysctl    │
│   02-install-haproxy.sh         HAProxy + Keepalived na masterech    │
│   03-install-k3s-first.sh       Bootstrap prvního serveru (cluster-init)│
│   04-install-k3s-servers.sh     Připojení dalších serverových uzlů   │
│   05-install-k3s-agents.sh      Připojení worker uzlů                │
│   06-install-storage.sh         Nasazení Longhorn nebo local-path    │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       Vrstva infrastruktury                           │
│                                                                       │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐                          │
│   │master-01 │  │master-02 │  │master-03 │  Control Plane (3 uzly)  │
│   │HAProxy   │  │HAProxy   │  │HAProxy   │                          │
│   │Keepalived│  │Keepalived│  │Keepalived│                          │
│   │K3s Server│  │K3s Server│  │K3s Server│                          │
│   │etcd      │  │etcd      │  │etcd      │                          │
│   └──────────┘  └──────────┘  └──────────┘                          │
│         │              │              │                               │
│         └──────────────┼──────────────┘                              │
│                        │ VIP: 192.168.1.100                          │
│                        │                                             │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐                          │
│   │worker-01 │  │worker-02 │  │worker-03 │  Data Plane (N uzlů)    │
│   │K3s Agent │  │K3s Agent │  │K3s Agent │                          │
│   │Longhorn  │  │Longhorn  │  │Longhorn  │                          │
│   └──────────┘  └──────────┘  └──────────┘                          │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.3 Struktura repozitáře

```
k3s/
├── variables.yaml                  # Jediný zdroj pravdy
├── generate.py                     # Python renderer šablon
├── lint_configs.py                 # Vlastní linter konfigurace
├── requirements.txt                # Závislosti Pythonu
├── pyproject.toml                  # Konfigurace linteru Ruff
├── .yamllint.yaml                  # Pravidla pro lint YAML souborů
├── .shellcheckrc                   # Konfigurace lintu shellu
├── .github/workflows/
│   ├── lint.yaml                   # CI: lint všech typů souborů
│   └── pages.yaml                  # CI: nasazení webového UI na GitHub Pages
├── docs/                           # Podrobná dokumentace krok za krokem
├── templates/jinja2/               # 18 šablon Jinja2 pro konfiguraci
├── configs/                        # Statické referenční konfigurace
├── scripts/                        # 7 automatizačních skriptů pro nasazení
├── web/                            # Generátor konfigurace v prohlížeči
└── generated/                      # Výstupní adresář (v .gitignore)
```

---

## 3. Architektura

### 3.1 Topologie vysoké dostupnosti

Cluster využívá **3-uzlový control plane** s **vestavěným etcd** pro konsenzus, před kterým stojí **HAProxy** pro rozložení zátěže API a **Keepalived** pro failover virtuální IP adresy (VIP).

```
                    ┌─────────────────────────────┐
                    │          Klienti             │
                    │   (kubectl, CI/CD, aplikace) │
                    └──────────────┬───────────────┘
                                   │
                                   ▼
                    ┌─────────────────────────────┐
                    │     Virtuální IP (VIP)       │
                    │    192.168.1.100:6443        │
                    │    fd00::100:6443            │
                    │  (spravováno Keepalived)     │
                    └──────────────┬───────────────┘
                                   │
              ┌────────────────────┼────────────────────┐
              │                    │                    │
              ▼                    ▼                    ▼
    ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
    │   HAProxy       │  │   HAProxy       │  │   HAProxy       │
    │   (frontend)    │  │   (frontend)    │  │   (frontend)    │
    │   master-01     │  │   master-02     │  │   master-03     │
    │                 │  │                 │  │                 │
    │   K3s Server    │  │   K3s Server    │  │   K3s Server    │
    │   API Server    │  │   API Server    │  │   API Server    │
    │   Controller    │  │   Controller    │  │   Controller    │
    │   Scheduler     │  │   Scheduler     │  │   Scheduler     │
    │                 │  │                 │  │                 │
    │   etcd          │  │   etcd          │  │   etcd          │
    │  (vestavěný)    │  │  (vestavěný)    │  │  (vestavěný)    │
    └─────────────────┘  └─────────────────┘  └─────────────────┘
              │                    │                    │
              │       Replikace mezi etcd peery        │
              └────────────────────┼────────────────────┘
                                   │
                                   ▼
    ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
    │   K3s Agent     │  │   K3s Agent     │  │   K3s Agent     │
    │   kubelet       │  │   kubelet       │  │   kubelet       │
    │   kube-proxy    │  │   kube-proxy    │  │   kube-proxy    │
    │   Longhorn      │  │   Longhorn      │  │   Longhorn      │
    │                 │  │                 │  │                 │
    │   worker-01     │  │   worker-02     │  │   worker-03     │
    └─────────────────┘  └─────────────────┘  └─────────────────┘
```

### 3.2 Domény selhání

Architektura toleruje následující selhání bez přerušení služby:

| Scénář selhání | Dopad | Obnova |
|----------------|-------|--------|
| 1 master uzel mimo provoz | Žádný dopad (kvórum etcd 2/3 zachováno) | Automatický failover VIP |
| 1 worker uzel mimo provoz | Pody přeplánovány na zbývající workery | Automaticky Kubernetes |
| HAProxy na 1 masteru | VIP se přesune na zdravý HAProxy uzel | Failover Keepalived (<3 s) |
| Síťová partice (1 master izolován) | Kvórum udrženo většinou | Automatická rekonsolidace |
| 2 master uzly mimo provoz | **Cluster nedostupný** (ztráta kvóra) | Vyžadován manuální zásah |

### 3.3 Síťový tok

```
kubectl ──► VIP:6443 ──► HAProxy ──► K3s API Server (kterýkoli ze 3 masterů)
                              │
                              ├──► master-01:6443 (kontrola: TCP health)
                              ├──► master-02:6443 (kontrola: TCP health)
                              └──► master-03:6443 (kontrola: TCP health)

Worker Agent ──► VIP:6443 ──► HAProxy ──► K3s API Server
                                              │
                                              ▼
                                     Registrace uzlu
                                     Příjem specifikací podů
                                     Hlášení stavu
```

---

## 4. Podrobný popis komponent

### 4.1 Vrstva operačního systému

#### SUSE Linux Enterprise Micro (SLE Micro)

**SLE Micro** je komerčně podporovaný neměnný operační systém od společnosti SUSE, speciálně vytvořený pro kontejnerizované a virtualizované workloady. Klíčové vlastnosti:

- **Neměnný kořenový souborový systém**: Kořenový oddíl je jen pro čtení. Změny se aplikují prostřednictvím `transactional-update`, který vytvoří nový Btrfs snapshot. Systém se při dalším restartu spustí do nového snapshotu, což poskytuje atomické upgrady s možností okamžitého návratu.
- **Minimální plocha pro útoky**: Dodáván pouze s nezbytnými balíčky. Žádné desktopové prostředí, žádní nepotřební démoni.
- **SELinux/AppArmor**: Povinná kontrola přístupu ve výchozím nastavení zapnuta.
- **Komerční životní cyklus**: 4+ let údržby a bezpečnostních aktualizací na hlavní verzi.
- **Certifikace**: K dispozici varianty certifikované FIPS 140-2 a Common Criteria.

#### openSUSE MicroOS

**openSUSE MicroOS** je komunitní upstream verze SLE Micro sdílející stejnou architekturu:

- **Průběžná vydání**: Kontinuální aktualizace (založeno na Tumbleweed).
- **Identický mechanismus transactional-update**: Stejný systém atomických upgradů.
- **Nevyžaduje registraci**: Volně dostupný, podporovaný komunitou.
- **Ideální pro**: Vývojové clustery, proof-of-concept, komunitní produkční prostředí.

#### Mechanismus transakčních aktualizací

```
┌─────────────────────────────────────────────────────────────┐
│                   Kořenový souborový systém Btrfs             │
│                                                              │
│  Snapshot #1 (aktuální, jen pro čtení)                      │
│  └── / (běžící systém)                                      │
│                                                              │
│  Snapshot #2 (vytvořen pomocí transactional-update)          │
│  └── / (modifikovaný systém: nové balíčky, změny konfigurace)│
│                                                              │
│  transactional-update reboot ──► Spuštění do Snapshotu #2   │
│                                                              │
│  Pokud Snapshot #2 selže:                                    │
│  └── Návrat na Snapshot #1 (okamžitý, bez ztráty dat)       │
└─────────────────────────────────────────────────────────────┘
```

Nástroj `transactional-update` je výhradním mechanismem pro modifikaci operačního systému:

```bash
# Instalace balíčků (projeví se po restartu)
transactional-update pkg install open-iscsi nfs-client

# Aplikace všech čekajících aktualizací
transactional-update up

# Restart do nového snapshotu
transactional-update reboot
```

### 4.2 Distribuce K3s Kubernetes

#### Co je K3s?

**K3s** je certifikovaná produkční distribuce Kubernetes vyvinutá společností SUSE/Rancher. Balí celý control plane Kubernetes do jednoho binárního souboru (~60 MB), což ji činí vhodnou pro prostředí s omezenými zdroji, edge computing a nasazení na baremetal, kde je provozní režie clusterů založených na kubeadm nežádoucí.

#### K3s vs upstream Kubernetes

| Vlastnost | K3s | Upstream (kubeadm) |
|-----------|-----|-------------------|
| Velikost binárního souboru | ~60 MB | ~300+ MB (více binárních souborů) |
| Paměťová náročnost | ~512 MB (server) | ~1-2 GB (server) |
| Instalace | Jeden příkaz curl | Vícekrokový postup, správa certifikátů |
| etcd | Vestavěný (nebo externí) | Nutno provisnout samostatně |
| Runtime kontejnerů | containerd (vestavěný) | Nutno instalovat samostatně |
| Síťování | Flannel (vestavěný) | Nutno instalovat CNI plugin |
| Správa certifikátů | Automatická rotace | Manuální konfigurace |
| Upgrade | Výměna binárního souboru + restart | Postup postupného upgradu |

#### Architektura serveru K3s (Control Plane)

Každý serverový uzel K3s provozuje:

```
┌──────────────────────────────────────────────────────┐
│                    Proces K3s Server                   │
│                                                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │ API Server  │  │ Controller  │  │  Scheduler  │  │
│  │             │  │  Manager    │  │             │  │
│  └──────┬──────┘  └─────────────┘  └─────────────┘  │
│         │                                            │
│  ┌──────▼──────┐  ┌─────────────┐                   │
│  │   etcd      │  │ containerd  │                   │
│  │ (vestavěný) │  │             │                   │
│  └─────────────┘  └─────────────┘                   │
│                                                       │
│  ┌─────────────┐  ┌─────────────┐                   │
│  │  Flannel    │  │ CoreDNS     │                   │
│  │  (CNI)      │  │             │                   │
│  └─────────────┘  └─────────────┘                   │
└──────────────────────────────────────────────────────┘
```

#### Architektura agenta K3s (Worker)

Každý agent K3s provozuje:

```
┌──────────────────────────────────────────────────────┐
│                    Proces K3s Agent                    │
│                                                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │  kubelet    │  │ kube-proxy  │  │ containerd  │  │
│  │             │  │             │  │             │  │
│  └─────────────┘  └─────────────┘  └─────────────┘  │
│                                                       │
│  ┌─────────────┐  ┌─────────────────────────────┐   │
│  │  Flannel    │  │  Workload pody              │   │
│  │  (CNI)      │  │  (uživatelské aplikace)     │   │
│  └─────────────┘  └─────────────────────────────┘   │
└──────────────────────────────────────────────────────┘
```

#### Vestavěný cluster etcd

K3s využívá vestavěný cluster etcd pro ukládání veškerého stavu clusteru. Se 3 serverovými uzly operuje cluster etcd s algoritmem konsenzu Raft:

- **Kvórum**: 2 ze 3 uzlů se musí shodnout na zápisech (většina)
- **Volba vedoucího**: Jeden uzel je vedoucí (leader); ostatní jsou následovníci (followers)
- **Replikace dat**: Veškerá data jsou replikována na všechny 3 uzly
- **Tolerance selhání**: Přežije selhání 1 uzlu bez ztráty dat

```
         ┌─────────────┐
         │   etcd      │
         │  (leader)   │
         │  master-01  │
         └──────┬──────┘
                │
       ┌────────┴────────┐
       │  Raft konsenzus  │
       │  replikace       │
       ▼                 ▼
┌─────────────┐   ┌─────────────┐
│   etcd      │   │   etcd      │
│ (follower)  │   │ (follower)  │
│  master-02  │   │  master-03  │
└─────────────┘   └─────────────┘
```

#### Sekvence bootstrapu clusteru K3s

Inicializace clusteru probíhá v přesně daném pořadí:

1. **První server** se spustí s `--cluster-init`, čímž vytvoří jednouzlový cluster etcd
2. **Druhý server** se připojí přes `--server https://<první>:6443`, stane se followerem etcd
3. **Třetí server** se připojí obdobně, čímž se dokončí 3-uzlové kvórum etcd
4. **Agenti** se připojují přes VIP (`https://<VIP>:6443`) pro zajištění vysoké dostupnosti

```
Čas ──────────────────────────────────────────────────────────────►

master-01: [cluster-init] ──► [etcd leader, 1/1] ──► [etcd leader, 1/3]
                                                              │
master-02:                    [join] ──► [etcd follower, 2/3] ─┤
                                                              │
master-03:                              [join] ──► [follower, 3/3]
                                                              │
                                              Kvórum dosaženo ─┘
                                                              │
worker-01:                                         [join přes VIP]
worker-02:                                         [join přes VIP]
worker-03:                                         [join přes VIP]
```

#### Architektura TLS certifikátů

K3s automaticky generuje a spravuje TLS certifikáty. Příznaky `--tls-san` zajišťují platnost certifikátů pro všechny přístupové cesty:

```
Subject Alternative Names certifikátu:
├── 192.168.1.100        (VIP IPv4)
├── fd00::100            (VIP IPv6)
├── k3s-api.k3s.local    (VIP hostname)
├── master-01.k3s.local  (FQDN uzlu)
├── master-01            (krátký název)
├── 192.168.1.101        (IP uzlu)
├── master-02.k3s.local
├── master-02
├── 192.168.1.102
├── master-03.k3s.local
├── master-03
└── 192.168.1.103
```

To zajišťuje, že `kubectl` se může připojit přes:
- VIP (běžný provoz)
- Jakoukoli individuální IP adresu masteru (ladění/nouzový přístup)
- Jakoukoli variantu hostname

### 4.3 Load balancer HAProxy

#### Účel

HAProxy slouží jako **load balancer na vrstvě 4 (TCP)** pro API server K3s. Distribuuje příchozí spojení na portu 6443 mezi všechny tři master uzly a poskytuje:

- **Rozložení zátěže**: Round-robin balancování mezi zdravými backendy
- **Kontroly zdraví**: TCP sondy každých 10 sekund
- **Automatický failover**: Odstranění nezdravých backendů z poolu po 2 neúspěšných kontrolách
- **Perzistence spojení**: Udržení stávajících spojení během přechodů backendů

#### Architektura konfigurace HAProxy

```
┌──────────────────────────────────────────────────────┐
│                   Proces HAProxy                       │
│                                                       │
│  ┌─────────────────────────────────────────────────┐ │
│  │              Frontend: k3s_api_frontend          │ │
│  │              bind *:6443 (režim TCP)            │ │
│  └──────────────────────┬──────────────────────────┘ │
│                          │                            │
│  ┌──────────────────────▼──────────────────────────┐ │
│  │              Backend: k3s_api_backend            │ │
│  │              balance: roundrobin                 │ │
│  │                                                  │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐      │ │
│  │  │master-01 │  │master-02 │  │master-03 │      │ │
│  │  │:6443     │  │:6443     │  │:6443     │      │ │
│  │  │ check ✓  │  │ check ✓  │  │ check ✓  │      │ │
│  │  └──────────┘  └──────────┘  └──────────┘      │ │
│  └─────────────────────────────────────────────────┘ │
│                                                       │
│  ┌─────────────────────────────────────────────────┐ │
│  │              Listen: stats                       │ │
│  │              bind *:8404 (režim HTTP)            │ │
│  │              /stats dashboard                    │ │
│  └─────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

#### Parametry kontroly zdraví

| Parametr | Hodnota | Popis |
|----------|---------|-------|
| `inter` | 10 s | Interval kontroly, když je server NAHOŘE |
| `downinter` | 5 s | Interval kontroly, když je server DOLE |
| `rise` | 2 | Počet po sobě jdoucích úspěšných kontrol pro označení NAHOŘE |
| `fall` | 2 | Počet po sobě jdoucích neúspěšných kontrol pro označení DOLE |
| `slowstart` | 60 s | Postupné navyšování provozu po obnově |
| `maxconn` | 250 | Maximální počet současných spojení na backend |

#### Proč režim TCP (vrstva 4)?

HAProxy pracuje v režimu TCP (nikoli HTTP), protože:

1. API K3s používá **vzájemné TLS** (mTLS) — HAProxy nemůže ukončit spojení
2. Režim TCP má **nižší režii** (žádné parsování HTTP)
3. Protokol API je **HTTP/2** se streamováním (watches) — režim TCP toto zpracovává nativně
4. Kontroly zdraví používají **TCP connect** (port 6443 odpovídá = zdravý)

### 4.4 Keepalived a virtuální IP

#### Účel

Keepalived implementuje **Virtual Router Redundancy Protocol (VRRP)** pro správu plovoucí virtuální IP adresy (VIP) mezi třemi master uzly. Tato VIP je jediným vstupním bodem pro veškerý přístup k API.

#### Provoz VRRP

```
Běžný provoz:                         Po selhání master-01:

  master-01 (MASTER, priorita 101)      master-01 (MIMO PROVOZ)
  ├── VIP: 192.168.1.100 ✓             ├── VIP: (uvolněna)
  ├── Odesílá VRRP oznámení            │
  │                                     │
  master-02 (BACKUP, priorita 100)      master-02 (MASTER, priorita 100)
  ├── VIP: (pohotovost)                ├── VIP: 192.168.1.100 ✓
  ├── Naslouchá oznámením              ├── Odesílá VRRP oznámení
  │                                     │
  master-03 (BACKUP, priorita 99)       master-03 (BACKUP, priorita 99)
  ├── VIP: (pohotovost)                ├── VIP: (pohotovost)
  ├── Naslouchá oznámením              ├── Naslouchá oznámením
```

#### Sekvence failoveru

1. Master-01 (MASTER) odesílá VRRP oznámení každou 1 sekundu
2. Master-02 a master-03 (BACKUP) naslouchají těmto oznámením
3. Pokud oznámení přestanou přicházet po dobu 3 sekund (fall × interval):
   - BACKUP s nejvyšší prioritou (master-02, priorita 100) přejde do role MASTER
   - Odešle Gratuitous ARP oznamující VIP na své MAC adrese
   - Všechny síťové přepínače aktualizují své MAC tabulky
   - Provoz okamžitě proudí na master-02
4. Když se master-01 obnoví:
   - S povoleným preemption: master-01 si znovu nárokuje roli MASTER (vyšší priorita)
   - Bez preemption: master-02 si ponechá roli MASTER, dokud neselže

#### Skript pro sledování zdraví

Keepalived používá skript pro kontrolu zdraví, který váže vlastnictví VIP na stav HAProxy:

```bash
vrrp_script check_haproxy {
    script "/usr/bin/killall -0 haproxy"   # Signál 0 = kontrola existence procesu
    interval 2                              # Kontrola každé 2 sekundy
    weight 2                                # Přidání 2 k prioritě, pokud je zdravý
    fall 3                                  # 3 selhání pro označení MIMO PROVOZ
    rise 2                                  # 2 úspěchy pro označení V PROVOZU
}
```

To zajišťuje, že VIP se nachází pouze na uzlu, kde HAProxy skutečně běží a přijímá spojení.

#### Dual-stack VIP (IPv4 + IPv6)

Konfigurace VIP zahrnuje jak IPv4, tak IPv6 adresy:

```
virtual_ipaddress {
    192.168.1.100/24 dev eth0    # IPv4 VIP
    fd00::100/64 dev eth0        # IPv6 VIP
}
```

Obě adresy se přesouvají společně, čímž se udržuje dual-stack dostupnost API.

### 4.5 Distribuované úložiště Longhorn

#### Co je Longhorn?

**Longhorn** je open-source cloudově nativní distribuovaný systém blokového úložiště vyvinutý společností SUSE/Rancher pro Kubernetes. Poskytuje:

- **Replikované blokové úložiště**: Každý svazek je replikován na více uzlů
- **Snapshoty a zálohy**: Snapshoty k určitému časovému bodu s cíli zálohování na S3/NFS
- **Zotavení po havárii**: Replikace mezi clustery pro scénáře DR
- **Samoopravitelnost**: Automatická obnova replik při selhání uzlů
- **Thin provisioning**: Úložiště alokováno na vyžádání, nikoli předem
- **Webové rozhraní**: Vizuální dashboard pro správu svazků

#### Architektura Longhorn

```
┌─────────────────────────────────────────────────────────────────┐
│                    Cluster Kubernetes                             │
│                                                                   │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │              Longhorn Manager (DaemonSet)                  │   │
│  │              Běží na všech uzlech                          │   │
│  │              Orchestruje svazky, repliky, enginy           │   │
│  └───────────────────────────────────────────────────────────┘   │
│                                                                   │
│  ┌──────────────────┐  ┌──────────────────┐                     │
│  │  Longhorn CSI    │  │  Longhorn UI     │                     │
│  │  Driver          │  │  (Deployment)    │                     │
│  │  (DaemonSet)     │  │  Dashboard       │                     │
│  └──────────────────┘  └──────────────────┘                     │
│                                                                   │
│  Architektura jednotlivých svazků:                                │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  Svazek: my-app-data (10Gi, 3 repliky)                   │    │
│  │                                                           │    │
│  │  ┌─────────────┐                                         │    │
│  │  │   Engine    │  (běží na uzlu, kde je pod naplánován)  │    │
│  │  │  (iSCSI)    │                                         │    │
│  │  └──────┬──────┘                                         │    │
│  │         │                                                 │    │
│  │    ┌────┼────────────────┐                                │    │
│  │    │    │                │                                │    │
│  │    ▼    ▼                ▼                                │    │
│  │  ┌────────┐  ┌────────┐  ┌────────┐                      │    │
│  │  │Replika │  │Replika │  │Replika │                      │    │
│  │  │worker-1│  │worker-2│  │worker-3│                      │    │
│  │  └────────┘  └────────┘  └────────┘                      │    │
│  └──────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

#### Cesta zápisu

Když pod zapíše data na svazek Longhorn:

1. Zápis vstoupí do **Enginu** (iSCSI target na uzlu podu)
2. Engine **synchronně replikuje** na všechny nakonfigurované repliky
3. Zápis je potvrzen až poté, co **všechny repliky** potvrdí
4. Pokud replika selže, Engine ji označí jako degradovanou a pokračuje se zbývajícími replikami
5. Longhorn Manager detekuje degradovaný stav a naplánuje **obnovu** na zdravém uzlu

#### Porovnání Longhorn vs Local-Path

| Vlastnost | Longhorn | Local-Path |
|-----------|----------|------------|
| Replikace | Ano (konfigurovatelná, 1-5 replik) | Ne (jeden uzel) |
| Tolerance selhání uzlu | Ano (data přežijí ztrátu uzlu) | Ne (data ztracena při selhání uzlu) |
| Snapshoty | Ano (inkrementální, efektivní) | Ne |
| Zálohy | Ano (cíle S3, NFS) | Ne (manuální) |
| Výkonnostní režie | ~10-15 % (náklady na replikaci) | Žádná (přímé diskové I/O) |
| Složitost | Střední (nasazení přes Helm) | Minimální (vestavěný v K3s) |
| Spotřeba zdrojů | ~500 MB RAM na uzel | Zanedbatelná |
| Případ použití | Produkce, stavové workloady | Vývoj, efemérní data |

### 4.6 Síťová architektura (DHCPv4/DHCPv6)

#### Proč DHCP se statickými pronájmy?

Toto nasazení používá **DHCP** (jak v4, tak v6) pro konfiguraci sítě místo statické konfigurace na úrovni OS, protože:

1. **Centralizovaná správa**: Veškeré adresování je spravováno na DHCP serveru
2. **Konzistence**: Stejný mechanismus jako u ostatních síťových zařízení
3. **Flexibilita**: Změna adres nevyžaduje rekonfiguraci OS
4. **Kompatibilita s IPv6**: SLAAC a DHCPv6 s tímto modelem přirozeně fungují

Avšak **statické DHCP pronájmy** (rezervace) jsou povinné, protože:

- Certifikáty K3s jsou vázány na konkrétní IP adresy
- Členství v clusteru etcd vyžaduje stabilní adresování
- Backendy HAProxy jsou nakonfigurovány s pevnými IP adresami
- VIP Keepalived musí být předvídatelná

#### IPv6 a forwarding: Problém accept_ra

Existuje kritická interakce mezi forwardováním IPv6 a zpracováním Router Advertisement (RA):

```
Výchozí chování jádra Linuxu:
  net.ipv6.conf.all.forwarding = 0  →  accept_ra = 1 (zpracovává RA) ✓
  net.ipv6.conf.all.forwarding = 1  →  accept_ra = 1 (IGNORUJE RA)  ✗

K3s vyžaduje forwarding = 1 pro síťování podů.
Toto NARUŠÍ SLAAC a získávání adresy DHCPv6.

Řešení:
  net.ipv6.conf.all.accept_ra = 2   →  Zpracovává RA i s forwardováním ✓
  net.ipv6.conf.eth0.accept_ra = 2  →  Přepsání pro jednotlivé rozhraní  ✓
```

Tato platforma automaticky konfiguruje `accept_ra = 2` na všech uzlech, aby bylo zajištěno, že adresování IPv6 nadále funguje se zapnutým předáváním paketů.

#### Dual-stack síťování

Cluster pracuje v plném dual-stack režimu:

| Síť | IPv4 | IPv6 |
|-----|------|------|
| Síť uzlů | 192.168.1.0/24 | fd00::/64 |
| Pod CIDR | 10.42.0.0/16 | fd42::/48 |
| Service CIDR | 10.43.0.0/16 | fd43::/112 |
| VIP | 192.168.1.100 | fd00::100 |

---

## 5. Postup nasazení

Nasazení probíhá v přísném sekvenčním pořadí. Každý krok závisí na úspěšném dokončení předchozího kroku.

### Krok 0: Validace prostředí

```bash
./scripts/00-validate-environment.sh
```

**Účel**: Ověření všech předpokladů před provedením jakýchkoli změn.

**Prováděné kontroly**:
1. Inventární soubor existuje a je parsovatelný
2. Požadované lokální nástroje jsou přítomny (ssh, scp, curl, openssl)
3. Soubor SSH klíče existuje na konfigurované cestě
4. SSH konektivita ke všem master uzlům (timeout: 10 s na každý)
5. SSH konektivita ke všem worker uzlům
6. Skutečné IP adresy odpovídají očekávaným DHCP pronájmům (ověření funkčnosti DHCP)
7. Identifikace operačního systému na každém uzlu

**Chování při ukončení**: Ukončí se s kódem 1, pokud jakákoli kontrola selže, a nahlásí všechna selhání.

### Krok 1: Konfigurace operačního systému

```bash
./scripts/01-configure-os.sh
```

**Účel**: Konfigurace všech uzlů pro provoz K3s po instalaci OS.

**Akce na každém uzlu**:

| Akce | Detail |
|------|--------|
| Nastavení hostname | `hostnamectl set-hostname <hostname>.<doména>` |
| Konfigurace /etc/hosts | Všechny IP uzlů (IPv4 + IPv6) pro lokální rozlišení |
| Parametry jádra | ip_forward, bridge-nf-call, accept_ra=2, inotify, conntrack |
| Moduly jádra | br_netfilter, overlay, ip_vs, ip_vs_rr/wrr/sh, nf_conntrack |
| Limity souborů | nofile=65536, nproc=65536 (soft+hard) |
| Firewall | Otevřené porty: 6443, 2379, 2380, 10250, 8472, 51820 atd. |
| Balíčky | open-iscsi, nfs-client, cryptsetup, apparmor-parser |
| Non-local bind | Pro HAProxy (pouze mastery): ip_nonlocal_bind=1 |
| SSH klíče | Nasazení authorized_keys + zabezpečení sshd |
| Klíče z GitHubu | Stažení z https://github.com/<uživatel>.keys |

### Krok 2: Instalace HAProxy + Keepalived

```bash
./scripts/02-install-haproxy.sh
```

**Účel**: Instalace a konfigurace load balanceru API na všech master uzlech.

**Sekvence**:
1. Generování konfigurace HAProxy (backendy z inventáře)
2. Generování konfigurace Keepalived specifické pro každý uzel (různá priorita na uzel)
3. Pro každý master uzel:
   - Instalace balíčků haproxy a keepalived
   - Nasazení haproxy.cfg
   - Nasazení keepalived.conf (specifické pro uzel)
   - Povolení a spuštění služeb
4. Ověření, že VIP je přiřazena uzlu s nejvyšší prioritou
5. Ověření, že HAProxy naslouchá na portu 6443

### Krok 3: Bootstrap prvního serveru K3s

```bash
./scripts/03-install-k3s-first.sh
```

**Účel**: Inicializace clusteru K3s na prvním master uzlu.

**Kritické detaily**:
- Používá příznak `--cluster-init` (vytvoří jednouzlový cluster etcd)
- Generuje nebo použije poskytnutý token clusteru
- Zahrnuje všechny TLS SAN (VIP, všechny IP masterů, všechny hostnames)
- Konfiguruje dual-stack CIDR
- Zakáže výchozí Traefik a ServiceLB
- Čeká, dokud uzel nedosáhne stavu Ready
- Uloží token do lokálního souboru pro následující skripty

### Krok 4: Připojení dalších serverů

```bash
./scripts/04-install-k3s-servers.sh
```

**Účel**: Připojení master-02 a master-03 k clusteru.

**Klíčový rozdíl od kroku 3**: Používá `--server https://<IP-prvního-masteru>:6443` místo `--cluster-init`. Připojuje se přes přímou IP prvního masteru (nikoli VIP), aby se předešlo problému slepice a vejce během bootstrapu.

**Po dokončení**: Je ustanoveno 3-uzlové kvórum etcd. Cluster je nyní vysoce dostupný.

### Krok 5: Připojení worker uzlů

```bash
./scripts/05-install-k3s-agents.sh
```

**Účel**: Registrace všech worker uzlů do clusteru.

**Klíčové detaily**:
- Workery se připojují přes **VIP** (nikoli jednotlivé mastery) — vysoká dostupnost je již aktivní
- Používá `INSTALL_K3S_EXEC="agent"` (nikoli "server")
- Automaticky aplikuje štítky workerů
- Čeká, dokud každý uzel nedosáhne stavu Ready

### Krok 6: Instalace perzistentního úložiště

```bash
STORAGE_PROVIDER=longhorn ./scripts/06-install-storage.sh
```

**Účel**: Nasazení zvoleného řešení perzistentního úložiště.

**Pro Longhorn**:
1. Ověření předpokladů (open-iscsi, iscsid, datová cesta)
2. Instalace Helm na prvním masteru
3. Přidání Helm repozitáře Longhorn
4. Nasazení s vygenerovaným souborem hodnot
5. Čekání na připravenost všech podů (timeout: 300 s)
6. Ověření vytvoření StorageClass

**Pro local-path**:
1. Vytvoření datového adresáře na všech uzlech
2. Aplikace konfigurace StorageClass
3. Nastavení jako výchozí StorageClass

---

## 6. Systém generování konfigurace

### 6.1 Filozofie návrhu

Systém generování konfigurace se řídí principem **„jediný zdroj pravdy, více výstupů"**:

```
                    ┌─────────────────┐
                    │  variables.yaml  │  ◄── Uživatel edituje TENTO JEDEN soubor
                    │  (240+ řádků)    │
                    └────────┬─────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              ▼              ▼
     ┌────────────┐  ┌────────────┐  ┌────────────┐
     │  Python    │  │ Webové UI  │  │  Skripty   │
     │ generate.py│  │ (prohlížeč)│  │  (bash)    │
     └─────┬──────┘  └─────┬──────┘  └─────┬──────┘
           │                │               │
           ▼                ▼               │
     ┌────────────┐  ┌────────────┐         │
     │ generated/ │  │ ZIP soubor │         │
     │ (19 souborů)│  │ (stažení) │         │
     └────────────┘  └────────────┘         │
                                            ▼
                                    ┌────────────┐
                                    │ Vzdálené   │
                                    │ SSH spuštění│
                                    └────────────┘
```

### 6.2 Šablonový engine

**Na straně serveru (Python)**: Používá Jinja2 3.1+ s `StrictUndefined` — jakákoli chybějící proměnná způsobí okamžitou chybu namísto tichého prázdného výstupu.

**Na straně klienta (prohlížeč)**: Používá Nunjucks 3.2.4, JavaScriptový port Jinja2, umožňující identickou syntaxi šablon ve webovém rozhraní.

### 6.3 Katalog šablon

| Šablona | Výstup | Typ |
|---------|--------|-----|
| haproxy.cfg.j2 | haproxy/haproxy.cfg | Jednorázový |
| keepalived.conf.j2 | keepalived/{hostname}/keepalived.conf | Per-master |
| k3s-server.yaml.j2 | k3s/{hostname}/config.yaml | Per-master |
| k3s-agent.yaml.j2 | k3s/{hostname}/config.yaml | Per-worker |
| dhcpd4-leases.conf.j2 | network/dhcpd4-leases.conf | Jednorázový |
| dhcpd6-leases.conf.j2 | network/dhcpd6-leases.conf | Jednorázový |
| dnsmasq-leases.conf.j2 | network/dnsmasq-leases.conf | Jednorázový |
| hosts.j2 | network/hosts | Jednorázový |
| sysctl-k3s.conf.j2 | os/sysctl-k3s.conf | Jednorázový |
| ssh-config.j2 | os/ssh-config.txt | Jednorázový |
| disk-single-root.xml.j2 | os/disk-partitioning.xml | Podmíněný |
| disk-multipart.xml.j2 | os/disk-partitioning.xml | Podmíněný |
| disk-multidisk.xml.j2 | os/disk-partitioning.xml | Podmíněný |
| disk-ignition.json.j2 | os/disk-ignition.json | Jednorázový |
| longhorn-values.yaml.j2 | storage/longhorn-values.yaml | Podmíněný |
| storageclass-local-path.yaml.j2 | storage/storageclass-local-path.yaml | Podmíněný |

### 6.4 Podmíněné vykreslování

Generátor podporuje dva typy podmíněné logiky:

1. **Dynamický výběr šablony**: Šablona dělení disků je vybrána na základě hodnoty `storage.disk_layout`
2. **Podmínka poskytovatele**: Šablony úložiště se vykreslí pouze tehdy, když je vybrán odpovídající poskytovatel

```python
# Dynamický výběr šablony
if target.get("dynamic_template"):
    disk_layout = variables["storage"]["disk_layout"]
    template_name = layout_map[disk_layout]

# Podmíněné vykreslování
condition = target.get("condition")
if condition and variables["storage"]["provider"] != condition:
    continue  # Přeskočit tuto šablonu
```

---

## 7. Strategie dělení disků

### 7.1 Možnosti rozložení

#### Varianta A: Jeden kořenový oddíl

```
┌─────────────────────────────────────────┐
│             /dev/sda                     │
├──────────┬──────────────────────────────┤
│ /boot/efi│            /                 │
│  512 MB  │     (Btrfs, zbytek)          │
│  (vfat)  │                              │
│          │  Subvolumes:                  │
│          │  @/var                        │
│          │  @/var/lib/rancher            │
│          │  @/var/lib/longhorn           │
│          │  @/home                       │
│          │  @/.snapshots                 │
└──────────┴──────────────────────────────┘
```

#### Varianta B: Více oddílů (doporučeno)

```
┌─────────────────────────────────────────┐
│             /dev/sda                     │
├──────────┬──────────┬──────────┬────────┤
│ /boot/efi│    /     │/var/lib/ │Úložiště│
│  512 MB  │  40 GB   │rancher   │  max   │
│  (vfat)  │ (Btrfs)  │ 100 GB   │ (XFS)  │
│          │          │  (XFS)   │        │
└──────────┴──────────┴──────────┴────────┘
```

#### Varianta C: Více disků

```
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│    /dev/sda      │  │    /dev/sdb      │  │    /dev/sdc      │
├──────────┬───────┤  ├──────────────────┤  ├──────────────────┤
│ /boot/efi│   /   │  │  /var/lib/rancher│  │  /var/lib/       │
│  512 MB  │  max  │  │    (celý disk)   │  │  longhorn        │
│  (vfat)  │(Btrfs)│  │      (XFS)       │  │  (celý disk)     │
│          │       │  │                  │  │    (XFS)         │
└──────────┴───────┘  └──────────────────┘  └──────────────────┘
    Disk OS               Datový disk           Disk úložiště
```

### 7.2 Zdůvodnění výběru souborového systému

| Přípojný bod | Souborový systém | Důvod |
|--------------|-----------------|-------|
| / | Btrfs | Podpora snapshotů transactional-update, copy-on-write, komprese |
| /var/lib/rancher | XFS | Vysoký výkon pro zápisy kontejnerových vrstev, bez režie CoW |
| /var/lib/longhorn | XFS | Backend blokového úložiště potřebuje konzistentní sekvenční zápisy |
| /boot/efi | vfat | Vyžadováno specifikací UEFI |

---

## 8. Model zabezpečení

### 8.1 Správa SSH klíčů

Platforma poskytuje tři metody nasazení SSH klíčů:

```
┌─────────────────────────────────────────────────────────┐
│                 Zdroje SSH klíčů                          │
│                                                          │
│  1. Manuální klíče (variables.yaml)                     │
│     ssh.authorized_keys:                                 │
│       - "ssh-ed25519 AAAA... user@host"                 │
│                                                          │
│  2. Import klíčů z GitHubu (staženo při nasazení)       │
│     ssh.github_users:                                    │
│       - "username"                                       │
│     → curl https://github.com/username.keys             │
│                                                          │
│  3. Záložní lokální soubor klíče                        │
│     ssh.key_path: "~/.ssh/id_ed25519"                   │
│     → Čte ~/.ssh/id_ed25519.pub                         │
└─────────────────────────────────────────────┬───────────┘
                                              │
                                              ▼
                                    ┌──────────────────┐
                                    │ Všechny klíče    │
                                    │ sloučeny         │
                                    │ Nasazeny do:     │
                                    │ /root/.ssh/      │
                                    │ authorized_keys  │
                                    │ (všechny uzly)   │
                                    └──────────────────┘
```

### 8.2 Zabezpečení SSH

Pokud je nastaveno `ssh.disable_password_auth: true`:

```
/etc/ssh/sshd_config.d/10-k3s-hardening.conf:
  PasswordAuthentication no
  ChallengeResponseAuthentication no
  PubkeyAuthentication yes
  PermitRootLogin prohibit-password
  MaxAuthTries 3
  ClientAliveInterval 300
  ClientAliveCountMax 2
```

### 8.3 Síťové zabezpečení (pravidla firewallu)

| Port | Protokol | Směr | Účel | Uzly |
|------|----------|------|------|------|
| 6443 | TCP | Příchozí | API server K3s | Mastery |
| 2379 | TCP | Pouze mastery | Klient etcd | Mastery |
| 2380 | TCP | Pouze mastery | Peer etcd | Mastery |
| 10250 | TCP | Příchozí | Metriky kubelet | Všechny |
| 8472 | UDP | Příchozí | VXLAN (Flannel) | Všechny |
| 51820 | UDP | Příchozí | WireGuard IPv4 | Všechny |
| 51821 | UDP | Příchozí | WireGuard IPv6 | Všechny |
| 8404 | TCP | Příchozí | Statistiky HAProxy | Mastery |
| 30000-32767 | TCP/UDP | Příchozí | Rozsah NodePort | Workery |
| VRRP (112) | IP | Pouze mastery | Keepalived | Mastery |

---

## 9. Architektura perzistentního úložiště

### 9.1 Datový tok Longhorn

```
┌─────────────────────────────────────────────────────────────┐
│  Pod zapisuje data                                           │
│  └──► /dev/longhorn/volume-xyz (blokové zařízení)           │
│        └──► Longhorn Engine (iSCSI target, stejný uzel)     │
│              └──► Synchronní replikace                       │
│                    ├──► Replika 1 (worker-01:/var/lib/longhorn/replicas/vol-xyz/)
│                    ├──► Replika 2 (worker-02:/var/lib/longhorn/replicas/vol-xyz/)
│                    └──► Replika 3 (worker-03:/var/lib/longhorn/replicas/vol-xyz/)
│                                                              │
│  Všechny 3 repliky potvrdí ──► Zápis potvrzen podu          │
└─────────────────────────────────────────────────────────────┘
```

### 9.2 Konfigurace StorageClass

**StorageClass Longhorn** (nasazená přes Helm):
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "3"
  staleReplicaTimeout: "2880"
```

**StorageClass Local-Path** (vestavěná v K3s):
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
```

---

## 10. Kontinuální integrace a zajištění kvality

### 10.1 CI pipeline

```
┌─────────────────────────────────────────────────────────────┐
│              GitHub Actions Workflow: lint.yaml               │
│                                                              │
│  Spouštěč: push do main, pull_request do main               │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ python-lint  │  │  yaml-lint   │  │ config-lint  │      │
│  │              │  │              │  │              │      │
│  │ ruff check . │  │  yamllint    │  │lint_configs.py│     │
│  │ ruff format  │  │  variables   │  │  HAProxy     │      │
│  │  --check .   │  │  configs/k3s │  │  Keepalived  │      │
│  │              │  │  workflows   │  │  DHCP        │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│                                                              │
│  ┌──────────────────────────┐  ┌──────────────────────┐     │
│  │  generate-validate       │  │    shell-lint        │     │
│  │                          │  │                      │     │
│  │  python3 generate.py     │  │  shellcheck -x       │     │
│  │    --dry-run             │  │    scripts/*.sh      │     │
│  │  python3 generate.py     │  │                      │     │
│  │  lint vygenerovaný výstup│  │                      │     │
│  │  yamllint vygener. YAML  │  │                      │     │
│  └──────────────────────────┘  └──────────────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

### 10.2 Nástroje pro lint

| Nástroj | Cíl | Pravidla |
|---------|-----|----------|
| **ruff** | Python (.py) | PEP8, isort, bugbear, comprehensions, pathlib, type-checking |
| **yamllint** | YAML (.yaml) | Délka řádku 120, odsazení 2 mezerami, pravdivostní hodnoty |
| **shellcheck** | Shell (.sh) | SC1091 zakázáno (dynamický source), všechna ostatní pravidla |
| **lint_configs.py** | .cfg, .conf | Sekce HAProxy, syntaxe Keepalived, závorky/středníky DHCP |

---

## 11. Webový generátor konfigurace

### 11.1 Architektura

Webové rozhraní je **statická jednostránková aplikace** nasazená na GitHub Pages. Běží výhradně v prohlížeči — žádné zpracování na straně serveru, žádný přenos dat.

```
┌─────────────────────────────────────────────────────────────┐
│                Prohlížeč (pouze na straně klienta)            │
│                                                              │
│  ┌──────────┐    ┌──────────────┐    ┌──────────────────┐   │
│  │HTML form. │──►│  Nunjucks    │──►│ Vygenerované soub.│   │
│  │ (vstup    │    │  Šablonový   │    │  (náhled +        │   │
│  │ uživatele)│    │  engine      │    │   stažení)        │   │
│  └──────────┘    └──────────────┘    └────────┬──────────┘   │
│                                               │              │
│                                     ┌─────────▼──────────┐   │
│                                     │      JSZip         │   │
│                                     │ Generátor archivů  │   │
│                                     └─────────┬──────────┘   │
│                                               │              │
│                                     ┌─────────▼──────────┐   │
│                                     │    FileSaver.js    │   │
│                                     │  Spouštěč stahování│   │
│                                     └────────────────────┘   │
│                                               │              │
│                                               ▼              │
│                                     k3s-config-v1.0.0-       │
│                                     20260804-143052.zip      │
└─────────────────────────────────────────────────────────────┘
```

### 11.2 Technologický stack

| Knihovna | Verze | Účel |
|---------|-------|------|
| Nunjucks | 3.2.4 | Šablonový engine kompatibilní s Jinja2 (CDN) |
| JSZip | 3.10.1 | Generování ZIP archivů v prohlížeči (CDN) |
| FileSaver.js | 2.0.5 | Spouštění stahování souborů z Blob (CDN) |
| Pure CSS | - | Vlastní tmavý motiv, responzivní layout |

### 11.3 Pojmenování ZIP archivu

```
k3s-config-v1.0.0-20260804-143052.zip
│           │     │        │
│           │     │        └── Čas: HHMMSS
│           │     └── Datum: RRRRMMDD
│           └── Verze aplikace
└── Pevný prefix
```

---

## 12. Souhrn

Tato platforma pro vysoce dostupné nasazení K3s na baremetal poskytuje kompletní, produkčně připravené řešení pro nasazení Kubernetes na fyzických serverech. Klíčové vlastnosti:

**Architektura**:
- 3-uzlový control plane s vestavěným etcd pro HA konsenzus
- HAProxy + Keepalived pro rozložení zátěže API serveru a failover VIP
- Toleruje selhání jednoho uzlu bez přerušení služby
- Dual-stack síťování (IPv4 + IPv6) v celém řešení

**Automatizace**:
- 7 sekvenčních skriptů pokrývajících celý životní cyklus nasazení
- Generování konfigurace z jediného souboru proměnných (19+ výstupních souborů)
- Webový generátor pro provoz pouze v prohlížeči (nevyžaduje server)
- GitHub Actions CI pro kontinuální zajištění kvality

**Úložiště**:
- Distribuované replikované úložiště Longhorn (produkční kvalita, snapshoty, zálohy)
- Alternativa s provisionerem local-path (vývoj/jednoduché workloady)
- 3 varianty rozložení disků pro různé hardwarové konfigurace

**Zabezpečení**:
- Nasazení SSH klíčů s importem klíčů z GitHubu
- Zabezpečení SSHD (autentizace heslem zakázána, přístup pouze klíčem)
- Konfigurace firewallu s minimálním počtem otevřených portů
- TLS certifikáty pokrývající všechny přístupové cesty (VIP + jednotlivé uzly)
- Neměnný základ OS (transactional-update, kořenový oddíl jen pro čtení)

**Flexibilita**:
- Volba mezi SLE Micro (komerční) nebo openSUSE MicroOS (komunitní)
- Volba mezi Longhorn, local-path nebo žádným úložištěm
- Volba mezi jedním kořenovým oddílem, více oddíly nebo více disky
- Podpora DHCPv4/DHCPv6 s konfiguracemi ISC DHCP, dnsmasq a Kea
- Konfigurovatelné přes YAML, webové UI nebo proměnné prostředí

**Kvalita**:
- Veškerý kód lintovaný (Python, YAML, Shell, konfigurační soubory)
- Validace šablon při každém commitu
- Vygenerovaný výstup ověřen CI pipeline
- Komplexní dokumentace (7 průvodců + tento referenční dokument)

---

*Tento dokument popisuje verzi 1.0.0 platformy pro vysoce dostupné nasazení K3s na baremetal. Nejnovější aktualizace naleznete v [repozitáři](https://github.com/opentreecz/k3s).*
