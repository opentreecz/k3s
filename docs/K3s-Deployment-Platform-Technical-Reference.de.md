# K3s Hochverfügbare Baremetal-Bereitstellungsplattform

## Technisches Referenzdokument

**Version:** 1.0.0  
**Zuletzt aktualisiert:** August 2026  
**Repository:** [github.com/opentreecz/k3s](https://github.com/opentreecz/k3s)  
**Web-Generator:** [opentreecz.github.io/k3s](https://opentreecz.github.io/k3s/)

---

## Inhaltsverzeichnis

1. [Zusammenfassung](#1-zusammenfassung)
2. [Projektübersicht](#2-projektübersicht)
3. [Architektur](#3-architektur)
4. [Detaillierte Komponentenanalyse](#4-detaillierte-komponentenanalyse)
   - [4.1 Betriebssystemschicht](#41-betriebssystemschicht)
   - [4.2 K3s Kubernetes-Distribution](#42-k3s-kubernetes-distribution)
   - [4.3 HAProxy Load Balancer](#43-haproxy-load-balancer)
   - [4.4 Keepalived und virtuelle IP](#44-keepalived-und-virtuelle-ip)
   - [4.5 Verteilter Longhorn-Speicher](#45-verteilter-longhorn-speicher)
   - [4.6 Netzwerkarchitektur (DHCPv4/DHCPv6)](#46-netzwerkarchitektur-dhcpv4dhcpv6)
5. [Bereitstellungsablauf](#5-bereitstellungsablauf)
6. [Konfigurationserzeugungssystem](#6-konfigurationserzeugungssystem)
7. [Festplattenpartitionierungsstrategie](#7-festplattenpartitionierungsstrategie)
8. [Sicherheitsmodell](#8-sicherheitsmodell)
9. [Architektur für persistenten Speicher](#9-architektur-für-persistenten-speicher)
10. [Kontinuierliche Integration und Qualitätssicherung](#10-kontinuierliche-integration-und-qualitätssicherung)
11. [Webbasierter Konfigurationsgenerator](#11-webbasierter-konfigurationsgenerator)
12. [Zusammenfassung](#12-zusammenfassung)

---

## 1. Zusammenfassung

Dieses Projekt stellt eine vollständige, automatisierte Bereitstellungsplattform zur Einrichtung eines **hochverfügbaren K3s-Kubernetes-Clusters** auf Baremetal-Servern bereit. Die Plattform zielt auf Umgebungen ab, die **SUSE Linux Enterprise Micro (SLE Micro)** oder **openSUSE MicroOS** verwenden — unveränderliche, containeroptimierte Betriebssysteme, die speziell für Edge- und Kubernetes-Workloads entwickelt wurden.

Die Bereitstellungsplattform deckt den gesamten Lebenszyklus der Cluster-Provisionierung ab:

- Installation und Konfiguration des Betriebssystems
- Netzwerkplanung mit DHCPv4/DHCPv6-Verwaltung statischer Leases
- API-Server-Hochverfügbarkeit über HAProxy und Keepalived
- Automatisierter K3s-Cluster-Bootstrap mit eingebettetem etcd
- Aufnahme von Worker-Knoten
- Bereitstellung von persistentem Speicher (Longhorn oder local-path)
- SSH-Schlüsselverwaltung mit GitHub-Schlüsselimport
- Einheitliche Konfigurationsverwendung: Bereitstellungsskripte nutzen vorerzeugte Konfigurationen aus `generated/` (erstellt durch `generate.py` oder Web-UI-ZIP-Extraktion), mit automatischem Fallback auf Inline-Erzeugung aus `inventory.conf`

Die gesamte Konfiguration wird durch eine **einzelne Variablendatei** gesteuert und über **Jinja2-Templates** gerendert, was Konsistenz, Wiederholbarkeit und Nachvollziehbarkeit über alle Umgebungen hinweg gewährleistet.

---

## 2. Projektübersicht

### 2.1 Problemstellung

Die Bereitstellung eines produktionsreifen Kubernetes-Clusters auf Baremetal-Servern stellt mehrere Herausforderungen dar, die verwaltete Cloud-Umgebungen abstrahieren:

- Keine automatisierte Infrastrukturbereitstellung (kein Terraform/Cloud-APIs)
- Kein integrierter Load Balancer für den API-Server
- Kein verwaltetes Speicher-Backend
- Netzwerkadressierung muss geplant und mit bestehender DHCP-Infrastruktur koordiniert werden
- Installation und Härtung des Betriebssystems sind manuell
- Zertifikatsverwaltung erfordert sorgfältige IP-/Hostname-Planung

### 2.2 Lösungsarchitektur

Diese Plattform löst diese Herausforderungen durch einen schichtbasierten Ansatz:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Konfigurationserzeugungsschicht                    │
│                                                                       │
│   variables.yaml ──► Jinja2-Templates ──► Erzeugte Konfigurationen   │
│   (einzige Quelle)   (18 Templates)       (19+ Ausgabedateien)       │
│                                                                       │
│   Web-UI (GitHub Pages) ──► Browserseitiges Nunjucks ──► ZIP-Archiv  │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Bereitstellungsautomatisierungsschicht             │
│                                                                       │
│   00-validate-environment.sh    Vorabprüfungen                       │
│   01-configure-os.sh            OS-Härtung, SSH-Schlüssel, sysctl    │
│   02-install-haproxy.sh         HAProxy + Keepalived auf Mastern     │
│   03-install-k3s-first.sh       Bootstrap erster Server (cluster-init)│
│   04-install-k3s-servers.sh     Weitere Server-Knoten beitreten      │
│   05-install-k3s-agents.sh      Worker-Knoten beitreten              │
│   06-install-storage.sh         Longhorn- oder local-path-Bereitst.  │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       Infrastrukturschicht                            │
│                                                                       │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐                          │
│   │master-01 │  │master-02 │  │master-03 │  Control Plane (3 Knoten)│
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
│   │worker-01 │  │worker-02 │  │worker-03 │  Datenebene (N Knoten)   │
│   │K3s Agent │  │K3s Agent │  │K3s Agent │                          │
│   │Longhorn  │  │Longhorn  │  │Longhorn  │                          │
│   └──────────┘  └──────────┘  └──────────┘                          │
└─────────────────────────────────────────────────────────────────────┘
```

**Konfigurationsfluss**: Das Verzeichnis `generated/` dient als Brücke zwischen der Konfigurationserzeugungsschicht und der Bereitstellungsautomatisierungsschicht. Es kann entweder durch `python3 generate.py` (aus `variables.yaml`) oder durch Extrahieren eines Web-UI-ZIP-Archivs (`unzip k3s-config-*.zip -d generated/`) befüllt werden. Wenn die Bereitstellungsskripte vorerzeugte Konfigurationen in diesem Verzeichnis finden, verwenden sie diese direkt. Wenn keine vorerzeugten Konfigurationen gefunden werden, fallen die Skripte auf die Inline-Erzeugung von Konfigurationen aus `inventory.conf` zurück.

### 2.3 Repository-Struktur

```
k3s/
├── variables.yaml                  # Einzige Wahrheitsquelle
├── generate.py                     # Python-Template-Renderer
├── lint_configs.py                 # Benutzerdefinierter Konfigurationslinter
├── requirements.txt                # Python-Abhängigkeiten
├── pyproject.toml                  # Ruff-Linter-Konfiguration
├── .yamllint.yaml                  # YAML-Lint-Regeln
├── .shellcheckrc                   # Shell-Lint-Konfiguration
├── .github/workflows/
│   ├── lint.yaml                   # CI: Alle Dateitypen linten
│   └── pages.yaml                  # CI: Web-UI auf GitHub Pages bereitstellen
├── docs/                           # Schritt-für-Schritt-Dokumentation
├── templates/jinja2/               # 18 Jinja2-Konfigurationstemplates
├── configs/                        # Statische Referenzkonfigurationen
├── scripts/                        # 7 Bereitstellungsautomatisierungsskripte
├── web/                            # Browserbasierter Konfigurationsgenerator
└── generated/                      # Ausgabeverzeichnis (gitignored)
```

---

## 3. Architektur

### 3.1 Hochverfügbarkeitstopologie

Der Cluster verwendet eine **3-Knoten-Control-Plane** mit **eingebettetem etcd** für den Konsens, vorgeschaltet mit **HAProxy** für das API-Load-Balancing und **Keepalived** für das Virtual-IP-(VIP-)Failover.

```
                    ┌─────────────────────────────┐
                    │         Clients              │
                    │   (kubectl, CI/CD, Apps)     │
                    └──────────────┬───────────────┘
                                   │
                                   ▼
                    ┌─────────────────────────────┐
                    │     Virtuelle IP (VIP)       │
                    │    192.168.1.100:6443        │
                    │    fd00::100:6443            │
                    │  (verwaltet durch Keepalived)│
                    └──────────────┬───────────────┘
                                   │
              ┌────────────────────┼────────────────────┐
              │                    │                    │
              ▼                    ▼                    ▼
    ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
    │   HAProxy       │  │   HAProxy       │  │   HAProxy       │
    │   (Frontend)    │  │   (Frontend)    │  │   (Frontend)    │
    │   master-01     │  │   master-02     │  │   master-03     │
    │                 │  │                 │  │                 │
    │   K3s Server    │  │   K3s Server    │  │   K3s Server    │
    │   API Server    │  │   API Server    │  │   API Server    │
    │   Controller    │  │   Controller    │  │   Controller    │
    │   Scheduler     │  │   Scheduler     │  │   Scheduler     │
    │                 │  │                 │  │                 │
    │   etcd          │  │   etcd          │  │   etcd          │
    │  (eingebettet)  │  │  (eingebettet)  │  │  (eingebettet)  │
    └─────────────────┘  └─────────────────┘  └─────────────────┘
              │                    │                    │
              │         etcd-Peer-Replikation           │
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

### 3.2 Ausfalldomänen

Die Architektur toleriert folgende Ausfälle ohne Dienstunterbrechung:

| Ausfallszenario | Auswirkung | Wiederherstellung |
|-----------------|------------|-------------------|
| 1 Master-Knoten ausgefallen | Keine Auswirkung (2/3 etcd-Quorum erhalten) | Automatisches VIP-Failover |
| 1 Worker-Knoten ausgefallen | Pods werden auf verbleibende Worker umgeplant | Automatisch durch Kubernetes |
| HAProxy auf 1 Master | VIP wechselt zu gesundem HAProxy-Knoten | Keepalived-Failover (<3s) |
| Netzwerkpartition (1 Master isoliert) | Quorum durch Mehrheit erhalten | Automatische Abstimmung |
| 2 Master-Knoten ausgefallen | **Cluster nicht verfügbar** (Quorum verloren) | Manueller Eingriff erforderlich |

### 3.3 Netzwerkfluss

```
kubectl ──► VIP:6443 ──► HAProxy ──► K3s API Server (einer von 3 Mastern)
                              │
                              ├──► master-01:6443 (Prüfung: TCP-Health)
                              ├──► master-02:6443 (Prüfung: TCP-Health)
                              └──► master-03:6443 (Prüfung: TCP-Health)

Worker Agent ──► VIP:6443 ──► HAProxy ──► K3s API Server
                                              │
                                              ▼
                                     Knoten registrieren
                                     Pod-Spezifikationen empfangen
                                     Status melden
```

---

## 4. Detaillierte Komponentenanalyse

### 4.1 Betriebssystemschicht

#### SUSE Linux Enterprise Micro (SLE Micro)

**SLE Micro** ist SUSEs kommerziell unterstütztes, unveränderliches Betriebssystem, das speziell für containerisierte und virtualisierte Workloads entwickelt wurde. Wesentliche Eigenschaften:

- **Unveränderliches Root-Dateisystem**: Die Root-Partition ist schreibgeschützt. Änderungen werden über `transactional-update` angewendet, das einen neuen Btrfs-Snapshot erstellt. Das System startet beim nächsten Neustart in den neuen Snapshot, was atomare Upgrades mit sofortiger Rollback-Fähigkeit ermöglicht.
- **Minimale Angriffsfläche**: Wird nur mit wesentlichen Paketen ausgeliefert. Keine Desktopumgebung, keine unnötigen Daemons.
- **SELinux/AppArmor**: Mandatory Access Control standardmäßig aktiviert.
- **Kommerzieller Lebenszyklus**: 4+ Jahre Wartung und Sicherheitsupdates pro Hauptversion.
- **Zertifizierung**: FIPS 140-2, Common-Criteria-zertifizierte Varianten verfügbar.

#### openSUSE MicroOS

**openSUSE MicroOS** ist die communitygetriebene Upstream-Version von SLE Micro mit derselben Architektur:

- **Rolling Release**: Kontinuierliche Updates (Tumbleweed-basiert).
- **Identischer transactional-update-Mechanismus**: Dasselbe atomare Upgrade-System.
- **Keine Registrierung erforderlich**: Frei verfügbar, Community-unterstützt.
- **Ideal für**: Entwicklungscluster, Proof-of-Concept, Community-Produktionsumgebungen.

#### Transactional-Update-Mechanismus

```
┌─────────────────────────────────────────────────────────────┐
│                    Btrfs-Root-Dateisystem                      │
│                                                              │
│  Snapshot #1 (aktuell, schreibgeschützt)                    │
│  └── / (laufendes System)                                   │
│                                                              │
│  Snapshot #2 (erstellt durch transactional-update)           │
│  └── / (modifiziertes System: neue Pakete, Konfig.-Änder.)  │
│                                                              │
│  transactional-update reboot ──► Start in Snapshot #2       │
│                                                              │
│  Falls Snapshot #2 fehlschlägt:                              │
│  └── Rollback auf Snapshot #1 (sofort, kein Datenverlust)   │
└─────────────────────────────────────────────────────────────┘
```

Das Werkzeug `transactional-update` ist der exklusive Mechanismus zur Modifikation des Betriebssystems:

```bash
# Pakete installieren (wirksam nach Neustart)
transactional-update pkg install open-iscsi nfs-client

# Alle ausstehenden Updates anwenden
transactional-update up

# In den neuen Snapshot neustarten
transactional-update reboot
```

### 4.2 K3s Kubernetes-Distribution

#### Was ist K3s?

**K3s** ist eine zertifizierte, produktionsreife Kubernetes-Distribution, die von SUSE/Rancher entwickelt wird. Sie verpackt die gesamte Kubernetes-Control-Plane in eine einzige Binärdatei (~60 MB) und eignet sich damit für ressourcenbeschränkte Umgebungen, Edge-Computing und Baremetal-Bereitstellungen, bei denen der betriebliche Aufwand von kubeadm-basierten Clustern unerwünscht ist.

#### K3s vs. Upstream-Kubernetes

| Merkmal | K3s | Upstream (kubeadm) |
|---------|-----|-------------------|
| Binärgröße | ~60 MB | ~300+ MB (mehrere Binärdateien) |
| Speicherbedarf | ~512 MB (Server) | ~1–2 GB (Server) |
| Installation | Einzelner curl-Befehl | Mehrstufig, Zertifikatsverwaltung |
| etcd | Eingebettet (oder extern) | Muss separat bereitgestellt werden |
| Container-Runtime | containerd (integriert) | Muss separat installiert werden |
| Netzwerk | Flannel (integriert) | CNI-Plugin muss installiert werden |
| Zertifikatsverwaltung | Automatische Rotation | Manuelle Konfiguration |
| Upgrade | Binärdatei ersetzen + Neustart | Rollierendes Upgrade-Verfahren |

#### K3s-Server-Architektur (Control Plane)

Jeder K3s-Server-Knoten führt aus:

```
┌──────────────────────────────────────────────────────┐
│                    K3s-Server-Prozess                   │
│                                                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │ API Server  │  │ Controller  │  │  Scheduler  │  │
│  │             │  │  Manager    │  │             │  │
│  └──────┬──────┘  └─────────────┘  └─────────────┘  │
│         │                                            │
│  ┌──────▼──────┐  ┌─────────────┐                   │
│  │   etcd      │  │ containerd  │                   │
│  │ (eingebettet)│  │             │                   │
│  └─────────────┘  └─────────────┘                   │
│                                                       │
│  ┌─────────────┐  ┌─────────────┐                   │
│  │  Flannel    │  │ CoreDNS     │                   │
│  │  (CNI)      │  │             │                   │
│  └─────────────┘  └─────────────┘                   │
└──────────────────────────────────────────────────────┘
```

#### K3s-Agent-Architektur (Worker)

Jeder K3s-Agent-Knoten führt aus:

```
┌──────────────────────────────────────────────────────┐
│                    K3s-Agent-Prozess                    │
│                                                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │  kubelet    │  │ kube-proxy  │  │ containerd  │  │
│  │             │  │             │  │             │  │
│  └─────────────┘  └─────────────┘  └─────────────┘  │
│                                                       │
│  ┌─────────────┐  ┌─────────────────────────────┐   │
│  │  Flannel    │  │  Workload-Pods              │   │
│  │  (CNI)      │  │  (Benutzeranwendungen)      │   │
│  └─────────────┘  └─────────────────────────────┘   │
└──────────────────────────────────────────────────────┘
```

#### Eingebetteter etcd-Cluster

K3s verwendet einen eingebetteten etcd-Cluster zur Speicherung des gesamten Cluster-Zustands. Mit 3 Server-Knoten arbeitet der etcd-Cluster mit dem Raft-Konsensalgorithmus:

- **Quorum**: 2 von 3 Knoten müssen Schreibvorgängen zustimmen (Mehrheit)
- **Leader-Wahl**: Ein Knoten ist der Leader; die anderen sind Follower
- **Datenreplikation**: Alle Daten werden auf alle 3 Knoten repliziert
- **Ausfalltoleranz**: Übersteht 1 Knotenausfall ohne Datenverlust

```
         ┌─────────────┐
         │   etcd      │
         │  (Leader)   │
         │  master-01  │
         └──────┬──────┘
                │
       ┌────────┴────────┐
       │  Raft-Konsens   │
       │  Replikation    │
       ▼                 ▼
┌─────────────┐   ┌─────────────┐
│   etcd      │   │   etcd      │
│ (Follower)  │   │ (Follower)  │
│  master-02  │   │  master-03  │
└─────────────┘   └─────────────┘
```

#### K3s-Cluster-Bootstrap-Sequenz

Die Cluster-Initialisierung folgt einer präzisen Reihenfolge:

1. **Erster Server** startet mit `--cluster-init` und erstellt einen Einzelknoten-etcd-Cluster
2. **Zweiter Server** tritt über `--server https://<erster>:6443` bei und wird ein etcd-Follower
3. **Dritter Server** tritt ähnlich bei und vervollständigt das 3-Knoten-etcd-Quorum
4. **Agents** treten über die VIP (`https://<VIP>:6443`) für Hochverfügbarkeit bei

```
Zeit ──────────────────────────────────────────────────────────────►

master-01: [cluster-init] ──► [etcd Leader, 1/1] ──► [etcd Leader, 1/3]
                                                              │
master-02:                    [Beitritt] ──► [etcd Follower, 2/3] ─┤
                                                              │
master-03:                              [Beitritt] ──► [Follower, 3/3]
                                                              │
                                              Quorum erreicht ─┘
                                                              │
worker-01:                                         [Beitritt über VIP]
worker-02:                                         [Beitritt über VIP]
worker-03:                                         [Beitritt über VIP]
```

#### TLS-Zertifikatsarchitektur

K3s erzeugt und verwaltet TLS-Zertifikate automatisch. Die `--tls-san`-Flags stellen sicher, dass Zertifikate für alle Zugriffspfade gültig sind:

```
Subject Alternative Names des Zertifikats:
├── 192.168.1.100        (VIP IPv4)
├── fd00::100            (VIP IPv6)
├── k3s-api.k3s.local    (VIP-Hostname)
├── master-01.k3s.local  (Knoten-FQDN)
├── master-01            (Kurzname)
├── 192.168.1.101        (Knoten-IP)
├── master-02.k3s.local
├── master-02
├── 192.168.1.102
├── master-03.k3s.local
├── master-03
└── 192.168.1.103
```

Dies stellt sicher, dass `kubectl` sich verbinden kann über:
- Die VIP (Normalbetrieb)
- Jede einzelne Master-IP (Debugging/Notfall)
- Jede Hostname-Variante

### 4.3 HAProxy Load Balancer

#### Zweck

HAProxy dient als **Layer-4-(TCP-)Load-Balancer** für den K3s-API-Server. Er verteilt eingehende Verbindungen auf Port 6443 auf alle drei Master-Knoten und bietet:

- **Lastverteilung**: Round-Robin-Balancing über gesunde Backends
- **Gesundheitsprüfung**: TCP-Level-Health-Probes alle 10 Sekunden
- **Automatisches Failover**: Entfernt ungesunde Backends innerhalb von 2 fehlgeschlagenen Prüfungen aus dem Pool
- **Verbindungspersistenz**: Erhält bestehende Verbindungen während Backend-Übergängen

#### HAProxy-Konfigurationsarchitektur

```
┌──────────────────────────────────────────────────────┐
│                   HAProxy-Prozess                      │
│                                                       │
│  ┌─────────────────────────────────────────────────┐ │
│  │              Frontend: k3s_api_frontend          │ │
│  │              bind *:6443 (TCP-Modus)            │ │
│  └──────────────────────┬──────────────────────────┘ │
│                          │                            │
│  ┌──────────────────────▼──────────────────────────┐ │
│  │              Backend: k3s_api_backend            │ │
│  │              balance: roundrobin                 │ │
│  │                                                  │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐      │ │
│  │  │master-01 │  │master-02 │  │master-03 │      │ │
│  │  │:6443     │  │:6443     │  │:6443     │      │ │
│  │  │ Prüf. ✓  │  │ Prüf. ✓  │  │ Prüf. ✓  │      │ │
│  │  └──────────┘  └──────────┘  └──────────┘      │ │
│  └─────────────────────────────────────────────────┘ │
│                                                       │
│  ┌─────────────────────────────────────────────────┐ │
│  │              Listen: stats                       │ │
│  │              bind *:8404 (HTTP-Modus)           │ │
│  │              /stats Dashboard                    │ │
│  └─────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

#### Gesundheitsprüfungsparameter

| Parameter | Wert | Beschreibung |
|-----------|------|--------------|
| `inter` | 10s | Prüfintervall wenn Server AKTIV |
| `downinter` | 5s | Prüfintervall wenn Server INAKTIV |
| `rise` | 2 | Aufeinanderfolgende erfolgreiche Prüfungen für Status AKTIV |
| `fall` | 2 | Aufeinanderfolgende fehlgeschlagene Prüfungen für Status INAKTIV |
| `slowstart` | 60s | Schrittweise Verkehrserhöhung nach Wiederherstellung |
| `maxconn` | 250 | Max. gleichzeitige Verbindungen pro Backend |

#### Warum TCP-Modus (Layer 4)?

HAProxy arbeitet im TCP-Modus (nicht HTTP), weil:

1. Die K3s-API **Mutual TLS** (mTLS) verwendet — HAProxy kann die Verbindung nicht terminieren
2. Der TCP-Modus **geringeren Overhead** hat (kein HTTP-Parsing)
3. Das API-Protokoll **HTTP/2** mit Streaming (Watches) ist — der TCP-Modus verarbeitet dies nativ
4. Gesundheitsprüfungen **TCP-Connect** verwenden (Port 6443 reagiert = gesund)

### 4.4 Keepalived und virtuelle IP

#### Zweck

Keepalived implementiert das **Virtual Router Redundancy Protocol (VRRP)** zur Verwaltung einer schwebenden virtuellen IP-Adresse (VIP) über die drei Master-Knoten. Diese VIP ist der einzige Einstiegspunkt für alle API-Zugriffe.

#### VRRP-Betrieb

```
Normalbetrieb:                        Nach Ausfall von master-01:

  master-01 (MASTER, Priorität 101)     master-01 (AUSGEFALLEN)
  ├── VIP: 192.168.1.100 ✓             ├── VIP: (freigegeben)
  ├── Sendet VRRP-Advertisements       │
  │                                     │
  master-02 (BACKUP, Priorität 100)     master-02 (MASTER, Priorität 100)
  ├── VIP: (Standby)                   ├── VIP: 192.168.1.100 ✓
  ├── Horcht auf Advertisements        ├── Sendet VRRP-Advertisements
  │                                     │
  master-03 (BACKUP, Priorität 99)      master-03 (BACKUP, Priorität 99)
  ├── VIP: (Standby)                   ├── VIP: (Standby)
  ├── Horcht auf Advertisements        ├── Horcht auf Advertisements
```

#### Failover-Sequenz

1. Master-01 (MASTER) sendet VRRP-Advertisements jede Sekunde
2. Master-02 und master-03 (BACKUP) horchen auf diese Advertisements
3. Wenn Advertisements 3 Sekunden lang ausbleiben (fall × Intervall):
   - Der BACKUP mit der höchsten Priorität (master-02, Priorität 100) wechselt zu MASTER
   - Er sendet ein Gratuitous ARP, das die VIP auf seiner MAC-Adresse ankündigt
   - Alle Netzwerk-Switches aktualisieren ihre MAC-Tabellen
   - Der Datenverkehr fließt sofort zu master-02
4. Wenn master-01 sich erholt:
   - Mit Preemption aktiviert: master-01 übernimmt MASTER zurück (höhere Priorität)
   - Ohne Preemption: master-02 behält MASTER, bis er ausfällt

#### Gesundheitsüberwachungsskript

Keepalived verwendet ein Gesundheitsprüfungsskript, um den VIP-Besitz an die HAProxy-Gesundheit zu koppeln:

```bash
vrrp_script check_haproxy {
    script "/usr/bin/killall -0 haproxy"   # Signal 0 = prüfen ob Prozess existiert
    interval 2                              # Alle 2 Sekunden prüfen
    weight 2                                # 2 zur Priorität addieren wenn gesund
    fall 3                                  # 3 Fehlschläge für Status INAKTIV
    rise 2                                  # 2 Erfolge für Status AKTIV
}
```

Dies stellt sicher, dass die VIP nur auf einem Knoten liegt, auf dem HAProxy tatsächlich läuft und Verbindungen akzeptiert.

#### Dual-Stack-VIP (IPv4 + IPv6)

Die VIP-Konfiguration umfasst sowohl IPv4- als auch IPv6-Adressen:

```
virtual_ipaddress {
    192.168.1.100/24 dev eth0    # IPv4-VIP
    fd00::100/64 dev eth0        # IPv6-VIP
}
```

Beide Adressen wechseln gemeinsam über, wodurch die Dual-Stack-API-Erreichbarkeit erhalten bleibt.

### 4.5 Verteilter Longhorn-Speicher

#### Was ist Longhorn?

**Longhorn** ist ein quelloffenes, cloudnatives verteiltes Blockspeichersystem, das von SUSE/Rancher für Kubernetes entwickelt wurde. Es bietet:

- **Replizierten Blockspeicher**: Jedes Volume wird über mehrere Knoten repliziert
- **Snapshots und Backups**: Zeitpunktbezogene Snapshots mit S3-/NFS-Backup-Zielen
- **Disaster Recovery**: Clusterübergreifende Replikation für DR-Szenarien
- **Selbstheilung**: Automatischer Replica-Neuaufbau bei Knotenausfall
- **Thin Provisioning**: Speicher wird bei Bedarf zugewiesen, nicht im Voraus
- **Web-UI**: Visuelles Dashboard für Volume-Verwaltung

#### Longhorn-Architektur

```
┌─────────────────────────────────────────────────────────────────┐
│                    Kubernetes-Cluster                              │
│                                                                   │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │              Longhorn Manager (DaemonSet)                  │   │
│  │              Läuft auf allen Knoten                        │   │
│  │              Orchestriert Volumes, Replicas, Engines       │   │
│  └───────────────────────────────────────────────────────────┘   │
│                                                                   │
│  ┌──────────────────┐  ┌──────────────────┐                     │
│  │  Longhorn CSI    │  │  Longhorn UI     │                     │
│  │  Treiber         │  │  (Deployment)    │                     │
│  │  (DaemonSet)     │  │  Dashboard       │                     │
│  └──────────────────┘  └──────────────────┘                     │
│                                                                   │
│  Pro-Volume-Architektur:                                          │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  Volume: my-app-data (10Gi, 3 Replicas)                  │    │
│  │                                                           │    │
│  │  ┌─────────────┐                                         │    │
│  │  │   Engine    │  (läuft auf Knoten, auf dem Pod geplant)│    │
│  │  │  (iSCSI)    │                                         │    │
│  │  └──────┬──────┘                                         │    │
│  │         │                                                 │    │
│  │    ┌────┼────────────────┐                                │    │
│  │    │    │                │                                │    │
│  │    ▼    ▼                ▼                                │    │
│  │  ┌────────┐  ┌────────┐  ┌────────┐                      │    │
│  │  │Replica │  │Replica │  │Replica │                      │    │
│  │  │worker-1│  │worker-2│  │worker-3│                      │    │
│  │  └────────┘  └────────┘  └────────┘                      │    │
│  └──────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

#### Schreibpfad

Wenn ein Pod Daten in ein Longhorn-Volume schreibt:

1. Der Schreibvorgang gelangt zur **Engine** (iSCSI-Target auf dem Knoten des Pods)
2. Die Engine **repliziert synchron** auf alle konfigurierten Replicas
3. Der Schreibvorgang wird erst bestätigt, nachdem **alle Replicas** bestätigt haben
4. Falls eine Replica ausfällt, markiert die Engine sie als degradiert und fährt mit den verbleibenden Replicas fort
5. Der Longhorn Manager erkennt den degradierten Zustand und plant einen **Neuaufbau** auf einem gesunden Knoten

#### Vergleich Longhorn vs. Local-Path

| Merkmal | Longhorn | Local-Path |
|---------|----------|------------|
| Replikation | Ja (konfigurierbar, 1–5 Replicas) | Nein (einzelner Knoten) |
| Knotenausfalltoleranz | Ja (Daten überleben Knotenverlust) | Nein (Daten verloren bei Knotenausfall) |
| Snapshots | Ja (inkrementell, effizient) | Nein |
| Backups | Ja (S3-, NFS-Ziele) | Nein (manuell) |
| Leistungsoverhead | ~10–15 % (Replikationskosten) | Keiner (direkte Festplatten-I/O) |
| Komplexität | Mittel (Helm-Deployment) | Minimal (in K3s integriert) |
| Ressourcenverbrauch | ~500 MB RAM pro Knoten | Vernachlässigbar |
| Anwendungsfall | Produktion, zustandsbehaftete Workloads | Entwicklung, kurzlebige Daten |

### 4.6 Netzwerkarchitektur (DHCPv4/DHCPv6)

#### Warum DHCP mit statischen Leases?

Diese Bereitstellung verwendet **DHCP** (sowohl v4 als auch v6) für die Netzwerkkonfiguration anstelle statischer Konfiguration auf OS-Ebene, weil:

1. **Zentralisierte Verwaltung**: Die gesamte Adressierung wird auf dem DHCP-Server verwaltet
2. **Konsistenz**: Derselbe Mechanismus wie bei anderen Netzwerkgeräten
3. **Flexibilität**: Adressänderungen erfordern keine OS-Neukonfiguration
4. **IPv6-Kompatibilität**: SLAAC und DHCPv6 funktionieren natürlich mit diesem Modell

Jedoch sind **statische DHCP-Leases** (Reservierungen) zwingend erforderlich, weil:

- K3s-Zertifikate an bestimmte IP-Adressen gebunden sind
- Die etcd-Clustermitgliedschaft stabile Adressierung erfordert
- HAProxy-Backends mit festen IPs konfiguriert sind
- Die Keepalived-VIP vorhersagbar sein muss

#### IPv6 und Forwarding: Das accept_ra-Problem

Es besteht eine kritische Wechselwirkung zwischen IPv6-Forwarding und der Verarbeitung von Router Advertisements (RA):

```
Standard-Linux-Kernel-Verhalten:
  net.ipv6.conf.all.forwarding = 0  →  accept_ra = 1 (RAs verarbeiten) ✓
  net.ipv6.conf.all.forwarding = 1  →  accept_ra = 1 (RAs IGNORIEREN)  ✗

K3s benötigt forwarding = 1 für Pod-Netzwerk.
Dies BRICHT SLAAC und DHCPv6-Adressbezug.

Lösung:
  net.ipv6.conf.all.accept_ra = 2   →  RAs auch mit Forwarding verarbeiten ✓
  net.ipv6.conf.eth0.accept_ra = 2  →  Schnittstellen-spezifische Überschreibung ✓
```

Diese Plattform konfiguriert automatisch `accept_ra = 2` auf allen Knoten, um sicherzustellen, dass die IPv6-Adressierung bei aktiviertem Paket-Forwarding weiterhin funktioniert.

#### Dual-Stack-Netzwerk

Der Cluster arbeitet im vollständigen Dual-Stack-Modus:

| Netzwerk | IPv4 | IPv6 |
|----------|------|------|
| Knotennetzwerk | 192.168.1.0/24 | fd00::/64 |
| Pod-CIDR | 10.42.0.0/16 | fd42::/48 |
| Service-CIDR | 10.43.0.0/16 | fd43::/112 |
| VIP | 192.168.1.100 | fd00::100 |

---

## 5. Bereitstellungsablauf

Die Bereitstellung folgt einer strikten sequenziellen Reihenfolge. Jeder Schritt hängt vom erfolgreichen Abschluss des vorherigen Schritts ab.

**Konfigurationsquelle**: Jedes Bereitstellungsskript prüft vor der Ausführung, ob vorerzeugte Konfigurationsdateien im Verzeichnis `generated/` vorhanden sind. Wenn welche gefunden werden (erzeugt durch `python3 generate.py` oder durch Extrahieren eines Web-UI-ZIP), werden die vorerzeugten Konfigurationen direkt auf die Knoten übertragen. Wenn das Verzeichnis `generated/` fehlt oder unvollständig ist, fallen die Skripte auf die Inline-Erzeugung von Konfigurationen aus `inventory.conf` zurück. Das Konfigurationsverzeichnis kann mit der Umgebungsvariable `CONFIG_DIR` überschrieben werden.

### Schritt 0: Umgebungsvalidierung

```bash
./scripts/00-validate-environment.sh
```

**Zweck**: Validiert alle Voraussetzungen, bevor Änderungen vorgenommen werden.

**Durchgeführte Prüfungen**:
1. Inventardatei existiert und ist parsebar
2. Erforderliche lokale Werkzeuge vorhanden (ssh, scp, curl, openssl)
3. SSH-Schlüsseldatei existiert am konfigurierten Pfad
4. SSH-Konnektivität zu allen Master-Knoten (Timeout: 10s pro Knoten)
5. SSH-Konnektivität zu allen Worker-Knoten
6. Tatsächliche IP-Adressen stimmen mit erwarteten DHCP-Leases überein (verifiziert DHCP-Funktion)
7. Betriebssystemidentifikation auf jedem Knoten
8. Validierung des Verzeichnisses mit vorerzeugten Konfigurationen (falls `generated/` existiert)

**Beendungsverhalten**: Beendet sich mit Exit-Code 1, wenn eine Prüfung fehlschlägt, und meldet alle Fehler.

### Schritt 1: Betriebssystemkonfiguration

```bash
./scripts/01-configure-os.sh
```

**Zweck**: Konfiguriert alle Knoten für den K3s-Betrieb nach der OS-Installation.

**Aktionen pro Knoten**:

| Aktion | Detail |
|--------|--------|
| Hostname setzen | `hostnamectl set-hostname <hostname>.<domain>` |
| /etc/hosts konfigurieren | Alle Knoten-IPs (IPv4 + IPv6) für lokale Auflösung |
| Kernel-Parameter | ip_forward, bridge-nf-call, accept_ra=2, inotify, conntrack |
| Kernel-Module | br_netfilter, overlay, ip_vs, ip_vs_rr/wrr/sh, nf_conntrack |
| Datei-Limits | nofile=65536, nproc=65536 (soft+hard) |
| Firewall | Ports öffnen: 6443, 2379, 2380, 10250, 8472, 51820, etc. |
| Pakete | open-iscsi, nfs-client, cryptsetup, apparmor-parser |
| Non-local Bind | Für HAProxy (nur Master): ip_nonlocal_bind=1 |
| SSH-Schlüssel | authorized_keys bereitstellen + sshd-Härtung |
| GitHub-Schlüssel | Abruf von https://github.com/<user>.keys |

Wenn vorerzeugte Konfigurationen in `generated/` verfügbar sind, verwendet das Skript `os/sysctl-k3s.conf`, `network/hosts`, `os/ssh-authorized-keys` und `os/sshd-hardening.conf` direkt, anstatt sie inline zu erzeugen.

### Schritt 2: HAProxy- + Keepalived-Installation

```bash
./scripts/02-install-haproxy.sh
```

**Zweck**: Installiert und konfiguriert den API-Load-Balancer auf allen Master-Knoten.

**Ablauf**:
1. HAProxy-Konfiguration generieren (Backends aus Inventar)
2. Knotenspezifische Keepalived-Konfiguration generieren (unterschiedliche Priorität pro Knoten)
3. Für jeden Master-Knoten:
   - haproxy- und keepalived-Pakete installieren
   - haproxy.cfg bereitstellen
   - keepalived.conf bereitstellen (knotenspezifisch)
   - Dienste aktivieren und starten
4. VIP ist dem Knoten mit der höchsten Priorität zugewiesen — verifizieren
5. HAProxy lauscht auf Port 6443 — verifizieren

Wenn vorerzeugte Konfigurationen verfügbar sind, liest das Skript `generated/haproxy/haproxy.cfg` und `generated/keepalived/{hostname}/keepalived.conf`, anstatt sie inline zu erzeugen.

### Schritt 3: Ersten K3s-Server bootstrappen

```bash
./scripts/03-install-k3s-first.sh
```

**Zweck**: Initialisiert den K3s-Cluster auf dem ersten Master-Knoten.

**Kritische Details**:
- Verwendet das Flag `--cluster-init` (erstellt einen Einzelknoten-etcd-Cluster)
- Erzeugt oder verwendet bereitgestelltes Cluster-Token
- Enthält alle TLS-SANs (VIP, alle Master-IPs, alle Hostnamen)
- Konfiguriert Dual-Stack-CIDRs
- Deaktiviert Standard-Traefik und ServiceLB
- Wartet, bis der Knoten den Status „Ready" erreicht
- Speichert Token in lokaler Datei für nachfolgende Skripte

Wenn vorerzeugte Konfigurationen verfügbar sind, stellt das Skript `generated/k3s/{hostname}/config.yaml` direkt bereit, anstatt die Konfiguration inline zu erstellen.

### Schritt 4: Weitere Server beitreten lassen

```bash
./scripts/04-install-k3s-servers.sh
```

**Zweck**: Lässt master-02 und master-03 dem Cluster beitreten.

**Hauptunterschied zu Schritt 3**: Verwendet `--server https://<erster-master-IP>:6443` anstelle von `--cluster-init`. Tritt über die direkte IP des ersten Masters bei (nicht die VIP), um Henne-Ei-Probleme während des Bootstraps zu vermeiden.

**Nach Abschluss**: Das 3-Knoten-etcd-Quorum ist hergestellt. Der Cluster ist nun hochverfügbar.

Verwendet vorerzeugte `generated/k3s/{hostname}/config.yaml`, wenn verfügbar, mit Inline-Fallback.

### Schritt 5: Worker-Knoten beitreten lassen

```bash
./scripts/05-install-k3s-agents.sh
```

**Zweck**: Nimmt alle Worker-Knoten in den Cluster auf.

**Wichtige Details**:
- Worker verbinden sich über die **VIP** (nicht einzelne Master) — HA ist bereits aktiv
- Verwendet `INSTALL_K3S_EXEC="agent"` (nicht "server")
- Wendet Worker-Labels automatisch an
- Wartet, bis jeder Knoten den Status „Ready" erreicht

Verwendet vorerzeugte `generated/k3s/{hostname}/config.yaml`, wenn verfügbar, mit Inline-Fallback.

### Schritt 6: Persistenten Speicher installieren

```bash
STORAGE_PROVIDER=longhorn ./scripts/06-install-storage.sh
```

**Zweck**: Stellt die gewählte persistente Speicherlösung bereit.

**Für Longhorn**:
1. Voraussetzungen verifizieren (open-iscsi, iscsid, Datenpfad)
2. Helm auf dem ersten Master installieren
3. Longhorn-Helm-Repository hinzufügen
4. Mit generierter Values-Datei bereitstellen
5. Warten, bis alle Pods bereit sind (Timeout: 300s)
6. StorageClass-Erstellung verifizieren

**Für local-path**:
1. Datenverzeichnis auf allen Knoten erstellen
2. StorageClass-Konfiguration anwenden
3. Als Standard-StorageClass festlegen

---

## 6. Konfigurationserzeugungssystem

### 6.1 Designphilosophie

Das Konfigurationserzeugungssystem folgt dem Prinzip **„Einzige Wahrheitsquelle, mehrere Ausgaben"**:

```
                    ┌─────────────────┐
                    │  variables.yaml  │  ◄── Benutzer bearbeitet DIESE EINE Datei
                    │  (240+ Zeilen)   │
                    └────────┬─────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              ▼              ▼
     ┌────────────┐  ┌────────────┐  ┌────────────┐
     │  Python    │  │  Web-UI    │  │  Skripte   │
     │ generate.py│  │ (Browser)  │  │  (Bash)    │
     └─────┬──────┘  └─────┬──────┘  └─────┬──────┘
           │                │               │
           ▼                ▼               │
     ┌────────────┐  ┌────────────┐         │
     │ generated/ │  │  ZIP-Datei │         │
     │ (19 Dateien)│  │ (Download) │         │
     └────────────┘  └────────────┘         │
                                            ▼
                                     ┌────────────┐
                                     │ Remote-SSH │
                                     │ Ausführung │
                                     └────────────┘
```

### 6.5 Einheitliche Konfigurationsverwendung

Die Bereitstellungsskripte verwenden nun vorerzeugte Konfigurationsdateien aus dem Verzeichnis `generated/` und schaffen so eine einheitliche Pipeline:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Konfigurationsquellen                              │
│                                                                       │
│   Pfad A: variables.yaml ──► generate.py ──► generated/              │
│                                                    │                  │
│   Pfad B: Web-UI ──► ZIP-Download ──► unzip ──► generated/           │
│                                                    │                  │
│   Pfad C: inventory.conf ──► inline (Fallback) ────┤                 │
│                                                    │                  │
└────────────────────────────────────────────────────┼──────────────────┘
                                                     │
                                                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Bereitstellungsskripte                           │
│                                                                       │
│   Skripte prüfen zuerst generated/, Fallback auf inventory.conf      │
│                                                                       │
│   00-validate ──► 01-configure-os ──► 02-haproxy ──► 03-k3s-first   │
│   ──► 04-k3s-servers ──► 05-k3s-agents ──► 06-storage               │
└─────────────────────────────────────────────────────────────────────┘
```

Überschreiben des Konfigurationsverzeichnisses mit: `CONFIG_DIR=/path/to/configs ./scripts/01-configure-os.sh`

### 6.2 Template-Engine

**Serverseitig (Python)**: Verwendet Jinja2 3.1+ mit `StrictUndefined` — jede fehlende Variable verursacht einen sofortigen Fehler anstatt einer stillen leeren Ausgabe.

**Clientseitig (Browser)**: Verwendet Nunjucks 3.2.4, eine JavaScript-Portierung von Jinja2, die identische Template-Syntax in der Web-UI ermöglicht.

### 6.3 Template-Katalog

| Template | Ausgabe | Typ |
|----------|---------|-----|
| haproxy.cfg.j2 | haproxy/haproxy.cfg | Einzeln |
| keepalived.conf.j2 | keepalived/{hostname}/keepalived.conf | Pro Master |
| k3s-server.yaml.j2 | k3s/{hostname}/config.yaml | Pro Master |
| k3s-agent.yaml.j2 | k3s/{hostname}/config.yaml | Pro Worker |
| dhcpd4-leases.conf.j2 | network/dhcpd4-leases.conf | Einzeln |
| dhcpd6-leases.conf.j2 | network/dhcpd6-leases.conf | Einzeln |
| dnsmasq-leases.conf.j2 | network/dnsmasq-leases.conf | Einzeln |
| hosts.j2 | network/hosts | Einzeln |
| sysctl-k3s.conf.j2 | os/sysctl-k3s.conf | Einzeln |
| ssh-config.j2 | os/ssh-config.txt | Einzeln |
| disk-single-root.xml.j2 | os/disk-partitioning.xml | Bedingt |
| disk-multipart.xml.j2 | os/disk-partitioning.xml | Bedingt |
| disk-multidisk.xml.j2 | os/disk-partitioning.xml | Bedingt |
| disk-ignition.json.j2 | os/disk-ignition.json | Einzeln |
| longhorn-values.yaml.j2 | storage/longhorn-values.yaml | Bedingt |
| storageclass-local-path.yaml.j2 | storage/storageclass-local-path.yaml | Bedingt |

### 6.4 Bedingtes Rendering

Der Generator unterstützt zwei Arten von bedingter Logik:

1. **Dynamische Template-Auswahl**: Das Festplattenpartitionierungstemplate wird basierend auf dem Wert von `storage.disk_layout` ausgewählt
2. **Anbieterbedingung**: Speicher-Templates werden nur gerendert, wenn der passende Anbieter ausgewählt ist

```python
# Dynamische Template-Auswahl
if target.get("dynamic_template"):
    disk_layout = variables["storage"]["disk_layout"]
    template_name = layout_map[disk_layout]

# Bedingtes Rendering
condition = target.get("condition")
if condition and variables["storage"]["provider"] != condition:
    continue  # Dieses Template überspringen
```

---

## 7. Festplattenpartitionierungsstrategie

### 7.1 Layout-Optionen

#### Option A: Einzelne Root-Partition

```
┌─────────────────────────────────────────┐
│             /dev/sda                     │
├──────────┬──────────────────────────────┤
│ /boot/efi│            /                 │
│  512 MB  │     (Btrfs, verbleibend)     │
│  (vfat)  │                              │
│          │  Subvolumes:                  │
│          │  @/var                        │
│          │  @/var/lib/rancher            │
│          │  @/var/lib/longhorn           │
│          │  @/home                       │
│          │  @/.snapshots                 │
└──────────┴──────────────────────────────┘
```

#### Option B: Mehrfachpartition (empfohlen)

```
┌─────────────────────────────────────────┐
│             /dev/sda                     │
├──────────┬──────────┬──────────┬────────┤
│ /boot/efi│    /     │/var/lib/ │Speicher│
│  512 MB  │  40 GB   │rancher   │  max   │
│  (vfat)  │ (Btrfs)  │ 100 GB   │ (XFS)  │
│          │          │  (XFS)   │        │
└──────────┴──────────┴──────────┴────────┘
```

#### Option C: Mehrere Festplatten

```
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│    /dev/sda      │  │    /dev/sdb      │  │    /dev/sdc      │
├──────────┬───────┤  ├──────────────────┤  ├──────────────────┤
│ /boot/efi│   /   │  │  /var/lib/rancher│  │  /var/lib/       │
│  512 MB  │  max  │  │    (gesamte Disk)│  │  longhorn        │
│  (vfat)  │(Btrfs)│  │      (XFS)       │  │  (gesamte Disk)  │
│          │       │  │                  │  │    (XFS)         │
└──────────┴───────┘  └──────────────────┘  └──────────────────┘
    OS-Disk                Daten-Disk           Speicher-Disk
```

### 7.2 Begründung der Dateisystemwahl

| Einhängepunkt | Dateisystem | Begründung |
|---------------|------------|------------|
| / | Btrfs | Unterstützt transactional-update-Snapshots, Copy-on-Write, Kompression |
| /var/lib/rancher | XFS | Hohe Leistung für Container-Layer-Schreibvorgänge, kein CoW-Overhead |
| /var/lib/longhorn | XFS | Blockspeicher-Backend benötigt konsistente sequenzielle Schreibleistung |
| /boot/efi | vfat | Erforderlich durch UEFI-Spezifikation |

---

## 8. Sicherheitsmodell

### 8.1 SSH-Schlüsselverwaltung

Die Plattform bietet drei Methoden zur SSH-Schlüsselbereitstellung:

```
┌─────────────────────────────────────────────────────────┐
│                 SSH-Schlüsselquellen                      │
│                                                          │
│  1. Manuelle Schlüssel (variables.yaml)                 │
│     ssh.authorized_keys:                                 │
│       - "ssh-ed25519 AAAA... user@host"                 │
│                                                          │
│  2. GitHub-Schlüsselimport (zur Bereitstellungszeit)    │
│     ssh.github_users:                                    │
│       - "username"                                       │
│     → curl https://github.com/username.keys             │
│                                                          │
│  3. Lokale Schlüsseldatei als Fallback                  │
│     ssh.key_path: "~/.ssh/id_ed25519"                   │
│     → Liest ~/.ssh/id_ed25519.pub                       │
└─────────────────────────────────────────────────┬───────┘
                                              │
                                              ▼
                                    ┌──────────────────┐
                                    │Alle Schlüssel     │
                                    │zusammengeführt    │
                                    │Bereitgestellt in: │
                                    │  /root/.ssh/      │
                                    │  authorized_keys  │
                                    │  (alle Knoten)    │
                                    └──────────────────┘
```

### 8.2 SSH-Härtung

Wenn `ssh.disable_password_auth: true` gesetzt ist:

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

### 8.3 Netzwerksicherheit (Firewall-Regeln)

| Port | Protokoll | Richtung | Zweck | Knoten |
|------|-----------|----------|-------|--------|
| 6443 | TCP | Eingehend | K3s API Server | Master |
| 2379 | TCP | Nur Master | etcd Client | Master |
| 2380 | TCP | Nur Master | etcd Peer | Master |
| 10250 | TCP | Eingehend | Kubelet-Metriken | Alle |
| 8472 | UDP | Eingehend | VXLAN (Flannel) | Alle |
| 51820 | UDP | Eingehend | WireGuard IPv4 | Alle |
| 51821 | UDP | Eingehend | WireGuard IPv6 | Alle |
| 8404 | TCP | Eingehend | HAProxy-Statistiken | Master |
| 30000-32767 | TCP/UDP | Eingehend | NodePort-Bereich | Worker |
| VRRP (112) | IP | Nur Master | Keepalived | Master |

---

## 9. Architektur für persistenten Speicher

### 9.1 Longhorn-Datenfluss

```
┌─────────────────────────────────────────────────────────────┐
│  Pod schreibt Daten                                          │
│  └──► /dev/longhorn/volume-xyz (Blockgerät)                 │
│        └──► Longhorn Engine (iSCSI-Target, selber Knoten)   │
│              └──► Synchrone Replikation                      │
│                    ├──► Replica 1 (worker-01:/var/lib/longhorn/replicas/vol-xyz/)
│                    ├──► Replica 2 (worker-02:/var/lib/longhorn/replicas/vol-xyz/)
│                    └──► Replica 3 (worker-03:/var/lib/longhorn/replicas/vol-xyz/)
│                                                              │
│  Alle 3 Replicas bestätigen ──► Schreibvorgang an Pod bestätigt │
└─────────────────────────────────────────────────────────────┘
```

### 9.2 StorageClass-Konfiguration

**Longhorn-StorageClass** (durch Helm bereitgestellt):
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

**Local-Path-StorageClass** (in K3s integriert):
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

## 10. Kontinuierliche Integration und Qualitätssicherung

### 10.1 CI-Pipeline

```
┌─────────────────────────────────────────────────────────────┐
│                GitHub Actions Workflow: lint.yaml             │
│                                                              │
│  Auslöser: Push auf main, Pull-Request auf main             │
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
│  │  Erzeugte Ausgabe linten │  │                      │     │
│  │  yamllint erzeugtes YAML │  │                      │     │
│  └──────────────────────────┘  └──────────────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

### 10.2 Lint-Werkzeuge

| Werkzeug | Ziel | Regeln |
|----------|------|--------|
| **ruff** | Python (.py) | PEP8, isort, bugbear, comprehensions, pathlib, type-checking |
| **yamllint** | YAML (.yaml) | Zeilenlänge 120, 2-Leerzeichen-Einrückung, truthy-Werte |
| **shellcheck** | Shell (.sh) | SC1091 deaktiviert (dynamisches Source), alle anderen Regeln |
| **lint_configs.py** | .cfg, .conf | HAProxy-Sektionen, Keepalived-Syntax, DHCP-Klammern/-Semikolons |

---

## 11. Webbasierter Konfigurationsgenerator

### 11.1 Architektur

Die Web-UI ist eine **statische Single-Page-Anwendung**, die auf GitHub Pages bereitgestellt wird. Sie läuft vollständig im Browser — keine serverseitige Verarbeitung, keine Datenübertragung.

```
┌─────────────────────────────────────────────────────────────┐
│                  Browser (nur clientseitig)                    │
│                                                              │
│  ┌──────────┐    ┌──────────────┐    ┌──────────────────┐   │
│  │HTML-      │──►│  Nunjucks    │──►│  Erzeugte Dateien │   │
│  │Formular   │    │  Template-   │    │  (Vorschau +      │   │
│  │(Benutzer- │    │  Engine      │    │   Download)       │   │
│  │ eingabe)  │    │              │    │                   │   │
│  └──────────┘    └──────────────┘    └────────┬──────────┘   │
│                                               │              │
│                                     ┌─────────▼──────────┐   │
│                                     │      JSZip         │   │
│                                     │  Archiv-Generator  │   │
│                                     └─────────┬──────────┘   │
│                                               │              │
│                                     ┌─────────▼──────────┐   │
│                                     │    FileSaver.js    │   │
│                                     │  Download-Auslöser │   │
│                                     └────────────────────┘   │
│                                               │              │
│                                               ▼              │
│                                     k3s-config-v1.0.0-       │
│                                     20260804-143052.zip      │
└─────────────────────────────────────────────────────────────┘
```

### 11.2 Technologie-Stack

| Bibliothek | Version | Zweck |
|------------|---------|-------|
| Nunjucks | 3.2.4 | Jinja2-kompatible Template-Engine (CDN) |
| JSZip | 3.10.1 | ZIP-Archiv-Erzeugung im Browser (CDN) |
| FileSaver.js | 2.0.5 | Löst Datei-Download aus Blob aus (CDN) |
| Pure CSS | - | Benutzerdefiniertes dunkles Theme, responsives Layout |

### 11.3 ZIP-Archiv-Benennung

```
k3s-config-v1.0.0-20260804-143052.zip
│           │     │        │
│           │     │        └── Uhrzeit: HHMMSS
│           │     └── Datum: JJJJMMTT
│           └── Anwendungsversion
└── Fester Präfix
```

### 11.4 Verwendung des ZIP mit CLI-Skripten

Das Web-UI-ZIP-Archiv kann direkt mit den CLI-Bereitstellungsskripten verwendet werden:

```bash
# 1. ZIP herunterladen von https://opentreecz.github.io/k3s/
# 2. In das Verzeichnis generated/ entpacken
unzip k3s-config-v1.0.0-*.zip -d generated/

# 3. inventory.conf mit SSH-Verbindungseinstellungen konfigurieren
cp templates/inventory.example.conf inventory.conf
# Bearbeiten: SSH_USER, SSH_KEY_PATH, SSH_PORT, MASTER_NODES (IPs), WORKER_NODES (IPs)

# 4. Bereitstellungsskripte ausführen (sie erkennen und verwenden vorerzeugte Konfigurationen)
./scripts/00-validate-environment.sh
./scripts/01-configure-os.sh
./scripts/02-install-haproxy.sh
./scripts/03-install-k3s-first.sh
./scripts/04-install-k3s-servers.sh
./scripts/05-install-k3s-agents.sh
```

Die Skripte erkennen automatisch die vorerzeugten Konfigurationen in `generated/` und verwenden diese anstatt Konfigurationen inline zu erzeugen. Die Datei `inventory.conf` wird weiterhin für SSH-Verbindungsparameter (Benutzer, Schlüsselpfad, Port) und Knoten-IP-Adressen für die SSH-Konnektivität benötigt.

---

## 12. Zusammenfassung

Diese K3s-Baremetal-Hochverfügbarkeits-Bereitstellungsplattform bietet eine vollständige, produktionsreife Lösung für die Bereitstellung von Kubernetes auf physischen Servern. Die wesentlichen Eigenschaften sind:

**Architektur**:
- 3-Knoten-Control-Plane mit eingebettetem etcd für HA-Konsens
- HAProxy + Keepalived für API-Server-Load-Balancing und VIP-Failover
- Toleriert Einzelknotenausfall ohne Dienstunterbrechung
- Dual-Stack-Netzwerk (IPv4 + IPv6) durchgängig

**Automatisierung**:
- 7 sequenzielle Skripte, die den gesamten Bereitstellungslebenszyklus abdecken
- Konfigurationserzeugung aus einer einzelnen Variablendatei (19+ Ausgabedateien)
- Webbasierter Generator für reinen Browserbetrieb (kein Server erforderlich)
- Einheitliche Konfigurationsverwendung: Skripte nutzen vorerzeugte Konfigurationen aus `generated/` (über `generate.py` oder Web-UI-ZIP), mit automatischem Fallback auf Inline-Erzeugung
- GitHub Actions CI für kontinuierliche Qualitätssicherung

**Speicher**:
- Longhorn verteilter replizierter Speicher (produktionsreif, Snapshots, Backups)
- Local-Path-Provisioner als Alternative (Entwicklung/einfache Workloads)
- 3 Festplattenlayout-Optionen für verschiedene Hardwarekonfigurationen

**Sicherheit**:
- SSH-Schlüsselbereitstellung mit GitHub-Schlüsselimport
- SSHD-Härtung (Passwortauthentifizierung deaktiviert, nur Schlüsselzugang)
- Firewall-Konfiguration mit minimal geöffneten Ports
- TLS-Zertifikate für alle Zugriffspfade (VIP + einzelne Knoten)
- Unveränderliche OS-Basis (transactional-update, schreibgeschütztes Root)

**Flexibilität**:
- Wahl zwischen SLE Micro (kommerziell) oder openSUSE MicroOS (Community)
- Wahl zwischen Longhorn, local-path oder keinem Speicher
- Wahl zwischen Einzelpartition, Mehrfachpartition oder Mehrfachfestplatten-Layout
- DHCPv4-/DHCPv6-Unterstützung mit ISC DHCP-, dnsmasq- und Kea-Konfigurationen
- Konfigurierbar über YAML, Web-UI oder Umgebungsvariablen

**Qualität**:
- Gesamter Code gelintet (Python, YAML, Shell, Konfigurationsdateien)
- Template-Validierung bei jedem Commit
- Erzeugte Ausgabe durch CI-Pipeline verifiziert
- Umfassende Dokumentation (7 Anleitungen + diese Referenz)

---

*Dieses Dokument beschreibt Version 1.0.0 der K3s-Baremetal-HA-Bereitstellungsplattform. Für die neuesten Aktualisierungen siehe das [Repository](https://github.com/opentreecz/k3s).*
