/* K3s Configuration Generator - Application Logic */

(function () {
    "use strict";

    // =========================================================================
    // Constants
    // =========================================================================

    const APP_VERSION = "1.0.0";
    const ARCHIVE_PREFIX = "k3s-config";

    // =========================================================================
    // State
    // =========================================================================

    let generatedFiles = {};
    let workerCount = 1;

    // =========================================================================
    // Initialization
    // =========================================================================

    document.addEventListener("DOMContentLoaded", function () {
        document.getElementById("app-version").textContent = "v" + APP_VERSION;

        // Event listeners
        document.getElementById("btn-generate").addEventListener("click", handleGenerate);
        document.getElementById("btn-download").addEventListener("click", handleDownload);
        document.getElementById("add-worker").addEventListener("click", addWorkerNode);
        document.getElementById("os-distribution").addEventListener("change", toggleSleFields);

        // Disk layout radio buttons
        document.querySelectorAll('input[name="disk_layout"]').forEach(function (radio) {
            radio.addEventListener("change", toggleDiskFields);
        });

        // Storage provider radio buttons
        document.querySelectorAll('input[name="storage_provider"]').forEach(function (radio) {
            radio.addEventListener("change", toggleStorageFields);
        });

        // Worker remove buttons
        document.addEventListener("click", function (e) {
            if (e.target.classList.contains("btn-remove-worker")) {
                removeWorkerNode(e.target);
            }
        });
    });

    // =========================================================================
    // Form Handling
    // =========================================================================

    function toggleSleFields() {
        var isSle = document.getElementById("os-distribution").value === "sle-micro";
        var sleFields = document.querySelectorAll(".sle-only");
        sleFields.forEach(function (el) {
            el.style.display = isSle ? "block" : "none";
        });
    }

    function toggleDiskFields() {
        var layout = document.querySelector('input[name="disk_layout"]:checked').value;
        var multipartFields = document.querySelectorAll(".disk-multipart-fields");
        var multidiskFields = document.querySelectorAll(".disk-multidisk-fields");

        multipartFields.forEach(function (el) {
            el.style.display = (layout === "single-disk-multipart") ? "grid" : "none";
        });
        multidiskFields.forEach(function (el) {
            el.style.display = (layout === "multi-disk") ? "grid" : "none";
        });
    }

    function toggleStorageFields() {
        var provider = document.querySelector('input[name="storage_provider"]:checked').value;
        var longhornFields = document.getElementById("longhorn-fields");
        var localPathFields = document.getElementById("local-path-fields");

        longhornFields.style.display = (provider === "longhorn") ? "block" : "none";
        localPathFields.style.display = (provider === "local-path") ? "block" : "none";
    }

    function addWorkerNode() {
        var container = document.getElementById("worker-nodes");
        var index = workerCount;
        workerCount++;

        var nextNum = index + 1;
        var padded = nextNum < 10 ? "0" + nextNum : "" + nextNum;

        var div = document.createElement("div");
        div.className = "node-entry";
        div.setAttribute("data-index", index);
        div.innerHTML = `
            <h3>Worker ${nextNum} <button type="button" class="btn-remove-worker" title="Remove">&#x2715;</button></h3>
            <div class="form-row">
                <div class="form-group">
                    <label>Hostname</label>
                    <input type="text" name="worker_hostname_${index}" value="worker-${padded}" required>
                </div>
                <div class="form-group">
                    <label>IPv4</label>
                    <input type="text" name="worker_ipv4_${index}" value="192.168.1.${111 + index}" required>
                </div>
                <div class="form-group">
                    <label>IPv6</label>
                    <input type="text" name="worker_ipv6_${index}" value="fd00::${111 + index}" required>
                </div>
                <div class="form-group">
                    <label>MAC Address</label>
                    <input type="text" name="worker_mac_${index}" value="aa:bb:cc:dd:ee:${(index + 17).toString(16)}" required>
                </div>
                <div class="form-group">
                    <label>DHCPv6 DUID</label>
                    <input type="text" name="worker_duid_${index}" value="00:01:00:01:XX:XX:XX:XX:aa:bb:cc:dd:ee:${(index + 17).toString(16)}">
                </div>
            </div>
        `;
        container.appendChild(div);
    }

    function removeWorkerNode(btn) {
        var entry = btn.closest(".node-entry");
        if (entry && document.querySelectorAll("#worker-nodes .node-entry").length > 1) {
            entry.remove();
        }
    }

    // =========================================================================
    // Collect Form Data into Template Context
    // =========================================================================

    function collectFormData() {
        var form = document.getElementById("config-form");

        // Collect masters
        var masters = [];
        for (var i = 0; i < 3; i++) {
            masters.push({
                hostname: form.querySelector('[name="master_hostname_' + i + '"]').value,
                ipv4: form.querySelector('[name="master_ipv4_' + i + '"]').value,
                ipv6: form.querySelector('[name="master_ipv6_' + i + '"]').value,
                mac: form.querySelector('[name="master_mac_' + i + '"]').value,
                duid: form.querySelector('[name="master_duid_' + i + '"]').value
            });
        }

        // Collect workers
        var workers = [];
        var workerEntries = document.querySelectorAll("#worker-nodes .node-entry");
        workerEntries.forEach(function (entry) {
            var idx = entry.getAttribute("data-index");
            var hostname = entry.querySelector('[name="worker_hostname_' + idx + '"]');
            if (hostname) {
                workers.push({
                    hostname: hostname.value,
                    ipv4: entry.querySelector('[name="worker_ipv4_' + idx + '"]').value,
                    ipv6: entry.querySelector('[name="worker_ipv6_' + idx + '"]').value,
                    mac: entry.querySelector('[name="worker_mac_' + idx + '"]').value,
                    duid: entry.querySelector('[name="worker_duid_' + idx + '"]').value
                });
            }
        });

        // Build disable list
        var disableStr = form.querySelector('[name="k3s_disable"]').value;
        var disableList = disableStr ? disableStr.split(",").map(function (s) { return s.trim(); }) : [];

        // Build context
        return {
            os: {
                distribution: form.querySelector('[name="os_distribution"]').value
            },
            network: {
                interface: form.querySelector('[name="network_interface"]').value,
                domain: form.querySelector('[name="network_domain"]').value,
                dns_servers: [form.querySelector('[name="dns_server"]').value],
                gateway_ipv4: form.querySelector('[name="gateway_ipv4"]').value,
                subnet_mask_ipv4: parseInt(form.querySelector('[name="subnet_mask_ipv4"]').value),
                subnet_mask_ipv6: parseInt(form.querySelector('[name="subnet_mask_ipv6"]').value),
                ipv6_mode: form.querySelector('[name="ipv6_mode"]').value
            },
            vip: {
                ipv4: form.querySelector('[name="vip_ipv4"]').value,
                ipv6: form.querySelector('[name="vip_ipv6"]').value,
                hostname: form.querySelector('[name="vip_hostname"]').value
            },
            masters: masters,
            workers: workers,
            k3s: {
                version: form.querySelector('[name="k3s_version"]').value || "",
                token: form.querySelector('[name="k3s_token"]').value || "",
                api_port: parseInt(form.querySelector('[name="k3s_api_port"]').value),
                disable: disableList,
                cluster_cidr_v4: form.querySelector('[name="k3s_cluster_cidr_v4"]').value,
                cluster_cidr_v6: form.querySelector('[name="k3s_cluster_cidr_v6"]').value,
                service_cidr_v4: form.querySelector('[name="k3s_service_cidr_v4"]').value,
                service_cidr_v6: form.querySelector('[name="k3s_service_cidr_v6"]').value
            },
            haproxy: {
                frontend_port: parseInt(form.querySelector('[name="haproxy_frontend_port"]').value),
                stats_port: parseInt(form.querySelector('[name="haproxy_stats_port"]').value),
                stats_user: form.querySelector('[name="haproxy_stats_user"]').value,
                stats_password: form.querySelector('[name="haproxy_stats_password"]').value
            },
            keepalived: {
                router_id: parseInt(form.querySelector('[name="keepalived_router_id"]').value),
                auth_pass: form.querySelector('[name="keepalived_auth_pass"]').value,
                check_interval: 2,
                fall: 3,
                rise: 2
            },
            dhcp: {
                default_lease_time: parseInt(form.querySelector('[name="dhcp_default_lease_time"]').value),
                max_lease_time: parseInt(form.querySelector('[name="dhcp_max_lease_time"]').value)
            },
            ssh: {
                user: "root",
                port: parseInt(form.querySelector('[name="ssh_port"]').value) || 22,
                github_users: (form.querySelector('[name="ssh_github_users"]').value || "").split(",").map(function (s) { return s.trim(); }).filter(function (s) { return s !== ""; }),
                authorized_keys: (form.querySelector('[name="ssh_authorized_keys"]').value || "").split("\n").filter(function (l) { return l.trim() !== ""; }),
                disable_password_auth: form.querySelector('[name="ssh_disable_password_auth"]').value === "true"
            },
            storage: {
                disk_layout: document.querySelector('input[name="disk_layout"]:checked').value,
                os_disk: form.querySelector('[name="os_disk"]').value,
                os_root_size: form.querySelector('[name="os_root_size"]').value,
                os_root_size_mib: parseInt(form.querySelector('[name="os_root_size"]').value) * 1024 || 40960,
                rancher_size: form.querySelector('[name="rancher_size"]').value,
                rancher_size_mib: parseInt(form.querySelector('[name="rancher_size"]').value) * 1024 || 102400,
                data_disk: form.querySelector('[name="data_disk"]').value,
                storage_disk: form.querySelector('[name="storage_disk"]').value,
                storage_size: form.querySelector('[name="storage_size"]').value,
                provider: document.querySelector('input[name="storage_provider"]:checked').value,
                longhorn: {
                    version: form.querySelector('[name="longhorn_version"]').value || "",
                    replica_count: parseInt(form.querySelector('[name="longhorn_replica_count"]').value),
                    data_path: form.querySelector('[name="longhorn_data_path"]').value,
                    default_class: form.querySelector('[name="longhorn_default_class"]').value === "true",
                    ui_enabled: form.querySelector('[name="longhorn_ui_enabled"]').value === "true"
                },
                local_path: {
                    data_path: form.querySelector('[name="local_path_data_path"]').value,
                    default_class: form.querySelector('[name="local_path_default_class"]').value === "true"
                }
            }
        };
    }

    // =========================================================================
    // Template Rendering
    // =========================================================================

    function renderTemplates(context) {
        var env = new nunjucks.Environment(null, { autoescape: false });
        var files = {};

        // Single files (no per-node)
        var singleFiles = [
            "haproxy/haproxy.cfg",
            "network/dhcpd4-leases.conf",
            "network/dhcpd6-leases.conf",
            "network/dnsmasq-leases.conf",
            "network/hosts",
            "os/sysctl-k3s.conf",
            "os/ssh-authorized-keys",
            "os/sshd-hardening.conf",
            "variables.yaml"
        ];

        singleFiles.forEach(function (name) {
            var tmpl = TEMPLATES[name];
            if (tmpl) {
                files[name] = env.renderString(tmpl, context);
            }
        });

        // Per-master files
        context.masters.forEach(function (master, idx) {
            var nodeContext = Object.assign({}, context, {
                node: master,
                node_index: idx
            });

            // Keepalived
            var keepalivedPath = "keepalived/" + master.hostname + "/keepalived.conf";
            files[keepalivedPath] = env.renderString(TEMPLATES["keepalived.conf"], nodeContext);

            // K3s server config
            var k3sPath = "k3s/" + master.hostname + "/config.yaml";
            files[k3sPath] = env.renderString(TEMPLATES["k3s-server.yaml"], nodeContext);
        });

        // Per-worker files
        context.workers.forEach(function (worker, idx) {
            var nodeContext = Object.assign({}, context, {
                node: worker,
                node_index: idx
            });

            var k3sPath = "k3s/" + worker.hostname + "/config.yaml";
            files[k3sPath] = env.renderString(TEMPLATES["k3s-agent.yaml"], nodeContext);
        });

        // Disk partitioning (select template based on layout)
        var diskLayoutMap = {
            "single-root": "os/disk-single-root.xml",
            "single-disk-multipart": "os/disk-multipart.xml",
            "multi-disk": "os/disk-multidisk.xml"
        };
        var diskTemplateName = diskLayoutMap[context.storage.disk_layout] || "os/disk-multipart.xml";
        var diskTmpl = TEMPLATES[diskTemplateName];
        if (diskTmpl) {
            files["os/disk-partitioning.xml"] = env.renderString(diskTmpl, context);
        }

        // Disk Ignition config
        if (TEMPLATES["os/disk-ignition.json"]) {
            files["os/disk-ignition.json"] = env.renderString(TEMPLATES["os/disk-ignition.json"], context);
        }

        // Storage provider configs
        if (context.storage.provider === "longhorn" && TEMPLATES["storage/longhorn-values.yaml"]) {
            files["storage/longhorn-values.yaml"] = env.renderString(TEMPLATES["storage/longhorn-values.yaml"], context);
        }
        if (context.storage.provider === "local-path" && TEMPLATES["storage/storageclass-local-path.yaml"]) {
            files["storage/storageclass-local-path.yaml"] = env.renderString(TEMPLATES["storage/storageclass-local-path.yaml"], context);
        }

        return files;
    }

    // =========================================================================
    // Generate Handler
    // =========================================================================

    function handleGenerate() {
        try {
            var context = collectFormData();
            generatedFiles = renderTemplates(context);

            // Show output section
            var outputSection = document.getElementById("output-section");
            outputSection.style.display = "block";

            // Update summary
            var fileCount = Object.keys(generatedFiles).length;
            document.getElementById("output-summary").textContent =
                fileCount + " file(s) generated. Click a tab to preview, or download all as ZIP.";

            // Build tabs
            buildFileTabs();

            // Enable download button
            document.getElementById("btn-download").disabled = false;

            // Scroll to output
            outputSection.scrollIntoView({ behavior: "smooth" });
        } catch (err) {
            alert("Error generating configuration: " + err.message);
            console.error(err);
        }
    }

    // =========================================================================
    // File Preview Tabs
    // =========================================================================

    function buildFileTabs() {
        var tabBar = document.getElementById("tab-bar");
        tabBar.innerHTML = "";

        var fileNames = Object.keys(generatedFiles).sort();
        fileNames.forEach(function (name, idx) {
            var btn = document.createElement("button");
            btn.textContent = name;
            btn.setAttribute("data-file", name);
            if (idx === 0) btn.classList.add("active");
            btn.addEventListener("click", function () {
                selectTab(name);
            });
            tabBar.appendChild(btn);
        });

        // Show first file
        if (fileNames.length > 0) {
            showFileContent(fileNames[0]);
        }
    }

    function selectTab(fileName) {
        // Update active tab
        var tabs = document.querySelectorAll("#tab-bar button");
        tabs.forEach(function (tab) {
            tab.classList.toggle("active", tab.getAttribute("data-file") === fileName);
        });
        showFileContent(fileName);
    }

    function showFileContent(fileName) {
        var code = document.getElementById("file-code");
        code.textContent = generatedFiles[fileName] || "";
    }

    // =========================================================================
    // Download Handler
    // =========================================================================

    function handleDownload() {
        if (Object.keys(generatedFiles).length === 0) return;

        var zip = new JSZip();

        // Add all files to ZIP
        Object.keys(generatedFiles).forEach(function (path) {
            zip.file(path, generatedFiles[path]);
        });

        // Generate filename with version and date
        var now = new Date();
        var dateStr = now.getFullYear() +
            padZero(now.getMonth() + 1) +
            padZero(now.getDate()) + "-" +
            padZero(now.getHours()) +
            padZero(now.getMinutes()) +
            padZero(now.getSeconds());

        var fileName = ARCHIVE_PREFIX + "-v" + APP_VERSION + "-" + dateStr + ".zip";

        // Generate and save
        zip.generateAsync({ type: "blob" }).then(function (content) {
            saveAs(content, fileName);
        });
    }

    function padZero(n) {
        return n < 10 ? "0" + n : "" + n;
    }

})();
