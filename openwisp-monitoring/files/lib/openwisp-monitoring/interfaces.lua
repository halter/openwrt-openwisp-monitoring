-- retrieve interfaces information
local utils = require('openwisp-monitoring.utils')

local cjson = require('cjson')
local nixio = require('nixio')
local nixio_data = nixio.getifaddrs()
local io = require('io')

local uci = require('uci')
local uci_cursor = uci.cursor()

local ubus_lib = require('ubus')
local ubus = ubus_lib.connect()
if not ubus then error('Failed to connect to ubusd') end
local interface_data = ubus:call('network.interface', 'dump', {})

-- Lookup to convert gsmctl output to modem-manager
local access_lookup = {
  gsm = {
    gsm = {
      rssi = 'rssi_value'
    }
  },
  wcdma = {
    umts = {
      rssi = 'rssi_value',
      rscp = 'rscp_value',
      ecio = 'ecio_value'
    }
  },
  tdscdma = {
    umts = {
      rssi = 'rssi_value',
      rscp = 'rscp_value',
      ecio = 'ecio_value'
    }
  },
  lte = {
    lte = {
      rssi = 'rssi_value',
      rsrp = 'rsrp_value',
      rsrq = 'rsrq_value',
      snr = 'sinr_value'
    }
  }
}

local interfaces = {}

local specialized_interfaces = {
  modemmanager = function(_, interface)
    local modem = uci_cursor.get('network', interface['interface'], 'device')
    local info = {}
    local general_file = io.popen('mmcli --output-json -m ' .. modem)
    local general = general_file:read("*a")
    general_file:close()
    if general and pcall(cjson.decode, general) then
      general = cjson.decode(general)
      general = general.modem

      if not utils.is_table_empty(general['3gpp']) then
        info.imei = general['3gpp'].imei
        info.operator_name = general['3gpp']['operator-name']
        info.operator_code = general['3gpp']['operator-code']
      end

      if not utils.is_table_empty(general.generic) then
        info.manufacturer = general.generic.manufacturer
        info.model = general.generic.model
        info.connection_status = general.generic.state
        info.power_status = general.generic['power-state']
      end
    end

    local signal_file =
      io.popen('mmcli --output-json -m ' .. modem .. ' --signal-get')
    local signal = signal_file:read("*a")
    signal_file:close()
    if signal and pcall(cjson.decode, signal) then
      signal = cjson.decode(signal)
      -- only send data if not empty to avoid generating too much traffic
      if not utils.is_table_empty(signal.modem) and
        not utils.is_table_empty(signal.modem.signal) then
        -- omit refresh rate
        signal.modem.signal.refresh = nil
        info.signal = {}
        -- collect section and values only if not empty
        for section_key, section_values in pairs(signal.modem.signal) do
          for key, value in pairs(section_values) do
            if value ~= '--' then
              if utils.is_table_empty(info.signal[section_key]) then
                info.signal[section_key] = {}
              end
              info.signal[section_key][key] = tonumber(value)
            end
          end
        end
      end
    end

    return {type = 'modem-manager', mobile = info}
  end,
  -- jank gsmctl convert to modem-manager format
  wwan = function(_, interface)
    local modem = uci_cursor.get('network', interface['interface'], 'modem')
    local info = {}
    local general_file = io.popen('gsmctl -E -O ' .. modem .. " | grep -iv 'Enabled band'")
    local general = general_file:read("*a")
    general_file:close()
    if general and pcall(cjson.decode, general) then
      general = cjson.decode(general)
      info.manufacturer = general.manuf
      info.model = general.model

      if not utils.is_table_empty(general['cache']) then
        info.imei = general['cache']['imei']
        info.temperature = general['cache']['temperature_value']
        info.power_status = "on"

        -- Retrieve connection and signal stats only if SIM is readable
        -- pin_state 1 = "OK"
        if general['cache']['pin_state'] == 1 then
          info.imsi = general['cache']['imsi']
          -- service_mode 2 = "No service"
          if general['cache']['service_mode'] ~= 2 then
            info.connection_status = "connected"
            info.signal = {}

            local operator_file = io.popen('gsmctl -of -O ' .. modem)
            local operaator = operator_file:read("*a")
            operator_file:close()
            operaator = utils.split(operaator, "\n")
            info.operator_name = operaator[1]
            info.operator_code = operaator[2]

            gsmctl_conn_type = string.lower(general['cache']['service_mode_str'])
            if access_lookup[gsmctl_conn_type] ~= nil then
              for section_key, section_values in pairs(access_lookup[gsmctl_conn_type]) do
                for signal_metric, signal_field in pairs(section_values) do
                  if utils.is_table_empty(info.signal[section_key]) then
                    info.signal[section_key] = {}
                  end
                  info.signal[section_key][signal_metric] = general['cache'][signal_field]
                end
              end
            end
          else
            info.connection_status = "disconnected"
          end
        end
      else
        info.power_status = "off"
      end
    end
    return {type = 'modem-manager', mobile = info}
  end
}

function interfaces.find_default_gateway(routes)
  for i = 1, #routes do
    if routes[i].target == '0.0.0.0' then return routes[i].nexthop end
  end
  return nil
end

function interfaces.new_address_array(address, interface, family)
  local proto = interface['proto']
  if proto == 'dhcpv6' then proto = 'dhcp' end
  local new_address = {
    address = address['address'],
    mask = address['mask'],
    proto = proto,
    family = family,
    gateway = interfaces.find_default_gateway(interface.route)
  }
  return new_address
end

-- collect interface addresses
function interfaces.get_addresses(name)
  local addresses = {}
  local proto = nil
  local interface_list = interface_data['interface']
  local addresses_list = {}
  for _, interface in pairs(interface_list) do
    if interface['l3_device'] == name then
      for _, address in pairs(interface['ipv4-address']) do
        table.insert(addresses_list, address['address'])
        local new_address = interfaces.new_address_array(address, interface, 'ipv4')
        table.insert(addresses, new_address)
      end
      for _, address in pairs(interface['ipv6-address']) do
        table.insert(addresses_list, address['address'])
        local new_address = interfaces.new_address_array(address, interface, 'ipv6')
        table.insert(addresses, new_address)
      end
    end
  end
  for i = 1, #nixio_data do
    if nixio_data[i].name == name then
      if not utils.is_excluded(name) then
        local family = nixio_data[i].family
        local addr = nixio_data[i].addr
        if family == 'inet' then
          family = 'ipv4'
          -- Since we don't already know this from the dump, we can
          -- consider this dynamically assigned, this is the case for
          -- example for OpenVPN interfaces, which get their address
          -- from the DHCP server embedded in OpenVPN
          proto = 'dhcp'
        elseif family == 'inet6' then
          family = 'ipv6'
          if utils.starts_with(addr, 'fe80') then
            proto = 'static'
          else
            -- LuaFormatter off
            local ula_prefix = uci_cursor.get('network', 'globals', 'ula_prefix') or '' -- luacheck: ignore
            -- LuaFormatter on
            if ula_prefix then ula_prefix = ula_prefix:sub(0, 13) end
            if utils.starts_with(addr, ula_prefix) then
              proto = 'static'
            else
              proto = 'dhcp'
            end
          end
        end
        if family == 'ipv4' or family == 'ipv6' then
          if not utils.has_value(addresses_list, addr) then
            table.insert(addresses, {
              address = addr,
              mask = nixio_data[i].prefix,
              proto = proto,
              family = family
            })
          end
        end
      end
    end
  end
  return addresses
end

function interfaces.get_network_devices()
  local devices = {}
  uci_cursor:foreach('network', 'device', function(uci_device)
    local device = {}
    for key, value in pairs(uci_device) do
      if not string.match(key, '^%.') then device[key] = value end
    end
    devices[uci_device['name']] = device
  end)
  return devices
end

local network_devices = interfaces.get_network_devices()

function interfaces.get_interface_info(name, netjson_interface)
  local info = {dns_search = nil, dns_servers = nil}
  for _, interface in pairs(interface_data['interface']) do
    if interface['l3_device'] == name then
      if next(interface['dns-search']) then
        info.dns_search = interface['dns-search']
      end
      if next(interface['dns-server']) then
        info.dns_servers = interface['dns-server']
      end
      if netjson_interface.type == 'bridge' then
        -- On OpenWrt > 21, "stp" is present in the "device" section
        local device_name = interface['device']
        if device_name and network_devices[device_name] then
          info.stp = network_devices[device_name]['stp']
        else
          info.stp = uci_cursor.get('network', interface['interface'], 'stp')
        end
        info.stp = info.stp == '1'
      end
      -- collect specialized info if available
      local specialized_info = specialized_interfaces[interface.proto]
      if specialized_info then
        info.specialized = specialized_info(name, interface)
      end
    end
  end
  return info
end

function interfaces.get_vpn_interfaces()
  -- only openvpn supported for now
  local items = uci_cursor:get_all('openvpn')
  local vpn_interfaces = {}

  if utils.is_table_empty(items) then return {} end

  for _, config in pairs(items) do
    if config and config.dev then vpn_interfaces[config.dev] = true end
  end
  return vpn_interfaces
end

function interfaces.get_gps_position()
  local gps_position = {}
  local gps_position_data = ubus:call('gpsd', 'position', {})
  if gps_position_data == nil then
    return gps_position
  end
  for key, value in pairs(gps_position_data) do
    gps_position[key] = value
  end
  return gps_position
end

return interfaces