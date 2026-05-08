import os
from flask import Flask, request, jsonify, render_template_string
from flask_cors import CORS
from datetime import datetime

app = Flask(__name__)
CORS(app)

# Get port from environment variable or use default 5000
PORT = int(os.environ.get('API_PORT', 8080))

# In-memory database
db = {
    "customers": [],
    "vpns": [],
    "routes": []
}

# ID counters
customer_id_counter = 0
vpn_id_counter = 0
route_id_counter = 0

# Template HTML untuk Web UI
HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="id">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VPN Management System</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #f0f2f5; padding: 20px; }
        .header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 30px; border-radius: 10px; margin-bottom: 30px; text-align: center; }
        .header h1 { font-size: 2em; margin-bottom: 10px; }
        .container { max-width: 1200px; margin: 0 auto; }
        .section { background: white; padding: 25px; border-radius: 10px; margin-bottom: 20px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .section h2 { color: #667eea; margin-bottom: 20px; padding-bottom: 10px; border-bottom: 2px solid #667eea; }
        .form-group { margin-bottom: 15px; }
        .form-group label { display: block; margin-bottom: 5px; font-weight: bold; color: #333; }
        .form-group input, .form-group select, .form-group textarea { width: 100%; padding: 12px; border: 1px solid #ddd; border-radius: 6px; font-size: 14px; }
        .form-group input:focus, .form-group select:focus { outline: none; border-color: #667eea; }
        .btn { padding: 12px 24px; border: none; border-radius: 6px; cursor: pointer; font-size: 14px; font-weight: bold; transition: all 0.3s; margin: 5px; }
        .btn-primary { background: #667eea; color: white; }
        .btn-primary:hover { background: #5568d3; }
        .btn-success { background: #28a745; color: white; }
        .btn-success:hover { background: #218838; }
        .btn-danger { background: #dc3545; color: white; }
        .btn-danger:hover { background: #c82333; }
        .btn-info { background: #17a2b8; color: white; }
        .btn-info:hover { background: #138496; }
        .data-list { margin-top: 20px; }
        .data-item { background: #f8f9fa; padding: 15px; border-radius: 6px; margin-bottom: 10px; border-left: 4px solid #667eea; }
        .data-item h4 { color: #333; margin-bottom: 10px; }
        .data-item p { color: #666; margin: 5px 0; font-size: 14px; }
        .badge { display: inline-block; padding: 4px 12px; border-radius: 20px; font-size: 12px; font-weight: bold; }
        .badge-customer { background: #667eea; color: white; }
        .badge-vpn { background: #28a745; color: white; }
        .badge-route { background: #17a2b8; color: white; }
        .tabs { display: flex; margin-bottom: 20px; }
        .tab { padding: 12px 24px; background: #e9ecef; border: none; cursor: pointer; font-weight: bold; }
        .tab.active { background: #667eea; color: white; }
        .tab:first-child { border-radius: 6px 0 0 6px; }
        .tab:last-child { border-radius: 0 6px 6px 0; }
        .hidden { display: none; }
        .result-box { background: #2d3748; color: #68d391; padding: 20px; border-radius: 6px; font-family: monospace; white-space: pre-wrap; margin-top: 20px; max-height: 400px; overflow-y: auto; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; }
        .stat-card { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 20px; border-radius: 10px; text-align: center; }
        .stat-card h3 { font-size: 2.5em; margin-bottom: 5px; }
        .stat-card p { opacity: 0.9; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🌐 VPN Management System</h1>
            <p>Kelola Customers, VPNs, dan Routes dengan mudah</p>
        </div>

        <!-- Statistics -->
        <div class="grid" style="margin-bottom: 20px;">
            <div class="stat-card">
                <h3 id="stat-customers">0</h3>
                <p>Total Customers</p>
            </div>
            <div class="stat-card">
                <h3 id="stat-vpns">0</h3>
                <p>Total VPNs</p>
            </div>
            <div class="stat-card">
                <h3 id="stat-routes">0</h3>
                <p>Total Routes</p>
            </div>
        </div>

        <!-- Tabs -->
        <div class="tabs">
            <button class="tab active" onclick="showTab('customers')">👥 Customers</button>
            <button class="tab" onclick="showTab('vpns')">🔒 VPNs</button>
            <button class="tab" onclick="showTab('routes')">🛣️ Routes</button>
        </div>

        <!-- Customers Section -->
        <div id="tab-customers" class="section">
            <h2>👥 Manage Customers/Instances</h2>
            <div class="form-group">
                <label>Nama Customer</label>
                <input type="text" id="customer-name" placeholder="Contoh: PT. ABC Corporation">
            </div>
            <div class="form-group">
                <label>Deskripsi</label>
                <textarea id="customer-desc" rows="2" placeholder="Deskripsi customer"></textarea>
            </div>
            <div class="form-group">
                <label>IP Address (optional)</label>
                <input type="text" id="customer-ip" placeholder="Contoh: 192.168.1.100">
            </div>
            <button class="btn btn-success" onclick="addCustomer()">➕ Add Customer</button>
            <button class="btn btn-info" onclick="loadCustomers()">🔄 Refresh List</button>
            
            <div class="data-list" id="customer-list"></div>
        </div>

        <!-- VPNs Section -->
        <div id="tab-vpns" class="section hidden">
            <h2>🔒 Manage VPNs</h2>
            <div class="form-group">
                <label>Pilih Customer</label>
                <select id="vpn-customer-id"></select>
            </div>
            <div class="form-group">
                <label>Nama VPN</label>
                <input type="text" id="vpn-name" placeholder="Contoh: VPN-Office-Jakarta">
            </div>
            <div class="form-group">
                <label>Tipe VPN</label>
                <select id="vpn-type">
                    <option value="openvpn">OpenVPN</option>
                    <option value="wireguard">WireGuard</option>
                    <option value="ipsec">IPSec</option>
                    <option value="l2tp">L2TP</option>
                </select>
            </div>
            <div class="form-group">
                <label>VPN Network CIDR</label>
                <input type="text" id="vpn-network" placeholder="Contoh: 10.0.1.0/24">
            </div>
            <button class="btn btn-success" onclick="addVPN()">➕ Add VPN</button>
            <button class="btn btn-info" onclick="loadVPNs()">🔄 Refresh List</button>
            
            <div class="data-list" id="vpn-list"></div>
        </div>

        <!-- Routes Section -->
        <div id="tab-routes" class="section hidden">
            <h2>🛣️ Manage Routes</h2>
            <div class="form-group">
                <label>Pilih VPN</label>
                <select id="route-vpn-id"></select>
            </div>
            <div class="form-group">
                <label>Destination Network</label>
                <input type="text" id="route-destination" placeholder="Contoh: 192.168.100.0/24">
            </div>
            <div class="form-group">
                <label>Gateway/Next Hop</label>
                <input type="text" id="route-gateway" placeholder="Contoh: 10.0.1.1">
            </div>
            <div class="form-group">
                <label>Deskripsi Route</label>
                <textarea id="route-desc" rows="2" placeholder="Deskripsi route"></textarea>
            </div>
            <button class="btn btn-success" onclick="addRoute()">➕ Add Route</button>
            <button class="btn btn-info" onclick="loadRoutes()">🔄 Refresh List</button>
            
            <div class="data-list" id="route-list"></div>
        </div>

        <!-- API Result -->
        <div class="section">
            <h2>📊 API Response</h2>
            <div class="result-box" id="api-result">Response akan muncul di sini...</div>
        </div>
    </div>

    <script>
        let customers = [];
        let vpns = [];
        let routes = [];

        function showTab(tabName) {
            document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
            document.querySelectorAll('.section[id^="tab-"]').forEach(s => s.classList.add('hidden'));
            event.target.classList.add('active');
            document.getElementById('tab-' + tabName).classList.remove('hidden');
            
            if (tabName === 'customers') loadCustomers();
            if (tabName === 'vpns') { loadCustomersForDropdown(); loadVPNs(); }
            if (tabName === 'routes') { loadVPNsForDropdown(); loadRoutes(); }
        }

        function showResult(data) {
            document.getElementById('api-result').textContent = JSON.stringify(data, null, 2);
        }

        function updateStats() {
            document.getElementById('stat-customers').textContent = customers.length;
            document.getElementById('stat-vpns').textContent = vpns.length;
            document.getElementById('stat-routes').textContent = routes.length;
        }

        // CUSTOMERS
        async function loadCustomers() {
            const res = await fetch('/api/customers');
            const data = await res.json();
            customers = data.data || [];
            renderCustomers();
            updateStats();
        }

        function renderCustomers() {
            const container = document.getElementById('customer-list');
            if (customers.length === 0) {
                container.innerHTML = '<p style="color:#666;padding:20px;text-align:center;">Belum ada customer</p>';
                return;
            }
            container.innerHTML = customers.map(c => `
                <div class="data-item">
                    <h4><span class="badge badge-customer">ID: ${c.id}</span> ${c.name}</h4>
                    <p><strong>Deskripsi:</strong> ${c.description || '-'}</p>
                    <p><strong>IP Address:</strong> ${c.ip_address || '-'}</p>
                    <p><strong>Created:</strong> ${c.created_at}</p>
                    <p><strong>VPN Count:</strong> ${c.vpn_count || 0}</p>
                    <button class="btn btn-danger" onclick="deleteCustomer(${c.id})">🗑️ Delete Customer</button>
                </div>
            `).join('');
        }

        async function addCustomer() {
            const name = document.getElementById('customer-name').value;
            const description = document.getElementById('customer-desc').value;
            const ip_address = document.getElementById('customer-ip').value;

            if (!name) { alert('Nama customer wajib diisi!'); return; }

            const res = await fetch('/api/customers', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ name, description, ip_address })
            });
            const data = await res.json();
            showResult(data);
            if (data.success) {
                document.getElementById('customer-name').value = '';
                document.getElementById('customer-desc').value = '';
                document.getElementById('customer-ip').value = '';
                loadCustomers();
            }
        }

        async function deleteCustomer(id) {
            if (!confirm('Yakin ingin delete customer ini? Semua VPN dan route terkait akan terhapus!')) return;
            const res = await fetch(`/api/customers/${id}`, { method: 'DELETE' });
            const data = await res.json();
            showResult(data);
            if (data.success) loadCustomers();
        }

        async function loadCustomersForDropdown() {
            const select = document.getElementById('vpn-customer-id');
            select.innerHTML = '<option value="">-- Pilih Customer --</option>' +
                customers.map(c => `<option value="${c.id}">${c.name}</option>`).join('');
        }

        // VPNS
        async function loadVPNs() {
            const res = await fetch('/api/vpns');
            const data = await res.json();
            vpns = data.data || [];
            renderVPNs();
            updateStats();
        }

        function renderVPNs() {
            const container = document.getElementById('vpn-list');
            if (vpns.length === 0) {
                container.innerHTML = '<p style="color:#666;padding:20px;text-align:center;">Belum ada VPN</p>';
                return;
            }
            container.innerHTML = vpns.map(v => `
                <div class="data-item">
                    <h4><span class="badge badge-vpn">ID: ${v.id}</span> ${v.name}</h4>
                    <p><strong>Customer:</strong> ${v.customer_name} (ID: ${v.customer_id})</p>
                    <p><strong>Type:</strong> ${v.type}</p>
                    <p><strong>Network:</strong> ${v.network || '-'}</p>
                    <p><strong>Created:</strong> ${v.created_at}</p>
                    <p><strong>Route Count:</strong> ${v.route_count || 0}</p>
                    <button class="btn btn-danger" onclick="deleteVPN(${v.id})">🗑️ Delete VPN</button>
                </div>
            `).join('');
        }

        async function addVPN() {
            const customer_id = document.getElementById('vpn-customer-id').value;
            const name = document.getElementById('vpn-name').value;
            const type = document.getElementById('vpn-type').value;
            const network = document.getElementById('vpn-network').value;

            if (!customer_id) { alert('Pilih customer terlebih dahulu!'); return; }
            if (!name) { alert('Nama VPN wajib diisi!'); return; }

            const res = await fetch(`/api/customers/${customer_id}/vpns`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ name, type, network })
            });
            const data = await res.json();
            showResult(data);
            if (data.success) {
                document.getElementById('vpn-name').value = '';
                document.getElementById('vpn-network').value = '';
                loadVPNs();
            }
        }

        async function deleteVPN(id) {
            if (!confirm('Yakin ingin delete VPN ini? Semua route terkait akan terhapus!')) return;
            const res = await fetch(`/api/vpns/${id}`, { method: 'DELETE' });
            const data = await res.json();
            showResult(data);
            if (data.success) loadVPNs();
        }

        async function loadVPNsForDropdown() {
            const select = document.getElementById('route-vpn-id');
            select.innerHTML = '<option value="">-- Pilih VPN --</option>' +
                vpns.map(v => `<option value="${v.id}">${v.name} (${v.customer_name})</option>`).join('');
        }

        // ROUTES
        async function loadRoutes() {
            const res = await fetch('/api/routes');
            const data = await res.json();
            routes = data.data || [];
            renderRoutes();
            updateStats();
        }

        function renderRoutes() {
            const container = document.getElementById('route-list');
            if (routes.length === 0) {
                container.innerHTML = '<p style="color:#666;padding:20px;text-align:center;">Belum ada route</p>';
                return;
            }
            container.innerHTML = routes.map(r => `
                <div class="data-item">
                    <h4><span class="badge badge-route">ID: ${r.id}</span> ${r.destination}</h4>
                    <p><strong>VPN:</strong> ${r.vpn_name} (ID: ${r.vpn_id})</p>
                    <p><strong>Gateway:</strong> ${r.gateway}</p>
                    <p><strong>Description:</strong> ${r.description || '-'}</p>
                    <p><strong>Created:</strong> ${r.created_at}</p>
                    <button class="btn btn-danger" onclick="deleteRoute(${r.id})">🗑️ Delete Route</button>
                </div>
            `).join('');
        }

        async function addRoute() {
            const vpn_id = document.getElementById('route-vpn-id').value;
            const destination = document.getElementById('route-destination').value;
            const gateway = document.getElementById('route-gateway').value;
            const description = document.getElementById('route-desc').value;

            if (!vpn_id) { alert('Pilih VPN terlebih dahulu!'); return; }
            if (!destination) { alert('Destination network wajib diisi!'); return; }
            if (!gateway) { alert('Gateway wajib diisi!'); return; }

            const res = await fetch(`/api/vpns/${vpn_id}/routes`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ destination, gateway, description })
            });
            const data = await res.json();
            showResult(data);
            if (data.success) {
                document.getElementById('route-destination').value = '';
                document.getElementById('route-gateway').value = '';
                document.getElementById('route-desc').value = '';
                loadRoutes();
            }
        }

        async function deleteRoute(id) {
            if (!confirm('Yakin ingin delete route ini?')) return;
            const res = await fetch(`/api/routes/${id}`, { method: 'DELETE' });
            const data = await res.json();
            showResult(data);
            if (data.success) loadRoutes();
        }

        // Initialize
        loadCustomers();
    </script>
</body>
</html>
"""

@app.route('/')
def index():
    return render_template_string(HTML_TEMPLATE)

# ==================== CUSTOMERS API ====================
@app.route('/api/customers', methods=['GET'])
def get_customers():
    """Get all customers"""
    # Count VPNs for each customer
    for customer in db["customers"]:
        customer["vpn_count"] = len([v for v in db["vpns"] if v["customer_id"] == customer["id"]])
    
    return jsonify({"success": True, "data": db["customers"]})

@app.route('/api/customers/<int:customer_id>', methods=['GET'])
def get_customer(customer_id):
    """Get customer by ID"""
    customer = next((c for c in db["customers"] if c["id"] == customer_id), None)
    if customer:
        customer["vpn_count"] = len([v for v in db["vpns"] if v["customer_id"] == customer_id])
        customer["vpns"] = [v for v in db["vpns"] if v["customer_id"] == customer_id]
        return jsonify({"success": True, "data": customer})
    return jsonify({"success": False, "error": "Customer not found"}), 404

@app.route('/api/customers', methods=['POST'])
def create_customer():
    """Create new customer"""
    global customer_id_counter
    data = request.get_json()
    
    if not data or 'name' not in data:
        return jsonify({"success": False, "error": "Field 'name' is required"}), 400
    
    customer_id_counter += 1
    customer = {
        "id": customer_id_counter,
        "name": data["name"],
        "description": data.get("description", ""),
        "ip_address": data.get("ip_address", ""),
        "created_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "vpn_count": 0
    }
    db["customers"].append(customer)
    
    return jsonify({"success": True, "message": "Customer created successfully", "data": customer}), 201

@app.route('/api/customers/<int:customer_id>', methods=['DELETE'])
def delete_customer(customer_id):
    """Delete customer and all related VPNs and routes"""
    customer = next((c for c in db["customers"] if c["id"] == customer_id), None)
    if not customer:
        return jsonify({"success": False, "error": "Customer not found"}), 404
    
    # Get all VPNs for this customer
    vpn_ids = [v["id"] for v in db["vpns"] if v["customer_id"] == customer_id]
    
    # Delete all routes for these VPNs
    db["routes"] = [r for r in db["routes"] if r["vpn_id"] not in vpn_ids]
    
    # Delete all VPNs for this customer
    db["vpns"] = [v for v in db["vpns"] if v["customer_id"] != customer_id]
    
    # Delete customer
    db["customers"] = [c for c in db["customers"] if c["id"] != customer_id]
    
    return jsonify({
        "success": True, 
        "message": "Customer and all related VPNs/routes deleted successfully",
        "deleted_vpn_count": len(vpn_ids)
    })

# ==================== VPNS API ====================
@app.route('/api/customers/<int:customer_id>/vpns', methods=['POST'])
def create_vpn(customer_id):
    """Create new VPN for customer"""
    global vpn_id_counter
    customer = next((c for c in db["customers"] if c["id"] == customer_id), None)
    if not customer:
        return jsonify({"success": False, "error": "Customer not found"}), 404
    
    data = request.get_json()
    if not data or 'name' not in data:
        return jsonify({"success": False, "error": "Field 'name' is required"}), 400
    
    vpn_id_counter += 1
    vpn = {
        "id": vpn_id_counter,
        "customer_id": customer_id,
        "customer_name": customer["name"],
        "name": data["name"],
        "type": data.get("type", "openvpn"),
        "network": data.get("network", ""),
        "created_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "route_count": 0
    }
    db["vpns"].append(vpn)
    
    return jsonify({"success": True, "message": "VPN created successfully", "data": vpn}), 201

@app.route('/api/vpns', methods=['GET'])
def get_all_vpns():
    """Get all VPNs"""
    # Count routes for each VPN
    for vpn in db["vpns"]:
        vpn["route_count"] = len([r for r in db["routes"] if r["vpn_id"] == vpn["id"]])
    
    return jsonify({"success": True, "data": db["vpns"]})

@app.route('/api/vpns/<int:vpn_id>', methods=['GET'])
def get_vpn(vpn_id):
    """Get VPN by ID"""
    vpn = next((v for v in db["vpns"] if v["id"] == vpn_id), None)
    if vpn:
        vpn["route_count"] = len([r for r in db["routes"] if r["vpn_id"] == vpn_id])
        vpn["routes"] = [r for r in db["routes"] if r["vpn_id"] == vpn_id]
        return jsonify({"success": True, "data": vpn})
    return jsonify({"success": False, "error": "VPN not found"}), 404

@app.route('/api/vpns/<int:vpn_id>', methods=['DELETE'])
def delete_vpn(vpn_id):
    """Delete VPN and all related routes"""
    vpn = next((v for v in db["vpns"] if v["id"] == vpn_id), None)
    if not vpn:
        return jsonify({"success": False, "error": "VPN not found"}), 404
    
    # Delete all routes for this VPN
    db["routes"] = [r for r in db["routes"] if r["vpn_id"] != vpn_id]
    
    # Delete VPN
    db["vpns"] = [v for v in db["vpns"] if v["id"] != vpn_id]
    
    return jsonify({"success": True, "message": "VPN and all related routes deleted successfully"})

# ==================== ROUTES API ====================
@app.route('/api/vpns/<int:vpn_id>/routes', methods=['POST'])
def create_route(vpn_id):
    """Create new route for VPN"""
    global route_id_counter
    vpn = next((v for v in db["vpns"] if v["id"] == vpn_id), None)
    if not vpn:
        return jsonify({"success": False, "error": "VPN not found"}), 404
    
    data = request.get_json()
    if not data or 'destination' not in data:
        return jsonify({"success": False, "error": "Field 'destination' is required"}), 400
    if 'gateway' not in data:
        return jsonify({"success": False, "error": "Field 'gateway' is required"}), 400
    
    route_id_counter += 1
    route = {
        "id": route_id_counter,
        "vpn_id": vpn_id,
        "vpn_name": vpn["name"],
        "destination": data["destination"],
        "gateway": data["gateway"],
        "description": data.get("description", ""),
        "created_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    }
    db["routes"].append(route)
    
    return jsonify({"success": True, "message": "Route created successfully", "data": route}), 201

@app.route('/api/routes', methods=['GET'])
def get_all_routes():
    """Get all routes"""
    return jsonify({"success": True, "data": db["routes"]})

@app.route('/api/routes/<int:route_id>', methods=['GET'])
def get_route(route_id):
    """Get route by ID"""
    route = next((r for r in db["routes"] if r["id"] == route_id), None)
    if route:
        return jsonify({"success": True, "data": route})
    return jsonify({"success": False, "error": "Route not found"}), 404

@app.route('/api/routes/<int:route_id>', methods=['DELETE'])
def delete_route(route_id):
    """Delete route"""
    route = next((r for r in db["routes"] if r["id"] == route_id), None)
    if not route:
        return jsonify({"success": False, "error": "Route not found"}), 404
    
    db["routes"] = [r for r in db["routes"] if r["id"] != route_id]
    
    return jsonify({"success": True, "message": "Route deleted successfully", "data": route})

if __name__ == '__main__':
    print("=" * 60)
    print("🚀 VPN Management System API Server Started!")
    print("=" * 60)
    print(f"📍 Web UI: http://localhost:{PORT}")
    print(f"📍 API Base: http://localhost:{PORT}/api")
    print("=" * 60)
    print("\n📋 Available Endpoints:")
    print("  👥 CUSTOMERS:")
    print("     POST   /api/customers              - Add customer")
    print("     GET    /api/customers              - List all customers")
    print("     GET    /api/customers/<id>         - Get customer detail")
    print("     DELETE /api/customers/<id>         - Delete customer")
    print("\n  🔒 VPNS:")
    print("     POST   /api/customers/<id>/vpns    - Add VPN for customer")
    print("     GET    /api/vpns                   - List all VPNs")
    print("     GET    /api/vpns/<id>              - Get VPN detail")
    print("     DELETE /api/vpns/<id>              - Delete VPN")
    print("\n  🛣️ ROUTES:")
    print("     POST   /api/vpns/<id>/routes       - Add route for VPN")
    print("     GET    /api/routes                 - List all routes")
    print("     GET    /api/routes/<id>            - Get route detail")
    print("     DELETE /api/routes/<id>            - Delete route")
    print("=" * 60)
    app.run(host='0.0.0.0', port=PORT, debug=False)
