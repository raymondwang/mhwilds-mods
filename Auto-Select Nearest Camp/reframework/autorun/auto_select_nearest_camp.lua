local CONFIG_PATH = 'auto_select_nearest_camp.json'

---@class AutoSelectNearestCampConfig
---@field isEnabled boolean
---@field isDebug boolean
local config = {
  isEnabled = true,
  isDebug = false,
}

local function save_config()
  json.dump_file(CONFIG_PATH, config)
end

---@param input AutoSelectNearestCampConfig
---@return boolean
local function is_valid_config(input)
  if not input then return false end
  if type(input.isEnabled) ~= 'boolean' then return false end
  if type(input.isDebug) ~= 'boolean' then return false end
  return true
end

local function load_config()
  local loaded_config = json.load_file(CONFIG_PATH)
  if is_valid_config(loaded_config) then
    config = loaded_config
  else
    -- Overwrite an invalid or missing config with default values:
    save_config()
  end
end

load_config()

---@class REManagedObject
---@field call fun(REManagedObject, ...): any
---@field get_field fun(REManagedObject, string): any

---@class System.Collections.Generic.List<T>: { _items: T[], _size: integer }
---@class Vector3f: { x: number, y: number, z: number }

---@param message string
local function debug(message)
  if not config.isDebug then return end
  log.debug('[Auto-Select Nearest Camp] ' .. message)
end

---@param label string
---@param pos Vector3f
---@param distance? number
local function debugPos(label, pos, distance)
  if not config.isDebug then return end
  log.debug('\n[Auto-Select Nearest Camp] Position of ' .. label .. ':')
  log.debug('  - x:        ' .. tostring(pos.x))
  log.debug('  - y:        ' .. tostring(pos.y))
  log.debug('  - z:        ' .. tostring(pos.z))
  if distance ~= nil then
    log.debug('  - distance: ' .. tostring(distance))
  end
end

-- Returns the approximate position of the first target monster for a quest.
-- Target locations are encoded only as area numbers (e.g. Uth Duna usually spawns in area 17);
-- in order to convert this to a position, we need to retrieve the map data for the quest stage,
-- which contains icon positions associated with each area.
---@param quest_accept_ui app.GUI050001
---@return Vector3f?
local function get_target_pos(quest_accept_ui)
  ---@class app.cGUIQuestOrderParam : REManagedObject
  ---@field QuestViewData app.cGUIQuestViewData

  ---@class app.cGUIQuestViewData : REManagedObject
  ---@field get_Stage fun(): app.FieldDef.STAGE
  ---@field get_TargetEmStartArea fun(): { get_element: fun(_, index: integer): { m_value: number } }
  local quest_view_data = quest_accept_ui:get_QuestOrderParam().QuestViewData

  local target_em_start_areas = quest_view_data:get_TargetEmStartArea()
  local target_em_start_area = target_em_start_areas:get_element(0).m_value

  if target_em_start_area == nil then
    debug('ERROR: No starting area found for target')
    return nil
  end

  ---@class app.cGUIMapController : REManagedObject
  ---@field _MapStageDrawData app.user_data.MapStageDrawData
  local map_controller = sdk.get_managed_singleton('app.GUIManager'):get_MAP3D()
  ---@class app.user_data.MapStageDrawData : REManagedObject
  local map_stage_draw_data = map_controller._MapStageDrawData

  ---@alias app.FieldDef.STAGE number
  local stage = quest_view_data:get_Stage()

  ---@class app.user_data.MapStageDrawData.cDrawData : REManagedObject
  ---@field _AreaIconPosList System.Collections.Generic.List<app.user_data.MapStageDrawData.cAreaIconData>
  local stage_draw_data = map_stage_draw_data:call('getDrawData(app.FieldDef.STAGE)', stage)
  if stage_draw_data == nil then
    debug("ERROR: Couldn't find cDrawData for stage " .. tostring(stage))
    return nil
  end

  local area_icon_pos_list = stage_draw_data._AreaIconPosList
  ---@class app.user_data.MapStageDrawData.cAreaIconData : REManagedObject
  ---@field _AreaIconPos Vector3f
  ---@field _AreaNum integer
  for _, area_icon_data in pairs(area_icon_pos_list._items) do
    if area_icon_data._AreaNum == target_em_start_area then
      return area_icon_data._AreaIconPos
    end
  end
end

---@class DistanceMethod
---@field call fun(_, _, Vector3f, Vector3f): number
local get_distance = sdk.find_type_definition('via.MathEx'):get_method('distance(via.vec3, via.vec3)')

-- Find the nearest start point to the target position and return its index in its list.
---@param target_pos Vector3f
---@param start_point_list System.Collections.Generic.List<app.cStartPointInfo>
---@return integer
local function get_index_of_nearest_start_point(target_pos, start_point_list)
  local shortest_distance = math.huge
  local nearest_index = 0

  debugPos('quest target', target_pos)

  for index, start_point in pairs(start_point_list._items) do
    ---@class app.cStartPointInfo : REManagedObject
    ---@field get_BeaconGimmick fun(): app.cGUIBeaconGimmick
    if start_point then
      ---@class app.cGUIBeaconGimmick : REManagedObject
      ---@field getPos fun(): Vector3f
      local beacon_gimmick = start_point:get_BeaconGimmick()
      local beacon_pos = beacon_gimmick:getPos()
      local d2 = get_distance:call(nil, beacon_pos, target_pos)
      if d2 < shortest_distance then
        shortest_distance = d2
        nearest_index = index
      end

      debugPos('start point at index ' .. tostring(index), beacon_pos, d2)
    end
  end

  return nearest_index
end

-- In order to update the quest map preview, we need to incrementally update the start point input
-- across multiple visible updates. Since we can't isolate our runtime to a single hook, we maintain
-- a local storage object meant to emulate the ephemeral hook storage API.
---@class HookStorageSingleton
---@field quest_accept_ui app.GUI050001?
---@field nearest_start_point_index integer
---@field should_select_next_item_on_visible_update boolean
local hook_storage_singleton = {
  quest_accept_ui = nil,
  nearest_start_point_index = 0,
  should_select_next_item_on_visible_update = false,
}

local function reset_operation_hook_storage()
  hook_storage_singleton = {
    quest_accept_ui = nil,
    nearest_start_point_index = 0,
    should_select_next_item_on_visible_update = false,
  }
end

-- Find the nearest start point and set it in the hook storage.
local function identify_nearest_start_point()
  local quest_accept_ui = hook_storage_singleton.quest_accept_ui
  if quest_accept_ui == nil then return end

  local start_point_list = quest_accept_ui:get_CurrentStartPointList()
  -- Exit early if the list only has 1 item:
  if start_point_list == nil or start_point_list._size <= 1 then return end

  local target_pos = get_target_pos(quest_accept_ui)
  if target_pos == nil then return end

  local nearest_start_point_index = get_index_of_nearest_start_point(target_pos, start_point_list)
  if nearest_start_point_index ~= nil and nearest_start_point_index > 0 then
    -- This is required to update the "Departure Point" GUI item, but not the map preview:
    quest_accept_ui:call('setCurrentSelectStartPointIndex(System.Int32)', nearest_start_point_index)
    -- Update hook storage with data for subsequent updates:
    hook_storage_singleton.nearest_start_point_index = nearest_start_point_index
    hook_storage_singleton.should_select_next_item_on_visible_update = true
  end
end

-- After each visible update, attempt to increment the start point in the input control GUI item.
-- This needs to be done iteratively across repaints in order to prevent race conditions;
-- the quest map preview will not show the correct start point otherwise.
local function select_next_start_point()
  local quest_accept_ui = hook_storage_singleton.quest_accept_ui
  local nearest_start_point_index = hook_storage_singleton.nearest_start_point_index
  if not quest_accept_ui or not nearest_start_point_index then
    hook_storage_singleton.should_select_next_item_on_visible_update = false
    return
  end

  ---@class app.GUI050001_StartPointList : REManagedObject
  ---@field _InputCtrl ace.cGUIInputCtrl_FluentItemsControlLink

  ---@class ace.cGUIInputCtrl_FluentItemsControlLink : REManagedObject
  ---@field getSelectedIndex fun(): integer
  ---@field selectNextItem fun(): nil
  local input_ctrl = quest_accept_ui._StartPointList._InputCtrl
  if input_ctrl:getSelectedIndex() ~= nearest_start_point_index then
    input_ctrl:selectNextItem()
  else
    hook_storage_singleton.should_select_next_item_on_visible_update = false
  end
end

local function on_pre_init_start_point(args)
  if config.isEnabled then
    reset_operation_hook_storage()
    ---@class app.GUI050001 : REManagedObject
    ---@field _StartPointList app.GUI050001_StartPointList
    ---@field get_CurrentStartPointList fun(): System.Collections.Generic.List<app.cStartPointInfo>
    ---@field get_QuestOrderParam fun(): app.cGUIQuestOrderParam
    hook_storage_singleton.quest_accept_ui = sdk.to_managed_object(args[2])
  end

  return sdk.PreHookResult.CALL_ORIGINAL
end

local function on_post_init_start_point(retval)
  if config.isEnabled then
    local ok, error = pcall(identify_nearest_start_point)
    if not ok then debug('ERROR: ' .. tostring(error)) end
  end

  return retval
end

local quest_accept_ui_t = sdk.find_type_definition('app.GUI050001')

sdk.hook(quest_accept_ui_t:get_method('initStartPoint()'), on_pre_init_start_point, on_post_init_start_point)

local function on_post_close(retval)
  if hook_storage_singleton.quest_accept_ui then
    reset_operation_hook_storage()
  end
  return retval
end

sdk.hook(quest_accept_ui_t:get_method('onClose()'), nil, on_post_close)

local function on_post_visible_update(retval)
  if config.isEnabled and hook_storage_singleton.should_select_next_item_on_visible_update then
    select_next_start_point()
  end
  return retval
end

local accept_list_t = sdk.find_type_definition("app.GUI050001_AcceptList")

sdk.hook(accept_list_t:get_method('onVisibleUpdate()'), nil, on_post_visible_update)

re.on_config_save(save_config)

re.on_draw_ui(function()
  if imgui.tree_node('Auto-Select Nearest Camp') then
    local hasChangedIsEnabled, isEnabled = imgui.checkbox('Enabled', config.isEnabled)
    if hasChangedIsEnabled then
      config.isEnabled = isEnabled
      save_config()
    end

    local hasChangedIsDebug, isDebug = imgui.checkbox('Debug', config.isDebug)
    if hasChangedIsDebug then
      config.isDebug = isDebug
      save_config()
    end

    imgui.tree_pop()
  end
end)

log.info('[Auto-Select Nearest Camp] Initialized')
