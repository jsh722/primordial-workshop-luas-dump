--[[
      backtrack.lua made by punch#7017
    - idea behind this is to store the enemies eye position and simulation time of past records and check which is closer to the crosshair
      adjust the cmd's tick count on shoot based off this logic
]]

local script_menu = {
  m_max_compensation_ticks = menu.add_slider( "backtrack", "max compensation ticks", 0, 12 )
}

local math_const = {
  m_pi_radians = 57.295779513082
}

local player_records = { }

-- push all previous records one up
-- and add a new one to index 0

local function push_player_record( player )
  local index = player:get_index( )
  local record = { }

  record.m_eye_position = player:get_eye_position( )
  record.m_simulation_time = player:get_prop( "m_flSimulationTime" )

  if( player_records[ index ] == nil ) then
    player_records[ index ] = { }
  end

  for i = 11, 0, -1 do
    if( player_records[ index ][ i ] ~= nil ) then
      player_records[ index ][ i + 1 ] = player_records[index ][ i ]
    end
  end

  player_records[ index ][ 0 ] = record
end


-- clamp values ( https://github.com/topameng/CsToLua/blob/master/tolua/Assets/Lua/Math.lua ) - straight stolen cause very lazzy :-)
local function clamp(num, min, max)
	if num < min then
		num = min
	elseif num > max then
		num = max
	end

	return num
end


-- convert ticks to time
local function ticks_to_time( ticks )
  return global_vars.interval_per_tick( ) * ticks
end


-- convert time to ticks
local function time_to_ticks( time )
  return math.floor( 0.5 + time / global_vars.interval_per_tick( ) )
end

-- calc interpolation adjustment
local function calc_lerp( )
  local update_rate = clamp( cvars.cl_updaterate:get_float( ), cvars.sv_minupdaterate:get_float( ), cvars.sv_maxupdaterate:get_float( ) )
  local lerp_ratio = clamp( cvars.cl_interp_ratio:get_float( ), cvars.sv_client_min_interp_ratio:get_float( ), cvars.sv_client_max_interp_ratio:get_float( ) )

  return clamp( lerp_ratio / update_rate, cvars.cl_interp:get_float( ), 1 )
end

-- calc if a record is valid
local function is_record_valid( record, tick_base )
  local max_unlag = cvars.sv_maxunlag:get_float( )
  local current_time = ticks_to_time( tick_base )

  local correct = engine.get_latency( e_latency_flows.INCOMING ) + engine.get_latency( e_latency_flows.OUTGOING )
  local correct = clamp( correct, 0, max_unlag )

  return math.abs( correct - ( current_time - record.m_simulation_time ) ) <= 0.2
end


-- calc angle to position
local function calc_angle( from, to )
  local result = angle_t( 0.0, 0.0, 0.0 )
  local delta = from - to
  local hyp = math.sqrt( delta.x * delta.x + delta.y * delta.y )

  result.x = math.atan( delta.z / hyp ) * math_const.m_pi_radians
  result.y = math.atan( delta.y / delta.x ) * math_const.m_pi_radians

  if( delta.x >= 0 ) then
    result.y = result.y + 180
  end

  return result
end

-- normalize angle
local function normalize_angle( angle )
  local result = angle

  while result.x < -180 do
    result.x = result.x + 360
  end

  while result.x > 180 do
    result.x = result.x - 360
  end

  while result.y < -180 do
    result.y = result.y + 360
  end

  while result.y > 180 do
    result.y = result.y - 360
  end

  result.x = clamp( result.x, -89, 89 )

  return result
end

-- calc fov to position
local function calc_fov( view_angle, target_angle )
  local delta = target_angle - view_angle
  local delta_normalized = normalize_angle( delta )

  return math.min( math.sqrt( math.pow( delta_normalized.x, 2 ) + math.pow( delta_normalized.y, 2 ) ), 180 )
end

-- loop trough all entities on net update
-- to store new records

local function on_net_update( )
  local enemies_only = entity_list.get_players(true)
  if( enemies_only == nil ) then
    return
  end

  for _, enemy in pairs(enemies_only) do
    if enemy:is_alive() then
      push_player_record( enemy )
    end
  end
end

local function on_setup_command( cmd )
  local enemies_only = entity_list.get_players(true)

  local closest_enemy = nil
  local closest_fov = 180

  local local_player = entity_list.get_local_player( )
  if( local_player == nil or local_player:is_alive( ) ~= true or cmd:has_button( e_cmd_buttons.ATTACK ) ~= true ) then
    return
  end

  local view_angle = engine.get_view_angles( )
  local eye_position = local_player:get_eye_position( )

  -- search for closest enemy to fov first (could maybe completely be swit)
  for _, enemy in pairs(enemies_only) do
    if enemy:is_alive() then
      local fov = calc_fov( view_angle, calc_angle( eye_position, enemy:get_eye_position( ) ) )

      if( fov < closest_fov ) then
        closest_enemy = enemy
        closest_fov = fov
      end
    end
  end

  if( closest_enemy ~= nil ) then
    closest_fov = 180

    local best_record = nil
    if( player_records[ closest_enemy:get_index( ) ] == nil ) then
      return
    end

    for i = 0, 12 do
      if( player_records[ closest_enemy:get_index( ) ][ i ] ~= nil ) then
        local record = player_records[ closest_enemy:get_index( ) ][ i ]
        local compensation_ticks = time_to_ticks( closest_enemy:get_prop( "m_flSimulationTime" ) - record.m_simulation_time )

        if( is_record_valid( record, local_player:get_prop( "m_nTickBase" ) ) and compensation_ticks <= script_menu.m_max_compensation_ticks:get( ) ) then
            local fov = calc_fov( view_angle, calc_angle( eye_position, record.m_eye_position ) )

            if( fov < closest_fov ) then
              closest_fov = fov
              best_record = record
            end
        end
      end
    end

    -- we found an record, apply it to the cmd
    if( best_record ~= nil ) then
      local tick_count = cmd.tick_count

      cmd.tick_count = time_to_ticks( best_record.m_simulation_time + calc_lerp( ) )
    end
  end
end


-- register all callbacks
callbacks.add( e_callbacks.NET_UPDATE, on_net_update )
callbacks.add( e_callbacks.SETUP_COMMAND, on_setup_command )