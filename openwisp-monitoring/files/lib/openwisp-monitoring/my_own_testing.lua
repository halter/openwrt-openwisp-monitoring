local output = [[
  Station 4c:5e:0c:11:6b:84 (on mesh0)
	signal:  	-60 [-61, -68] dBm
	signal avg:	-58 [-61, -68] dBm
	last ack signal:-95 dBm
	avg ack signal:	-94 dBm
	connected time:	9089 seconds
Station 4c:5e:0c:11:6b:91 (on mesh0)
	signal:  	-49 [-57, -66] dBm
	signal avg:	-53 [-57, -66] dBm
	last ack signal:-95 dBm
	avg ack signal:	-93 dBm
	connected time:	9088 seconds
Station 4c:5e:0c:11:6b:85 (on mesh0)
	signal:  	-65 [-70, -80] dBm
	signal avg:	-66 [-70, -79] dBm
	last ack signal:-95 dBm
	avg ack signal:	-94 dBm
	connected time:	9084 seconds
]]

-- Initialize a table to store stations
local stations = {}

-- Split the output into lines and iterate through them
for line in output:gmatch("[^\r\n]+") do
    -- Check if the line contains "Station numX"
    local station_name = line:match("Station (%S+)")
    if station_name then
        stations[station_name] = {}
    else
        -- If not, check for other relevant information and add it to the current station
        local current_station = next(stations)
        if current_station then
            local signal, signal_avg, last_ack_signal, avg_ack_signal, connected_time = line:match("signal:%s+([%d%-]+)%s+%[([%d%-]+),%s([%d%-]+)%]%s+dBm")
            if signal then
                stations[current_station].signal = tonumber(signal)
                stations[current_station].signal_avg = { tonumber(signal_avg), tonumber(avg_ack_signal) }
            elseif last_ack_signal then
                stations[current_station].last_ack_signal = tonumber(last_ack_signal)
            elseif connected_time then
                stations[current_station].connected_time = tonumber(connected_time)
            end
        end
    end
end

-- Print the stations and their information
for station, info in pairs(stations) do
    print("Station: " .. station)
    print("Signal: " .. info.signal .. " dBm")
    print("Signal Avg: " .. info.signal_avg[1] .. " dBm - " .. info.signal_avg[2] .. " dBm")
    print("Last Ack Signal: " .. info.last_ack_signal .. " dBm")
    print("Connected Time: " .. info.connected_time .. " seconds")
    print()
end