# Plataforma de Despliegue K3s de Alta Disponibilidad en Servidores Físicos

## Documento de Referencia Técnica

**Versión:** 1.0.0  
**Última actualización:** August 2026  
**Repositorio:** [github.com/opentreecz/k3s](https://github.com/opentreecz/k3s)  
**Generador web:** [opentreecz.github.io/k3s](https://opentreecz.github.io/k3s/)

---

## Tabla de Contenidos

1. [Resumen Ejecutivo](#1-resumen-ejecutivo)
2. [Visión General del Proyecto](#2-visión-general-del-proyecto)
3. [Arquitectura](#3-arquitectura)
4. [Análisis Detallado de Componentes](#4-análisis-detallado-de-componentes)
   - [4.1 Capa del Sistema Operativo](#41-capa-del-sistema-operativo)
   - [4.2 Distribución Kubernetes K3s](#42-distribución-kubernetes-k3s)
   - [4.3 Balanceador de Carga HAProxy](#43-balanceador-de-carga-haproxy)
   - [4.4 Keepalived e IP Virtual](#44-keepalived-e-ip-virtual)
   - [4.5 Almacenamiento Distribuido Longhorn](#45-almacenamiento-distribuido-longhorn)
   - [4.6 Arquitectura de Red (DHCPv4/DHCPv6)](#46-arquitectura-de-red-dhcpv4dhcpv6)
5. [Flujo de Trabajo de Despliegue](#5-flujo-de-trabajo-de-despliegue)
6. [Sistema de Generación de Configuración](#6-sistema-de-generación-de-configuración)
7. [Estrategia de Particionamiento de Disco](#7-estrategia-de-particionamiento-de-disco)
8. [Modelo de Seguridad](#8-modelo-de-seguridad)
9. [Arquitectura de Almacenamiento Persistente](#9-arquitectura-de-almacenamiento-persistente)
10. [Integración Continua y Aseguramiento de Calidad](#10-integración-continua-y-aseguramiento-de-calidad)
11. [Generador de Configuración Basado en Web](#11-generador-de-configuración-basado-en-web)
12. [Resumen](#12-resumen)

---

## 1. Resumen Ejecutivo

Este proyecto proporciona una plataforma de despliegue completa y automatizada para establecer un **clúster Kubernetes K3s de alta disponibilidad** en servidores físicos (baremetal). La plataforma está dirigida a entornos que ejecutan **SUSE Linux Enterprise Micro (SLE Micro)** u **openSUSE MicroOS** — sistemas operativos inmutables y optimizados para contenedores, diseñados específicamente para cargas de trabajo en el borde (edge) y Kubernetes.

La plataforma de despliegue abarca todo el ciclo de vida del aprovisionamiento del clúster:

- Instalación y configuración del sistema operativo
- Planificación de red con gestión de asignaciones estáticas DHCPv4/DHCPv6
- Alta disponibilidad del servidor API mediante HAProxy y Keepalived
- Arranque automatizado del clúster K3s con etcd integrado
- Incorporación de nodos de trabajo (workers)
- Aprovisionamiento de almacenamiento persistente (Longhorn o local-path)
- Gestión de claves SSH con importación de claves de GitHub

Toda la configuración se controla mediante un **único archivo de variables** y se renderiza a través de **plantillas Jinja2**, garantizando consistencia, repetibilidad y auditabilidad en todos los entornos.

---

## 2. Visión General del Proyecto

### 2.1 Planteamiento del Problema

Desplegar un clúster Kubernetes de grado producción en servidores físicos presenta varios desafíos que los entornos gestionados en la nube abstraen:

- Sin aprovisionamiento automatizado de infraestructura (sin Terraform/APIs de nube)
- Sin balanceador de carga integrado para el servidor API
- Sin backend de almacenamiento gestionado
- El direccionamiento de red debe planificarse y coordinarse con la infraestructura DHCP existente
- La instalación y el endurecimiento del sistema operativo son manuales
- La gestión de certificados requiere una planificación cuidadosa de IPs/nombres de host

### 2.2 Arquitectura de la Solución

Esta plataforma resuelve estos desafíos mediante un enfoque por capas:

```
┌─────────────────────────────────────────────────────────────────────┐
│                  Capa de Generación de Configuración                  │
│                                                                       │
│   variables.yaml ──► Plantillas Jinja2 ──► Configs Generadas         │
│   (fuente única)     (18 plantillas)       (19+ archivos de salida)  │
│                                                                       │
│   Web UI (GitHub Pages) ──► Nunjucks en navegador ──► Archivo ZIP    │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                   Capa de Automatización del Despliegue               │
│                                                                       │
│   00-validate-environment.sh    Verificaciones previas                │
│   01-configure-os.sh            Endurecimiento del SO, claves SSH    │
│   02-install-haproxy.sh         HAProxy + Keepalived en masters      │
│   03-install-k3s-first.sh       Arranque del primer servidor         │
│   04-install-k3s-servers.sh     Unión de nodos servidor adicionales  │
│   05-install-k3s-agents.sh      Unión de nodos de trabajo            │
│   06-install-storage.sh         Despliegue de Longhorn o local-path  │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        Capa de Infraestructura                        │
│                                                                       │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐                          │
│   │master-01 │  │master-02 │  │master-03 │  Plano de Control        │
│   │HAProxy   │  │HAProxy   │  │HAProxy   │  (3 nodos)               │
│   │Keepalived│  │Keepalived│  │Keepalived│                          │
│   │K3s Server│  │K3s Server│  │K3s Server│                          │
│   │etcd      │  │etcd      │  │etcd      │                          │
│   └──────────┘  └──────────┘  └──────────┘                          │
│         │              │              │                               │
│         └──────────────┼──────────────┘                              │
│                        │ VIP: 192.168.1.100                          │
│                        │                                             │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐                          │
│   │worker-01 │  │worker-02 │  │worker-03 │  Plano de Datos          │
│   │K3s Agent │  │K3s Agent │  │K3s Agent │  (N nodos)               │
│   │Longhorn  │  │Longhorn  │  │Longhorn  │                          │
│   └──────────┘  └──────────┘  └──────────┘                          │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.3 Estructura del Repositorio

```
k3s/
├── variables.yaml                  # Fuente única de verdad
├── generate.py                     # Renderizador de plantillas Python
├── lint_configs.py                 # Linter de configuración personalizado
├── requirements.txt                # Dependencias de Python
├── pyproject.toml                  # Configuración del linter Ruff
├── .yamllint.yaml                  # Reglas de lint para YAML
├── .shellcheckrc                   # Configuración de lint para shell
├── .github/workflows/
│   ├── lint.yaml                   # CI: lint de todos los tipos de archivo
│   └── pages.yaml                  # CI: despliegue de la UI web en GitHub Pages
├── docs/                           # Documentación paso a paso
├── templates/jinja2/               # 18 plantillas de configuración Jinja2
├── configs/                        # Configuraciones de referencia estáticas
├── scripts/                        # 7 scripts de automatización de despliegue
├── web/                            # Generador de configuración en navegador
└── generated/                      # Directorio de salida (en gitignore)
```

---

## 3. Arquitectura

### 3.1 Topología de Alta Disponibilidad

El clúster emplea un **plano de control de 3 nodos** con **etcd integrado** para consenso, respaldado por **HAProxy** para el balanceo de carga del API y **Keepalived** para la conmutación por error de la IP Virtual (VIP).

```
                    ┌─────────────────────────────────┐
                    │           Clientes               │
                    │   (kubectl, CI/CD, aplicaciones) │
                    └──────────────┬───────────────────┘
                                   │
                                   ▼
                    ┌─────────────────────────────────┐
                    │       IP Virtual (VIP)           │
                    │    192.168.1.100:6443            │
                    │    fd00::100:6443                │
                    │  (gestionada por Keepalived)     │
                    └──────────────┬───────────────────┘
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
    │  (integrado)    │  │  (integrado)    │  │  (integrado)    │
    └─────────────────┘  └─────────────────┘  └─────────────────┘
              │                    │                    │
              │     Replicación entre pares etcd       │
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

### 3.2 Dominios de Fallo

La arquitectura tolera los siguientes fallos sin interrupción del servicio:

| Escenario de Fallo | Impacto | Recuperación |
|---------------------|---------|-------------|
| 1 nodo master caído | Sin impacto (quórum etcd 2/3 mantenido) | Conmutación automática de VIP |
| 1 nodo worker caído | Los pods se reprograman en los workers restantes | Automática por Kubernetes |
| HAProxy en 1 master | La VIP se mueve al nodo HAProxy saludable | Conmutación por Keepalived (<3s) |
| Partición de red (1 master aislado) | Quórum mantenido por la mayoría | Reconciliación automática |
| 2 nodos master caídos | **Clúster no disponible** (quórum perdido) | Intervención manual requerida |

### 3.3 Flujo de Red

```
kubectl ──► VIP:6443 ──► HAProxy ──► K3s API Server (cualquiera de los 3 masters)
                              │
                              ├──► master-01:6443 (verificación: estado TCP)
                              ├──► master-02:6443 (verificación: estado TCP)
                              └──► master-03:6443 (verificación: estado TCP)

Worker Agent ──► VIP:6443 ──► HAProxy ──► K3s API Server
                                              │
                                              ▼
                                     Registrar nodo
                                     Recibir especificaciones de pod
                                     Reportar estado
```

---

## 4. Análisis Detallado de Componentes

### 4.1 Capa del Sistema Operativo

#### SUSE Linux Enterprise Micro (SLE Micro)

**SLE Micro** es el sistema operativo inmutable de SUSE con soporte comercial, diseñado específicamente para cargas de trabajo en contenedores y virtualizadas. Características principales:

- **Sistema de archivos raíz inmutable**: La partición raíz es de solo lectura. Los cambios se aplican mediante `transactional-update`, que crea una nueva instantánea Btrfs. El sistema arranca en la nueva instantánea en el siguiente reinicio, proporcionando actualizaciones atómicas con capacidad de reversión instantánea.
- **Superficie de ataque mínima**: Se distribuye solo con los paquetes esenciales. Sin entorno de escritorio, sin demonios innecesarios.
- **SELinux/AppArmor**: Control de acceso obligatorio habilitado por defecto.
- **Ciclo de vida comercial**: Más de 4 años de mantenimiento y actualizaciones de seguridad por cada versión mayor.
- **Certificaciones**: Variantes certificadas FIPS 140-2 y Common Criteria disponibles.

#### openSUSE MicroOS

**openSUSE MicroOS** es la versión upstream impulsada por la comunidad de SLE Micro, compartiendo la misma arquitectura:

- **Lanzamiento continuo (rolling release)**: Actualizaciones continuas (basado en Tumbleweed).
- **Mecanismo transactional-update idéntico**: Mismo sistema de actualización atómica.
- **Sin registro requerido**: Disponible gratuitamente, con soporte de la comunidad.
- **Ideal para**: Clústeres de desarrollo, pruebas de concepto, entornos de producción comunitarios.

#### Mecanismo de Actualización Transaccional

```
┌─────────────────────────────────────────────────────────────┐
│               Sistema de Archivos Raíz Btrfs                  │
│                                                              │
│  Instantánea #1 (actual, solo lectura)                      │
│  └── / (sistema en ejecución)                               │
│                                                              │
│  Instantánea #2 (creada por transactional-update)           │
│  └── / (sistema modificado: nuevos paquetes, cambios)       │
│                                                              │
│  transactional-update reboot ──► Arrancar en Instantánea #2 │
│                                                              │
│  Si la Instantánea #2 falla:                                 │
│  └── Reversión a Instantánea #1 (instantánea, sin pérdida)  │
└─────────────────────────────────────────────────────────────┘
```

La herramienta `transactional-update` es el mecanismo exclusivo para modificar el sistema operativo:

```bash
# Instalar paquetes (se aplica tras reinicio)
transactional-update pkg install open-iscsi nfs-client

# Aplicar todas las actualizaciones pendientes
transactional-update up

# Reiniciar en la nueva instantánea
transactional-update reboot
```

### 4.2 Distribución Kubernetes K3s

#### ¿Qué es K3s?

**K3s** es una distribución de Kubernetes certificada y de grado producción, desarrollada por SUSE/Rancher. Empaqueta todo el plano de control de Kubernetes en un único binario (~60MB), haciéndolo adecuado para entornos con recursos limitados, computación en el borde y despliegues en servidores físicos donde la sobrecarga operativa de los clústeres basados en kubeadm no es deseable.

#### K3s vs Kubernetes Upstream

| Característica | K3s | Upstream (kubeadm) |
|----------------|-----|-------------------|
| Tamaño del binario | ~60 MB | ~300+ MB (múltiples binarios) |
| Huella de memoria | ~512 MB (servidor) | ~1-2 GB (servidor) |
| Instalación | Un solo comando curl | Múltiples pasos, gestión de certificados |
| etcd | Integrado (o externo) | Se debe aprovisionar por separado |
| Runtime de contenedores | containerd (integrado) | Se debe instalar por separado |
| Red | Flannel (integrado) | Se debe instalar plugin CNI |
| Gestión de certificados | Rotación automática | Configuración manual |
| Actualización | Reemplazar binario + reiniciar | Procedimiento de actualización progresiva |

#### Arquitectura del Servidor K3s (Plano de Control)

Cada nodo servidor K3s ejecuta:

```
┌──────────────────────────────────────────────────────┐
│              Proceso del Servidor K3s                  │
│                                                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │ API Server  │  │ Controller  │  │  Scheduler  │  │
│  │             │  │  Manager    │  │             │  │
│  └──────┬──────┘  └─────────────┘  └─────────────┘  │
│         │                                            │
│  ┌──────▼──────┐  ┌─────────────┐                   │
│  │   etcd      │  │ containerd  │                   │
│  │ (integrado) │  │             │                   │
│  └─────────────┘  └─────────────┘                   │
│                                                       │
│  ┌─────────────┐  ┌─────────────┐                   │
│  │  Flannel    │  │ CoreDNS     │                   │
│  │  (CNI)      │  │             │                   │
│  └─────────────┘  └─────────────┘                   │
└──────────────────────────────────────────────────────┘
```

#### Arquitectura del Agente K3s (Worker)

Cada nodo agente K3s ejecuta:

```
┌──────────────────────────────────────────────────────┐
│               Proceso del Agente K3s                   │
│                                                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │  kubelet    │  │ kube-proxy  │  │ containerd  │  │
│  │             │  │             │  │             │  │
│  └─────────────┘  └─────────────┘  └─────────────┘  │
│                                                       │
│  ┌─────────────┐  ┌─────────────────────────────┐   │
│  │  Flannel    │  │  Pods de Carga de Trabajo   │   │
│  │  (CNI)      │  │  (aplicaciones de usuario)  │   │
│  └─────────────┘  └─────────────────────────────┘   │
└──────────────────────────────────────────────────────┘
```

#### Clúster etcd Integrado

K3s utiliza un clúster etcd integrado para almacenar todo el estado del clúster. Con 3 nodos servidor, el clúster etcd opera con el algoritmo de consenso Raft:

- **Quórum**: 2 de 3 nodos deben estar de acuerdo en las escrituras (mayoría)
- **Elección de líder**: Un nodo es el líder; los demás son seguidores
- **Replicación de datos**: Todos los datos se replican en los 3 nodos
- **Tolerancia a fallos**: Sobrevive al fallo de 1 nodo sin pérdida de datos

```
         ┌─────────────┐
         │   etcd      │
         │  (líder)    │
         │  master-01  │
         └──────┬──────┘
                │
       ┌────────┴────────┐
       │  Consenso Raft  │
       │  replicación    │
       ▼                 ▼
┌─────────────┐   ┌─────────────┐
│   etcd      │   │   etcd      │
│ (seguidor)  │   │ (seguidor)  │
│  master-02  │   │  master-03  │
└─────────────┘   └─────────────┘
```

#### Secuencia de Arranque del Clúster K3s

La inicialización del clúster sigue un orden preciso:

1. **Primer servidor** arranca con `--cluster-init`, creando un clúster etcd de un solo nodo
2. **Segundo servidor** se une vía `--server https://<primero>:6443`, convirtiéndose en seguidor de etcd
3. **Tercer servidor** se une de manera similar, completando el quórum de 3 nodos etcd
4. **Agentes** se unen vía la VIP (`https://<VIP>:6443`) para alta disponibilidad

```
Tiempo ────────────────────────────────────────────────────────────►

master-01: [cluster-init] ──► [etcd líder, 1/1] ──► [etcd líder, 1/3]
                                                              │
master-02:                    [unión] ──► [etcd seguidor, 2/3] ─┤
                                                              │
master-03:                              [unión] ──► [seguidor, 3/3]
                                                              │
                                              Quórum alcanzado ─┘
                                                              │
worker-01:                                         [unión vía VIP]
worker-02:                                         [unión vía VIP]
worker-03:                                         [unión vía VIP]
```

#### Arquitectura de Certificados TLS

K3s genera y gestiona automáticamente los certificados TLS. Los flags `--tls-san` aseguran que los certificados sean válidos para todas las rutas de acceso:

```
Nombres Alternativos del Sujeto del Certificado:
├── 192.168.1.100        (VIP IPv4)
├── fd00::100            (VIP IPv6)
├── k3s-api.k3s.local    (nombre de host de la VIP)
├── master-01.k3s.local  (FQDN del nodo)
├── master-01            (nombre corto)
├── 192.168.1.101        (IP del nodo)
├── master-02.k3s.local
├── master-02
├── 192.168.1.102
├── master-03.k3s.local
├── master-03
└── 192.168.1.103
```

Esto asegura que `kubectl` pueda conectarse vía:
- La VIP (operación normal)
- Cualquier IP individual de master (depuración/emergencia)
- Cualquier variante de nombre de host

### 4.3 Balanceador de Carga HAProxy

#### Propósito

HAProxy sirve como el **balanceador de carga de Capa 4 (TCP)** para el servidor API de K3s. Distribuye las conexiones entrantes en el puerto 6443 entre los tres nodos master, proporcionando:

- **Distribución de carga**: Balanceo round-robin entre backends saludables
- **Verificación de estado**: Sondas de salud a nivel TCP cada 10 segundos
- **Conmutación automática por error**: Elimina backends no saludables del pool en 2 verificaciones fallidas
- **Persistencia de conexión**: Mantiene las conexiones existentes durante las transiciones de backend

#### Arquitectura de Configuración de HAProxy

```
┌──────────────────────────────────────────────────────┐
│                  Proceso HAProxy                       │
│                                                       │
│  ┌─────────────────────────────────────────────────┐ │
│  │              Frontend: k3s_api_frontend          │ │
│  │              bind *:6443 (modo TCP)             │ │
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
│  │              bind *:8404 (modo HTTP)             │ │
│  │              panel de estadísticas /stats         │ │
│  └─────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

#### Parámetros de Verificación de Estado

| Parámetro | Valor | Descripción |
|-----------|-------|-------------|
| `inter` | 10s | Intervalo de verificación cuando el servidor está ACTIVO |
| `downinter` | 5s | Intervalo de verificación cuando el servidor está CAÍDO |
| `rise` | 2 | Verificaciones exitosas consecutivas para marcar ACTIVO |
| `fall` | 2 | Verificaciones fallidas consecutivas para marcar CAÍDO |
| `slowstart` | 60s | Rampa gradual de tráfico tras la recuperación |
| `maxconn` | 250 | Conexiones concurrentes máximas por backend |

#### ¿Por qué Modo TCP (Capa 4)?

HAProxy opera en modo TCP (no HTTP) porque:

1. El API de K3s utiliza **TLS mutuo** (mTLS) — HAProxy no puede terminar la conexión
2. El modo TCP tiene **menor sobrecarga** (sin análisis HTTP)
3. El protocolo del API es **HTTP/2** con streaming (watches) — el modo TCP maneja esto de forma nativa
4. Las verificaciones de estado usan **conexión TCP** (puerto 6443 responde = saludable)

### 4.4 Keepalived e IP Virtual

#### Propósito

Keepalived implementa el **Protocolo de Redundancia de Router Virtual (VRRP)** para gestionar una dirección IP Virtual (VIP) flotante entre los tres nodos master. Esta VIP es el punto de entrada único para todo el acceso al API.

#### Operación VRRP

```
Operación Normal:                     Tras Fallo de master-01:

  master-01 (MASTER, prioridad 101)     master-01 (CAÍDO)
  ├── VIP: 192.168.1.100 ✓             ├── VIP: (liberada)
  ├── Envía anuncios VRRP              │
  │                                     │
  master-02 (BACKUP, prioridad 100)     master-02 (MASTER, prioridad 100)
  ├── VIP: (en espera)                 ├── VIP: 192.168.1.100 ✓
  ├── Escucha anuncios                 ├── Envía anuncios VRRP
  │                                     │
  master-03 (BACKUP, prioridad 99)      master-03 (BACKUP, prioridad 99)
  ├── VIP: (en espera)                 ├── VIP: (en espera)
  ├── Escucha anuncios                 ├── Escucha anuncios
```

#### Secuencia de Conmutación por Error

1. Master-01 (MASTER) envía anuncios VRRP cada 1 segundo
2. Master-02 y master-03 (BACKUP) escuchan estos anuncios
3. Si los anuncios dejan de llegar durante 3 segundos (fall × intervalo):
   - El BACKUP con mayor prioridad (master-02, prioridad 100) transiciona a MASTER
   - Envía un ARP Gratuito anunciando la VIP en su dirección MAC
   - Todos los switches de red actualizan sus tablas MAC
   - El tráfico fluye a master-02 inmediatamente
4. Cuando master-01 se recupera:
   - Con preempción habilitada: master-01 reclama MASTER (mayor prioridad)
   - Sin preempción: master-02 retiene MASTER hasta que falle

#### Script de Seguimiento de Estado

Keepalived utiliza un script de verificación de estado para vincular la propiedad de la VIP con el estado de HAProxy:

```bash
vrrp_script check_haproxy {
    script "/usr/bin/killall -0 haproxy"   # Señal 0 = verificar si el proceso existe
    interval 2                              # Verificar cada 2 segundos
    weight 2                                # Sumar 2 a la prioridad si está saludable
    fall 3                                  # 3 fallos para considerar CAÍDO
    rise 2                                  # 2 éxitos para considerar ACTIVO
}
```

Esto asegura que la VIP solo resida en un nodo donde HAProxy esté realmente en ejecución y aceptando conexiones.

#### VIP de Doble Pila (IPv4 + IPv6)

La configuración de la VIP incluye tanto direcciones IPv4 como IPv6:

```
virtual_ipaddress {
    192.168.1.100/24 dev eth0    # VIP IPv4
    fd00::100/64 dev eth0        # VIP IPv6
}
```

Ambas direcciones conmutan juntas, manteniendo la accesibilidad de doble pila al API.

### 4.5 Almacenamiento Distribuido Longhorn

#### ¿Qué es Longhorn?

**Longhorn** es un sistema de almacenamiento en bloques distribuido, de código abierto y nativo de la nube, desarrollado por SUSE/Rancher para Kubernetes. Proporciona:

- **Almacenamiento en bloques replicado**: Cada volumen se replica entre múltiples nodos
- **Instantáneas y respaldos**: Instantáneas puntuales con destinos de respaldo S3/NFS
- **Recuperación ante desastres**: Replicación entre clústeres para escenarios de DR
- **Auto-reparación**: Reconstrucción automática de réplicas cuando los nodos fallan
- **Aprovisionamiento ligero (thin provisioning)**: Almacenamiento asignado bajo demanda, no por adelantado
- **Interfaz web**: Panel visual para la gestión de volúmenes

#### Arquitectura de Longhorn

```
┌─────────────────────────────────────────────────────────────────┐
│                      Clúster Kubernetes                          │
│                                                                   │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │              Longhorn Manager (DaemonSet)                  │   │
│  │              Se ejecuta en todos los nodos                 │   │
│  │              Orquesta volúmenes, réplicas, motores         │   │
│  └───────────────────────────────────────────────────────────┘   │
│                                                                   │
│  ┌──────────────────┐  ┌──────────────────┐                     │
│  │  Longhorn CSI    │  │  Longhorn UI     │                     │
│  │  Driver          │  │  (Deployment)    │                     │
│  │  (DaemonSet)     │  │  Panel           │                     │
│  └──────────────────┘  └──────────────────┘                     │
│                                                                   │
│  Arquitectura por Volumen:                                        │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  Volumen: my-app-data (10Gi, 3 réplicas)                 │    │
│  │                                                           │    │
│  │  ┌─────────────┐                                         │    │
│  │  │   Motor     │  (se ejecuta en el nodo del pod)        │    │
│  │  │  (iSCSI)    │                                         │    │
│  │  └──────┬──────┘                                         │    │
│  │         │                                                 │    │
│  │    ┌────┼────────────────┐                                │    │
│  │    │    │                │                                │    │
│  │    ▼    ▼                ▼                                │    │
│  │  ┌────────┐  ┌────────┐  ┌────────┐                      │    │
│  │  │Réplica │  │Réplica │  │Réplica │                      │    │
│  │  │worker-1│  │worker-2│  │worker-3│                      │    │
│  │  └────────┘  └────────┘  └────────┘                      │    │
│  └──────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

#### Ruta de Escritura

Cuando un pod escribe datos en un volumen Longhorn:

1. La escritura entra en el **Motor** (destino iSCSI en el nodo del pod)
2. El Motor **replica sincrónicamente** a todas las réplicas configuradas
3. La escritura se confirma solo después de que **todas las réplicas** confirmen
4. Si una réplica falla, el Motor la marca como degradada y continúa con las réplicas restantes
5. El Longhorn Manager detecta el estado degradado y programa una **reconstrucción** en un nodo saludable

#### Comparación entre Longhorn y Local-Path

| Característica | Longhorn | Local-Path |
|----------------|----------|------------|
| Replicación | Sí (configurable, 1-5 réplicas) | No (nodo único) |
| Tolerancia a fallo de nodo | Sí (los datos sobreviven a la pérdida del nodo) | No (datos perdidos si el nodo muere) |
| Instantáneas | Sí (incrementales, eficientes) | No |
| Respaldos | Sí (destinos S3, NFS) | No (manual) |
| Sobrecarga de rendimiento | ~10-15% (costo de replicación) | Ninguna (E/S directa de disco) |
| Complejidad | Media (despliegue con Helm) | Mínima (integrado en K3s) |
| Uso de recursos | ~500MB RAM por nodo | Despreciable |
| Caso de uso | Producción, cargas de trabajo con estado | Desarrollo, datos efímeros |

### 4.6 Arquitectura de Red (DHCPv4/DHCPv6)

#### ¿Por qué DHCP con Asignaciones Estáticas?

Este despliegue utiliza **DHCP** (tanto v4 como v6) para la configuración de red en lugar de configuración estática a nivel del sistema operativo porque:

1. **Gestión centralizada**: Todo el direccionamiento se gestiona en el servidor DHCP
2. **Consistencia**: Mismo mecanismo que otros dispositivos de red
3. **Flexibilidad**: Cambiar direcciones no requiere reconfiguración del SO
4. **Compatibilidad IPv6**: SLAAC y DHCPv6 funcionan de forma natural con este modelo

Sin embargo, las **asignaciones estáticas DHCP** (reservas) son obligatorias porque:

- Los certificados de K3s están vinculados a direcciones IP específicas
- La membresía del clúster etcd requiere direccionamiento estable
- Los backends de HAProxy se configuran con IPs fijas
- La VIP de Keepalived debe ser predecible

#### IPv6 y Reenvío: El Problema de accept_ra

Existe una interacción crítica entre el reenvío IPv6 y el procesamiento de Anuncios de Router (RA):

```
Comportamiento predeterminado del kernel Linux:
  net.ipv6.conf.all.forwarding = 0  →  accept_ra = 1 (procesar RAs) ✓
  net.ipv6.conf.all.forwarding = 1  →  accept_ra = 1 (IGNORAR RAs)  ✗

K3s requiere forwarding = 1 para la red de pods.
Esto ROMPE la adquisición de direcciones SLAAC y DHCPv6.

Solución:
  net.ipv6.conf.all.accept_ra = 2   →  Procesar RAs incluso con reenvío ✓
  net.ipv6.conf.eth0.accept_ra = 2  →  Anulación por interfaz             ✓
```

Esta plataforma configura automáticamente `accept_ra = 2` en todos los nodos para asegurar que el direccionamiento IPv6 continúe funcionando con el reenvío de paquetes habilitado.

#### Red de Doble Pila

El clúster opera en modo de doble pila completa:

| Red | IPv4 | IPv6 |
|-----|------|------|
| Red de nodos | 192.168.1.0/24 | fd00::/64 |
| CIDR de Pods | 10.42.0.0/16 | fd42::/48 |
| CIDR de Servicios | 10.43.0.0/16 | fd43::/112 |
| VIP | 192.168.1.100 | fd00::100 |

---

## 5. Flujo de Trabajo de Despliegue

El despliegue sigue un orden secuencial estricto. Cada paso depende de la finalización exitosa del paso anterior.

### Paso 0: Validación del Entorno

```bash
./scripts/00-validate-environment.sh
```

**Propósito**: Valida todos los prerrequisitos antes de realizar cualquier cambio.

**Verificaciones realizadas**:
1. El archivo de inventario existe y se puede analizar
2. Las herramientas locales requeridas están presentes (ssh, scp, curl, openssl)
3. El archivo de clave SSH existe en la ruta configurada
4. Conectividad SSH a todos los nodos master (tiempo de espera: 10s cada uno)
5. Conectividad SSH a todos los nodos worker
6. Las direcciones IP reales coinciden con las asignaciones DHCP esperadas (verifica que DHCP funciona)
7. Identificación del sistema operativo en cada nodo

**Comportamiento de salida**: Sale con código 1 si alguna verificación falla, reportando todos los fallos.

### Paso 1: Configuración del Sistema Operativo

```bash
./scripts/01-configure-os.sh
```

**Propósito**: Configura todos los nodos para la operación de K3s después de la instalación del SO.

**Acciones por nodo**:

| Acción | Detalle |
|--------|--------|
| Establecer nombre de host | `hostnamectl set-hostname <hostname>.<dominio>` |
| Configurar /etc/hosts | Todas las IPs de nodos (IPv4 + IPv6) para resolución local |
| Parámetros del kernel | ip_forward, bridge-nf-call, accept_ra=2, inotify, conntrack |
| Módulos del kernel | br_netfilter, overlay, ip_vs, ip_vs_rr/wrr/sh, nf_conntrack |
| Límites de archivos | nofile=65536, nproc=65536 (suave+duro) |
| Firewall | Abrir puertos: 6443, 2379, 2380, 10250, 8472, 51820, etc. |
| Paquetes | open-iscsi, nfs-client, cryptsetup, apparmor-parser |
| Enlace no local | Para HAProxy (solo masters): ip_nonlocal_bind=1 |
| Claves SSH | Desplegar authorized_keys + endurecimiento de sshd |
| Claves de GitHub | Obtener de https://github.com/<usuario>.keys |

### Paso 2: Instalación de HAProxy + Keepalived

```bash
./scripts/02-install-haproxy.sh
```

**Propósito**: Instala y configura el balanceador de carga del API en todos los nodos master.

**Secuencia**:
1. Generar configuración de HAProxy (backends desde el inventario)
2. Generar configuración de Keepalived por nodo (diferente prioridad por nodo)
3. Para cada nodo master:
   - Instalar paquetes haproxy y keepalived
   - Desplegar haproxy.cfg
   - Desplegar keepalived.conf (específico del nodo)
   - Habilitar e iniciar servicios
4. Verificar que la VIP está asignada al nodo de mayor prioridad
5. Verificar que HAProxy está escuchando en el puerto 6443

### Paso 3: Arranque del Primer Servidor K3s

```bash
./scripts/03-install-k3s-first.sh
```

**Propósito**: Inicializa el clúster K3s en el primer nodo master.

**Detalles críticos**:
- Usa el flag `--cluster-init` (crea un clúster etcd de un solo nodo)
- Genera o utiliza el token de clúster proporcionado
- Incluye todos los TLS SANs (VIP, todas las IPs de master, todos los nombres de host)
- Configura los CIDRs de doble pila
- Deshabilita Traefik y ServiceLB predeterminados
- Espera a que el nodo alcance el estado Ready
- Guarda el token en un archivo local para los scripts posteriores

### Paso 4: Unión de Servidores Adicionales

```bash
./scripts/04-install-k3s-servers.sh
```

**Propósito**: Une master-02 y master-03 al clúster.

**Diferencia clave respecto al Paso 3**: Usa `--server https://<IP-primer-master>:6443` en lugar de `--cluster-init`. Se une vía la IP directa del primer master (no la VIP) para evitar problemas de dependencia circular durante el arranque.

**Tras la finalización**: Se establece el quórum de 3 nodos etcd. El clúster es ahora de alta disponibilidad.

### Paso 5: Unión de Nodos de Trabajo

```bash
./scripts/05-install-k3s-agents.sh
```

**Propósito**: Incorpora todos los nodos de trabajo al clúster.

**Detalles clave**:
- Los workers se conectan vía la **VIP** (no masters individuales) — la HA ya está activa
- Usa `INSTALL_K3S_EXEC="agent"` (no "server")
- Aplica etiquetas de worker automáticamente
- Espera a que cada nodo alcance el estado Ready

### Paso 6: Instalación de Almacenamiento Persistente

```bash
STORAGE_PROVIDER=longhorn ./scripts/06-install-storage.sh
```

**Propósito**: Despliega la solución de almacenamiento persistente elegida.

**Para Longhorn**:
1. Verificar prerrequisitos (open-iscsi, iscsid, ruta de datos)
2. Instalar Helm en el primer master
3. Agregar repositorio Helm de Longhorn
4. Desplegar con el archivo de valores generado
5. Esperar a que todos los pods estén listos (tiempo de espera: 300s)
6. Verificar que la StorageClass se ha creado

**Para local-path**:
1. Crear directorio de datos en todos los nodos
2. Aplicar la configuración de la StorageClass
3. Establecer como StorageClass predeterminada

---

## 6. Sistema de Generación de Configuración

### 6.1 Filosofía de Diseño

El sistema de generación de configuración sigue el principio de **"fuente única de verdad, múltiples salidas"**:

```
                    ┌─────────────────┐
                    │  variables.yaml  │  ◄── El usuario edita ESTE ÚNICO archivo
                    │  (240+ líneas)   │
                    └────────┬─────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              ▼              ▼
     ┌────────────┐  ┌────────────┐  ┌────────────┐
     │  Python    │  │  Web UI    │  │  Scripts   │
     │ generate.py│  │ (navegador)│  │  (bash)    │
     └─────┬──────┘  └─────┬──────┘  └─────┬──────┘
           │                │               │
           ▼                ▼               │
     ┌────────────┐  ┌────────────┐         │
     │ generated/ │  │ Archivo ZIP│         │
     │(19 archivos)│  │ (descarga) │         │
     └────────────┘  └────────────┘         │
                                            ▼
                                    ┌────────────┐
                                    │ Ejecución  │
                                    │ remota SSH │
                                    └────────────┘
```

### 6.2 Motor de Plantillas

**Lado servidor (Python)**: Usa Jinja2 3.1+ con `StrictUndefined` — cualquier variable faltante causa un error inmediato en lugar de una salida vacía silenciosa.

**Lado cliente (Navegador)**: Usa Nunjucks 3.2.4, un port JavaScript de Jinja2, habilitando una sintaxis de plantillas idéntica en la interfaz web.

### 6.3 Catálogo de Plantillas

| Plantilla | Salida | Tipo |
|-----------|--------|------|
| haproxy.cfg.j2 | haproxy/haproxy.cfg | Única |
| keepalived.conf.j2 | keepalived/{hostname}/keepalived.conf | Por master |
| k3s-server.yaml.j2 | k3s/{hostname}/config.yaml | Por master |
| k3s-agent.yaml.j2 | k3s/{hostname}/config.yaml | Por worker |
| dhcpd4-leases.conf.j2 | network/dhcpd4-leases.conf | Única |
| dhcpd6-leases.conf.j2 | network/dhcpd6-leases.conf | Única |
| dnsmasq-leases.conf.j2 | network/dnsmasq-leases.conf | Única |
| hosts.j2 | network/hosts | Única |
| sysctl-k3s.conf.j2 | os/sysctl-k3s.conf | Única |
| ssh-config.j2 | os/ssh-config.txt | Única |
| disk-single-root.xml.j2 | os/disk-partitioning.xml | Condicional |
| disk-multipart.xml.j2 | os/disk-partitioning.xml | Condicional |
| disk-multidisk.xml.j2 | os/disk-partitioning.xml | Condicional |
| disk-ignition.json.j2 | os/disk-ignition.json | Única |
| longhorn-values.yaml.j2 | storage/longhorn-values.yaml | Condicional |
| storageclass-local-path.yaml.j2 | storage/storageclass-local-path.yaml | Condicional |

### 6.4 Renderizado Condicional

El generador soporta dos tipos de lógica condicional:

1. **Selección dinámica de plantilla**: La plantilla de particionamiento de disco se selecciona según el valor de `storage.disk_layout`
2. **Condición de proveedor**: Las plantillas de almacenamiento solo se renderizan cuando el proveedor correspondiente está seleccionado

```python
# Selección dinámica de plantilla
if target.get("dynamic_template"):
    disk_layout = variables["storage"]["disk_layout"]
    template_name = layout_map[disk_layout]

# Renderizado condicional
condition = target.get("condition")
if condition and variables["storage"]["provider"] != condition:
    continue  # Omitir esta plantilla
```

---

## 7. Estrategia de Particionamiento de Disco

### 7.1 Opciones de Distribución

#### Opción A: Raíz Única

```
┌─────────────────────────────────────────┐
│             /dev/sda                     │
├──────────┬──────────────────────────────┤
│ /boot/efi│            /                 │
│  512 MB  │     (Btrfs, restante)        │
│  (vfat)  │                              │
│          │  Subvolúmenes:                │
│          │  @/var                        │
│          │  @/var/lib/rancher            │
│          │  @/var/lib/longhorn           │
│          │  @/home                       │
│          │  @/.snapshots                 │
└──────────┴──────────────────────────────┘
```

#### Opción B: Multi-Partición (Recomendada)

```
┌─────────────────────────────────────────┐
│             /dev/sda                     │
├──────────┬──────────┬──────────┬────────┤
│ /boot/efi│    /     │/var/lib/ │Almace- │
│  512 MB  │  40 GB   │rancher   │namiento│
│  (vfat)  │ (Btrfs)  │ 100 GB   │  máx   │
│          │          │  (XFS)   │ (XFS)  │
└──────────┴──────────┴──────────┴────────┘
```

#### Opción C: Multi-Disco

```
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│    /dev/sda      │  │    /dev/sdb      │  │    /dev/sdc      │
├──────────┬───────┤  ├──────────────────┤  ├──────────────────┤
│ /boot/efi│   /   │  │  /var/lib/rancher│  │  /var/lib/       │
│  512 MB  │  máx  │  │  (disco completo)│  │  longhorn        │
│  (vfat)  │(Btrfs)│  │      (XFS)       │  │  (disco completo)│
│          │       │  │                  │  │    (XFS)         │
└──────────┴───────┘  └──────────────────┘  └──────────────────┘
   Disco del SO           Disco de Datos       Disco de Almac.
```

### 7.2 Justificación de la Selección de Sistemas de Archivos

| Punto de Montaje | Sistema de Archivos | Razón |
|------------------|---------------------|-------|
| / | Btrfs | Soporta instantáneas de transactional-update, copy-on-write, compresión |
| /var/lib/rancher | XFS | Alto rendimiento para escrituras de capas de contenedor, sin sobrecarga CoW |
| /var/lib/longhorn | XFS | El backend de almacenamiento en bloques necesita rendimiento de escritura secuencial consistente |
| /boot/efi | vfat | Requerido por la especificación UEFI |

---

## 8. Modelo de Seguridad

### 8.1 Gestión de Claves SSH

La plataforma proporciona tres métodos para el despliegue de claves SSH:

```
┌─────────────────────────────────────────────────────────┐
│               Fuentes de Claves SSH                       │
│                                                          │
│  1. Claves manuales (variables.yaml)                    │
│     ssh.authorized_keys:                                 │
│       - "ssh-ed25519 AAAA... user@host"                 │
│                                                          │
│  2. Importación de claves de GitHub (obtenidas           │
│     en tiempo de despliegue)                             │
│     ssh.github_users:                                    │
│       - "username"                                       │
│     → curl https://github.com/username.keys             │
│                                                          │
│  3. Respaldo con archivo de clave local                  │
│     ssh.key_path: "~/.ssh/id_ed25519"                   │
│     → Lee ~/.ssh/id_ed25519.pub                          │
└─────────────────────────────────────────────────┬───────┘
                                                  │
                                                  ▼
                                     ┌──────────────────┐
                                     │ Todas las claves │
                                     │ combinadas       │
                                     │ Desplegadas en:  │
                                     │ /root/.ssh/      │
                                     │ authorized_keys  │
                                     │ (todos los nodos)│
                                     └──────────────────┘
```

### 8.2 Endurecimiento de SSH

Cuando `ssh.disable_password_auth: true` está configurado:

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

### 8.3 Seguridad de Red (Reglas de Firewall)

| Puerto | Protocolo | Dirección | Propósito | Nodos |
|--------|-----------|-----------|-----------|-------|
| 6443 | TCP | Entrada | Servidor API de K3s | Masters |
| 2379 | TCP | Solo masters | Cliente etcd | Masters |
| 2380 | TCP | Solo masters | Par etcd | Masters |
| 10250 | TCP | Entrada | Métricas de kubelet | Todos |
| 8472 | UDP | Entrada | VXLAN (Flannel) | Todos |
| 51820 | UDP | Entrada | WireGuard IPv4 | Todos |
| 51821 | UDP | Entrada | WireGuard IPv6 | Todos |
| 8404 | TCP | Entrada | Estadísticas de HAProxy | Masters |
| 30000-32767 | TCP/UDP | Entrada | Rango de NodePort | Workers |
| VRRP (112) | IP | Solo masters | Keepalived | Masters |

---

## 9. Arquitectura de Almacenamiento Persistente

### 9.1 Flujo de Datos de Longhorn

```
┌─────────────────────────────────────────────────────────────┐
│  El pod escribe datos                                        │
│  └──► /dev/longhorn/volume-xyz (dispositivo de bloques)     │
│        └──► Motor Longhorn (destino iSCSI, mismo nodo)      │
│              └──► Replicación síncrona                       │
│                    ├──► Réplica 1 (worker-01:/var/lib/longhorn/replicas/vol-xyz/)
│                    ├──► Réplica 2 (worker-02:/var/lib/longhorn/replicas/vol-xyz/)
│                    └──► Réplica 3 (worker-03:/var/lib/longhorn/replicas/vol-xyz/)
│                                                              │
│  Las 3 réplicas confirman ──► Escritura confirmada al Pod   │
└─────────────────────────────────────────────────────────────┘
```

### 9.2 Configuración de StorageClass

**StorageClass de Longhorn** (desplegada por Helm):
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

**StorageClass de Local-Path** (integrada en K3s):
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

## 10. Integración Continua y Aseguramiento de Calidad

### 10.1 Pipeline de CI

```
┌─────────────────────────────────────────────────────────────┐
│            Flujo de GitHub Actions: lint.yaml                 │
│                                                              │
│  Disparador: push a main, pull_request a main               │
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
│  │  lint de salida generada │  │                      │     │
│  │  yamllint del YAML       │  │                      │     │
│  │  generado                │  │                      │     │
│  └──────────────────────────┘  └──────────────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

### 10.2 Herramientas de Lint

| Herramienta | Objetivo | Reglas |
|-------------|----------|--------|
| **ruff** | Python (.py) | PEP8, isort, bugbear, comprehensions, pathlib, verificación de tipos |
| **yamllint** | YAML (.yaml) | Longitud de línea 120, indentación de 2 espacios, valores truthy |
| **shellcheck** | Shell (.sh) | SC1091 deshabilitado (source dinámico), todas las demás reglas |
| **lint_configs.py** | .cfg, .conf | Secciones de HAProxy, sintaxis de Keepalived, llaves/puntos y coma de DHCP |

---

## 11. Generador de Configuración Basado en Web

### 11.1 Arquitectura

La interfaz web es una **aplicación de página única estática** desplegada en GitHub Pages. Se ejecuta completamente en el navegador — sin procesamiento del lado del servidor, sin transmisión de datos.

```
┌─────────────────────────────────────────────────────────────┐
│              Navegador (Solo del Lado del Cliente)             │
│                                                              │
│  ┌──────────┐    ┌──────────────┐    ┌──────────────────┐   │
│  │Formulario│──►│  Nunjucks    │──►│ Archivos Generados│   │
│  │  HTML     │    │  Motor de   │    │  (vista previa +  │   │
│  │ (entrada  │    │  Plantillas │    │   descarga)       │   │
│  │  usuario) │    │             │    │                   │   │
│  └──────────┘    └──────────────┘    └────────┬──────────┘   │
│                                               │              │
│                                     ┌─────────▼──────────┐   │
│                                     │      JSZip         │   │
│                                     │ Generador de       │   │
│                                     │ Archivos ZIP       │   │
│                                     └─────────┬──────────┘   │
│                                               │              │
│                                     ┌─────────▼──────────┐   │
│                                     │    FileSaver.js    │   │
│                                     │ Disparador de      │   │
│                                     │ Descarga           │   │
│                                     └────────────────────┘   │
│                                               │              │
│                                               ▼              │
│                                     k3s-config-v1.0.0-       │
│                                     20260804-143052.zip      │
└─────────────────────────────────────────────────────────────┘
```

### 11.2 Pila Tecnológica

| Biblioteca | Versión | Propósito |
|------------|---------|-----------|
| Nunjucks | 3.2.4 | Motor de plantillas compatible con Jinja2 (CDN) |
| JSZip | 3.10.1 | Generación de archivos ZIP en el navegador (CDN) |
| FileSaver.js | 2.0.5 | Dispara la descarga de archivos desde Blob (CDN) |
| CSS puro | - | Tema oscuro personalizado, diseño responsivo |

### 11.3 Nomenclatura del Archivo ZIP

```
k3s-config-v1.0.0-20260804-143052.zip
│           │     │        │
│           │     │        └── Hora: HHMMSS
│           │     └── Fecha: AAAAMMDD
│           └── Versión de la aplicación
└── Prefijo fijo
```

---

## 12. Resumen

Esta Plataforma de Despliegue K3s de Alta Disponibilidad en Servidores Físicos proporciona una solución completa y lista para producción para desplegar Kubernetes en servidores físicos. Las características clave son:

**Arquitectura**:
- Plano de control de 3 nodos con etcd integrado para consenso HA
- HAProxy + Keepalived para balanceo de carga del servidor API y conmutación por error de VIP
- Tolera el fallo de un solo nodo sin interrupción del servicio
- Red de doble pila (IPv4 + IPv6) en todo el sistema

**Automatización**:
- 7 scripts secuenciales que cubren todo el ciclo de vida del despliegue
- Generación de configuración desde un único archivo de variables (19+ archivos de salida)
- Generador basado en web para operación solo en navegador (sin servidor requerido)
- CI con GitHub Actions para aseguramiento continuo de la calidad

**Almacenamiento**:
- Almacenamiento distribuido replicado Longhorn (grado producción, instantáneas, respaldos)
- Alternativa con aprovisionador local-path (desarrollo/cargas de trabajo simples)
- 3 opciones de distribución de disco para diferentes configuraciones de hardware

**Seguridad**:
- Despliegue de claves SSH con importación de claves de GitHub
- Endurecimiento de SSHD (autenticación por contraseña deshabilitada, acceso solo por clave)
- Configuración de firewall con puertos abiertos mínimos
- Certificados TLS que cubren todas las rutas de acceso (VIP + nodos individuales)
- Base de SO inmutable (transactional-update, raíz de solo lectura)

**Flexibilidad**:
- Elección entre SLE Micro (comercial) u openSUSE MicroOS (comunidad)
- Elección entre Longhorn, local-path, o sin almacenamiento
- Elección entre raíz única, multi-partición, o multi-disco
- Soporte DHCPv4/DHCPv6 con configuraciones ISC DHCP, dnsmasq y Kea
- Configurable mediante YAML, interfaz web o variables de entorno

**Calidad**:
- Todo el código con lint (Python, YAML, Shell, archivos de configuración)
- Validación de plantillas en cada commit
- Salida generada verificada por el pipeline de CI
- Documentación exhaustiva (7 guías + esta referencia)

---

*Este documento describe la versión 1.0.0 de la Plataforma de Despliegue HA K3s en Servidores Físicos. Para las últimas actualizaciones, consulte el [repositorio](https://github.com/opentreecz/k3s).*
