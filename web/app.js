/* K3s Configuration Generator - Application Logic (v2.0.0) */

(function () {
    "use strict";

    // =========================================================================
    // Constants
    // =========================================================================

    var APP_VERSION = "2.0.0";
    var ARCHIVE_PREFIX = "k3s-config";

    // =========================================================================
    // State
    // =========================================================================

    var generatedFiles = {};
    var workerCount = 1;
    var validationDebounceTimers = {};

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
        document.getElementById("ipv6-mode").addEventListener("change", toggleIPv6Fields);
        document.getElementById("generate-all-duids").addEventListener("click", handleGenerateAllDuids);

        // Disk layout radio buttons
        document.querySelectorAll('input[name="disk_layout"]').forEach(function (radio) {
            radio.addEventListener("change", toggleDiskFields);
        });

        // Storage provider radio buttons
        document.querySelectorAll('input[name="storage_provider"]').forEach(function (radio) {
            radio.addEventListener("change", toggleStorageFields);
        });

        // Delegated click handlers
        document.addEventListener("click", function (e) {
            if (e.target.classList.contains("btn-remove-worker")) {
                removeWorkerNode(e.target);
            }
            if (e.target.classList.contains("btn-generate-duid")) {
                handleGenerateDuid(e.target);
            }
        });

        // Live validation on input
        document.addEventListener("input", function (e) {
            var input = e.target;
            if (input.tagName === "INPUT" && input.getAttribute("data-validate")) {
                debouncedValidateField(input);
            }
        });

        // Immediate validation on change (selects)
        document.addEventListener("change", function (e) {
            var el = e.target;
            if (el.tagName === "SELECT" && el.getAttribute("data-validate")) {
                validateAndShowField(el);
            }
        });

        // Initialize visibility states
        toggleIPv6Fields();
    });

    // =========================================================================
    // Validation
    // =========================================================================

    var VALIDATORS = {
        required: function (val) {
            if (!val || !val.trim()) { return "This field is required"; }
            return "";
        },
        ipv4: function (val) {
            if (!val || !val.trim()) { return "This field is required"; }
            var parts = val.trim().split(".");
            if (parts.length !== 4) { return "Invalid IPv4 address"; }
            for (var i = 0; i < 4; i++) {
                var n = parseInt(parts[i], 10);
                if (isNaN(n) || n < 0 || n > 255 || parts[i] !== String(n)) {
                    return "Invalid IPv4 address";
                }
            }
            return "";
        },
        ipv6: function (val) {
            if (!val || !val.trim()) { return "This field is required"; }
            var v = val.trim();
            // Basic IPv6 validation: hex groups separated by colons, with :: shorthand
            if (!/^[0-9a-fA-F:]+$/.test(v)) { return "Invalid IPv6 address"; }
            if (v.indexOf(":::") !== -1) { return "Invalid IPv6 address"; }
            var doubleColon = (v.match(/::/g) || []).length;
            if (doubleColon > 1) { return "Invalid IPv6 address (multiple ::)"; }
            var groups = v.split(":");
            if (doubleColon === 0 && groups.length !== 8) { return "Invalid IPv6 address (need 8 groups or use ::)"; }
            for (var i = 0; i < groups.length; i++) {
                if (groups[i].length > 4) { return "Invalid IPv6 address (group too long)"; }
            }
            return "";
        },
        mac: function (val) {
            if (!val || !val.trim()) { return "This field is required"; }
            if (!/^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/.test(val.trim())) {
                return "Invalid MAC address (format: aa:bb:cc:dd:ee:ff)";
            }
            return "";
        },
        hostname: function (val) {
            if (!val || !val.trim()) { return "This field is required"; }
            if (!/^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$/.test(val.trim())) {
                return "Invalid hostname (alphanumeric and hyphens only)";
            }
            if (val.trim().length > 63) { return "Hostname too long (max 63 chars)"; }
            return "";
        },
        domain: function (val) {
            if (!val || !val.trim()) { return "This field is required"; }
            if (!/^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$/.test(val.trim())) {
                return "Invalid domain name";
            }
            return "";
        },
        port: function (val) {
            var n = parseInt(val, 10);
            if (isNaN(n) || n < 1 || n > 65535) { return "Port must be 1-65535"; }
            return "";
        },
        cidr4: function (val) {
            var n = parseInt(val, 10);
            if (isNaN(n) || n < 8 || n > 30) { return "CIDR must be 8-30"; }
            return "";
        },
        cidr6: function (val) {
            var n = parseInt(val, 10);
            if (isNaN(n) || n < 16 || n > 128) { return "CIDR must be 16-128"; }
            return "";
        },
        cidr: function (val) {
            if (!val || !val.trim()) { return "This field is required"; }
            if (!/^[0-9a-fA-F.:]+\/\d{1,3}$/.test(val.trim())) {
                return "Invalid CIDR notation (e.g., 10.42.0.0/16)";
            }
            return "";
        },
        routerid: function (val) {
            var n = parseInt(val, 10);
            if (isNaN(n) || n < 1 || n > 255) { return "Router ID must be 1-255"; }
            return "";
        },
        positive: function (val) {
            var n = parseInt(val, 10);
            if (isNaN(n) || n < 1) { return "Must be a positive number"; }
            return "";
        }
    };

    function validateSingleField(input) {
        var type = input.getAttribute("data-validate");
        if (!type || !VALIDATORS[type]) { return ""; }

        // Skip validation for hidden fields
        var group = input.closest(".form-group");
        if (group && group.offsetParent === null) { return ""; }

        return VALIDATORS[type](input.value);
    }

    function showFieldError(input, msg) {
        var group = input.closest(".form-group");
        if (!group) { return; }
        var errSpan = group.querySelector(".error-message");
        if (msg) {
            group.classList.add("has-error");
            group.classList.remove("has-success");
            if (errSpan) { errSpan.textContent = msg; }
        } else {
            group.classList.remove("has-error");
            if (input.value && input.value.trim()) {
                group.classList.add("has-success");
            } else {
                group.classList.remove("has-success");
            }
            if (errSpan) { errSpan.textContent = ""; }
        }
    }

    function validateAndShowField(input) {
        var msg = validateSingleField(input);
        showFieldError(input, msg);
        return msg;
    }

    function debouncedValidateField(input) {
        var key = input.name || input.id || Math.random();
        if (validationDebounceTimers[key]) {
            clearTimeout(validationDebounceTimers[key]);
        }
        validationDebounceTimers[key] = setTimeout(function () {
            validateAndShowField(input);
        }, 300);
    }

    function validateForm() {
        var errors = [];
        var allInputs = document.querySelectorAll("#config-form input[data-validate], #config-form select[data-validate]");

        allInputs.forEach(function (input) {
            var msg = validateAndShowField(input);
            if (msg) {
                errors.push({ field: input, message: msg });
            }
        });

        // Cross-field: duplicate hostnames
        var hostnames = {};
        document.querySelectorAll('input[name^="master_hostname_"], input[name^="worker_hostname_"]').forEach(function (input) {
            if (input.offsetParent === null) { return; }
            var val = input.value.trim().toLowerCase();
            if (val) {
                if (hostnames[val]) {
                    showFieldError(input, "Duplicate hostname");
                    errors.push({ field: input, message: "Duplicate hostname" });
                } else {
                    hostnames[val] = true;
                }
            }
        });

        // Cross-field: duplicate IPv4
        var ipv4s = {};
        document.querySelectorAll('input[name^="master_ipv4_"], input[name^="worker_ipv4_"]').forEach(function (input) {
            if (input.offsetParent === null) { return; }
            var val = input.value.trim();
            if (val) {
                if (ipv4s[val]) {
                    showFieldError(input, "Duplicate IPv4 address");
                    errors.push({ field: input, message: "Duplicate IPv4 address" });
                } else {
                    ipv4s[val] = true;
                }
            }
        });

        // Cross-field: duplicate MACs
        var macs = {};
        document.querySelectorAll('input[name^="master_mac_"], input[name^="worker_mac_"]').forEach(function (input) {
            if (input.offsetParent === null) { return; }
            var val = input.value.trim().toLowerCase();
            if (val) {
                if (macs[val]) {
                    showFieldError(input, "Duplicate MAC address");
                    errors.push({ field: input, message: "Duplicate MAC address" });
                } else {
                    macs[val] = true;
                }
            }
        });

        // Cross-field: VIP must not be a node IP
        var vipV4 = document.querySelector('[name="vip_ipv4"]').value.trim();
        if (ipv4s[vipV4]) {
            var vipInput = document.querySelector('[name="vip_ipv4"]');
            showFieldError(vipInput, "VIP must not be a node IP");
            errors.push({ field: vipInput, message: "VIP must not be a node IP" });
        }

        return errors;
    }

    function showValidationBanner(errors) {
        var banner = document.getElementById("validation-banner");
        var text = document.getElementById("validation-text");
        banner.classList.remove("is-valid", "is-invalid");

        if (errors.length === 0) {
            banner.classList.add("is-valid");
            text.textContent = "\u2713 All fields valid \u2014 configuration generated successfully.";
        } else {
            banner.classList.add("is-invalid");
            text.textContent = "\u2717 " + errors.length + " validation error(s) found. Please fix the highlighted fields.";
        }
        banner.style.display = "block";
    }

    // =========================================================================
    // IPv6 Toggle
    // =========================================================================

    function toggleIPv6Fields() {
        var mode = document.getElementById("ipv6-mode").value;
        var ipv6Enabled = (mode !== "disabled");
        var dhcpv6Enabled = (mode === "dhcpv6" || mode === "both");

        // Show/hide IPv6 fields
        document.querySelectorAll(".ipv6-field").forEach(function (el) {
            el.style.display = ipv6Enabled ? "" : "none";
            // Toggle required on hidden inputs
            var inputs = el.querySelectorAll("input[required]");
            inputs.forEach(function (input) {
                if (!ipv6Enabled) {
                    input.removeAttribute("required");
                    input.setAttribute("data-was-required", "true");
                } else if (input.getAttribute("data-was-required")) {
                    input.setAttribute("required", "");
                }
            });
        });

        // Show/hide DHCPv6-specific fields (DUID, generate buttons)
        document.querySelectorAll(".dhcpv6-field").forEach(function (el) {
            el.style.display = dhcpv6Enabled ? "" : "none";
        });
    }

    // =========================================================================
    // DUID Generation
    // =========================================================================

    function generateDuidLLT(mac) {
        // DUID-LLT: type(2) + hw-type(2) + time(4) + link-layer(6)
        // Time = seconds since 2000-01-01 00:00:00 UTC
        var epoch2000 = Date.UTC(2000, 0, 1, 0, 0, 0) / 1000;
        var now = Math.floor(Date.now() / 1000);
        var timeSince2000 = now - epoch2000;

        // Convert timestamp to 4 hex bytes
        var timeHex = timeSince2000.toString(16).padStart(8, "0");
        var t = timeHex.match(/.{2}/g).join(":");

        return "00:01:00:01:" + t + ":" + mac.toLowerCase().trim();
    }

    function handleGenerateDuid(button) {
        var entry = button.closest(".node-entry");
        if (!entry) { return; }

        var macInput = entry.querySelector('input[name*="_mac_"]');
        var duidInput = entry.querySelector('input[name*="_duid_"]');
        if (!macInput || !duidInput) { return; }

        var mac = macInput.value.trim();
        if (!/^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/.test(mac)) {
            showFieldError(macInput, "Enter a valid MAC address first");
            return;
        }

        duidInput.value = generateDuidLLT(mac);
    }

    function handleGenerateAllDuids() {
        document.querySelectorAll(".node-entry").forEach(function (entry) {
            var macInput = entry.querySelector('input[name*="_mac_"]');
            var duidInput = entry.querySelector('input[name*="_duid_"]');
            if (!macInput || !duidInput) { return; }

            var mac = macInput.value.trim();
            if (/^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/.test(mac)) {
                duidInput.value = generateDuidLLT(mac);
            }
        });
    }

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

        var ipv6Mode = document.getElementById("ipv6-mode").value;
        var ipv6Enabled = (ipv6Mode !== "disabled");
        var dhcpv6Enabled = (ipv6Mode === "dhcpv6" || ipv6Mode === "both");
        var ipv6Display = ipv6Enabled ? "" : "display:none;";
        var dhcpv6Display = dhcpv6Enabled ? "" : "display:none;";

        var div = document.createElement("div");
        div.className = "node-entry";
        div.setAttribute("data-index", index);
        div.innerHTML =
            '<h3>Worker ' + nextNum + ' <button type="button" class="btn-remove-worker" title="Remove">&#x2715;</button></h3>' +
            '<div class="form-row">' +
                '<div class="form-group">' +
                    '<label>Hostname</label>' +
                    '<input type="text" name="worker_hostname_' + index + '" value="worker-' + padded + '" required data-validate="hostname">' +
                    '<span class="error-message"></span>' +
                '</div>' +
                '<div class="form-group">' +
                    '<label>IPv4</label>' +
                    '<input type="text" name="worker_ipv4_' + index + '" value="192.168.1.' + (111 + index) + '" required data-validate="ipv4">' +
                    '<span class="error-message"></span>' +
                '</div>' +
                '<div class="form-group ipv6-field" style="' + ipv6Display + '">' +
                    '<label>IPv6</label>' +
                    '<input type="text" name="worker_ipv6_' + index + '" value="fd00::' + (111 + index) + '"' + (ipv6Enabled ? ' required' : '') + ' data-validate="ipv6">' +
                    '<span class="error-message"></span>' +
                '</div>' +
                '<div class="form-group">' +
                    '<label>MAC Address</label>' +
                    '<input type="text" name="worker_mac_' + index + '" value="aa:bb:cc:dd:ee:' + (index + 17).toString(16).padStart(2, "0") + '" required data-validate="mac">' +
                    '<span class="error-message"></span>' +
                '</div>' +
                '<div class="form-group ipv6-field dhcpv6-field" style="' + dhcpv6Display + '">' +
                    '<label>DHCPv6 DUID</label>' +
                    '<input type="text" name="worker_duid_' + index + '" value="00:01:00:01:XX:XX:XX:XX:aa:bb:cc:dd:ee:' + (index + 17).toString(16).padStart(2, "0") + '">' +
                    '<button type="button" class="btn-generate-duid" title="Generate DUID-LLT from MAC address">Generate</button>' +
                    '<span class="error-message"></span>' +
                '</div>' +
            '</div>' +
            '<details class="node-advanced">' +
                '<summary>Advanced: Per-Node Hardware</summary>' +
                '<div class="advanced-content">' +
                    '<div class="form-row">' +
                        '<div class="form-group">' +
                            '<label>Network Interface</label>' +
                            '<input type="text" name="worker_net_interface_' + index + '" placeholder="Leave empty for global default, or \'auto\'">' +
                        '</div>' +
                        '<div class="form-group">' +
                            '<label>OS Disk Device</label>' +
                            '<input type="text" name="worker_os_disk_' + index + '" placeholder="Leave empty for global default, or \'auto\'">' +
                        '</div>' +
                    '</div>' +
                '</div>' +
            '</details>';
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
        var ipv6Mode = form.querySelector('[name="ipv6_mode"]').value;
        var ipv6Enabled = (ipv6Mode !== "disabled");
        var globalInterface = form.querySelector('[name="network_interface"]').value;
        var globalOsDisk = form.querySelector('[name="os_disk"]').value;

        // Collect masters
        var masters = [];
        for (var i = 0; i < 3; i++) {
            var nodeIface = form.querySelector('[name="master_net_interface_' + i + '"]');
            var nodeOsDisk = form.querySelector('[name="master_os_disk_' + i + '"]');
            masters.push({
                hostname: form.querySelector('[name="master_hostname_' + i + '"]').value,
                ipv4: form.querySelector('[name="master_ipv4_' + i + '"]').value,
                ipv6: ipv6Enabled ? form.querySelector('[name="master_ipv6_' + i + '"]').value : "",
                mac: form.querySelector('[name="master_mac_' + i + '"]').value,
                duid: ipv6Enabled ? form.querySelector('[name="master_duid_' + i + '"]').value : "",
                net_interface: (nodeIface && nodeIface.value) ? nodeIface.value : "",
                os_disk: (nodeOsDisk && nodeOsDisk.value) ? nodeOsDisk.value : ""
            });
        }

        // Collect workers
        var workers = [];
        var workerEntries = document.querySelectorAll("#worker-nodes .node-entry");
        workerEntries.forEach(function (entry) {
            var idx = entry.getAttribute("data-index");
            var hostname = entry.querySelector('[name="worker_hostname_' + idx + '"]');
            if (hostname) {
                var wIface = entry.querySelector('[name="worker_net_interface_' + idx + '"]');
                var wOsDisk = entry.querySelector('[name="worker_os_disk_' + idx + '"]');
                workers.push({
                    hostname: hostname.value,
                    ipv4: entry.querySelector('[name="worker_ipv4_' + idx + '"]').value,
                    ipv6: ipv6Enabled ? entry.querySelector('[name="worker_ipv6_' + idx + '"]').value : "",
                    mac: entry.querySelector('[name="worker_mac_' + idx + '"]').value,
                    duid: ipv6Enabled ? entry.querySelector('[name="worker_duid_' + idx + '"]').value : "",
                    net_interface: (wIface && wIface.value) ? wIface.value : "",
                    os_disk: (wOsDisk && wOsDisk.value) ? wOsDisk.value : ""
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
                interface: globalInterface,
                domain: form.querySelector('[name="network_domain"]').value,
                dns_servers: [form.querySelector('[name="dns_server"]').value],
                gateway_ipv4: form.querySelector('[name="gateway_ipv4"]').value,
                subnet_mask_ipv4: parseInt(form.querySelector('[name="subnet_mask_ipv4"]').value),
                subnet_mask_ipv6: ipv6Enabled ? parseInt(form.querySelector('[name="subnet_mask_ipv6"]').value) : 64,
                ipv6_mode: ipv6Mode,
                ipv6_enabled: ipv6Enabled
            },
            vip: {
                ipv4: form.querySelector('[name="vip_ipv4"]').value,
                ipv6: ipv6Enabled ? form.querySelector('[name="vip_ipv6"]').value : "",
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
                cluster_cidr_v6: ipv6Enabled ? form.querySelector('[name="k3s_cluster_cidr_v6"]').value : "",
                service_cidr_v4: form.querySelector('[name="k3s_service_cidr_v4"]').value,
                service_cidr_v6: ipv6Enabled ? form.querySelector('[name="k3s_service_cidr_v6"]').value : ""
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
                os_disk: globalOsDisk,
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
            "network/dnsmasq-leases.conf",
            "network/hosts",
            "os/sysctl-k3s.conf",
            "os/ssh-authorized-keys",
            "os/sshd-hardening.conf",
            "network/router-checklist.md",
            "variables.yaml"
        ];

        // Conditionally include DHCPv6 leases
        if (context.network.ipv6_enabled && (context.network.ipv6_mode === "dhcpv6" || context.network.ipv6_mode === "both")) {
            singleFiles.push("network/dhcpd6-leases.conf");
        }

        singleFiles.forEach(function (name) {
            var tmpl = TEMPLATES[name];
            if (tmpl) {
                files[name] = env.renderString(tmpl, context);
            }
        });

        // Per-master files
        context.masters.forEach(function (master, idx) {
            var resolvedIface = master.net_interface || context.network.interface;
            var resolvedOsDisk = master.os_disk || context.storage.os_disk;
            var nodeContext = Object.assign({}, context, {
                node: master,
                node_index: idx,
                resolved_interface: resolvedIface,
                resolved_os_disk: resolvedOsDisk
            });

            // Keepalived
            var keepalivedPath = "keepalived/" + master.hostname + "/keepalived.conf";
            files[keepalivedPath] = env.renderString(TEMPLATES["keepalived.conf"], nodeContext);

            // K3s server config
            var k3sPath = "k3s/" + master.hostname + "/config.yaml";
            files[k3sPath] = env.renderString(TEMPLATES["k3s-server.yaml"], nodeContext);

            // Per-node disk partitioning
            var diskLayoutMap = {
                "single-root": "os/disk-single-root.xml",
                "single-disk-multipart": "os/disk-multipart.xml",
                "multi-disk": "os/disk-multidisk.xml"
            };
            var diskTemplateName = diskLayoutMap[context.storage.disk_layout] || "os/disk-multipart.xml";
            var diskTmpl = TEMPLATES[diskTemplateName];
            if (diskTmpl) {
                files["os/" + master.hostname + "/disk-partitioning.xml"] = env.renderString(diskTmpl, nodeContext);
            }
            if (TEMPLATES["os/disk-ignition.json"]) {
                files["os/" + master.hostname + "/disk-ignition.json"] = env.renderString(TEMPLATES["os/disk-ignition.json"], nodeContext);
            }
        });

        // Per-worker files
        context.workers.forEach(function (worker, idx) {
            var resolvedIface = worker.net_interface || context.network.interface;
            var resolvedOsDisk = worker.os_disk || context.storage.os_disk;
            var nodeContext = Object.assign({}, context, {
                node: worker,
                node_index: idx,
                resolved_interface: resolvedIface,
                resolved_os_disk: resolvedOsDisk
            });

            var k3sPath = "k3s/" + worker.hostname + "/config.yaml";
            files[k3sPath] = env.renderString(TEMPLATES["k3s-agent.yaml"], nodeContext);

            // Per-node disk partitioning
            var diskLayoutMap = {
                "single-root": "os/disk-single-root.xml",
                "single-disk-multipart": "os/disk-multipart.xml",
                "multi-disk": "os/disk-multidisk.xml"
            };
            var diskTemplateName = diskLayoutMap[context.storage.disk_layout] || "os/disk-multipart.xml";
            var diskTmpl = TEMPLATES[diskTemplateName];
            if (diskTmpl) {
                files["os/" + worker.hostname + "/disk-partitioning.xml"] = env.renderString(diskTmpl, nodeContext);
            }
            if (TEMPLATES["os/disk-ignition.json"]) {
                files["os/" + worker.hostname + "/disk-ignition.json"] = env.renderString(TEMPLATES["os/disk-ignition.json"], nodeContext);
            }
        });

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
        // Validate first
        var errors = validateForm();
        showValidationBanner(errors);

        if (errors.length > 0) {
            // Scroll to first error
            errors[0].field.scrollIntoView({ behavior: "smooth", block: "center" });
            errors[0].field.focus();
            return;
        }

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
            if (idx === 0) { btn.classList.add("active"); }
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
        if (Object.keys(generatedFiles).length === 0) { return; }

        var zip = new JSZip();

        Object.keys(generatedFiles).forEach(function (path) {
            zip.file(path, generatedFiles[path]);
        });

        var now = new Date();
        var dateStr = now.getFullYear() +
            padZero(now.getMonth() + 1) +
            padZero(now.getDate()) + "-" +
            padZero(now.getHours()) +
            padZero(now.getMinutes()) +
            padZero(now.getSeconds());

        var fileName = ARCHIVE_PREFIX + "-v" + APP_VERSION + "-" + dateStr + ".zip";

        zip.generateAsync({ type: "blob" }).then(function (content) {
            saveAs(content, fileName);
        });
    }

    function padZero(n) {
        return n < 10 ? "0" + n : "" + n;
    }

})();
