# Plataforma de Despliegue Baremetal de Alta Disponibilidad K3s

## Documento de Referencia Técnica

**Versión:** 1.0.0  
**Última actualización:** Agosto 2026  
**Repositorio:** [github.com/opentreecz/k3s](https://github.com/opentreecz/k3s)  
**Generador Web:** [opentreecz.github.io/k3s](https://opentreecz.github.io/k3s/)

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

Este proyecto proporciona una plataforma de despliegue completa y automatizada para establecer un **clúster Kubernetes K3s de alta disponibilidad** en servidores baremetal. La plataforma está dirigida a entornos que ejecutan **SUSE Linux Enterprise Micro (SLE Micro)** u **openSUSE MicroOS** — sistemas operativos inmutables y optimizados para contenedores, diseñados específicamente para cargas de trabajo de edge computing y Kubernetes.

La plataforma de despliegue aborda el ciclo de vida completo del aprovisionamiento del clúster:

- Instalación y configuración del sistema operativo
- Planificación de red con gestión de asignaciones estáticas DHCPv4/DHCPv6
- Alta disponibilidad del servidor API mediante HAProxy y Keepalived
- Inicialización automatizada del clúster K3s con etcd integrado
- Registro de nodos de trabajo
- Aprovisionamiento de almacenamiento persistente (Longhorn o local-path)
- Gestión de claves SSH con importación de claves de GitHub
- Consumo unificado de configuración: los scripts de despliegue utilizan configuraciones pre-generadas del directorio `generated/` (producidas por `generate.py` o extracción de ZIP de la interfaz web), con respaldo automático a generación en línea desde `inventory.conf`

Toda la configuración se controla mediante un **único archivo de variables** y se renderiza a través de **plantillas Jinja2**, asegurando consistencia, repetibilidad y auditabilidad en todos los entornos.

---

## 2. Visión General del Proyecto

### 2.1 Planteamiento del Problema

Desplegar un clúster Kubernetes de nivel de producción en servidores baremetal presenta varios desafíos que los entornos gestionados en la nube abstraen:

- Sin aprovisionamiento automatizado de infraestructura (sin Terraform/APIs de nube)
- Sin balanceador de carga incorporado para el servidor API
- Sin backend de almacenamiento gestionado
- El direccionamiento de red debe planificarse y coordinarse con la infraestructura DHCP existente
- La instalación y el endurecimiento del sistema operativo son manuales
- La gestión de certificados requiere una planificación cuidadosa de IPs/nombres de host

### 2.2 Arquitectura de la Solución

Esta plataforma resuelve estos desafíos mediante un enfoque por capas:

```
┌─────────────────────────────────────────────────────────────────────┐
│                 Capa de Generación de Configuración                   │
│                                                                       │
│   variables.yaml ──► Plantillas Jinja2 ──► Configs Generadas         │
│   (fuente única)     (18 plantillas)       (19+ archivos de salida)  │
│                                                                       │
│   Web UI (GitHub Pages) ──► Nunjucks en navegador ──► Archivo ZIP    │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                 Capa de Automatización de Despliegue                  │
│                                                                       │
│   00-validate-environment.sh    Verificaciones previas                │
│   01-configure-os.sh            Endurecimiento del SO, claves SSH    │
│   02-install-haproxy.sh         HAProxy + Keepalived en maestros     │
│   03-install-k3s-first.sh       Inicializar primer servidor          │
│   04-install-k3s-servers.sh     Unir nodos de servidor adicionales   │
│   05-install-k3s-agents.sh      Unir nodos de trabajo                │
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

**Flujo de Configuración**: El directorio `generated/` sirve como puente entre la capa de generación de configuración y la capa de automatización de despliegue. Puede ser poblado ya sea por `python3 generate.py` (desde `variables.yaml`) o extrayendo un archivo ZIP de la interfaz web (`unzip k3s-config-*.zip -d generated/`). Cuando los scripts de despliegue encuentran configuraciones pre-generadas en este directorio, las utilizan directamente. Cuando no se encuentran configuraciones pre-generadas, los scripts recurren a generar las configuraciones en línea desde `inventory.conf`.

### 2.3 Estructura del Repositorio

```
k3s/
├── variables.yaml                  # Fuente única de verdad
├── generate.py                     # Renderizador de plantillas Python
├── lint_configs.py                 # Linter personalizado de configuración
├── requirements.txt                # Dependencias de Python
├── pyproject.toml                  # Configuración del linter Ruff
├── .yamllint.yaml                  # Reglas de lint para YAML
├── .shellcheckrc                   # Configuración de lint para Shell
├── .github/workflows/
│   ├── lint.yaml                   # CI: lint de todos los tipos de archivo
│   └── pages.yaml                  # CI: desplegar interfaz web en GitHub Pages
├── docs/                           # Documentación paso a paso
├── templates/jinja2/               # 18 plantillas de configuración Jinja2
├── configs/                        # Configuraciones estáticas de referencia
├── scripts/                        # 7 scripts de automatización de despliegue
├── web/                            # Generador de configuración basado en navegador
└── generated/                      # Directorio de salida (ignorado por git)
```

---

## 3. Arquitectura

### 3.1 Topología de Alta Disponibilidad

El clúster emplea un **plano de control de 3 nodos** con **etcd integrado** para consenso, respaldado por **HAProxy** para el balanceo de carga del API y **Keepalived** para la conmutación por error de la IP Virtual (VIP).

```
                    ┌─────────────────────────────┐
                    │         Clientes             │
                    │   (kubectl, CI/CD, apps)     │
                    └──────────────┬───────────────┘
                                   │
                                   ▼
                    ┌─────────────────────────────┐
                    │     IP Virtual (VIP)         │
                    │    192.168.1.100:6443        │
                    │    fd00::100:6443            │
                    │  (gestionada por Keepalived) │
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
|---------------------|---------|--------------|
| 1 nodo maestro caído | Sin impacto (quórum etcd 2/3 mantenido) | Conmutación automática de VIP |
| 1 nodo de trabajo caído | Pods reprogramados en los nodos restantes | Automática por Kubernetes |
| HAProxy en 1 maestro | VIP se mueve al nodo HAProxy saludable | Conmutación por error de Keepalived (<3s) |
| Partición de red (1 maestro aislado) | Quórum mantenido por mayoría | Reconciliación automática |
| 2 nodos maestros caídos | **Clúster no disponible** (quórum perdido) | Intervención manual requerida |

### 3.3 Flujo de Red

```
kubectl ──► VIP:6443 ──► HAProxy ──► K3s API Server (cualquiera de los 3 maestros)
                              │
                              ├──► master-01:6443 (verificación: salud TCP)
                              ├──► master-02:6443 (verificación: salud TCP)
                              └──► master-03:6443 (verificación: salud TCP)

Worker Agent ──► VIP:6443 ──► HAProxy ──► K3s API Server
                                              │
                                              ▼
                                     Registrar nodo
                                     Recibir especificaciones de pods
                                     Reportar estado
```

---

## 4. Análisis Detallado de Componentes

### 4.1 Capa del Sistema Operativo

#### SUSE Linux Enterprise Micro (SLE Micro)

**SLE Micro** es el sistema operativo inmutable de SUSE con soporte comercial, diseñado específicamente para cargas de trabajo contenedorizadas y virtualizadas. Características principales:

- **Sistema de archivos raíz inmutable**: La partición raíz es de solo lectura. Los cambios se aplican mediante `transactional-update`, que crea una nueva instantánea Btrfs. El sistema arranca con la nueva instantánea en el siguiente reinicio, proporcionando actualizaciones atómicas con capacidad de reversión instantánea.
- **Superficie de ataque mínima**: Se distribuye solo con paquetes esenciales. Sin entorno de escritorio, sin daemons innecesarios.
- **SELinux/AppArmor**: Control de acceso obligatorio habilitado por defecto.
- **Ciclo de vida comercial**: 4+ años de mantenimiento y actualizaciones de seguridad por versión mayor.
- **Certificación**: Variantes certificadas FIPS 140-2 y Common Criteria disponibles.

#### openSUSE MicroOS

**openSUSE MicroOS** es la versión upstream impulsada por la comunidad de SLE Micro, compartiendo la misma arquitectura:

- **Versión continua**: Actualizaciones continuas (basada en Tumbleweed).
- **Mecanismo idéntico de transactional-update**: Mismo sistema de actualización atómica.
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
│  transactional-update reboot ──► Arrancar con Instantánea #2│
│                                                              │
│  Si la Instantánea #2 falla:                                 │
│  └── Revertir a Instantánea #1 (instantáneo, sin pérdida)  │
└─────────────────────────────────────────────────────────────┘
```

La herramienta `transactional-update` es el mecanismo exclusivo para modificar el sistema operativo:

```bash
# Instalar paquetes (tiene efecto después de reiniciar)
transactional-update pkg install open-iscsi nfs-client

# Aplicar todas las actualizaciones pendientes
transactional-update up

# Reiniciar con la nueva instantánea
transactional-update reboot
```

### 4.2 Distribución Kubernetes K3s

#### ¿Qué es K3s?

**K3s** es una distribución Kubernetes certificada y de nivel de producción, desarrollada por SUSE/Rancher. Empaqueta todo el plano de control de Kubernetes en un único binario (~60MB), lo que la hace adecuada para entornos con recursos limitados, computación en el borde y despliegues baremetal donde la sobrecarga operativa de los clústeres basados en kubeadm es indeseable.

#### K3s vs Kubernetes Upstream

| Característica | K3s | Upstream (kubeadm) |
|----------------|-----|-------------------|
| Tamaño del binario | ~60 MB | ~300+ MB (múltiples binarios) |
| Huella de memoria | ~512 MB (servidor) | ~1-2 GB (servidor) |
| Instalación | Un único comando curl | Múltiples pasos, gestión de certificados |
| etcd | Integrado (o externo) | Debe aprovisionarse por separado |
| Runtime de contenedores | containerd (incorporado) | Debe instalarse por separado |
| Red | Flannel (incorporado) | Debe instalarse plugin CNI |
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

#### Arquitectura del Agente K3s (Trabajador)

Cada nodo agente K3s ejecuta:

```
┌──────────────────────────────────────────────────────┐
│                Proceso del Agente K3s                  │
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

K3s utiliza un clúster etcd integrado para almacenar todo el estado del clúster. Con 3 nodos de servidor, el clúster etcd opera con el algoritmo de consenso Raft:

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

#### Secuencia de Inicialización del Clúster K3s

La inicialización del clúster sigue un orden preciso:

1. **Primer servidor** inicia con `--cluster-init`, creando un clúster etcd de un solo nodo
2. **Segundo servidor** se une vía `--server https://<primero>:6443`, convirtiéndose en seguidor etcd
3. **Tercer servidor** se une de manera similar, completando el quórum etcd de 3 nodos
4. **Agentes** se unen vía la VIP (`https://<VIP>:6443`) para alta disponibilidad

```
Tiempo ────────────────────────────────────────────────────────────►

master-01: [cluster-init] ──► [líder etcd, 1/1] ──► [líder etcd, 1/3]
                                                              │
master-02:                    [unión] ──► [seguidor etcd, 2/3] ─┤
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

K3s genera y gestiona automáticamente los certificados TLS. Las opciones `--tls-san` aseguran que los certificados sean válidos para todas las rutas de acceso:

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
- Cualquier IP individual de maestro (depuración/emergencia)
- Cualquier variante de nombre de host

### 4.3 Balanceador de Carga HAProxy

#### Propósito

HAProxy sirve como el **balanceador de carga de Capa 4 (TCP)** para el servidor API de K3s. Distribuye las conexiones entrantes en el puerto 6443 entre los tres nodos maestros, proporcionando:

- **Distribución de carga**: Balanceo round-robin entre backends saludables
- **Verificación de salud**: Sondeos de salud a nivel TCP cada 10 segundos
- **Conmutación automática por error**: Elimina backends no saludables del grupo en 2 verificaciones fallidas
- **Persistencia de conexiones**: Mantiene las conexiones existentes durante las transiciones de backend

#### Arquitectura de Configuración de HAProxy

```
┌──────────────────────────────────────────────────────┐
│                   Proceso HAProxy                      │
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
│  │              bind *:8404 (modo HTTP)            │ │
│  │              /stats panel de control             │ │
│  └─────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

#### Parámetros de Verificación de Salud

| Parámetro | Valor | Descripción |
|-----------|-------|-------------|
| `inter` | 10s | Intervalo de verificación cuando el servidor está ACTIVO |
| `downinter` | 5s | Intervalo de verificación cuando el servidor está CAÍDO |
| `rise` | 2 | Verificaciones exitosas consecutivas para marcar como ACTIVO |
| `fall` | 2 | Verificaciones fallidas consecutivas para marcar como CAÍDO |
| `slowstart` | 60s | Aumento gradual de tráfico tras la recuperación |
| `maxconn` | 250 | Máximo de conexiones concurrentes por backend |

#### ¿Por Qué el Modo TCP (Capa 4)?

HAProxy opera en modo TCP (no HTTP) porque:

1. El API de K3s usa **TLS mutuo** (mTLS) — HAProxy no puede terminar la conexión
2. El modo TCP tiene **menor sobrecarga** (sin análisis HTTP)
3. El protocolo del API es **HTTP/2** con streaming (watches) — el modo TCP lo maneja de forma nativa
4. Las verificaciones de salud usan **conexión TCP** (puerto 6443 respondiendo = saludable)

### 4.4 Keepalived e IP Virtual

#### Propósito

Keepalived implementa el **Protocolo de Redundancia de Router Virtual (VRRP)** para gestionar una dirección IP Virtual (VIP) flotante entre los tres nodos maestros. Esta VIP es el punto de entrada único para todo el acceso al API.

#### Operación VRRP

```
Operación Normal:                     Tras Fallo de master-01:

  master-01 (MAESTRO, prioridad 101)    master-01 (CAÍDO)
  ├── VIP: 192.168.1.100 ✓             ├── VIP: (liberada)
  ├── Envía anuncios VRRP              │
  │                                     │
  master-02 (RESPALDO, prioridad 100)   master-02 (MAESTRO, prioridad 100)
  ├── VIP: (en espera)                 ├── VIP: 192.168.1.100 ✓
  ├── Escucha anuncios                 ├── Envía anuncios VRRP
  │                                     │
  master-03 (RESPALDO, prioridad 99)    master-03 (RESPALDO, prioridad 99)
  ├── VIP: (en espera)                 ├── VIP: (en espera)
  ├── Escucha anuncios                 ├── Escucha anuncios
```

#### Secuencia de Conmutación por Error

1. Master-01 (MAESTRO) envía anuncios VRRP cada 1 segundo
2. Master-02 y master-03 (RESPALDO) escuchan estos anuncios
3. Si los anuncios dejan de llegar durante 3 segundos (fall × intervalo):
   - El RESPALDO con mayor prioridad (master-02, prioridad 100) transiciona a MAESTRO
   - Envía un ARP Gratuito anunciando la VIP en su dirección MAC
   - Todos los switches de red actualizan sus tablas MAC
   - El tráfico fluye a master-02 inmediatamente
4. Cuando master-01 se recupera:
   - Con preempción habilitada: master-01 reclama MAESTRO (mayor prioridad)
   - Sin preempción: master-02 retiene MAESTRO hasta que falle

#### Script de Seguimiento de Salud

Keepalived usa un script de verificación de salud para vincular la propiedad de la VIP al estado de HAProxy:

```bash
vrrp_script check_haproxy {
    script "/usr/bin/killall -0 haproxy"   # Señal 0 = verificar si el proceso existe
    interval 2                              # Verificar cada 2 segundos
    weight 2                                # Añadir 2 a la prioridad si está saludable
    fall 3                                  # 3 fallos para considerar CAÍDO
    rise 2                                  # 2 éxitos para considerar ACTIVO
}
```

Esto asegura que la VIP solo resida en un nodo donde HAProxy esté realmente ejecutándose y aceptando conexiones.

#### VIP de Doble Pila (IPv4 + IPv6)

La configuración de la VIP incluye tanto direcciones IPv4 como IPv6:

```
virtual_ipaddress {
    192.168.1.100/24 dev eth0    # VIP IPv4
    fd00::100/64 dev eth0        # VIP IPv6
}
```

Ambas direcciones conmutan juntas, manteniendo la accesibilidad al API en doble pila.

### 4.5 Almacenamiento Distribuido Longhorn

#### ¿Qué es Longhorn?

**Longhorn** es un sistema de almacenamiento de bloques distribuido, de código abierto y nativo de la nube, desarrollado por SUSE/Rancher para Kubernetes. Proporciona:

- **Almacenamiento de bloques replicado**: Cada volumen se replica en múltiples nodos
- **Instantáneas y respaldos**: Instantáneas puntuales con destinos de respaldo S3/NFS
- **Recuperación ante desastres**: Replicación entre clústeres para escenarios de DR
- **Auto-reparación**: Reconstrucción automática de réplicas cuando fallan nodos
- **Aprovisionamiento fino**: Almacenamiento asignado bajo demanda, no por adelantado
- **Interfaz web**: Panel visual para gestión de volúmenes

#### Arquitectura de Longhorn

```
┌─────────────────────────────────────────────────────────────────┐
│                      Clúster Kubernetes                           │
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
│  │  (DaemonSet)     │  │  Panel de control│                     │
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

Cuando un pod escribe datos en un volumen de Longhorn:

1. La escritura entra al **Motor** (destino iSCSI en el nodo del pod)
2. El Motor **replica sincrónicamente** a todas las réplicas configuradas
3. La escritura se confirma solo después de que **todas las réplicas** confirmen
4. Si una réplica falla, el Motor la marca como degradada y continúa con las réplicas restantes
5. Longhorn Manager detecta el estado degradado y programa una **reconstrucción** en un nodo saludable

#### Comparación Longhorn vs Local-Path

| Característica | Longhorn | Local-Path |
|----------------|----------|------------|
| Replicación | Sí (configurable, 1-5 réplicas) | No (nodo único) |
| Tolerancia a fallo de nodo | Sí (datos sobreviven a la pérdida del nodo) | No (datos perdidos si el nodo muere) |
| Instantáneas | Sí (incrementales, eficientes) | No |
| Respaldos | Sí (destinos S3, NFS) | No (manual) |
| Sobrecarga de rendimiento | ~10-15% (costo de replicación) | Ninguna (E/S directa de disco) |
| Complejidad | Media (despliegue con Helm) | Mínima (incorporado en K3s) |
| Uso de recursos | ~500MB RAM por nodo | Insignificante |
| Caso de uso | Producción, cargas de trabajo con estado | Desarrollo, datos efímeros |

### 4.6 Arquitectura de Red (DHCPv4/DHCPv6)

#### ¿Por Qué DHCP con Asignaciones Estáticas?

Este despliegue usa **DHCP** (tanto v4 como v6) para la configuración de red en lugar de configuración estática a nivel de sistema operativo porque:

1. **Gestión centralizada**: Todo el direccionamiento se gestiona en el servidor DHCP
2. **Consistencia**: Mismo mecanismo que otros dispositivos de red
3. **Flexibilidad**: Cambiar direcciones no requiere reconfiguración del SO
4. **Compatibilidad IPv6**: SLAAC y DHCPv6 funcionan naturalmente con este modelo

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
  net.ipv6.conf.eth0.accept_ra = 2  →  Anulación por interfaz              ✓
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

**Fuente de Configuración**: Cada script de despliegue verifica la existencia de archivos de configuración pre-generados en el directorio `generated/` antes de ejecutarse. Si se encuentran (producidos por `python3 generate.py` o extrayendo un ZIP de la interfaz web), las configuraciones pre-generadas se despliegan directamente a los nodos. Si el directorio `generated/` está ausente o incompleto, los scripts recurren a generar las configuraciones en línea desde `inventory.conf`. El directorio de configuración puede anularse con la variable de entorno `CONFIG_DIR`.

### Paso 0: Validación del Entorno

```bash
./scripts/00-validate-environment.sh
```

**Propósito**: Valida todos los prerrequisitos antes de realizar cualquier cambio.

**Verificaciones realizadas**:
1. El archivo de inventario existe y es analizable
2. Las herramientas locales requeridas están presentes (ssh, scp, curl, openssl)
3. El archivo de clave SSH existe en la ruta configurada
4. Conectividad SSH a todos los nodos maestros (tiempo de espera: 10s cada uno)
5. Conectividad SSH a todos los nodos de trabajo
6. Las direcciones IP reales coinciden con las asignaciones DHCP esperadas (verifica que DHCP funciona)
7. Identificación del sistema operativo en cada nodo
8. Validación del directorio de configuración pre-generada (si existe `generated/`)

**Comportamiento de salida**: Sale con código 1 si alguna verificación falla, reportando todos los fallos.

### Paso 1: Configuración del Sistema Operativo

```bash
./scripts/01-configure-os.sh
```

**Propósito**: Configura todos los nodos para la operación de K3s después de la instalación del SO.

**Acciones por nodo**:

| Acción | Detalle |
|--------|---------|
| Establecer nombre de host | `hostnamectl set-hostname <hostname>.<domain>` |
| Configurar /etc/hosts | Todas las IPs de nodos (IPv4 + IPv6) para resolución local |
| Parámetros del kernel | ip_forward, bridge-nf-call, accept_ra=2, inotify, conntrack |
| Módulos del kernel | br_netfilter, overlay, ip_vs, ip_vs_rr/wrr/sh, nf_conntrack |
| Límites de archivos | nofile=65536, nproc=65536 (soft+hard) |
| Cortafuegos | Abrir puertos: 6443, 2379, 2380, 10250, 8472, 51820, etc. |
| Paquetes | open-iscsi, nfs-client, cryptsetup, apparmor-parser |
| Enlace no local | Para HAProxy (solo maestros): ip_nonlocal_bind=1 |
| Claves SSH | Desplegar authorized_keys + endurecimiento de sshd |
| Claves de GitHub | Obtener de https://github.com/<user>.keys |

Cuando las configuraciones pre-generadas están disponibles en `generated/`, el script usa `os/sysctl-k3s.conf`, `network/hosts`, `os/ssh-authorized-keys` y `os/sshd-hardening.conf` directamente en lugar de generarlos en línea.

### Paso 2: Instalación de HAProxy + Keepalived

```bash
./scripts/02-install-haproxy.sh
```

**Propósito**: Instala y configura el balanceador de carga del API en todos los nodos maestros.

**Secuencia**:
1. Generar configuración de HAProxy (backends desde el inventario)
2. Generar configuración de Keepalived por nodo (diferente prioridad por nodo)
3. Para cada nodo maestro:
   - Instalar paquetes haproxy y keepalived
   - Desplegar haproxy.cfg
   - Desplegar keepalived.conf (específico por nodo)
   - Habilitar e iniciar servicios
4. Verificar que la VIP está asignada al nodo con mayor prioridad
5. Verificar que HAProxy está escuchando en el puerto 6443

Cuando las configuraciones pre-generadas están disponibles, el script lee `generated/haproxy/haproxy.cfg` y `generated/keepalived/{hostname}/keepalived.conf` en lugar de generarlos en línea.

### Paso 3: Inicializar Primer Servidor K3s

```bash
./scripts/03-install-k3s-first.sh
```

**Propósito**: Inicializa el clúster K3s en el primer nodo maestro.

**Detalles críticos**:
- Usa la opción `--cluster-init` (crea un clúster etcd de un solo nodo)
- Genera o usa el token de clúster proporcionado
- Incluye todos los TLS SANs (VIP, todas las IPs de maestros, todos los nombres de host)
- Configura CIDRs de doble pila
- Deshabilita Traefik y ServiceLB predeterminados
- Espera a que el nodo alcance el estado Ready
- Guarda el token en archivo local para los scripts siguientes

Cuando las configuraciones pre-generadas están disponibles, el script despliega `generated/k3s/{hostname}/config.yaml` directamente en lugar de construir la configuración en línea.

### Paso 4: Unir Servidores Adicionales

```bash
./scripts/04-install-k3s-servers.sh
```

**Propósito**: Une master-02 y master-03 al clúster.

**Diferencia clave con el Paso 3**: Usa `--server https://<primer-maestro-IP>:6443` en lugar de `--cluster-init`. Se une vía la IP directa del primer maestro (no la VIP) para evitar problemas de dependencia circular durante la inicialización.

**Después de completar**: El quórum etcd de 3 nodos queda establecido. El clúster ahora tiene HA.

Usa `generated/k3s/{hostname}/config.yaml` pre-generado cuando está disponible, con respaldo en línea.

### Paso 5: Unir Nodos de Trabajo

```bash
./scripts/05-install-k3s-agents.sh
```

**Propósito**: Registra todos los nodos de trabajo en el clúster.

**Detalles clave**:
- Los trabajadores se conectan vía la **VIP** (no a maestros individuales) — la HA ya está activa
- Usa `INSTALL_K3S_EXEC="agent"` (no "server")
- Aplica etiquetas de trabajador automáticamente
- Espera a que cada nodo alcance el estado Ready

Usa `generated/k3s/{hostname}/config.yaml` pre-generado cuando está disponible, con respaldo en línea.

### Paso 6: Instalar Almacenamiento Persistente

```bash
STORAGE_PROVIDER=longhorn ./scripts/06-install-storage.sh
```

**Propósito**: Despliega la solución de almacenamiento persistente elegida.

**Para Longhorn**:
1. Verificar prerrequisitos (open-iscsi, iscsid, ruta de datos)
2. Instalar Helm en el primer maestro
3. Añadir el repositorio Helm de Longhorn
4. Desplegar con archivo de valores generado
5. Esperar a que todos los pods estén listos (tiempo de espera: 300s)
6. Verificar que el StorageClass está creado

**Para local-path**:
1. Crear directorio de datos en todos los nodos
2. Aplicar configuración de StorageClass
3. Establecer como StorageClass predeterminado

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
     │ generate.py│  │(navegador) │  │  (bash)    │
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

### 6.5 Consumo Unificado de Configuración

Los scripts de despliegue ahora consumen archivos de configuración pre-generados del directorio `generated/`, creando un pipeline unificado:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Fuentes de Configuración                          │
│                                                                       │
│   Ruta A: variables.yaml ──► generate.py ──► generated/              │
│                                                    │                  │
│   Ruta B: Web UI ──► descarga ZIP ──► unzip ──► generated/           │
│                                                    │                  │
│   Ruta C: inventory.conf ──► en línea (respaldo) ──┤                 │
│                                                    │                  │
└────────────────────────────────────────────────────┼──────────────────┘
                                                     │
                                                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Scripts de Despliegue                            │
│                                                                       │
│   Los scripts verifican generated/ primero, recurren a inventory.conf│
│                                                                       │
│   00-validate ──► 01-configure-os ──► 02-haproxy ──► 03-k3s-first   │
│   ──► 04-k3s-servers ──► 05-k3s-agents ──► 06-storage               │
└─────────────────────────────────────────────────────────────────────┘
```

Anular el directorio de configuración con: `CONFIG_DIR=/path/to/configs ./scripts/01-configure-os.sh`

### 6.2 Motor de Plantillas

**Lado servidor (Python)**: Usa Jinja2 3.1+ con `StrictUndefined` — cualquier variable faltante causa un error inmediato en lugar de una salida vacía silenciosa.

**Lado cliente (Navegador)**: Usa Nunjucks 3.2.4, un port JavaScript de Jinja2, que permite una sintaxis de plantillas idéntica en la interfaz web.

### 6.3 Catálogo de Plantillas

| Plantilla | Salida | Tipo |
|-----------|--------|------|
| haproxy.cfg.j2 | haproxy/haproxy.cfg | Único |
| keepalived.conf.j2 | keepalived/{hostname}/keepalived.conf | Por maestro |
| k3s-server.yaml.j2 | k3s/{hostname}/config.yaml | Por maestro |
| k3s-agent.yaml.j2 | k3s/{hostname}/config.yaml | Por trabajador |
| dhcpd4-leases.conf.j2 | network/dhcpd4-leases.conf | Único |
| dhcpd6-leases.conf.j2 | network/dhcpd6-leases.conf | Único |
| dnsmasq-leases.conf.j2 | network/dnsmasq-leases.conf | Único |
| hosts.j2 | network/hosts | Único |
| sysctl-k3s.conf.j2 | os/sysctl-k3s.conf | Único |
| ssh-config.j2 | os/ssh-config.txt | Único |
| disk-single-root.xml.j2 | os/disk-partitioning.xml | Condicional |
| disk-multipart.xml.j2 | os/disk-partitioning.xml | Condicional |
| disk-multidisk.xml.j2 | os/disk-partitioning.xml | Condicional |
| disk-ignition.json.j2 | os/disk-ignition.json | Único |
| longhorn-values.yaml.j2 | storage/longhorn-values.yaml | Condicional |
| storageclass-local-path.yaml.j2 | storage/storageclass-local-path.yaml | Condicional |

### 6.4 Renderizado Condicional

El generador soporta dos tipos de lógica condicional:

1. **Selección dinámica de plantillas**: La plantilla de particionamiento de disco se selecciona según el valor de `storage.disk_layout`
2. **Condición de proveedor**: Las plantillas de almacenamiento solo se renderizan cuando el proveedor correspondiente está seleccionado

```python
# Selección dinámica de plantillas
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

### 7.1 Opciones de Disposición

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
│ /boot/efi│    /     │/var/lib/ │Almac.  │
│  512 MB  │  40 GB   │rancher   │  máx   │
│  (vfat)  │ (Btrfs)  │ 100 GB   │ (XFS)  │
│          │          │  (XFS)   │        │
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
  Disco del SO           Disco de Datos       Disco de Almacen.
```

### 7.2 Justificación de la Selección de Sistemas de Archivos

| Punto de Montaje | Sistema de Archivos | Razón |
|------------------|---------------------|-------|
| / | Btrfs | Soporta instantáneas de transactional-update, copia en escritura, compresión |
| /var/lib/rancher | XFS | Alto rendimiento para escrituras de capas de contenedor, sin sobrecarga CoW |
| /var/lib/longhorn | XFS | El backend de almacenamiento de bloques necesita rendimiento consistente de escritura secuencial |
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
│  2. Importación de claves de GitHub (obtenidas al       │
│     desplegar)                                           │
│     ssh.github_users:                                    │
│       - "username"                                       │
│     → curl https://github.com/username.keys             │
│                                                          │
│  3. Respaldo de archivo de clave local                  │
│     ssh.key_path: "~/.ssh/id_ed25519"                   │
│     → Lee ~/.ssh/id_ed25519.pub                         │
└─────────────────────────────────────────────┬───────────┘
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

### 8.2 Endurecimiento SSH

Cuando se establece `ssh.disable_password_auth: true`:

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

### 8.3 Seguridad de Red (Reglas de Cortafuegos)

| Puerto | Protocolo | Dirección | Propósito | Nodos |
|--------|-----------|-----------|-----------|-------|
| 6443 | TCP | Entrante | Servidor API de K3s | Maestros |
| 2379 | TCP | Solo maestros | Cliente etcd | Maestros |
| 2380 | TCP | Solo maestros | Par etcd | Maestros |
| 10250 | TCP | Entrante | Métricas de Kubelet | Todos |
| 8472 | UDP | Entrante | VXLAN (Flannel) | Todos |
| 51820 | UDP | Entrante | WireGuard IPv4 | Todos |
| 51821 | UDP | Entrante | WireGuard IPv6 | Todos |
| 8404 | TCP | Entrante | Estadísticas de HAProxy | Maestros |
| 30000-32767 | TCP/UDP | Entrante | Rango de NodePort | Trabajadores |
| VRRP (112) | IP | Solo maestros | Keepalived | Maestros |

---

## 9. Arquitectura de Almacenamiento Persistente

### 9.1 Flujo de Datos de Longhorn

```
┌─────────────────────────────────────────────────────────────┐
│  Pod escribe datos                                           │
│  └──► /dev/longhorn/volume-xyz (dispositivo de bloques)     │
│        └──► Motor Longhorn (destino iSCSI, mismo nodo)      │
│              └──► Replicación sincrónica                    │
│                    ├──► Réplica 1 (worker-01:/var/lib/longhorn/replicas/vol-xyz/)
│                    ├──► Réplica 2 (worker-02:/var/lib/longhorn/replicas/vol-xyz/)
│                    └──► Réplica 3 (worker-03:/var/lib/longhorn/replicas/vol-xyz/)
│                                                              │
│  Las 3 réplicas confirman ──► Escritura confirmada al Pod   │
└─────────────────────────────────────────────────────────────┘
```

### 9.2 Configuración del StorageClass

**StorageClass de Longhorn** (desplegado por Helm):
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

**StorageClass de Local-Path** (incorporado en K3s):
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
│            Flujo de Trabajo de GitHub Actions: lint.yaml      │
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
│  │  yamllint en YAML generado│  │                      │     │
│  └──────────────────────────┘  └──────────────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

### 10.2 Herramientas de Lint

| Herramienta | Objetivo | Reglas |
|-------------|----------|--------|
| **ruff** | Python (.py) | PEP8, isort, bugbear, comprehensions, pathlib, type-checking |
| **yamllint** | YAML (.yaml) | Longitud de línea 120, sangría de 2 espacios, valores truthy |
| **shellcheck** | Shell (.sh) | SC1091 deshabilitado (source dinámico), todas las demás reglas |
| **lint_configs.py** | .cfg, .conf | Secciones de HAProxy, sintaxis de Keepalived, llaves/punto y coma de DHCP |

---

## 11. Generador de Configuración Basado en Web

### 11.1 Arquitectura

La interfaz web es una **aplicación estática de página única** desplegada en GitHub Pages. Se ejecuta completamente en el navegador — sin procesamiento del lado del servidor, sin transmisión de datos.

```
┌─────────────────────────────────────────────────────────────┐
│              Navegador (Solo Lado del Cliente)                 │
│                                                              │
│  ┌──────────┐    ┌──────────────┐    ┌──────────────────┐   │
│  │Formulario│──►│  Nunjucks    │──►│ Archivos Generados│   │
│  │ HTML     │    │  Motor de   │    │ (vista previa +   │   │
│  │(entrada  │    │  Plantillas │    │  descarga)        │   │
│  │ usuario) │    │             │    │                   │   │
│  └──────────┘    └──────────────┘    └────────┬──────────┘   │
│                                               │              │
│                                     ┌─────────▼──────────┐   │
│                                     │      JSZip         │   │
│                                     │ Generador de       │   │
│                                     │ Archivos           │   │
│                                     └─────────┬──────────┘   │
│                                               │              │
│                                     ┌─────────▼──────────┐   │
│                                     │    FileSaver.js    │   │
│                                     │  Disparador de     │   │
│                                     │  Descarga          │   │
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
| Pure CSS | - | Tema oscuro personalizado, diseño responsivo |

### 11.3 Nomenclatura del Archivo ZIP

```
k3s-config-v1.0.0-20260804-143052.zip
│           │     │        │
│           │     │        └── Hora: HHMMSS
│           │     └── Fecha: AAAAMMDD
│           └── Versión de la aplicación
└── Prefijo fijo
```

### 11.4 Uso del ZIP con Scripts CLI

El archivo ZIP de la interfaz web puede usarse directamente con los scripts de despliegue CLI:

```bash
# 1. Descargar el ZIP desde https://opentreecz.github.io/k3s/
# 2. Extraer en el directorio generated/
unzip k3s-config-v1.0.0-*.zip -d generated/

# 3. Configurar inventory.conf con los ajustes de conexión SSH
cp templates/inventory.example.conf inventory.conf
# Editar: SSH_USER, SSH_KEY_PATH, SSH_PORT, MASTER_NODES (IPs), WORKER_NODES (IPs)

# 4. Ejecutar scripts de despliegue (detectarán y usarán las configs pre-generadas)
./scripts/00-validate-environment.sh
./scripts/01-configure-os.sh
./scripts/02-install-haproxy.sh
./scripts/03-install-k3s-first.sh
./scripts/04-install-k3s-servers.sh
./scripts/05-install-k3s-agents.sh
```

Los scripts detectan automáticamente las configuraciones pre-generadas en `generated/` y las usan en lugar de generar configuraciones en línea. El archivo `inventory.conf` sigue siendo necesario para los parámetros de conexión SSH (usuario, ruta de clave, puerto) y las direcciones IP de los nodos utilizadas para la conectividad SSH.

---

## 12. Resumen

Esta Plataforma de Despliegue Baremetal de Alta Disponibilidad K3s proporciona una solución completa y lista para producción para desplegar Kubernetes en servidores físicos. Las características principales son:

**Arquitectura**:
- Plano de control de 3 nodos con etcd integrado para consenso de HA
- HAProxy + Keepalived para balanceo de carga del servidor API y conmutación por error de VIP
- Tolera el fallo de un solo nodo sin interrupción del servicio
- Red de doble pila (IPv4 + IPv6) en todo el sistema

**Automatización**:
- 7 scripts secuenciales que cubren el ciclo de vida completo del despliegue
- Generación de configuración desde un único archivo de variables (19+ archivos de salida)
- Generador basado en web para operación solo en navegador (sin servidor requerido)
- Consumo unificado de configuración: los scripts usan configuraciones pre-generadas de `generated/` (vía `generate.py` o ZIP de la interfaz web), con respaldo automático a generación en línea
- GitHub Actions CI para aseguramiento de calidad continuo

**Almacenamiento**:
- Almacenamiento replicado distribuido Longhorn (nivel de producción, instantáneas, respaldos)
- Alternativa con aprovisionador local-path (desarrollo/cargas de trabajo simples)
- 3 opciones de disposición de disco que acomodan diferentes configuraciones de hardware

**Seguridad**:
- Despliegue de claves SSH con importación de claves de GitHub
- Endurecimiento de SSHD (autenticación por contraseña deshabilitada, acceso solo por clave)
- Configuración de cortafuegos con puertos abiertos mínimos
- Certificados TLS que cubren todas las rutas de acceso (VIP + nodos individuales)
- Base de SO inmutable (transactional-update, raíz de solo lectura)

**Flexibilidad**:
- Opción entre SLE Micro (comercial) u openSUSE MicroOS (comunitario)
- Opción entre Longhorn, local-path o sin almacenamiento
- Opción entre raíz única, multi-partición o multi-disco
- Soporte DHCPv4/DHCPv6 con configuraciones de ISC DHCP, dnsmasq y Kea
- Configurable vía YAML, interfaz web o variables de entorno

**Calidad**:
- Todo el código verificado con lint (Python, YAML, Shell, archivos de configuración)
- Validación de plantillas en cada commit
- Salida generada verificada por el pipeline de CI
- Documentación completa (7 guías + esta referencia)

---

*Este documento describe la versión 1.0.0 de la Plataforma de Despliegue Baremetal HA K3s. Para las últimas actualizaciones, consulte el [repositorio](https://github.com/opentreecz/k3s).*
