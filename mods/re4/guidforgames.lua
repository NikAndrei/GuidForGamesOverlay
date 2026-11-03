-- GuidForGames — мост между Resident Evil 4 (Remake) и приложением-компаньоном (REFramework, Lua).
--
-- Только ЧИТАЕТ состояние игры и пишет его в файл; в игре ничего не меняет, объектов игры не создаёт.
-- Установка: файл в <папка игры>\reframework\autorun\ (или gfg-service install-mods).
-- Файлы пишутся в <папка игры>\reframework\data\:
--   guidforgames_re4_live.json — живое состояние, раз в 2 секунды: позиция игрока, глава (CampaignManager.CurrentChapter,
--                                самая дальняя — GameStatsManager.MostProceedChapter), локация (CurrentStageID), сцена
--                                карты, сложность, песеты (InventoryManager.CurrPTAS), здоровье (v2);
--                                v6: ещё items (полученные предметы, chainsaw.ItemID) и files (открытые документы,
--                                chainsaw.FileID) — для автоотметок в справочнике, пересчёт раз в 10 с;
--   guidforgames_re4_diag.json — диагностика по кнопке в меню REFramework (Insert → Script Generated UI →
--                                GuidForGames RE4): устройство менеджеров игры (chainsaw.*) — по ней делаются
--                                следующие версии (глава, сокровища, кастеляны, поручения, деньги);
--   guidforgames_re4_mapprobe.json — v7: разведка игровой карты — при каждом открытии карты (до 6 раз за запуск)
--                                пишется, как игра переводит координаты мира в координаты карты (MapManager.
--                                ConvertGamePosToGuiPos, getPlayerIconPos) — основа для своих значков на карте;
-- v8: поверх открытой игровой карты рисуются значки непрочитанных документов («F»); в меню мода — переключатели
--     «Show icons on map» и отладочные круги «Debug: player markers on map» (должны совпасть со значком Леона).
--   guidforgames_re4_points.json — точки по кнопке «Remember point» (v4): позиция, локация и глава — для привязки
--                                карт guides4gamers к координатам игры (встать у пишущей машинки или торговца).
-- Текст в меню — английский: шрифт оверлея REFramework не всегда показывает кириллицу.

local VERSION = 22
local LIVE_FILE = "guidforgames_re4_live.json"
local DIAG_FILE = "guidforgames_re4_diag.json"
local POINTS_FILE = "guidforgames_re4_points.json"
local MAPPROBE_FILE = "guidforgames_re4_mapprobe.json"
local INTERVAL = 2.0

local last_write = -INTERVAL
local status = "waiting for player"
local last_live = nil
local player_how = nil
-- Данные, которые заполняются ниже по файлу (v17: подобранное), а пишутся в живое состояние раньше по коду.
local shared = {}

local function try_call(obj, method, ...)
    if obj == nil then return nil end
    local args = { ... }
    local ok, r = pcall(function() return obj:call(method, table.unpack(args)) end)
    if ok then return r end
    return nil
end

local function try_field(obj, name)
    if obj == nil then return nil end
    local ok, r = pcall(function() return obj:get_field(name) end)
    if ok then return r end
    return nil
end

local function num(v, key)
    local ok, r = pcall(function() return v[key] end)
    if ok and type(r) == "number" then return r end
    ok, r = pcall(function() return v:get_field(key) end)
    if ok and type(r) == "number" then return r end
    return nil
end

local function vec3(v)
    if v == nil then return nil end
    local x, y, z = num(v, "x"), num(v, "y"), num(v, "z")
    if x == nil or y == nil or z == nil then return nil end
    return { x = x, y = y, z = z }
end

local function type_name(obj)
    if type(obj) ~= "userdata" then return nil end
    local ok, td = pcall(function() return obj:get_type_definition() end)
    if ok and td ~= nil then return td:get_full_name() end
    return nil
end

-- Позиция объекта игры: сам GameObject, компонент с get_GameObject или контекст с полем-ссылкой на него.
local function position_of(obj)
    if obj == nil then return nil end
    local go = obj
    if type_name(obj) ~= "via.GameObject" then go = try_call(obj, "get_GameObject") end
    local tr = try_call(go, "get_Transform")
    return vec3(try_call(tr, "get_Position"))
end

-- Персонаж игрока: перебираем вероятные пути (точные имена типов RE4 узнаём по диагностике) и запоминаем удачный.
local PLAYER_PATHS = {
    { "chainsaw.CharacterManager", "getPlayerContextRef" },
    { "chainsaw.CharacterManager", "get_PlayerContext" },
    { "chainsaw.CharacterManager", "getPlayerContext" },
    { "chainsaw.PlayerManager", "get_Player" },
    { "chainsaw.PlayerManager", "getPlayer" },
}

local function player_object()
    for _, p in ipairs(PLAYER_PATHS) do
        local mgr = sdk.get_managed_singleton(p[1])
        local ctx = try_call(mgr, p[2])
        if ctx ~= nil then
            -- у контекста может быть своя позиция или ссылка на тело (GameObject/компонент)
            local pos = vec3(try_call(ctx, "get_Position")) or vec3(try_field(ctx, "<Position>k__BackingField"))
            if pos == nil then
                for _, m in ipairs({ "get_BodyGameObject", "get_GameObject", "get_Body", "get_Character" }) do
                    pos = position_of(try_call(ctx, m))
                    if pos ~= nil then break end
                end
            end
            if pos ~= nil then
                player_how = p[1] .. "." .. p[2]
                return pos
            end
        end
    end
    return nil
end

-- Числа здоровья из chainsaw.character.Vital: имена полей узнаём по диагностике v2 — берём первые подходящие.
local function vital_numbers(v)
    if v == nil then return nil end
    local out = {}
    for _, pair in ipairs({ { "current", { "get_CurrentValue", "get_Value", "get_Current" } }, { "max", { "get_MaxValue", "get_Max", "get_DefaultMaxValue" } } }) do
        for _, m in ipairs(pair[2]) do
            local x = try_call(v, m)
            if type(x) == "number" then out[pair[1]] = x break end
        end
    end
    return next(out) ~= nil and out or nil
end

-- Глава, локация, деньги, здоровье (v2) — только чтение свойств менеджеров.
local function game_state(live)
    local cm = sdk.get_managed_singleton("chainsaw.CampaignManager")
    live.chapter = try_call(cm, "get_CurrentChapter")
    live.campaign = try_call(cm, "get_CurrentCampaign")
    live.campaignKey = try_call(cm, "get_CurrentCampaignKey")
    live.difficulty = try_call(cm, "get_CurrentDifficulty")
    local gs = sdk.get_managed_singleton("chainsaw.GameStatsManager")
    live.mostChapter = try_call(gs, "get_MostProceedChapter")
    live.mostChapterSw = try_call(gs, "get_MostProceedChapterCp1011")
    live.ptas = try_call(sdk.get_managed_singleton("chainsaw.InventoryManager"), "get_CurrPTAS")
    local mm = sdk.get_managed_singleton("chainsaw.MapManager")
    live.mapScene = try_call(mm, "get_CurrMapSceneID")
    live.mapFloor = try_call(mm, "get_CurrMapPlayerFloorID")
    local ctx = try_call(sdk.get_managed_singleton("chainsaw.CharacterManager"), "getPlayerContextRef")
    live.stage = try_field(ctx, "<CurrentStageID>k__BackingField")
    live.hp = vital_numbers(try_call(ctx, "getHitPointVital"))
end

-- v6: что уже собрано — полученные предметы (номера chainsaw.ItemID, флаг InventoryManager.getItemGetFlag) и
-- открытые документы (номера chainsaw.FileID, FileManager.IsOpenedFile). Пересчёт раз в 10 с: это ~460 вызовов.
local function enum_values(name)
    local td = sdk.find_type_definition(name)
    local out = {}
    if td == nil then return out end
    for _, f in ipairs(td:get_fields()) do
        if f:is_static() then
            local ok, v = pcall(function() return f:get_data(nil) end)
            if ok and type(v) == "number" and v >= 0 then out[#out + 1] = v end
        end
    end
    table.sort(out)
    return out
end

local item_ids, file_ids = nil, nil
local collected = nil
local COLLECT_EVERY = 10.0
local last_collect = -COLLECT_EVERY

-- v16: сбитые кастеляны. GimmickManager._SrRamons — 16 кукол; у сбитой первый байт _SaveCur.Attr становится 1.
-- v19: глава куклы — не порядок локаций (кукла главы 2 оказалась в 44101, третьей по порядку), а таблица
-- «локация → глава»: известные пары плюс выученные (v21: когда Леон в локации куклы — см. learn_castellans ниже),
-- пары сохраняются в guidforgames_re4_picked.json.
local CASTELLAN_STAGE_CH = { [43411] = 1, [44101] = 2 }

local function castellan_dolls()
    local list = try_field(sdk.get_managed_singleton("chainsaw.GimmickManager"), "_SrRamons")
    local n = try_call(list, "get_Count")
    local dolls = {}
    for i = 0, math.min(type(n) == "number" and n or 0, 40) - 1 do
        local c = try_call(list, "get_Item", i)
        local attr = try_field(try_field(c, "_SaveCur"), "Attr")
        local ok, b = pcall(function() return attr:get_element(0) end)
        if ok and type(b) ~= "number" then ok, b = pcall(function() return b:get_field("mValue") end) end
        dolls[#dolls + 1] = { stage = try_field(c, "<Stage>k__BackingField") or 0, hit = ok and b == 1 }
    end
    return dolls
end

-- Главы сбитых кастелянов (только тех, чья глава известна).
local function castellans_destroyed()
    local out = {}
    for _, d in ipairs(castellan_dolls()) do
        local ch = CASTELLAN_STAGE_CH[d.stage]
        if d.hit and ch then out[#out + 1] = ch end
    end
    table.sort(out)
    return out
end

local function collect_state()
    item_ids = item_ids or enum_values("chainsaw.ItemID")
    file_ids = file_ids or enum_values("chainsaw.FileID")
    local inv = sdk.get_managed_singleton("chainsaw.InventoryManager")
    local fm = sdk.get_managed_singleton("chainsaw.FileManager")
    local c = { items = {}, files = {} }
    if inv ~= nil then
        for _, id in ipairs(item_ids) do
            if try_call(inv, "getItemGetFlag", id) == true then c.items[#c.items + 1] = id end
        end
    end
    if fm ~= nil then
        for _, id in ipairs(file_ids) do
            if try_call(fm, "IsOpenedFile", id) == true then c.files[#c.files + 1] = id end
        end
    end
    local okc, cs = pcall(castellans_destroyed)
    c.castellans = okc and cs or {}
    -- v20: выполненные поручения торговца — QuestOrder с CurrPhase 5 (при новой игре у всех 3; проверено на
    -- «Уничтожить все синие медальоны» 10001 и «Уничтожить всех крыс» 10005)
    c.requests = {}
    local orders = try_call(sdk.get_managed_singleton("chainsaw.QuestManager"), "get_Orders")
    local on = try_call(orders, "get_Count")
    for i = 0, math.min(type(on) == "number" and on or 0, 60) - 1 do
        local o = try_call(orders, "get_Item", i)
        local qid, phase = try_field(o, "<QID>k__BackingField"), try_field(o, "<CurrPhase>k__BackingField")
        if type(qid) == "number" and type(phase) == "number" and phase >= 5 then c.requests[#c.requests + 1] = qid end
    end
    collected = c
end

local function write_live()
    local live = { version = VERSION, time = os.time() }
    pcall(game_state, live)
    local now = os.clock()
    if now - last_collect >= COLLECT_EVERY then
        last_collect = now
        pcall(collect_state)
    end
    if collected ~= nil then
        live.items = collected.items
        live.files = collected.files
        live.castellans = collected.castellans
        live.requests = collected.requests
    end
    if shared.pickups then
        live.pickups = shared.pickups
        local keys = {}
        for id in pairs(shared.keys) do keys[#keys + 1] = id end
        table.sort(keys)
        live.keys = keys
    end
    local okp, pos = pcall(player_object)
    if okp and pos ~= nil then
        live.player = pos
        live.playerHow = player_how
        status = "ok"
    else
        status = "no player position (send diagnostics)"
        live.status = "no-player"
    end
    last_live = live
    json.dump_file(LIVE_FILE, live)
end

-- v8: значки на игровой карте — оверлей REFramework поверх открытой карты (в саму игру ничего не добавляется).
-- Открытие карты в меню ловим перехватом MapManager.onMapStartOpen / onMapClosed (isMapGuiOpen для неё не срабатывает).
-- Точка мира → экран: ConvertGamePosToGuiPos (мир → координаты карты), затем сдвиг и масштаб карты (v11, см. map_view).
-- Документы — из контекстов GmContextReadFile (DocID и Position); уже открытые (FileManager.IsOpenedFile) не рисуются.
local map_open_hooked = false
local map_hooks = 0
do
    local td = sdk.find_type_definition("chainsaw.MapManager")
    for name, value in pairs({ onMapStartOpen = true, onMapClosed = false }) do
        local okm, m = pcall(function() return td:get_method(name) end)
        if okm and m ~= nil then
            local okh = pcall(sdk.hook, m, function(args) map_open_hooked = value end, function(retval) return retval end)
            if okh then map_hooks = map_hooks + 1 end
        end
    end
end

local show_icons = true
local show_debug = false
local doc_spots = nil -- { doc, pos, stage }
local doc_opened = {}

local function collect_doc_spots()
    local spots = {}
    local ctxs = try_field(sdk.get_managed_singleton("chainsaw.GimmickManager"), "_Context")
    local en = try_call(try_call(ctxs, "get_Values"), "GetEnumerator")
    if en == nil then return spots end
    for _ = 1, 20000 do
        local ok, more = pcall(function() return en:call("MoveNext") end)
        if not ok or more ~= true then break end
        local c = try_call(en, "get_Current")
        if type_name(c) == "chainsaw.GmContextReadFile" then
            local st = try_field(c, "<Static>k__BackingField")
            local doc = try_field(st, "DocID")
            local pos = vec3(try_field(st, "Position"))
            if type(doc) == "number" and pos ~= nil then
                spots[#spots + 1] = { doc = doc, pos = pos, stage = try_field(st, "Stage") or try_field(c, "<Stage>k__BackingField") }
            end
        end
    end
    return spots
end

-- v9: что происходит с проекцией — видно в меню мода (строка «Proj: …») и в guidforgames_re4_mapprobe.json.
local map_info = {}

-- Размер экрана (via.Size) для transformWorldToScreen: размер главного вида игры, иначе — размер окна (imgui).
local function screen_size()
    local ok, size = pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local view = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_MainView")
        return view:call("get_Size")
    end)
    if ok and size ~= nil then
        map_info.sizeFrom = "view"
        map_info.size = { w = try_field(size, "w"), h = try_field(size, "h") }
        return size
    end
    map_info.sizeErr = tostring(size)
    local ok2, size2 = pcall(function()
        local d = imgui.get_display_size()
        local v = ValueType.new(sdk.find_type_definition("via.Size"))
        v:set_field("w", d.x)
        v:set_field("h", d.y)
        return v
    end)
    if ok2 and size2 ~= nil then
        map_info.sizeFrom = "imgui"
        return size2
    end
    map_info.sizeErr2 = tostring(size2)
    return nil
end

local function vstr(v)
    if v == nil then return "nil" end
    return string.format("%.1f,%.1f,%.1f", v.x, v.y, v.z)
end

-- Точка мира (или карты, если gui = true) → экран; nil, если не получилось (ошибка — в map_info.err).
local function to_screen(mm, size, p, gui)
    local ok, r = pcall(function()
        local v = Vector3f.new(p.x, p.y, p.z)
        if not gui then v = mm:call("ConvertGamePosToGuiPos", v) end
        return mm:call("transformWorldToScreen", v, size)
    end)
    if not ok then
        map_info.err = tostring(r)
        return nil
    end
    local out = vec3(r)
    if out == nil then map_info.err = "result " .. tostring(r) end
    return out
end

-- v7: разведка карты. Только чтение и вызовы функций-преобразований координат (ConvertGamePosToGuiPos —
-- чистое вычисление); объектов игры не создаёт. Срабатывает на открытии карты, не чаще 6 раз за запуск.
local map_was_open = false
local probes = {}
local function vec_of(v)
    if v == nil then return nil end
    return vec3(v) or { raw = tostring(v) }
end
local function to_gui(mm, p)
    if p == nil then return nil end
    local ok, r = pcall(function() return mm:call("ConvertGamePosToGuiPos", Vector3f.new(p.x, p.y, p.z)) end)
    if ok then return vec_of(r) end
    return { error = tostring(r) }
end
local function map_probe(mm)
    local probe = { time = os.time(), version = VERSION }
    probe.scene = try_call(mm, "get_CurrMapSceneID")
    probe.floor = try_call(mm, "get_CurrMapFloorID")
    probe.playerFloor = try_call(mm, "get_CurrMapPlayerFloorID")
    probe.guiPos = vec_of(try_call(mm, "get_MapGuiPos"))
    probe.guiScale = try_call(mm, "get_MapGuiScale")
    probe.guiScaleRate = try_call(mm, "get_MapGuiScaleRate")
    probe.angle = try_call(mm, "get_MapAngle")
    probe.meshScale = try_call(mm, "get_MeshScaleDiff_RealToMap")
    probe.playerIcon = vec_of(try_call(mm, "getPlayerIconPos"))
    local player = last_live and last_live.player
    probe.player = player
    probe.playerGui = to_gui(mm, player)
    probe.phase = try_call(mm, "get_CurrPhase")
    probe.hooks = map_hooks
    local oks, size = pcall(screen_size)
    if oks and size ~= nil then
        probe.viewSize = { w = try_field(size, "w"), h = try_field(size, "h") }
        probe.playerIconScreen = probe.playerIcon and to_screen(mm, size, probe.playerIcon, true)
        probe.playerScreen = player and to_screen(mm, size, player)
    end
    probe.docSpots = doc_spots and #doc_spots or nil
    probe.info = map_info
    -- синие медальоны: точные мировые координаты из игры → координаты карты
    probe.medallions = {}
    local coins = try_field(sdk.get_managed_singleton("chainsaw.GimmickManager"), "_BlueCoins")
    local n = try_call(coins, "get_Count")
    for i = 0, math.min(type(n) == "number" and n or 0, 8) - 1 do
        local c = try_call(coins, "get_Item", i)
        local pos = vec3(try_field(try_field(c, "<Map>k__BackingField"), "MapPosition"))
        probe.medallions[#probe.medallions + 1] = { pos = pos, gui = to_gui(mm, pos), stage = try_field(c, "<Stage>k__BackingField") }
    end
    local okd, w, h = pcall(function()
        local s = imgui.get_display_size()
        return s.x, s.y
    end)
    if okd then probe.screen = { w = w, h = h } end
    -- устройство значков и камеры карты (типы и простые поля) — для следующего шага
    probes[#probes + 1] = probe
    json.dump_file(MAPPROBE_FILE, { version = VERSION, probes = probes })
    status = "map probe " .. #probes .. " saved"
end

-- v15: кастеляны и маленькие ключи — точки от сервера (guidforgames_re4_marks.json: справочник + метки
-- guides4gamers, переведённые в координаты игры). Кастелян показывается с его главы (по самой дальней главе).
local MARKS_FILE = "guidforgames_re4_marks.json"
local marks = {}
local CHAPTER_NUM = {
    [21100] = 1, [21200] = 2, [21300] = 3, [22100] = 4, [22200] = 5, [22300] = 6, [23100] = 7, [23200] = 8,
    [23300] = 9, [24100] = 10, [24200] = 11, [24300] = 12, [25100] = 13, [25200] = 14, [25300] = 15, [25400] = 16,
}

-- v22: глава, с которой показывать документ (FileID → глава, от сервера): документы будущих глав не рисуем.
local doc_chapters = {}
local function load_marks()
    local ok, data = pcall(json.load_file, MARKS_FILE)
    marks = (ok and type(data) == "table" and type(data.marks) == "table") and data.marks or {}
    doc_chapters = {}
    if ok and type(data) == "table" and type(data.docChapters) == "table" then
        for id, ch in pairs(data.docChapters) do
            local n = tonumber(id)
            if n and type(ch) == "number" then doc_chapters[n] = ch end
        end
    end
end

local castellan_hit = {}

-- v17: подобранные предметы — перехват GameRankSystem.addRankPointPlGetItem (игра начисляет очки ранга за каждый
-- поднятый предмет; хук только записывает номер предмета). В on_frame к номеру добавляется позиция Леона:
-- так различаем одинаковые предметы (маленькие ключи — один ItemID) — подобран тот ключ, что ближе всего.
local SMALL_KEY = 119244800
local PICKED_FILE = "guidforgames_re4_picked.json"
local KEY_RADIUS = 8.0 -- м; точки ключей — по меткам guides4gamers (точность ~1–2 м)
local picked_keys = {} -- id точки ключа → время записи игры при подборе (или true, если неизвестно)
local pickups = {}
local pickup_queue = {}
local pickup_hooks = 0
local last_pickup = nil

-- Привязка ко времени (как жетоны в DD2): время записи игры — GameStatsManager.getCalculatingRecordTime, оно
-- хранится в сохранении. Загрузили сохранение до подбора — время стало меньше, чем при подборе: ключ снова в мире.
local function record_time()
    local t = try_call(sdk.get_managed_singleton("chainsaw.GameStatsManager"), "getCalculatingRecordTime")
    if type(t) == "number" and t > 0 then return t end
    return nil
end

do
    local ok, d = pcall(json.load_file, PICKED_FILE)
    if ok and type(d) == "table" and type(d.keys) == "table" then
        for _, k in ipairs(d.keys) do
            if type(k) == "table" and k.id then picked_keys[k.id] = k.rec or true end
        end
    end
    if ok and type(d) == "table" and type(d.castellanStages) == "table" then
        for _, c in ipairs(d.castellanStages) do
            if type(c) == "table" and type(c.stage) == "number" and type(c.ch) == "number" then CASTELLAN_STAGE_CH[c.stage] = c.ch end
        end
    end
end

local function save_picked()
    local keys = {}
    for id, rec in pairs(picked_keys) do keys[#keys + 1] = { id = id, rec = type(rec) == "number" and rec or nil } end
    table.sort(keys, function(a, b) return a.id < b.id end)
    local stages = {}
    for stage, ch in pairs(CASTELLAN_STAGE_CH) do stages[#stages + 1] = { stage = stage, ch = ch } end
    table.sort(stages, function(a, b) return a.stage < b.stage end)
    json.dump_file(PICKED_FILE, { version = VERSION, keys = keys, castellanStages = stages })
end

local last_record = nil
local unpicked_note = nil
local function check_key_rollback()
    local now = record_time()
    if now == nil then return end
    -- первое чтение после запуска игры тоже сверяем: могли загрузить сохранение старше подбора
    if last_record == nil or now < last_record then
        local undone = 0
        for id, rec in pairs(picked_keys) do
            if type(rec) == "number" and rec > now then
                picked_keys[id] = nil
                undone = undone + 1
            end
        end
        if undone > 0 then
            pcall(save_picked)
            unpicked_note = undone .. " key(s) back after load"
        end
    end
    last_record = now
end

local function item_id_of(v)
    local ok, n = pcall(sdk.to_int64, v)
    if not ok or type(n) ~= "number" then return nil end
    n = n & 0xFFFFFFFF
    if n >= 0x80000000 then n = n - 0x100000000 end
    return n
end

do
    local td = sdk.find_type_definition("chainsaw.GameRankSystem")
    for _, m in ipairs(td and td:get_methods() or {}) do
        if m:get_name() == "addRankPointPlGetItem" then
            local okp, params = pcall(function() return m:get_param_types() end)
            local first = okp and params and params[1] and params[1]:get_full_name() or "?"
            local okh = pcall(sdk.hook, m, function(args)
                local id
                if first == "chainsaw.ItemID" then
                    id = item_id_of(args[3])
                else
                    local okm, item = pcall(sdk.to_managed_object, args[3])
                    if okm and item ~= nil then id = try_call(item, "get_ItemId") or try_field(item, "_ItemId") end
                end
                if type(id) == "number" then pickup_queue[#pickup_queue + 1] = { id = id, clock = os.clock() } end
            end, function(retval) return retval end)
            if okh then pickup_hooks = pickup_hooks + 1 end
        end
    end
end

shared.pickups = pickups
shared.keys = picked_keys

-- v19: сокровища перехват очков ранга не ловит — второй источник: InventoryManager.setItemGetFlag(ItemID, true).
do
    local td = sdk.find_type_definition("chainsaw.InventoryManager")
    for _, m in ipairs(td and td:get_methods() or {}) do
        if m:get_name() == "setItemGetFlag" then
            local okh = pcall(sdk.hook, m, function(args)
                local okb, on = pcall(sdk.to_int64, args[4])
                if okb and type(on) == "number" and (on & 1) == 1 then
                    local id = item_id_of(args[3])
                    if type(id) == "number" then pickup_queue[#pickup_queue + 1] = { id = id, clock = os.clock() } end
                end
            end, function(retval) return retval end)
            if okh then pickup_hooks = pickup_hooks + 1 end
        end
    end
end

-- v18: подобранные предметы с меток (сокровища, патроны, травы…): ближайшая метка в радиусе ITEM_RADIUS, причём
-- вид метки должен подходить к предмету — по префиксу внутреннего имени (it_sm70 — патроны, it_sm71 — лечение,
-- it_sm73 — материалы, it_sm74 — важные вещи, it_sm75/76 — сокровища, it_wp — оружие, гранаты, яйца).
local ITEM_RADIUS = 3.5
local ITEM_KINDS_BY_PREFIX = {
    sm70 = { ammo = true, gunpowder = true },
    sm71 = { herb = true, spray = true },
    sm73 = { gunpowder = true, resources = true },
    sm74 = { keyitem = true },
    sm75 = { treasure = true },
    sm76 = { treasure = true },
    wp = { weapon = true, grenade = true, egg = true },
}
local item_names = nil
local function item_kinds(id)
    if item_names == nil then
        item_names = {}
        local td = sdk.find_type_definition("chainsaw.ItemID")
        for _, f in ipairs(td and td:get_fields() or {}) do
            if f:is_static() then
                local ok, v = pcall(function() return f:get_data(nil) end)
                if ok and type(v) == "number" then item_names[v] = f:get_name() end
            end
        end
    end
    local name = item_names[id]
    if name == nil then return nil end
    local pre = name:match("^it_(sm%d%d)_") or (name:match("^it_wp") and "wp")
    return pre and ITEM_KINDS_BY_PREFIX[pre] or nil
end

local function nearest_mark(pos, group, radius, accept)
    local best, dist = nil, radius
    for _, m in ipairs(marks) do
        if accept(m) and not picked_keys[m.id] and (group == nil or m.group == group) then
            local d = math.sqrt((m.x - pos.x) ^ 2 + (m.z - pos.z) ^ 2)
            if d < dist then best, dist = m, d end
        end
    end
    return best
end

-- Глава куклы с неизвестной главой: номер локации куклы — та же локация (StageID), где стоит Леон рядом с ней
-- (кукла главы 2 — 44101, Леон при выстреле тоже в 44101). Когда Леон в локации такой куклы — сбита она или нет,
-- в том числе в загруженном сохранении, — её глава = глава ближайшей к Леону метки кастеляна той же части игры
-- (до 80 м), ещё не занятая. v20 учил только в момент выстрела и не узнавал кукол, сбитых до загрузки.
local CASTELLAN_LEARN_RADIUS = 80.0
local function learn_castellans()
    local stage = last_live and last_live.stage
    if type(stage) ~= "number" then return end
    local doll = nil
    for _, d in ipairs(castellan_dolls()) do
        if d.stage == stage and CASTELLAN_STAGE_CH[d.stage] == nil then doll = d end
    end
    if doll == nil then return end
    local okp, pos = pcall(player_object)
    if not okp or pos == nil then return end
    if #marks == 0 then pcall(load_marks) end
    local claimed = {}
    for _, ch in pairs(CASTELLAN_STAGE_CH) do claimed[ch] = true end
    local best = nearest_mark(pos, math.floor(stage / 10000), CASTELLAN_LEARN_RADIUS, function(m)
        return m.kind == "castellan" and m.ch ~= nil and not claimed[m.ch]
    end)
    if best then
        CASTELLAN_STAGE_CH[doll.stage] = best.ch
        if doll.hit then castellan_hit[best.ch] = true end
        pcall(save_picked)
    end
end

local function process_pickups()
    if #pickup_queue == 0 then return end
    local queue = pickup_queue
    pickup_queue = {}
    -- много «подборов» в одном кадре — это загрузка сохранения (игра выставляет флаги всем предметам), не подбор
    if #queue > 4 then return end
    if #marks == 0 then pcall(load_marks) end
    local okp, pos = pcall(player_object)
    pos = okp and pos or (last_live and last_live.player)
    local stage = last_live and last_live.stage
    local group = type(stage) == "number" and math.floor(stage / 10000) or nil
    for _, q in ipairs(queue) do
        -- оба варианта метода могут сработать на один подбор — повтор того же предмета за полсекунды пропускаем
        -- один подбор ловят оба перехвата — повтор того же предмета за секунду пропускаем
        local dup = false
        for k = #pickups, math.max(1, #pickups - 3), -1 do
            local prev = pickups[k]
            if prev.item == q.id and q.clock - (prev.clock or 0) < 1.0 then dup = true end
        end
        if not dup then
            local rec = { item = q.id, time = os.time(), clock = q.clock, stage = stage }
            if pos then rec.x, rec.y, rec.z = pos.x, pos.y, pos.z end
            local best = nil
            if q.id == -1 and pos then
                -- кнопка в меню: ближайшая метка предмета (до 3,5 м) или ключа (до 8 м)
                best = nearest_mark(pos, group, ITEM_RADIUS, function(m) return m.kind ~= "castellan" and m.kind ~= "key" end)
                    or nearest_mark(pos, group, KEY_RADIUS, function(m) return m.kind == "key" end)
            elseif q.id == SMALL_KEY and pos then
                best = nearest_mark(pos, group, KEY_RADIUS, function(m) return m.kind == "key" end)
            elseif pos then
                local kinds = item_kinds(q.id)
                best = nearest_mark(pos, group, ITEM_RADIUS, function(m)
                    return m.kind ~= "key" and m.kind ~= "castellan" and (kinds == nil or kinds[m.kind] == true)
                end)
            end
            if best then
                picked_keys[best.id] = record_time() or true
                rec.mark = best.id
                pcall(save_picked)
            end
            pickups[#pickups + 1] = rec
            if #pickups > 30 then table.remove(pickups, 1) end
            last_pickup = rec
        end
    end
end

local function on_map_open(mm)
    pcall(load_marks)
    castellan_hit = {}
    local okc, cs = pcall(castellans_destroyed)
    for _, i in ipairs(okc and cs or {}) do castellan_hit[i] = true end
    if doc_spots == nil then
        local ok, spots = pcall(collect_doc_spots)
        doc_spots = ok and spots or {}
    end
    local fm = sdk.get_managed_singleton("chainsaw.FileManager")
    doc_opened = {}
    for _, s in ipairs(doc_spots) do
        if s.doc < 1000 then doc_opened[s.doc] = try_call(fm, "IsOpenedFile", s.doc) == true end
    end
    if #probes < 6 then
        local ok, err = pcall(map_probe, mm)
        if not ok then map_info.probeErr = tostring(err) end
    end
end

-- v11: своё преобразование «карта → экран» (transformWorldToScreen считает через камеру мира и для карты не годится).
-- Выведено по трём скриншотам (сдвиг и масштаб карты разные, расхождение 2–3 %): точка карты g = ConvertGamePosToGuiPos(мир)
-- (это x и z мира), экран = центр + k · MapGuiScale · (g + MapGuiPos), k = высота экрана / 1080 (интерфейс рассчитан на 1080p).
local function map_view(mm)
    local size = map_info.size
    local pos = vec3(try_call(mm, "get_MapGuiPos"))
    local scale = try_call(mm, "get_MapGuiScale")
    if not size or type(size.w) ~= "number" or type(size.h) ~= "number" or pos == nil or type(scale) ~= "number" then return nil end
    return { cx = size.w / 2, cy = size.h / 2, k = size.h / 1080 * scale, ui = size.h / 1080, px = pos.x, py = pos.y }
end

-- v12–13: в режиме «Фиксированное положение» карта повёрнута. Поворот точки карты делает сама игра
-- (applyRotation); проверено по скриншотам: сначала поворот, потом сдвиг карты.

local function rotate(mm, fn, x, y)
    local ok, r = pcall(function() return mm:call(fn, Vector3f.new(x, y, 0)) end)
    r = ok and vec3(r) or nil
    if r == nil then return x, y end
    return r.x, r.y
end

local function map_to_screen(mm, view, p)
    local ok, g = pcall(function() return mm:call("ConvertGamePosToGuiPos", Vector3f.new(p.x, p.y, p.z)) end)
    g = ok and vec3(g) or nil
    if g == nil then return nil end
    local x, y = rotate(mm, "applyRotation", g.x, g.y)
    return { x = view.cx + view.k * (x + view.px), y = view.cy + view.k * (y + view.py) }
end

-- v14: значок документа в духе значков игры — тёмный круглый жетон с золотистой каймой и белым листом с загнутым
-- углом и строчками (эмодзи шрифт оверлея не рисует). ui — масштаб интерфейса (высота экрана / 1080).
local function draw_doc_icon(x, y, ui)
    local r = 14 * ui
    draw.filled_circle(x, y, r + 3 * ui, 0x60000000, 24) -- тень
    draw.filled_circle(x, y, r, 0xF0201C1A, 24)
    draw.outline_circle(x, y, r, 0xFF5AB4D2, 24)
    local w, h, f = 10 * ui, 13 * ui, 3.5 * ui
    local x0, y0 = x - w / 2, y - h / 2
    local x1, y1 = x0 + w, y0 + h
    draw.filled_rect(x0, y0 + f, w, h - f, 0xFFF2F2F2)
    draw.filled_quad(x0, y0, x1 - f, y0, x1 - f, y0 + f, x0, y0 + f, 0xFFF2F2F2)
    draw.filled_quad(x1 - f, y0, x1, y0 + f, x1 - f, y0 + f, x1 - f, y0 + f, 0xFFA0A0A0)
    for i = 1, 3 do
        local ly = y0 + f + i * (h - f) / 4.2
        draw.line(x0 + 2 * ui, ly, x1 - 2 * ui, ly, 0xFF505050)
    end
end

-- Жетон-основа для значков (тёмный круг с золотистой каймой и тенью); возвращает радиус.
local function draw_badge(x, y, ui)
    local r = 14 * ui
    draw.filled_circle(x, y, r + 3 * ui, 0x60000000, 24)
    draw.filled_circle(x, y, r, 0xF0201C1A, 24)
    draw.outline_circle(x, y, r, 0xFF5AB4D2, 24)
    return r
end

-- Кастелян: заводная шестерёнка (кольцо с зубцами и ключом завода сверху), медный цвет.
local function draw_castellan_icon(x, y, ui)
    draw_badge(x, y, ui)
    local c = 0xFF4A8CD8
    local r = 5.5 * ui
    for i = 0, 7 do
        local a = i * math.pi / 4
        draw.line(x + math.cos(a) * r, y + math.sin(a) * r, x + math.cos(a) * (r + 3 * ui), y + math.sin(a) * (r + 3 * ui), c)
    end
    draw.filled_circle(x, y, r, c, 16)
    draw.filled_circle(x, y, 2.2 * ui, 0xFF201C1A, 12)
end

-- Маленький ключ: кольцо, стержень и бородка, белый.
local function draw_key_icon(x, y, ui)
    draw_badge(x, y, ui)
    local c = 0xFFF2F2F2
    draw.outline_circle(x - 4 * ui, y, 3.2 * ui, c, 12)
    draw.line(x - 0.8 * ui, y, x + 7 * ui, y, c)
    draw.line(x + 4 * ui, y, x + 4 * ui, y + 3 * ui, c)
    draw.line(x + 6.5 * ui, y, x + 6.5 * ui, y + 3 * ui, c)
end

-- v18: значки предметов (жетон + простой рисунок), цвета ABGR.
local ITEM_ICONS = {
    treasure = function(x, y, u) -- белый ромб-самоцвет
        draw.filled_quad(x, y - 7 * u, x + 6 * u, y, x, y + 7 * u, x - 6 * u, y, 0xFFF5F0E6)
        draw.line(x - 6 * u, y, x + 6 * u, y, 0xFFB0A090)
    end,
    ammo = function(x, y, u) -- три патрона
        for i = -1, 1 do
            local bx = x + i * 4.5 * u
            draw.filled_rect(bx - 1.6 * u, y - 2 * u, 3.2 * u, 8 * u, 0xFF40B8E0)
            draw.filled_circle(bx, y - 2.5 * u, 1.7 * u, 0xFF70D8F0, 8)
        end
    end,
    herb = function(x, y, u) -- зелёный лист
        draw.filled_quad(x, y - 8 * u, x + 5 * u, y, x, y + 7 * u, x - 5 * u, y, 0xFF40B040)
        draw.line(x, y - 6 * u, x, y + 7 * u, 0xFF205020)
    end,
    spray = function(x, y, u) -- баллон с красным крестом
        draw.filled_rect(x - 4 * u, y - 5 * u, 8 * u, 12 * u, 0xFFF0F0F0)
        draw.filled_rect(x - 1.5 * u, y - 8 * u, 3 * u, 3 * u, 0xFFB0B0B0)
        draw.filled_rect(x - 1 * u, y - 2 * u, 2 * u, 7 * u, 0xFF2020D0)
        draw.filled_rect(x - 3.5 * u, y + 0.5 * u, 7 * u, 2 * u, 0xFF2020D0)
    end,
    grenade = function(x, y, u) -- граната с чекой
        draw.filled_circle(x, y + 1.5 * u, 6 * u, 0xFF306030, 16)
        draw.filled_rect(x - 2 * u, y - 7 * u, 4 * u, 3 * u, 0xFFA0A0A0)
        draw.outline_circle(x + 4 * u, y - 6 * u, 2 * u, 0xFFA0A0A0, 8)
    end,
    gunpowder = function(x, y, u) -- кучка пороха
        draw.filled_quad(x - 7 * u, y + 5 * u, x - 2 * u, y - 4 * u, x + 2 * u, y - 4 * u, x + 7 * u, y + 5 * u, 0xFF8090A0)
    end,
    resources = function(x, y, u) -- ящик с материалами
        draw.filled_rect(x - 6 * u, y - 5 * u, 12 * u, 10 * u, 0xFF3070A0)
        draw.line(x - 6 * u, y - 5 * u, x + 6 * u, y + 5 * u, 0xFF204060)
        draw.line(x + 6 * u, y - 5 * u, x - 6 * u, y + 5 * u, 0xFF204060)
    end,
    weapon = function(x, y, u) -- пистолет
        draw.filled_rect(x - 7 * u, y - 4 * u, 13 * u, 4 * u, 0xFFD0D0D0)
        draw.filled_quad(x + 1 * u, y, x + 6 * u, y, x + 4 * u, y + 7 * u, x, y + 7 * u, 0xFFD0D0D0)
    end,
    keyitem = function(x, y, u) -- золотой ключ
        local c = 0xFF40C0F0
        draw.outline_circle(x - 4 * u, y, 3.2 * u, c, 12)
        draw.line(x - 0.8 * u, y, x + 7 * u, y, c)
        draw.line(x + 4 * u, y, x + 4 * u, y + 3 * u, c)
        draw.line(x + 6.5 * u, y, x + 6.5 * u, y + 3 * u, c)
    end,
    egg = function(x, y, u) -- яйцо
        draw.filled_circle(x, y + 1 * u, 5.5 * u, 0xFFE0F0F8, 16)
        draw.filled_circle(x, y - 2 * u, 4.5 * u, 0xFFE0F0F8, 16)
    end,
    pesetas = function(x, y, u) -- монета
        draw.filled_circle(x, y, 6.5 * u, 0xFF30B8E8, 16)
        draw.outline_circle(x, y, 4.5 * u, 0xFF1A7090, 16)
    end,
}
local ICON_ORDER = { "treasure", "ammo", "herb", "spray", "grenade", "gunpowder", "resources", "weapon", "keyitem", "egg", "pesetas", "key", "castellan" }
local show_kind = {}
for _, k in ipairs(ICON_ORDER) do show_kind[k] = true end

local function draw_item_icon(kind, x, y, ui)
    draw_badge(x, y, ui)
    local f = ITEM_ICONS[kind]
    if f then f(x, y, ui) end
end

local function draw_map_icons(mm)
    map_info.frames = (map_info.frames or 0) + 1
    if map_info.size == nil then screen_size() end
    local view = map_view(mm)
    if view == nil then return end
    local drawn = 0
    local group = last_live and type(last_live.stage) == "number" and math.floor(last_live.stage / 10000) or nil
    if show_icons then
        for _, s in ipairs(doc_spots or {}) do
            local doc_ch = doc_chapters[s.doc]
            local most_ch = last_live and CHAPTER_NUM[last_live.mostChapter or -1] or nil
            if s.doc < 1000 and not doc_opened[s.doc] and (group == nil or type(s.stage) ~= "number" or math.floor(s.stage / 10000) == group)
                and (doc_ch == nil or most_ch == nil or doc_ch <= most_ch) then
                local p = map_to_screen(mm, view, s.pos)
                if p ~= nil and p.x > -20 and p.y > -20 and p.x < view.cx * 2 + 20 and p.y < view.cy * 2 + 20 then
                    drawn = drawn + 1
                    draw_doc_icon(p.x, p.y, view.ui)
                end
            end
        end
    end
    if show_icons then
        local most = last_live and CHAPTER_NUM[last_live.mostChapter or -1] or nil
        for _, m in ipairs(marks) do
            local show = (group == nil or m.group == group) and show_kind[m.kind] ~= false and not picked_keys[m.id]
                and (m.kind ~= "castellan" or ((m.ch == nil or most == nil or m.ch <= most) and not castellan_hit[m.ch]))
            if show and type(m.x) == "number" and type(m.z) == "number" then
                local p = map_to_screen(mm, view, { x = m.x, y = 0, z = m.z })
                if p ~= nil and p.x > -20 and p.y > -20 and p.x < view.cx * 2 + 20 and p.y < view.cy * 2 + 20 then
                    drawn = drawn + 1
                    if m.kind == "castellan" then
                        draw_castellan_icon(p.x, p.y, view.ui)
                    elseif m.kind == "key" then
                        draw_key_icon(p.x, p.y, view.ui)
                    else
                        draw_item_icon(m.kind, p.x, p.y, view.ui)
                    end
                end
            end
        end
    end
    if show_debug then
        -- проверка: зелёный круг должен лечь на стрелку Леона
        local pl = last_live and last_live.player
        local b = pl and map_to_screen(mm, view, pl)
        map_info.playerScreen = vstr(b and { x = b.x, y = b.y, z = 0 })
        if b then draw.outline_circle(b.x, b.y, 18, 0xFF00FF00, 20) end
        map_info.angle = string.format("angle %s, deg %s", tostring(try_call(mm, "get_MapAngle")), tostring(try_field(mm, "MapAngleDegCache")))
    end
    map_info.drawn = drawn
end

re.on_frame(function()
    if #pickup_queue > 0 then pcall(process_pickups) end
    local nowc = os.clock()
    if nowc - (shared.rollback_at or -10) >= 2.0 then
        shared.rollback_at = nowc
        pcall(check_key_rollback)
        pcall(learn_castellans)
    end
    local mm = sdk.get_managed_singleton("chainsaw.MapManager")
    local open = map_open_hooked or try_call(mm, "isMapGuiOpen") == true
    if open and not map_was_open then
        local ok, err = pcall(on_map_open, mm)
        if not ok then map_info.openErr = tostring(err) end
    end
    map_was_open = open
    if open and (show_icons or show_debug) then
        local ok, err = pcall(draw_map_icons, mm)
        if not ok then map_info.drawErr = tostring(err) end
    end
    local now = os.clock()
    if now - last_write < INTERVAL then return end
    last_write = now
    local ok, err = pcall(write_live)
    if not ok then status = "error: " .. tostring(err) end
end)

-- Текст сообщения игры по Guid (via.gui.message) на нужном языке: 6 — русский, 1 — английский (как в DD2).
local LANG_EN, LANG_RU = 1, 6
local message_td = nil
local function message(guid, lang)
    if guid == nil then return nil end
    message_td = message_td or sdk.find_type_definition("via.gui.message")
    if message_td == nil then return nil end
    local m = message_td:get_method(lang and "get(System.Guid, via.Language)" or "get(System.Guid)")
    if m == nil then return nil end
    local ok, r = pcall(function()
        if lang then return m:call(nil, guid, lang) end
        return m:call(nil, guid)
    end)
    if ok and type(r) == "string" and r ~= "" then return r end
    return nil
end

-- ── Диагностика ─────────────────────────────────────────────────────────────────────────────────────────────

local function describe_type(td)
    local out = { name = td:get_full_name(), fields = {}, methods = {}, parents = {} }
    local p = td:get_parent_type()
    while p ~= nil do
        table.insert(out.parents, p:get_full_name())
        p = p:get_parent_type()
    end
    for _, f in ipairs(td:get_fields()) do
        local t = f:get_type()
        table.insert(out.fields, f:get_name() .. ": " .. (t and t:get_full_name() or "?") .. (f:is_static() and " [static]" or ""))
    end
    for _, m in ipairs(td:get_methods()) do
        local r = m:get_return_type()
        -- v7: типы параметров — чтобы знать, что можно безопасно передать
        local params = {}
        local okp, ps = pcall(function() return m:get_param_types() end)
        if okp and ps then
            for _, pt in ipairs(ps) do params[#params + 1] = pt:get_full_name() end
        end
        local sig = #params > 0 and table.concat(params, ", ") or tostring(m:get_num_params())
        table.insert(out.methods, m:get_name() .. "(" .. sig .. "): " .. (r and r:get_full_name() or "?"))
    end
    return out
end

-- Простые значения полей (числа, строки, флаги) — без вызова методов, только чтение.
local function simple_values(obj, td)
    local values = {}
    local t, level = td, 0
    while t ~= nil and level < 3 and t:get_full_name() ~= "System.Object" do
        for _, f in ipairs(t:get_fields()) do
            if not f:is_static() then
                local ok, v = pcall(function() return obj:get_field(f:get_name()) end)
                if ok and (type(v) == "number" or type(v) == "boolean" or type(v) == "string") then
                    values[f:get_name()] = v
                elseif ok and type(v) == "userdata" then
                    values[f:get_name()] = "<" .. (type_name(v) or "?") .. ">"
                end
            end
        end
        t = t:get_parent_type()
        level = level + 1
    end
    return values
end

-- Вероятные менеджеры RE4 (пространство имён chainsaw); find_type_definition только читает описания типов.
local MANAGER_WORDS = {
    "Character", "Player", "Enemy", "Item", "Inventory", "Weapon", "Equipment", "Campaign", "Chapter", "Scenario",
    "Progress", "Game", "GameStats", "GameRank", "GameRankSystem", "Stage", "Level", "Area", "Location", "Map", "MapData",
    "Gimmick", "Interact", "Flag", "GlobalFlag", "StageFlag", "Save", "SaveData", "GameData", "Gui", "GUI", "Timeline",
    "Merchant", "Shop", "Request", "Quest", "Mission", "Collection", "Achievement", "Trophy", "Record", "Charm",
    "Typewriter", "KeyItem", "Treasure", "Difficulty", "Timer", "Clock", "Camera", "Movie", "Fade", "Scene", "Navigation",
    "Ingame", "InGame", "Message", "Option", "Statistics", "Score", "Money", "Wallet",
    -- v5: где лежат прочитанные документы («Файлы»)
    "File", "Files", "Document", "Archive", "Note", "Memo", "Book", "Library", "Reading", "Notebook", "Report",
}

-- Байты массива System.Byte[] (до 64) — для сравнения состояний.
local function bytes_of(arr)
    if arr == nil then return nil end
    local n = try_call(arr, "get_Length") or try_call(arr, "get_size")
    if type(n) ~= "number" then return nil end
    local out = {}
    for i = 0, math.min(n, 64) - 1 do
        local ok, v = pcall(function() return arr:get_element(i) end)
        if ok and type(v) ~= "number" then ok, v = pcall(function() return v:get_field("mValue") end) end
        out[#out + 1] = ok and v or "?"
    end
    return out
end

local function dump_diag()
    local diag = { version = VERSION, time = os.time(), status = status, live = last_live, singletons = {}, types = {} }
    local names = {}
    for _, w in ipairs(MANAGER_WORDS) do
        names[#names + 1] = "chainsaw." .. w .. "Manager"
        names[#names + 1] = "chainsaw." .. w .. "System"
    end
    for _, name in ipairs(names) do
        local okd, td = pcall(sdk.find_type_definition, name)
        if okd and td ~= nil then
            local entry = { type = describe_type(td) }
            local oks, obj = pcall(sdk.get_managed_singleton, name)
            if oks and obj ~= nil then
                entry.singleton = true
                local okv, values = pcall(simple_values, obj, td)
                entry.values = okv and values or tostring(values)
            end
            diag.singletons[name] = entry
        end
    end
    -- База типов, если она есть в этой сборке REFramework: все типы chainsaw.* с «Manager» в имени.
    local okt, tdb = pcall(sdk.get_tdb)
    if okt and tdb ~= nil then
        local list = {}
        local okn, n = pcall(function() return tdb:get_num_types() end)
        for i = 0, (okn and n or 0) - 1 do
            local okg, td = pcall(function() return tdb:get_type(i) end)
            local name = okg and td and td:get_full_name()
            if name and name:sub(1, 9) == "chainsaw." and (name:find("Manager") or name:find("Context")) and #list < 3000 then
                list[#list + 1] = name
            end
        end
        diag.typeList = list
    else
        diag.typeList = "no tdb"
    end
    -- v2: имена значений перечислений (номера глав, кампаний, сцен карты, предметов) — статические поля типа.
    diag.enums = {}
    for _, en in ipairs({ "chainsaw.ChapterID", "chainsaw.CampaignID", "chainsaw.CampaignManager.Difficulty",
        "chainsaw.MapDefine.MapSceneID", "chainsaw.MapDefine.MapFloorID", "chainsaw.StageID", "chainsaw.ItemID",
        "chainsaw.FileID", "chainsaw.DocumentID", "chainsaw.ArchiveID", "chainsaw.FileCategory", "chainsaw.gui.FileID" }) do
        local okd, td = pcall(sdk.find_type_definition, en)
        if okd and td ~= nil then
            local vals = {}
            for _, f in ipairs(td:get_fields()) do
                if f:is_static() then
                    local okv, v = pcall(function() return f:get_data(nil) end)
                    if okv and type(v) == "number" then vals[f:get_name()] = v end
                end
            end
            diag.enums[en] = vals
        end
    end
    -- v2: какие предметы игрок уже получал (getItemGetFlag — только чтение флага): по ним — найденные сокровища.
    local inv = sdk.get_managed_singleton("chainsaw.InventoryManager")
    local got = {}
    for name, id in pairs(diag.enums["chainsaw.ItemID"] or {}) do
        local okg, v = pcall(function() return inv:call("getItemGetFlag", id) end)
        if okg and v == true then got[#got + 1] = name end
    end
    diag.itemsGot = got
    -- v2: устройство сбора (кастеляны и т. п.), поручений торговца и здоровья — объекты на 2 уровня вглубь.
    local function explore(obj, depth)
        if obj == nil then return nil end
        local okt, td = pcall(function() return obj:get_type_definition() end)
        if not okt or td == nil then return tostring(obj) end
        local out = { ["$type"] = td:get_full_name() }
        local t, level = td, 0
        while t ~= nil and level < 3 and t:get_full_name() ~= "System.Object" do
            for _, f in ipairs(t:get_fields()) do
                if not f:is_static() then
                    local name = f:get_name()
                    local ok, v = pcall(function() return obj:get_field(name) end)
                    if ok then
                        local ft = f:get_type()
                        if ft ~= nil and ft:get_full_name() == "System.Guid" then
                            out[name] = { ru = message(v, LANG_RU), en = message(v, LANG_EN) }
                        elseif type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
                            out[name] = v
                        elseif depth > 0 and type(v) == "userdata" then
                            out[name] = explore(v, depth - 1)
                        else
                            out[name] = "<" .. (type_name(v) or tostring(v)) .. ">"
                        end
                    end
                end
            end
            t = t:get_parent_type()
            level = level + 1
        end
        return out
    end
    local cm = sdk.get_managed_singleton("chainsaw.CampaignManager")
    diag.collect = explore(try_call(cm, "get_MainCampaignCollectInfo"), 2)
    diag.collectSw = explore(try_call(cm, "get_Cp1011CollectInfo"), 2)
    diag.clearInfo = explore(try_call(cm, "get_MainCampaignTotalClearInfo"), 1)
    local qm = sdk.get_managed_singleton("chainsaw.QuestManager")
    local orders = try_call(qm, "get_Orders")
    local count = try_call(orders, "get_Count")
    diag.quests = { count = count, items = {} }
    for i = 0, math.min((type(count) == "number" and count or 0), 40) - 1 do
        local o = try_call(orders, "get_Item", i)
        diag.quests.items[#diag.quests.items + 1] = explore(o, 2)
    end
    -- v3: названия предметов — методы-«get» менеджеров предметов с одним параметром (ItemID), только для проб,
    -- и что лежит в менеджере сокровищ.
    local im = sdk.get_managed_singleton("chainsaw.ItemManager")
    diag.itemManagers = {}
    for _, getter in ipairs({ "get_ItemMessageManager", "get_ItemDefinitionManager", "get_TreasureItemManager" }) do
        local sub = try_call(im, getter)
        local okt, td = pcall(function() return sub:get_type_definition() end)
        if okt and td ~= nil then
            local info = { type = describe_type(td), probes = {} }
            local samples = {}
            for _, nm in ipairs(got) do if #samples < 3 then samples[#samples + 1] = diag.enums["chainsaw.ItemID"][nm] end end
            for _, m in ipairs(td:get_methods()) do
                local mn = m:get_name()
                if m:get_num_params() == 1 and (mn:sub(1, 3) == "get" or mn:sub(1, 4) == "find") then
                    for _, id in ipairs(samples) do
                        local okc, r = pcall(function() return m:call(sub, id) end)
                        if okc and r ~= nil then
                            local tn = type_name(r)
                            local val = type(r) == "string" and r or (tn == "System.Guid" and { ru = message(r, LANG_RU), en = message(r, LANG_EN) })
                                or (type(r) == "userdata" and explore(r, 1)) or r
                            info.probes[#info.probes + 1] = { method = mn, id = id, result = val }
                        end
                    end
                end
            end
            info.values = explore(sub, 1)
            diag.itemManagers[getter] = info
        end
    end
    -- v4: названия всех предметов (RU+EN) — ItemMessageManager.getItemNameMsgId → текст сообщения.
    local imm = try_call(im, "get_ItemMessageManager")
    diag.itemNames = {}
    for name, id in pairs(diag.enums["chainsaw.ItemID"] or {}) do
        if id > 0 then
            local guid = try_call(imm, "getItemNameMsgId", id)
            local ru, en = message(guid, LANG_RU), message(guid, LANG_EN)
            if ru or en then diag.itemNames[name] = { id = id, ru = ru, en = en } end
        end
    end
    -- v4: все списки GimmickManager (имя поля → число элементов, тип и первый элемент) — ищем кастелянов и сокровища;
    -- у синих медальонов — координаты (MapPosition) для привязки карт.
    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
    diag.gimmicks = {}
    diag.medallions = {}
    local okg, gtd = pcall(function() return gm:get_type_definition() end)
    if okg and gtd ~= nil then
        for _, f in ipairs(gtd:get_fields()) do
            local fname = f:get_name()
            if not f:is_static() then
                local list = try_field(gm, fname)
                local n = try_call(list, "get_Count")
                if type(n) == "number" then
                    diag.gimmicks[fname] = { count = n, type = type_name(list), first = n > 0 and explore(try_call(list, "get_Item", 0), 1) or nil }
                end
            end
        end
        local coins = try_field(gm, "_BlueCoins")
        local n = try_call(coins, "get_Count")
        for i = 0, math.min(type(n) == "number" and n or 0, 60) - 1 do
            local c = try_call(coins, "get_Item", i)
            local map = try_field(c, "<Map>k__BackingField")
            local save = try_field(c, "_SaveCur")
            diag.medallions[#diag.medallions + 1] = {
                stage = try_field(c, "<Stage>k__BackingField"),
                quest = try_field(c, "_QuestID"),
                pos = vec3(try_field(map, "MapPosition")),
                detected = try_field(save, "IsDetected"),
                attr = bytes_of(try_field(save, "Attr")),
            }
        end
        -- v5: кастеляны — локация и байты состояния (сравним до и после выстрела по кукле).
        diag.castellans = {}
        local rams = try_field(gm, "_SrRamons")
        local rn = try_call(rams, "get_Count")
        for i = 0, math.min(type(rn) == "number" and rn or 0, 40) - 1 do
            local c = try_call(rams, "get_Item", i)
            local save = try_field(c, "_SaveCur")
            diag.castellans[#diag.castellans + 1] = {
                stage = try_field(c, "<Stage>k__BackingField"),
                detected = try_field(save, "IsDetected"),
                attr = bytes_of(try_field(save, "Attr")),
                values = explore(c, 2),
            }
        end
    end
    -- v6: документы — открыт ли, прочитан ли и что лежит в FileData (названия — из Guid-полей, RU+EN).
    local fm = sdk.get_managed_singleton("chainsaw.FileManager")
    diag.files = {}
    if fm ~= nil then
        for _, id in ipairs(enum_values("chainsaw.FileID")) do
            diag.files[#diag.files + 1] = {
                id = id,
                opened = try_call(fm, "IsOpenedFile", id),
                read = try_call(fm, "HasReadFile", id),
                data = explore(try_call(fm, "getSingleFileData", id), 2),
            }
        end
    end
    diag.collected = collected
    -- v7: все контексты механизмов (GimmickManager._Context): сколько каких типов и примеры тех, что похожи на
    -- предметы и документы, с позицией на карте — источник точек для значков.
    local ctxs = try_field(sdk.get_managed_singleton("chainsaw.GimmickManager"), "_Context")
    local values = try_call(ctxs, "get_Values")
    local en = try_call(values, "GetEnumerator")
    diag.contexts = { types = {}, examples = {}, statics = {}, staticExamples = {} }
    if en ~= nil then
        for _ = 1, 20000 do
            local ok, more = pcall(function() return en:call("MoveNext") end)
            if not ok or more ~= true then break end
            local c = try_call(en, "get_Current")
            local tn = type_name(c) or "?"
            diag.contexts.types[tn] = (diag.contexts.types[tn] or 0) + 1
            local ex = diag.contexts.examples[tn] or {}
            if #ex < 3 and (tn:find("Item") or tn:find("Doc") or tn:find("File") or tn:find("Treasure") or tn:find("Drop")
                or tn:find("Pickup") or tn:find("Box") or tn:find("Chest") or tn:find("Drawer") or tn:find("Key")) then
                local map = try_field(c, "<Map>k__BackingField")
                ex[#ex + 1] = {
                    stage = try_field(c, "<Stage>k__BackingField"),
                    pos = vec3(try_field(map, "MapPosition")),
                    values = explore(c, 2),
                }
                diag.contexts.examples[tn] = ex
            end
            -- v13: какие статические данные у контекстов (там DocID у документов — ищем ItemID у сокровищ)
            local st = try_field(c, "<Static>k__BackingField")
            local sn = type_name(st) or "nil"
            diag.contexts.statics[sn] = (diag.contexts.statics[sn] or 0) + 1
            local sx = diag.contexts.staticExamples[sn] or {}
            if #sx < 2 and sn ~= "nil" and sn ~= "chainsaw.GmContextReadFile.StaticDataReadFile" then
                sx[#sx + 1] = { ctx = tn, stage = try_field(c, "<Stage>k__BackingField"), static = explore(st, 2) }
                diag.contexts.staticExamples[sn] = sx
            end
        end
    end
    local completed = try_call(qm, "getCompletedQuestOrder")
    diag.quests.completed = try_call(completed, "get_Count")
    local pctx = try_call(sdk.get_managed_singleton("chainsaw.CharacterManager"), "getPlayerContextRef")
    diag.vital = explore(try_call(pctx, "getHitPointVital"), 1)
    local okvt, vtd = pcall(function() return try_call(pctx, "getHitPointVital"):get_type_definition() end)
    if okvt and vtd ~= nil then diag.types[vtd:get_full_name()] = describe_type(vtd) end
    -- Контекст игрока по найденному пути — для следующих версий (здоровье, деньги, инвентарь).
    for _, p in ipairs(PLAYER_PATHS) do
        local ctx = try_call(sdk.get_managed_singleton(p[1]), p[2])
        if ctx ~= nil then
            local okc, td = pcall(function() return ctx:get_type_definition() end)
            if okc and td ~= nil then
                diag.types[td:get_full_name()] = describe_type(td)
                diag.playerContext = { path = p[1] .. "." .. p[2], values = simple_values(ctx, td) }
            end
            break
        end
    end
    json.dump_file(DIAG_FILE, diag)
    status = "diagnostics saved to reframework/data/" .. DIAG_FILE
end

-- v4: точка для привязки карты — добавляется в guidforgames_re4_points.json (файл копится, не перезаписывается).
local points = nil
local function remember_point()
    if points == nil then
        local ok, old = pcall(json.load_file, POINTS_FILE)
        points = (ok and type(old) == "table" and type(old.points) == "table") and old.points or {}
    end
    if last_live == nil or last_live.player == nil then
        status = "no player position yet"
        return
    end
    local l = last_live
    points[#points + 1] = { time = os.time(), player = l.player, stage = l.stage, mapScene = l.mapScene, mapFloor = l.mapFloor, chapter = l.chapter }
    json.dump_file(POINTS_FILE, { version = VERSION, points = points })
    status = "point " .. #points .. " saved"
end

re.on_draw_ui(function()
    if imgui.tree_node("GuidForGames RE4") then
        imgui.text("Bridge v" .. VERSION .. ": " .. status)
        if last_live ~= nil and last_live.player ~= nil then
            local p = last_live.player
            imgui.text(string.format("Player: x %.1f, y %.1f, z %.1f (%s)", p.x, p.y, p.z, tostring(last_live.playerHow)))
            imgui.text("Chapter: " .. tostring(last_live.chapter) .. " (most " .. tostring(last_live.mostChapter) .. "), stage: "
                .. tostring(last_live.stage) .. ", ptas: " .. tostring(last_live.ptas))
        end
        imgui.text("Map: hooks " .. map_hooks .. ", open " .. tostring(map_was_open) .. ", file spots " .. tostring(doc_spots and #doc_spots)
            .. ", marks " .. #marks)
        imgui.text("Proj: size " .. tostring(map_info.sizeFrom) .. " " .. (map_info.size and (tostring(map_info.size.w) .. "x" .. tostring(map_info.size.h)) or "?")
            .. ", frames " .. tostring(map_info.frames) .. ", drawn " .. tostring(map_info.drawn))
        imgui.text("Proj: player -> " .. tostring(map_info.playerScreen) .. ", " .. tostring(map_info.angle))
        for _, k in ipairs({ "err", "drawErr", "openErr", "probeErr", "sizeErr", "sizeErr2" }) do
            if map_info[k] then imgui.text("Proj " .. k .. ": " .. map_info[k]) end
        end
        local c1, v1 = imgui.checkbox("Show icons on map", show_icons)
        if c1 then show_icons = v1 end
        if imgui.tree_node("Icon types") then
            for _, k in ipairs(ICON_ORDER) do
                local ck, vk = imgui.checkbox(k, show_kind[k])
                if ck then show_kind[k] = vk end
            end
            imgui.tree_pop()
        end
        local c2, v2 = imgui.checkbox("Debug: player circle on map", show_debug)
        if c2 then show_debug = v2 end
        local lp = last_pickup
        imgui.text("Pickups: hooks " .. pickup_hooks .. ", marks picked " .. (function() local n = 0 for _ in pairs(picked_keys) do n = n + 1 end return n end)()
            .. (lp and string.format(", last item %d at %.1f, %.1f%s", lp.item, lp.x or 0, lp.z or 0, lp.mark and (" -> " .. lp.mark) or "") or ""))
        imgui.text("Record time: " .. tostring(last_record) .. (unpicked_note and (", " .. unpicked_note) or ""))
        -- ключ, подобранный до v17 (или если перехват не сработал): встать рядом и нажать
        if imgui.button("Mark nearest item as picked") then
            pickup_queue[#pickup_queue + 1] = { id = -1, clock = os.clock() }
        end
        imgui.same_line()
        if imgui.button("Reset picked items") then
            picked_keys = {}
            shared.keys = picked_keys
            pcall(save_picked)
        end
        if imgui.button("Remember point") then
            local ok, err = pcall(remember_point)
            if not ok then status = "point error: " .. tostring(err) end
        end
        if imgui.button("Dump diagnostics") then
            local ok, err = pcall(dump_diag)
            if not ok then status = "diagnostics error: " .. tostring(err) end
        end
        imgui.tree_pop()
    end
end)
