# K3s Vysoce dostupná platforma pro nasazení na bare-metal serverech

## Technický referenční dokument

**Verze:** 1.0.0  
**Poslední aktualizace:** August 2026  
**Repozitář:** [github.com/opentreecz/k3s](https://github.com/opentreecz/k3s)  
**Webový generátor:** [opentreecz.github.io/k3s](https://opentreecz.github.io/k3s/)

---

## Obsah

1. [Shrnutí](#1-shrnutí)
2. [Přehled projektu](#2-přehled-projektu)
3. [Architektura](#3-architektura)
4. [Detailní popis komponent](#4-detailní-popis-komponent)
   - [4.1 Vrstva operačního systému](#41-vrstva-operačního-systému)
   - [4.2 K3s distribuce Kubernetes](#42-k3s-distribuce-kubernetes)
   - [4.3 HAProxy load balancer](#43-haproxy-load-balancer)
   - [4.4 Keepalived a virtuální IP](#44-keepalived-a-virtuální-ip)
   - [4.5 Longhorn distribuované úložiště](#45-longhorn-distribuované-úložiště)
   - [4.6 Síťová architektura (DHCPv4/DHCPv6)](#46-síťová-architektura-dhcpv4dhcpv6)
5. [Postup nasazení](#5-postup-nasazení)
6. [Systém generování konfigurace](#6-systém-generování-konfigurace)
7. [Strategie rozdělení disků](#7-strategie-rozdělení-disků)
8. [Bezpečnostní model](#8-bezpečnostní-model)
9. [Architektura perzistentního úložiště](#9-architektura-perzistentního-úložiště)
10. [Kontinuální integrace a zajištění kvality](#10-kontinuální-integrace-a-zajištění-kvality)
11. [Webový generátor konfigurace](#11-webový-generátor-konfigurace)
12. [Shrnutí](#12-shrnutí)

---

## 1. Shrnutí

Tento projekt poskytuje kompletní, automatizovanou platformu pro nasazení **vysoce dostupného K3s Kubernetes clusteru** na bare-metal serverech. Platforma je určena pro prostředí se **SUSE Linux Enterprise Micro (SLE Micro)** nebo **openSUSE MicroOS** — neměnnými, kontejnerově optimalizovanými operačními systémy navrženými speciálně pro edge a Kubernetes zátěže.

Platforma pro nasazení pokrývá celý životní cyklus provisioningu clusteru:

- Instalace a konfigurace operačního systému
- Plánování sítě se správou statických DHCPv4/DHCPv6 lease záznamů
- Vysoká dostupnost API serveru přes HAProxy a Keepalived
- Automatizovaný bootstrap K3s clusteru s vestavěným etcd
- Připojení worker uzlů
- Provisioning perzistentního úložiště (Longhorn nebo local-path)
- Správa SSH klíčů s importem klíčů z GitHubu
- Jednotná konzumace konfigurace: nasazovací skripty používají předgenerované konfigurace z adresáře `generated/` (vytvořené pomocí `generate.py` nebo extrakcí ZIP z webového rozhraní), s automatickým fallbackem na inline generování z `inventory.conf`

Veškerá konfigurace je řízena **jediným souborem proměnných** a vykreslována pomocí **Jinja2 šablon**, což zajišťuje konzistenci, opakovatelnost a auditovatelnost napříč prostředími.

---

## 2. Přehled projektu

### 2.1 Popis problému

Nasazení Kubernetes clusteru produkční kvality na bare-metal serverech přináší několik výzev, které spravovaná cloudová prostředí abstrahují:

- Žádný automatizovaný provisioning infrastruktury (žádné Terraform/cloud API)
- Žádný vestavěný load balancer pro API server
- Žádný spravovaný storage backend
- Síťové adresování musí být plánováno a koordinováno se stávající DHCP infrastrukturou
- Instalace a hardening operačního systému je manuální
- Správa certifikátů vyžaduje pečlivé plánování IP adres a hostnames

### 2.2 Architektura řešení

Tato platforma řeší tyto výzvy pomocí vrstveného přístupu:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Vrstva generování konfigurace                      │
│                                                                       │
│   variables.yaml ──► Jinja2 šablony ──► Vygenerované konfigurace     │
│   (jediný zdroj)     (18 šablon)        (19+ výstupních souborů)     │
│                                                                       │
│   Webové rozhraní (GitHub Pages) ──► Nunjucks v prohlížeči ──► ZIP   │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Vrstva automatizace nasazení                     │
│                                                                       │
│   00-validate-environment.sh    Předběžné kontroly                   │
│   01-configure-os.sh            Hardening OS, SSH klíče, sysctl      │
│   02-install-haproxy.sh         HAProxy + Keepalived na masterech    │
│   03-install-k3s-first.sh       Bootstrap prvního serveru            │
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
│   │worker-01 │  │worker-02 │  │worker-03 │  Data Plane (N uzlů)     │
│   │K3s Agent │  │K3s Agent │  │K3s Agent │                          │
│   │Longhorn  │  │Longhorn  │  │Longhorn  │                          │
│   └──────────┘  └──────────┘  └──────────┘                          │
└─────────────────────────────────────────────────────────────────────┘
```

**Tok konfigurace**: Adresář `generated/` slouží jako propojení mezi vrstvou generování konfigurace a vrstvou automatizace nasazení. Může být naplněn buď pomocí `python3 generate.py` (z `variables.yaml`), nebo extrakcí ZIP archivu z webového rozhraní (`unzip k3s-config-*.zip -d generated/`). Když nasazovací skripty naleznou předgenerované konfigurace v tomto adresáři, použijí je přímo. Pokud předgenerované konfigurace nejsou nalezeny, skripty se vrátí k inline generování konfigurací z `inventory.conf`.

### 2.3 Struktura repozitáře

```
k3s/
├── variables.yaml                  # Jediný zdroj pravdy
├── generate.py                     # Python renderer šablon
├── lint_configs.py                 # Vlastní linter konfigurací
├── requirements.txt                # Python závislosti
├── pyproject.toml                  # Konfigurace Ruff linteru
├── .yamllint.yaml                  # YAML lint pravidla
├── .shellcheckrc                   # Konfigurace Shell lintu
├── .github/workflows/
│   ├── lint.yaml                   # CI: lint všech typů souborů
│   └── pages.yaml                  # CI: nasazení webového rozhraní na GitHub Pages
├── docs/                           # Podrobná dokumentace
├── templates/jinja2/               # 18 Jinja2 konfiguračních šablon
├── configs/                        # Statické referenční konfigurace
├── scripts/                        # 7 skriptů pro automatizaci nasazení
├── web/                            # Generátor konfigurace v prohlížeči
└── generated/                      # Výstupní adresář (v gitignore)
```

---

## 3. Architektura

### 3.1 Topologie vysoké dostupnosti

Cluster využívá **3-uzlový control plane** s **vestavěným etcd** pro konsenzus, před kterým stojí **HAProxy** pro rozložení zátěže API a **Keepalived** pro failover virtuální IP (VIP).

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
              │         Replikace etcd peer             │
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

Architektura toleruje následující selhání bez narušení služby:

| Scénář selhání | Dopad | Obnova |
|----------------|-------|--------|
| 1 master uzel mimo provoz | Žádný dopad (kvórum etcd 2/3 zachováno) | Automatický VIP failover |
| 1 worker uzel mimo provoz | Pody přeplánovány na zbývající workery | Automaticky Kubernetes |
| HAProxy na 1 masteru | VIP se přesune na zdravý HAProxy uzel | Keepalived failover (<3s) |
| Síťová izolace (1 master izolován) | Kvórum zachováno většinou | Automatická rekoncialiace |
| 2 master uzly mimo provoz | **Cluster nedostupný** (ztráta kvóra) | Vyžadován manuální zásah |

### 3.3 Síťový tok

```
kubectl ──► VIP:6443 ──► HAProxy ──► K3s API Server (kterýkoliv ze 3 masterů)
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

## 4. Detailní popis komponent

### 4.1 Vrstva operačního systému

#### SUSE Linux Enterprise Micro (SLE Micro)

**SLE Micro** je komerčně podporovaný, neměnný operační systém od SUSE, účelově vytvořený pro kontejnerizované a virtualizované zátěže. Klíčové vlastnosti:

- **Neměnný kořenový souborový systém**: Kořenová partition je pouze pro čtení. Změny se aplikují prostřednictvím `transactional-update`, který vytváří nový Btrfs snapshot. Systém se po restartu nabootuje do nového snapshotu, což poskytuje atomické upgrady s možností okamžitého rollbacku.
- **Minimální plocha pro útok**: Dodáván pouze se základními balíčky. Žádné desktopové prostředí, žádné zbytečné démony.
- **SELinux/AppArmor**: Povinná kontrola přístupu ve výchozím nastavení aktivní.
- **Komerční životní cyklus**: 4+ let údržby a bezpečnostních aktualizací na hlavní vydání.
- **Certifikace**: K dispozici varianty certifikované FIPS 140-2, Common Criteria.

#### openSUSE MicroOS

**openSUSE MicroOS** je komunitně řízený upstream SLE Micro, sdílející stejnou architekturu:

- **Rolling release**: Průběžné aktualizace (založeno na Tumbleweed).
- **Identický mechanismus transactional-update**: Stejný systém atomických upgradů.
- **Bez nutnosti registrace**: Volně dostupný, s komunitní podporou.
- **Ideální pro**: Vývojové clustery, proof-of-concept, komunitní produkční prostředí.

#### Mechanismus transactional-update

```
┌─────────────────────────────────────────────────────────────┐
│                    Kořenový souborový systém Btrfs            │
│                                                              │
│  Snapshot #1 (aktuální, pouze pro čtení)                    │
│  └── / (běžící systém)                                      │
│                                                              │
│  Snapshot #2 (vytvořen pomocí transactional-update)          │
│  └── / (modifikovaný systém: nové balíčky, změny konfigurace)│
│                                                              │
│  transactional-update reboot ──► Boot do Snapshotu #2       │
│                                                              │
│  Pokud Snapshot #2 selže:                                    │
│  └── Rollback na Snapshot #1 (okamžitý, bez ztráty dat)     │
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

### 4.2 K3s distribuce Kubernetes

#### Co je K3s?

**K3s** je certifikovaná, produkčně připravená distribuce Kubernetes vyvinutá společností SUSE/Rancher. Zabaluje celý Kubernetes control plane do jednoho binárního souboru (~60MB), což ji činí vhodnou pro prostředí s omezenými zdroji, edge computing a bare-metal nasazení, kde je provozní režie clusterů založených na kubeadm nežádoucí.

#### K3s vs. upstream Kubernetes

| Vlastnost | K3s | Upstream (kubeadm) |
|-----------|-----|-------------------|
| Velikost binárky | ~60 MB | ~300+ MB (více binárních souborů) |
| Paměťová náročnost | ~512 MB (server) | ~1-2 GB (server) |
| Instalace | Jeden curl příkaz | Více kroků, správa certifikátů |
| etcd | Vestavěný (nebo externí) | Nutno poskytnout samostatně |
| Container runtime | containerd (vestavěný) | Nutno instalovat samostatně |
| Síťování | Flannel (vestavěný) | Nutno instalovat CNI plugin |
| Správa certifikátů | Automatická rotace | Manuální konfigurace |
| Upgrade | Nahrazení binárky + restart | Postup rolling upgrade |

#### Architektura K3s serveru (Control Plane)

Každý K3s server uzel provozuje:

```
┌──────────────────────────────────────────────────────┐
│                    Proces K3s serveru                   │
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

#### Architektura K3s agenta (Worker)

Každý K3s agent uzel provozuje:

```
┌──────────────────────────────────────────────────────┐
│                    Proces K3s agenta                    │
│                                                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │  kubelet    │  │ kube-proxy  │  │ containerd  │  │
│  │             │  │             │  │             │  │
│  └─────────────┘  └─────────────┘  └─────────────┘  │
│                                                       │
│  ┌─────────────┐  ┌─────────────────────────────┐   │
│  │  Flannel    │  │  Pody se zátěží             │   │
│  │  (CNI)      │  │  (uživatelské aplikace)     │   │
│  └─────────────┘  └─────────────────────────────┘   │
└──────────────────────────────────────────────────────┘
```

#### Vestavěný etcd cluster

K3s používá vestavěný etcd cluster pro ukládání veškerého stavu clusteru. Se 3 serverovými uzly pracuje etcd cluster s algoritmem konsenzu Raft:

- **Kvórum**: 2 ze 3 uzlů musí souhlasit se zápisy (většina)
- **Volba leadera**: Jeden uzel je leader; ostatní jsou followeři
- **Replikace dat**: Všechna data jsou replikována na všechny 3 uzly
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

#### Sekvence bootstrapu K3s clusteru

Inicializace clusteru sleduje přesné pořadí:

1. **První server** startuje s `--cluster-init`, čímž vytváří jednouzlový etcd cluster
2. **Druhý server** se připojuje přes `--server https://<first>:6443` a stává se etcd followerem
3. **Třetí server** se připojuje obdobně, čímž dokončuje 3-uzlové etcd kvórum
4. **Agenti** se připojují přes VIP (`https://<VIP>:6443`) pro vysokou dostupnost

```
Čas ───────────────────────────────────────────────────────────────►

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

K3s automaticky generuje a spravuje TLS certifikáty. Příznaky `--tls-san` zajišťují, že certifikáty jsou platné pro všechny přístupové cesty:

```
Subject Alternative Names certifikátu:
├── 192.168.1.100        (VIP IPv4)
├── fd00::100            (VIP IPv6)
├── k3s-api.k3s.local    (VIP hostname)
├── master-01.k3s.local  (FQDN uzlu)
├── master-01            (krátké jméno)
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
- Jakékoliv individuální master IP (ladění/nouzový přístup)
- Jakoukoliv variantu hostname

### 4.3 HAProxy load balancer

#### Účel

HAProxy slouží jako **load balancer na vrstvě 4 (TCP)** pro K3s API server. Distribuuje příchozí spojení na portu 6443 mezi všechny tři master uzly a poskytuje:

- **Distribuce zátěže**: Round-robin balancování mezi zdravými backendy
- **Kontrola zdraví**: TCP zdravotní sondy každých 10 sekund
- **Automatický failover**: Odstraňuje nezdravé backendy z poolu do 2 neúspěšných kontrol
- **Persistence spojení**: Udržuje existující spojení během přechodů backendů

#### Architektura konfigurace HAProxy

```
┌──────────────────────────────────────────────────────┐
│                   Proces HAProxy                       │
│                                                       │
│  ┌─────────────────────────────────────────────────┐ │
│  │              Frontend: k3s_api_frontend          │ │
│  │              bind *:6443 (TCP režim)            │ │
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
│  │              bind *:8404 (HTTP režim)           │ │
│  │              /stats dashboard                    │ │
│  └─────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

#### Parametry kontroly zdraví

| Parametr | Hodnota | Popis |
|----------|---------|-------|
| `inter` | 10s | Interval kontroly, když je server UP |
| `downinter` | 5s | Interval kontroly, když je server DOWN |
| `rise` | 2 | Počet po sobě jdoucích úspěšných kontrol pro označení UP |
| `fall` | 2 | Počet po sobě jdoucích neúspěšných kontrol pro označení DOWN |
| `slowstart` | 60s | Postupné navyšování provozu po obnovení |
| `maxconn` | 250 | Maximální počet současných spojení na backend |

#### Proč TCP režim (vrstva 4)?

HAProxy pracuje v TCP režimu (nikoliv HTTP), protože:

1. K3s API používá **vzájemné TLS** (mTLS) — HAProxy nemůže ukončit spojení
2. TCP režim má **nižší režii** (žádné parsování HTTP)
3. API protokol je **HTTP/2** se streamováním (watches) — TCP režim to zpracovává nativně
4. Kontroly zdraví používají **TCP connect** (port 6443 odpovídá = zdravý)

### 4.4 Keepalived a virtuální IP

#### Účel

Keepalived implementuje **Virtual Router Redundancy Protocol (VRRP)** pro správu plovoucí virtuální IP (VIP) adresy mezi třemi master uzly. Tato VIP je jediným vstupním bodem pro veškerý přístup k API.

#### Fungování VRRP

```
Běžný provoz:                         Po selhání master-01:

  master-01 (MASTER, priorita 101)      master-01 (DOWN)
  ├── VIP: 192.168.1.100 ✓             ├── VIP: (uvolněna)
  ├── Odesílá VRRP advertisements      │
  │                                     │
  master-02 (BACKUP, priorita 100)      master-02 (MASTER, priorita 100)
  ├── VIP: (pohotovost)                ├── VIP: 192.168.1.100 ✓
  ├── Naslouchá advertisementům        ├── Odesílá VRRP advertisements
  │                                     │
  master-03 (BACKUP, priorita 99)       master-03 (BACKUP, priorita 99)
  ├── VIP: (pohotovost)                ├── VIP: (pohotovost)
  ├── Naslouchá advertisementům        ├── Naslouchá advertisementům
```

#### Sekvence failoveru

1. Master-01 (MASTER) odesílá VRRP advertisements každou 1 sekundu
2. Master-02 a master-03 (BACKUP) naslouchají těmto advertisementům
3. Pokud advertisementy přestanou přicházet po 3 sekundách (fall × interval):
   - BACKUP s nejvyšší prioritou (master-02, priorita 100) přechází do stavu MASTER
   - Odešle Gratuitous ARP oznamující VIP na své MAC adrese
   - Všechny síťové přepínače aktualizují své MAC tabulky
   - Provoz okamžitě proudí na master-02
4. Když se master-01 obnoví:
   - S povolenou preempcí: master-01 si vyžádá zpět roli MASTER (vyšší priorita)
   - Bez preempce: master-02 si zachová roli MASTER, dokud neselže

#### Skript pro sledování zdraví

Keepalived používá skript pro kontrolu zdraví, který váže vlastnictví VIP na stav HAProxy:

```bash
vrrp_script check_haproxy {
    script "/usr/bin/killall -0 haproxy"   # Signál 0 = kontrola existence procesu
    interval 2                              # Kontrola každé 2 sekundy
    weight 2                                # Přidat 2 k prioritě, pokud je zdravý
    fall 3                                  # 3 selhání pro považování za DOWN
    rise 2                                  # 2 úspěchy pro považování za UP
}
```

To zajišťuje, že VIP se nachází pouze na uzlu, kde HAProxy skutečně běží a přijímá spojení.

#### Dual-Stack VIP (IPv4 + IPv6)

Konfigurace VIP zahrnuje jak IPv4, tak IPv6 adresy:

```
virtual_ipaddress {
    192.168.1.100/24 dev eth0    # IPv4 VIP
    fd00::100/64 dev eth0        # IPv6 VIP
}
```

Obě adresy failoverují společně, čímž je zachována dual-stack dostupnost API.

### 4.5 Longhorn distribuované úložiště

#### Co je Longhorn?

**Longhorn** je open-source, cloud-native distribuovaný systém blokového úložiště vyvinutý společností SUSE/Rancher pro Kubernetes. Poskytuje:

- **Replikované blokové úložiště**: Každý svazek je replikován napříč více uzly
- **Snapshoty a zálohy**: Point-in-time snapshoty s cíli pro zálohy S3/NFS
- **Disaster recovery**: Replikace mezi clustery pro DR scénáře
- **Samoopravování**: Automatická obnova replik při selhání uzlů
- **Thin provisioning**: Úložiště přidělováno na vyžádání, nikoliv dopředu
- **Webové rozhraní**: Vizuální dashboard pro správu svazků

#### Architektura Longhorn

```
┌─────────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                             │
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
│  Architektura per-svazek:                                         │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  Svazek: my-app-data (10Gi, 3 repliky)                   │    │
│  │                                                           │    │
│  │  ┌─────────────┐                                         │    │
│  │  │   Engine    │  (běží na uzlu, kde je pod naplánován)   │    │
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

Když pod zapisuje data do Longhorn svazku:

1. Zápis vstupuje do **Engine** (iSCSI target na uzlu podu)
2. Engine **synchronně replikuje** na všechny nakonfigurované repliky
3. Zápis je potvrzen teprve poté, co **všechny repliky** potvrdí
4. Pokud replika selže, Engine ji označí jako degradovanou a pokračuje se zbývajícími replikami
5. Longhorn Manager detekuje degradovaný stav a naplánuje **rebuild** na zdravém uzlu

#### Porovnání Longhorn vs. Local-Path

| Vlastnost | Longhorn | Local-Path |
|-----------|----------|------------|
| Replikace | Ano (konfigurovatelná, 1-5 replik) | Ne (jeden uzel) |
| Tolerance selhání uzlu | Ano (data přežijí ztrátu uzlu) | Ne (data ztracena při selhání uzlu) |
| Snapshoty | Ano (inkrementální, efektivní) | Ne |
| Zálohy | Ano (cíle S3, NFS) | Ne (manuální) |
| Výkonnostní režie | ~10-15% (náklady na replikaci) | Žádná (přímý diskový I/O) |
| Složitost | Střední (Helm nasazení) | Minimální (součást K3s) |
| Spotřeba zdrojů | ~500MB RAM na uzel | Zanedbatelná |
| Případ užití | Produkce, stavové zátěže | Vývoj, efemérní data |

### 4.6 Síťová architektura (DHCPv4/DHCPv6)

#### Proč DHCP se statickými lease záznamy?

Toto nasazení používá **DHCP** (jak v4, tak v6) pro konfiguraci sítě namísto statické konfigurace na úrovni OS, protože:

1. **Centralizovaná správa**: Veškeré adresování je spravováno na DHCP serveru
2. **Konzistence**: Stejný mechanismus jako u ostatních síťových zařízení
3. **Flexibilita**: Změna adres nevyžaduje rekonfiguraci OS
4. **Kompatibilita s IPv6**: SLAAC a DHCPv6 fungují s tímto modelem přirozeně

Avšak **statické DHCP lease záznamy** (rezervace) jsou povinné, protože:

- Certifikáty K3s jsou vázány na specifické IP adresy
- Členství v etcd clusteru vyžaduje stabilní adresování
- Backendy HAProxy jsou konfigurovány s pevnými IP adresami
- Keepalived VIP musí být předvídatelná

#### IPv6 a forwarding: Problém accept_ra

Mezi IPv6 forwardingem a zpracováním Router Advertisement (RA) existuje kritická interakce:

```
Výchozí chování jádra Linuxu:
  net.ipv6.conf.all.forwarding = 0  →  accept_ra = 1 (zpracovává RA) ✓
  net.ipv6.conf.all.forwarding = 1  →  accept_ra = 1 (IGNORUJE RA)  ✗

K3s vyžaduje forwarding = 1 pro síťování podů.
To ROZBÍJÍ SLAAC a získávání DHCPv6 adres.

Řešení:
  net.ipv6.conf.all.accept_ra = 2   →  Zpracovávat RA i s forwardingem  ✓
  net.ipv6.conf.eth0.accept_ra = 2  →  Override per-rozhraní             ✓
```

Tato platforma automaticky konfiguruje `accept_ra = 2` na všech uzlech, aby zajistila funkčnost IPv6 adresování s povoleným forwardingem paketů.

#### Dual-Stack síťování

Cluster pracuje v plném dual-stack režimu:

| Síť | IPv4 | IPv6 |
|-----|------|------|
| Síť uzlů | 192.168.1.0/24 | fd00::/64 |
| Pod CIDR | 10.42.0.0/16 | fd42::/48 |
| Service CIDR | 10.43.0.0/16 | fd43::/112 |
| VIP | 192.168.1.100 | fd00::100 |

---

## 5. Postup nasazení

Nasazení sleduje přísné sekvenční pořadí. Každý krok závisí na úspěšném dokončení předchozího kroku.

**Zdroj konfigurace**: Každý nasazovací skript před spuštěním kontroluje existenci předgenerovaných konfiguračních souborů v adresáři `generated/`. Pokud jsou nalezeny (vytvořené pomocí `python3 generate.py` nebo extrakcí ZIP z webového rozhraní), předgenerované konfigurace jsou nasazeny přímo na uzly. Pokud adresář `generated/` chybí nebo je neúplný, skripty se vrátí k inline generování konfigurací z `inventory.conf`. Konfigurační adresář lze přepsat proměnnou prostředí `CONFIG_DIR`.

### Krok 0: Validace prostředí

```bash
./scripts/00-validate-environment.sh
```

**Účel**: Ověření všech předpokladů před provedením jakýchkoliv změn.

**Prováděné kontroly**:
1. Inventory soubor existuje a je parsovatelný
2. Požadované lokální nástroje přítomny (ssh, scp, curl, openssl)
3. Soubor SSH klíče existuje na konfigurované cestě
4. SSH konektivita ke všem master uzlům (timeout: 10s na uzel)
5. SSH konektivita ke všem worker uzlům
6. Skutečné IP adresy odpovídají očekávaným DHCP lease záznamům (ověření funkčnosti DHCP)
7. Identifikace operačního systému na každém uzlu
8. Validace adresáře s předgenerovanými konfiguracemi (pokud `generated/` existuje)

**Chování při ukončení**: Ukončí se s kódem 1, pokud jakákoliv kontrola selže, a hlásí všechna selhání.

### Krok 1: Konfigurace operačního systému

```bash
./scripts/01-configure-os.sh
```

**Účel**: Konfigurace všech uzlů pro provoz K3s po instalaci OS.

**Akce na každém uzlu**:

| Akce | Detail |
|------|--------|
| Nastavení hostname | `hostnamectl set-hostname <hostname>.<domain>` |
| Konfigurace /etc/hosts | Všechny IP uzlů (IPv4 + IPv6) pro lokální překlad |
| Parametry jádra | ip_forward, bridge-nf-call, accept_ra=2, inotify, conntrack |
| Moduly jádra | br_netfilter, overlay, ip_vs, ip_vs_rr/wrr/sh, nf_conntrack |
| Limity souborů | nofile=65536, nproc=65536 (soft+hard) |
| Firewall | Otevřené porty: 6443, 2379, 2380, 10250, 8472, 51820 atd. |
| Balíčky | open-iscsi, nfs-client, cryptsetup, apparmor-parser |
| Non-local bind | Pro HAProxy (pouze mastery): ip_nonlocal_bind=1 |
| SSH klíče | Nasazení authorized_keys + hardening sshd |
| GitHub klíče | Stažení z https://github.com/<user>.keys |

Pokud jsou v `generated/` k dispozici předgenerované konfigurace, skript přímo použije `os/sysctl-k3s.conf`, `network/hosts`, `os/ssh-authorized-keys` a `os/sshd-hardening.conf` namísto inline generování.

### Krok 2: Instalace HAProxy + Keepalived

```bash
./scripts/02-install-haproxy.sh
```

**Účel**: Instalace a konfigurace API load balanceru na všech master uzlech.

**Sekvence**:
1. Generování konfigurace HAProxy (backendy z inventory)
2. Generování Keepalived konfigurace per-uzel (odlišná priorita pro každý uzel)
3. Pro každý master uzel:
   - Instalace balíčků haproxy a keepalived
   - Nasazení haproxy.cfg
   - Nasazení keepalived.conf (specifické pro uzel)
   - Povolení a spuštění služeb
4. Ověření, že VIP je přiřazena uzlu s nejvyšší prioritou
5. Ověření, že HAProxy naslouchá na portu 6443

Pokud jsou k dispozici předgenerované konfigurace, skript čte `generated/haproxy/haproxy.cfg` a `generated/keepalived/{hostname}/keepalived.conf` namísto inline generování.

### Krok 3: Bootstrap prvního K3s serveru

```bash
./scripts/03-install-k3s-first.sh
```

**Účel**: Inicializace K3s clusteru na prvním master uzlu.

**Kritické detaily**:
- Používá příznak `--cluster-init` (vytváří jednouzlový etcd cluster)
- Generuje nebo používá poskytnutý cluster token
- Zahrnuje všechny TLS SANy (VIP, všechny master IP, všechny hostnames)
- Konfiguruje dual-stack CIDRy
- Deaktivuje výchozí Traefik a ServiceLB
- Čeká, až uzel dosáhne stavu Ready
- Ukládá token do lokálního souboru pro následné skripty

Pokud jsou k dispozici předgenerované konfigurace, skript nasazuje `generated/k3s/{hostname}/config.yaml` přímo namísto inline sestavení konfigurace.

### Krok 4: Připojení dalších serverů

```bash
./scripts/04-install-k3s-servers.sh
```

**Účel**: Připojení master-02 a master-03 do clusteru.

**Klíčový rozdíl oproti kroku 3**: Používá `--server https://<first-master-IP>:6443` namísto `--cluster-init`. Připojuje se přes přímou IP prvního masteru (ne VIP), aby se předešlo problémům s kruhovými závislostmi během bootstrapu.

**Po dokončení**: Je ustanoveno 3-uzlové etcd kvórum. Cluster je nyní vysoce dostupný.

Používá předgenerovaný `generated/k3s/{hostname}/config.yaml`, pokud je k dispozici, s inline fallbackem.

### Krok 5: Připojení worker uzlů

```bash
./scripts/05-install-k3s-agents.sh
```

**Účel**: Registrace všech worker uzlů do clusteru.

**Klíčové detaily**:
- Workery se připojují přes **VIP** (ne přes individuální mastery) — HA je již aktivní
- Používá `INSTALL_K3S_EXEC="agent"` (ne "server")
- Automaticky aplikuje worker labely
- Čeká, až každý uzel dosáhne stavu Ready

Používá předgenerovaný `generated/k3s/{hostname}/config.yaml`, pokud je k dispozici, s inline fallbackem.

### Krok 6: Instalace perzistentního úložiště

```bash
STORAGE_PROVIDER=longhorn ./scripts/06-install-storage.sh
```

**Účel**: Nasazení zvoleného řešení perzistentního úložiště.

**Pro Longhorn**:
1. Ověření předpokladů (open-iscsi, iscsid, datová cesta)
2. Instalace Helmu na prvním masteru
3. Přidání Longhorn Helm repozitáře
4. Nasazení s vygenerovaným values souborem
5. Čekání na připravenost všech podů (timeout: 300s)
6. Ověření vytvoření StorageClass

**Pro local-path**:
1. Vytvoření datového adresáře na všech uzlech
2. Aplikace konfigurace StorageClass
3. Nastavení jako výchozí StorageClass

---

## 6. Systém generování konfigurace

### 6.1 Filozofie návrhu

Systém generování konfigurace se řídí principem **"jediný zdroj pravdy, mnoho výstupů"**:

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
     │  Python    │  │  Webové    │  │  Skripty   │
     │ generate.py│  │  rozhraní  │  │  (bash)    │
     └─────┬──────┘  └─────┬──────┘  └─────┬──────┘
           │                │               │
           ▼                ▼               │
     ┌────────────┐  ┌────────────┐         │
     │ generated/ │  │  ZIP soubor│         │
     │ (19 souborů│  │ (stažení)  │         │
     └────────────┘  └────────────┘         │
                                            ▼
                                     ┌────────────┐
                                     │ Vzdálené   │
                                     │ SSH spuštění│
                                     └────────────┘
```

### 6.5 Jednotná konzumace konfigurace

Nasazovací skripty nyní konzumují předgenerované konfigurační soubory z adresáře `generated/`, čímž vzniká jednotný pipeline:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Zdroje konfigurace                                 │
│                                                                       │
│   Cesta A: variables.yaml ──► generate.py ──► generated/              │
│                                                    │                  │
│   Cesta B: Webové rozhraní ──► stažení ZIP ──► unzip ──► generated/   │
│                                                    │                  │
│   Cesta C: inventory.conf ──► inline (fallback) ────┤                 │
│                                                    │                  │
└────────────────────────────────────────────────────┼──────────────────┘
                                                     │
                                                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Nasazovací skripty                                │
│                                                                       │
│   Skripty kontrolují generated/ nejprve, fallback na inventory.conf   │
│                                                                       │
│   00-validate ──► 01-configure-os ──► 02-haproxy ──► 03-k3s-first   │
│   ──► 04-k3s-servers ──► 05-k3s-agents ──► 06-storage               │
└─────────────────────────────────────────────────────────────────────┘
```

Přepsání konfiguračního adresáře: `CONFIG_DIR=/path/to/configs ./scripts/01-configure-os.sh`

### 6.2 Šablonový engine

**Serverová strana (Python)**: Používá Jinja2 3.1+ s `StrictUndefined` — jakákoliv chybějící proměnná způsobí okamžitou chybu namísto tichého prázdného výstupu.

**Klientská strana (prohlížeč)**: Používá Nunjucks 3.2.4, JavaScriptový port Jinja2, umožňující identickou syntaxi šablon ve webovém rozhraní.

### 6.3 Katalog šablon

| Šablona | Výstup | Typ |
|---------|--------|-----|
| haproxy.cfg.j2 | haproxy/haproxy.cfg | Jednotlivý |
| keepalived.conf.j2 | keepalived/{hostname}/keepalived.conf | Per-master |
| k3s-server.yaml.j2 | k3s/{hostname}/config.yaml | Per-master |
| k3s-agent.yaml.j2 | k3s/{hostname}/config.yaml | Per-worker |
| dhcpd4-leases.conf.j2 | network/dhcpd4-leases.conf | Jednotlivý |
| dhcpd6-leases.conf.j2 | network/dhcpd6-leases.conf | Jednotlivý |
| dnsmasq-leases.conf.j2 | network/dnsmasq-leases.conf | Jednotlivý |
| hosts.j2 | network/hosts | Jednotlivý |
| sysctl-k3s.conf.j2 | os/sysctl-k3s.conf | Jednotlivý |
| ssh-config.j2 | os/ssh-config.txt | Jednotlivý |
| disk-single-root.xml.j2 | os/disk-partitioning.xml | Podmíněný |
| disk-multipart.xml.j2 | os/disk-partitioning.xml | Podmíněný |
| disk-multidisk.xml.j2 | os/disk-partitioning.xml | Podmíněný |
| disk-ignition.json.j2 | os/disk-ignition.json | Jednotlivý |
| longhorn-values.yaml.j2 | storage/longhorn-values.yaml | Podmíněný |
| storageclass-local-path.yaml.j2 | storage/storageclass-local-path.yaml | Podmíněný |

### 6.4 Podmíněné vykreslování

Generátor podporuje dva typy podmíněné logiky:

1. **Dynamický výběr šablon**: Šablona pro rozdělení disku je vybrána na základě hodnoty `storage.disk_layout`
2. **Podmínka poskytovatele**: Šablony úložiště se vykreslují pouze při výběru odpovídajícího poskytovatele

```python
# Dynamický výběr šablon
if target.get("dynamic_template"):
    disk_layout = variables["storage"]["disk_layout"]
    template_name = layout_map[disk_layout]

# Podmíněné vykreslování
condition = target.get("condition")
if condition and variables["storage"]["provider"] != condition:
    continue  # Přeskočit tuto šablonu
```

---

## 7. Strategie rozdělení disků

### 7.1 Možnosti rozložení

#### Varianta A: Jeden kořenový oddíl

```
┌─────────────────────────────────────────┐
│             /dev/sda                     │
├──────────┬──────────────────────────────┤
│ /boot/efi│            /                 │
│  512 MB  │     (Btrfs, zbývající)       │
│  (vfat)  │                              │
│          │  Podsvazky:                   │
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
    Systémový disk         Datový disk           Disk úložiště
```

### 7.2 Zdůvodnění výběru souborových systémů

| Přípojný bod | Souborový systém | Důvod |
|--------------|-----------------|-------|
| / | Btrfs | Podporuje transactional-update snapshoty, copy-on-write, komprese |
| /var/lib/rancher | XFS | Vysoký výkon pro zápisy vrstev kontejnerů, bez režie CoW |
| /var/lib/longhorn | XFS | Backend blokového úložiště vyžaduje konzistentní sekvenční výkon zápisu |
| /boot/efi | vfat | Požadováno specifikací UEFI |

---

## 8. Bezpečnostní model

### 8.1 Správa SSH klíčů

Platforma poskytuje tři metody pro nasazení SSH klíčů:

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
│  3. Fallback na lokální soubor klíče                    │
│     ssh.key_path: "~/.ssh/id_ed25519"                   │
│     → Čte ~/.ssh/id_ed25519.pub                         │
└─────────────────────────────────────────────────┬───────┘
                                                  │
                                                  ▼
                                        ┌──────────────────┐
                                        │  Všechny klíče   │
                                        │  sloučeny         │
                                        │  Nasazeny do:     │
                                        │  /root/.ssh/      │
                                        │  authorized_keys  │
                                        │  (všechny uzly)   │
                                        └──────────────────┘
```

### 8.2 Hardening SSH

Při nastavení `ssh.disable_password_auth: true`:

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

### 8.3 Síťová bezpečnost (pravidla firewallu)

| Port | Protokol | Směr | Účel | Uzly |
|------|----------|------|------|------|
| 6443 | TCP | Příchozí | K3s API server | Mastery |
| 2379 | TCP | Pouze mastery | etcd klient | Mastery |
| 2380 | TCP | Pouze mastery | etcd peer | Mastery |
| 10250 | TCP | Příchozí | Kubelet metriky | Všechny |
| 8472 | UDP | Příchozí | VXLAN (Flannel) | Všechny |
| 51820 | UDP | Příchozí | WireGuard IPv4 | Všechny |
| 51821 | UDP | Příchozí | WireGuard IPv6 | Všechny |
| 8404 | TCP | Příchozí | HAProxy stats | Mastery |
| 30000-32767 | TCP/UDP | Příchozí | Rozsah NodePort | Workery |
| VRRP (112) | IP | Pouze mastery | Keepalived | Mastery |

---

## 9. Architektura perzistentního úložiště

### 9.1 Datový tok Longhorn

```
┌─────────────────────────────────────────────────────────────┐
│  Pod zapisuje data                                           │
│  └──► /dev/longhorn/volume-xyz (blokové zařízení)            │
│        └──► Longhorn Engine (iSCSI target, stejný uzel)      │
│              └──► Synchronní replikace                       │
│                    ├──► Replika 1 (worker-01:/var/lib/longhorn/replicas/vol-xyz/)
│                    ├──► Replika 2 (worker-02:/var/lib/longhorn/replicas/vol-xyz/)
│                    └──► Replika 3 (worker-03:/var/lib/longhorn/replicas/vol-xyz/)
│                                                              │
│  Všechny 3 repliky potvrdí ──► Zápis potvrzen podu          │
└─────────────────────────────────────────────────────────────┘
```

### 9.2 Konfigurace StorageClass

**Longhorn StorageClass** (nasazena přes Helm):
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

**Local-Path StorageClass** (vestavěná v K3s):
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
│                GitHub Actions Workflow: lint.yaml             │
│                                                              │
│  Trigger: push do main, pull_request do main                 │
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
│  │   generate-validate      │  │    shell-lint        │     │
│  │                          │  │                      │     │
│  │  python3 generate.py     │  │  shellcheck -x       │     │
│  │    --dry-run             │  │    scripts/*.sh      │     │
│  │  python3 generate.py     │  │                      │     │
│  │  lint vygenerovaný výstup│  │                      │     │
│  │  yamllint generovaný YAML│  │                      │     │
│  └──────────────────────────┘  └──────────────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

### 10.2 Nástroje pro lintování

| Nástroj | Cíl | Pravidla |
|---------|-----|----------|
| **ruff** | Python (.py) | PEP8, isort, bugbear, comprehensions, pathlib, type-checking |
| **yamllint** | YAML (.yaml) | Délka řádku 120, 2-mezerové odsazení, truthy hodnoty |
| **shellcheck** | Shell (.sh) | SC1091 deaktivováno (dynamický source), všechna ostatní pravidla |
| **lint_configs.py** | .cfg, .conf | Sekce HAProxy, syntaxe Keepalived, závorky/středníky DHCP |

---

## 11. Webový generátor konfigurace

### 11.1 Architektura

Webové rozhraní je **statická jednostránková aplikace** nasazená na GitHub Pages. Běží zcela v prohlížeči — žádné serverové zpracování, žádný přenos dat.

```
┌─────────────────────────────────────────────────────────────┐
│                  Prohlížeč (pouze na straně klienta)         │
│                                                              │
│  ┌──────────┐    ┌──────────────┐    ┌──────────────────┐   │
│  │ HTML     │──►│  Nunjucks    │──►│  Vygenerované     │   │
│  │ formulář │    │  šablonový   │    │  soubory          │   │
│  │ (vstup   │    │  engine      │    │  (náhled +        │   │
│  │  uživat.)│    │              │    │   stažení)        │   │
│  └──────────┘    └──────────────┘    └────────┬──────────┘   │
│                                               │              │
│                                     ┌─────────▼──────────┐   │
│                                     │      JSZip         │   │
│                                     │  Generátor archivu │   │
│                                     └─────────┬──────────┘   │
│                                               │              │
│                                     ┌─────────▼──────────┐   │
│                                     │    FileSaver.js    │   │
│                                     │  Spuštění stahování│   │
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
| JSZip | 3.10.1 | Generování ZIP archivu v prohlížeči (CDN) |
| FileSaver.js | 2.0.5 | Spuštění stahování souboru z Blob (CDN) |
| Pure CSS | - | Vlastní tmavý motiv, responzivní rozložení |

### 11.3 Pojmenování ZIP archivu

```
k3s-config-v1.0.0-20260804-143052.zip
│           │     │        │
│           │     │        └── Čas: HHMMSS
│           │     └── Datum: RRRRMMDD
│           └── Verze aplikace
└── Pevný prefix
```

### 11.4 Použití ZIP s CLI skripty

ZIP archiv z webového rozhraní lze použít přímo s CLI nasazovacími skripty:

```bash
# 1. Stáhněte ZIP z https://opentreecz.github.io/k3s/
# 2. Rozbalte do adresáře generated/
unzip k3s-config-v1.0.0-*.zip -d generated/

# 3. Nakonfigurujte inventory.conf s SSH parametry připojení
cp templates/inventory.example.conf inventory.conf
# Upravte: SSH_USER, SSH_KEY_PATH, SSH_PORT, MASTER_NODES (IP), WORKER_NODES (IP)

# 4. Spusťte nasazovací skripty (automaticky detekují a použijí předgenerované konfigurace)
./scripts/00-validate-environment.sh
./scripts/01-configure-os.sh
./scripts/02-install-haproxy.sh
./scripts/03-install-k3s-first.sh
./scripts/04-install-k3s-servers.sh
./scripts/05-install-k3s-agents.sh
```

Skripty automaticky detekují předgenerované konfigurace v `generated/` a použijí je namísto inline generování konfigurací. Soubor `inventory.conf` je stále potřeba pro parametry SSH připojení (uživatel, cesta ke klíči, port) a IP adresy uzlů používané pro SSH konektivitu.

---

## 12. Shrnutí

Tato K3s platforma pro vysoce dostupné nasazení na bare-metal serverech poskytuje kompletní, produkčně připravené řešení pro nasazení Kubernetes na fyzických serverech. Klíčové vlastnosti jsou:

**Architektura**:
- 3-uzlový control plane s vestavěným etcd pro HA konsenzus
- HAProxy + Keepalived pro rozložení zátěže API serveru a VIP failover
- Toleruje selhání jednoho uzlu bez narušení služby
- Dual-stack síťování (IPv4 + IPv6) v celém systému

**Automatizace**:
- 7 sekvenčních skriptů pokrývajících celý životní cyklus nasazení
- Generování konfigurace z jediného souboru proměnných (19+ výstupních souborů)
- Webový generátor pro práci pouze v prohlížeči (bez nutnosti serveru)
- Jednotná konzumace konfigurace: skripty používají předgenerované konfigurace z `generated/` (přes `generate.py` nebo ZIP z webového rozhraní), s automatickým fallbackem na inline generování
- GitHub Actions CI pro průběžné zajištění kvality

**Úložiště**:
- Longhorn distribuované replikované úložiště (produkční kvalita, snapshoty, zálohy)
- Alternativa s local-path provisionerem (vývoj/jednoduché zátěže)
- 3 možnosti rozložení disku přizpůsobené různým hardwarovým konfiguracím

**Bezpečnost**:
- Nasazení SSH klíčů s importem klíčů z GitHubu
- Hardening SSHD (deaktivovaná autentizace heslem, přístup pouze přes klíče)
- Konfigurace firewallu s minimálním počtem otevřených portů
- TLS certifikáty pokrývající všechny přístupové cesty (VIP + individuální uzly)
- Neměnná základna OS (transactional-update, kořenový oddíl pouze pro čtení)

**Flexibilita**:
- Volba mezi SLE Micro (komerční) nebo openSUSE MicroOS (komunitní)
- Volba mezi Longhorn, local-path, nebo bez úložiště
- Volba mezi jedním kořenovým oddílem, více oddíly, nebo více disky
- Podpora DHCPv4/DHCPv6 s konfiguracemi pro ISC DHCP, dnsmasq a Kea
- Konfigurovatelné přes YAML, webové rozhraní nebo proměnné prostředí

**Kvalita**:
- Veškerý kód lintován (Python, YAML, Shell, konfigurační soubory)
- Validace šablon při každém commitu
- Vygenerovaný výstup ověřovaný CI pipelinou
- Kompletní dokumentace (7 průvodců + tento referenční dokument)

---

*Tento dokument popisuje verzi 1.0.0 platformy K3s Baremetal HA Deployment Platform. Pro nejnovější aktualizace viz [repozitář](https://github.com/opentreecz/k3s).*
