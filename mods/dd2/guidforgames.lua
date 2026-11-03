-- GuidForGames — мост между Dragon's Dogma 2 и приложением-компаньоном (REFramework, Lua).
--
-- Только ЧИТАЕТ состояние игры и пишет его в файл; в игре ничего не меняет.
-- Установка: файл в <папка игры>\reframework\autorun\ (или gfg-service install-mods).
-- Файлы пишутся в <папка игры>\reframework\data\:
--   guidforgames_live.json — живое состояние (позиция, отслеживаемый квест и его цель, время, метки игрока
--                            на карте, журнал квестов, пешки и драконья чума, симпатия NPC, какие жетоны
--                            искателя подобраны), раз в 2 секунды;
--   guidforgames_events.json — события: подобран жетон искателя (где стоял игрок), открыт сундук — копится;
--   guidforgames_names.json — названия квестов из игры на русском и английском (кнопка «Dump names»);
--   guidforgames_mapicons.json — иконки карты игры с мировыми координатами (кнопка «Dump map icons»):
--                                по ним выверяется привязка подложки карты; там же метки игрока (MapPin);
--   guidforgames_state.json — журнал квестов, пешки, симпатия NPC, номера It000078 (v27): меняются редко, поэтому
--                             вынесены из живого файла и пишутся, только когда изменились (живой — каждые 2 с, маленький);
--   guidforgames_tokens.json — где стоит каждый жетон искателя, который игра загружала рядом с игроком (номер → место,
--                              got = подобран при работающем моде), копится: по нему сервер отмечает записи-жетоны;
--   guidforgames_fog.json — маски исследованного (туман войны): мир и пещеры/подземелья, когда меняются (раз в 30 с);
--   guidforgames_diag.json — диагностика по кнопке в меню REFramework (Insert → Script Generated UI → GuidForGames):
--                            устройство игровых объектов, нужное для следующих версий моста.
-- Текст в меню — английский: шрифт оверлея REFramework не всегда показывает кириллицу.

local VERSION = 37
local LIVE_FILE = "guidforgames_live.json"
local EVENTS_FILE = "guidforgames_events.json"
local DIAG_FILE = "guidforgames_diag.json"
local NAMES_FILE = "guidforgames_names.json"
local ICONS_FILE = "guidforgames_mapicons.json"
local FOG_FILE = "guidforgames_fog.json"
local TOKENS_FILE = "guidforgames_tokens.json"
local STATE_FILE = "guidforgames_state.json"
local LANG_EN, LANG_RU = 1, 6 -- via.Language
local INTERVAL = 2.0
local MAX_EVENTS = 500

local last_write = -INTERVAL
local status = "waiting for player"
local last_live = nil

-- Число из поля значения: у векторов REFramework поля доступны как v.x, у value type игры — через get_field.
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

local function try_call(obj, method)
    if obj == nil then return nil end
    local ok, r = pcall(function() return obj:call(method) end)
    if ok then return r end
    return nil
end

local function manual_player()
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    return try_call(cm, "get_ManualPlayer")
end

-- Позиция: в большом мире RE Engine хранит мировую (universal, double) и локальную позицию.
-- Пишем обе — по ним сверим с координатами сохранения; основной считаем мировую.
local function player_position(chara)
    local go = try_call(chara, "get_GameObject")
    local tr = try_call(go, "get_Transform")
    if tr == nil then return nil, nil, nil end
    local universal = vec3(try_call(tr, "get_UniversalPosition"))
    local localpos = vec3(try_call(tr, "get_Position"))
    return universal or localpos, universal, localpos
end

local function try_field(obj, name)
    if obj == nil then return nil end
    local ok, r = pcall(function() return obj:get_field(name) end)
    if ok then return r end
    return nil
end

-- Элементы List<T>/массива игры как таблица Lua.
-- Массив .NET (T[])? У него get_Count может «сработать» и вернуть 0 — поэтому массивы распознаём по типу.
local function is_array(obj)
    local ok, td = pcall(function() return obj:get_type_definition() end)
    if not ok or td == nil then return false end
    local name = td:get_full_name()
    return name ~= nil and name:sub(-2) == "[]"
end

local function list_items(list)
    local out = {}
    if list == nil then return out end
    local count = not is_array(list) and try_call(list, "get_Count") or nil
    if type(count) == "number" then
        for i = 0, count - 1 do
            local ok, v = pcall(function() return list:call("get_Item", i) end)
            if ok then table.insert(out, v) end
        end
        return out
    end
    -- Массив .NET (T[], например MapIconInfo[]): у него нет get_Count. Перебираем по номерам и пропускаем
    -- пустые ячейки (у MapPinList они в начале, поэтому ipairs по get_elements() ничего не видел).
    local ok, size = pcall(function() return list:get_size() end)
    if not ok or type(size) ~= "number" then size = try_call(list, "get_Length") end
    if type(size) == "number" then
        for i = 0, size - 1 do
            local okv, v = pcall(function() return list:get_element(i) end)
            if not okv then okv, v = pcall(function() return list:call("GetValue", i) end) end
            if okv and v ~= nil then table.insert(out, v) end
        end
        return out
    end
    local oke, elements = pcall(function() return list:get_elements() end)
    if oke and type(elements) == "table" then
        for _, v in pairs(elements) do
            if v ~= nil then table.insert(out, v) end
        end
    end
    return out
end

-- События копятся в файле между запусками игры: сервер сопоставляет их с записями приложения.
local events = json.load_file(EVENTS_FILE)
if type(events) ~= "table" or type(events.items) ~= "table" then events = { items = {} } end

local function add_event(ev)
    table.insert(events.items, ev)
    while #events.items > MAX_EVENTS do table.remove(events.items, 1) end
    events.version = VERSION
    json.dump_file(EVENTS_FILE, events)
end

-- Текст сообщения игры по Guid: на языке игры или на заданном (via.Language).
local message_td = nil
local function message(guid, lang)
    if guid == nil then return nil end
    message_td = message_td or sdk.find_type_definition("via.gui.message")
    if message_td == nil then return nil end
    local sig = lang and "get(System.Guid, via.Language)" or "get(System.Guid)"
    local m = message_td:get_method(sig)
    if m == nil then return nil end
    local ok, r = pcall(function()
        if lang then return m:call(nil, guid, lang) end
        return m:call(nil, guid)
    end)
    if ok and type(r) == "string" and r ~= "" then return r end
    return nil
end

local function quest_name(qlm, id)
    local ok, log = pcall(function() return qlm:call("getQuestLog", id) end)
    if not ok or log == nil then return nil end
    local name = try_field(log, "QuestName")
    if type(name) == "string" and name ~= "" then return name end
    return nil
end

local function quest_state()
    local qlm = sdk.get_managed_singleton("app.QuestLogManager")
    if qlm == nil then return nil end
    local q = {}
    local tracked = try_field(qlm, "_CurrentDestinationTargetQuestID")
    if type(tracked) == "number" and tracked >= 0 then
        q.tracked = tracked
        q.trackedName = quest_name(qlm, tracked)
    end
    q.destination = vec3(try_field(qlm, "_CurrentDestinationPos"))
    q.progressing = {}
    for _, id in ipairs(list_items(try_call(qlm, "getProgressingQuestIds"))) do
        if type(id) == "number" then table.insert(q.progressing, id) end
    end
    return q
end

-- Сундуки рядом с игроком (игра держит загруженными ближайшие): смена состояния — сундук открыт.
local chest_states = {}
local function universal_pos(obj)
    local go = try_call(obj, "get_GameObject")
    local tr = try_call(go, "get_Transform")
    return vec3(try_call(tr, "get_UniversalPosition")) or vec3(try_call(tr, "get_Position"))
end

local function track_chests()
    local gm = sdk.get_managed_singleton("app.GimmickManager")
    local seen = {}
    for _, box in ipairs(list_items(try_call(gm, "get_TreasureBoxGimmicks"))) do
        local key = tostring(box)
        local state = try_field(box, "<NowState>k__BackingField")
        if type(state) == "number" then
            seen[key] = state
            local prev = chest_states[key]
            if prev ~= nil and prev ~= state then
                add_event({ type = "chest", time = os.time(), from = prev, to = state, pos = universal_pos(box) })
            end
        end
    end
    chest_states = seen
end

local function game_time()
    local tm = sdk.get_managed_singleton("app.TimeManager")
    if tm == nil then return nil end
    return { day = try_call(tm, "get_InGameDay"), hour = try_call(tm, "get_InGameHour") }
end

-- Метки игрока на карте игры (ориентиры, «Задать ориентир»): GuiManager.MapPinList — массив MapIconInfo,
-- пустые ячейки — с нулевой позицией или IsEnable = false.
local function map_pins()
    local gui = sdk.get_managed_singleton("app.GuiManager")
    local pins = {}
    local list = try_call(gui, "get_MapPinList") or try_field(gui, "<MapPinList>k__BackingField")
    for _, icon in ipairs(list_items(list)) do
        local pos = vec3(try_field(icon, "Pos"))
        if pos ~= nil and (pos.x ~= 0 or pos.z ~= 0) and try_field(icon, "IsEnable") ~= false then
            table.insert(pins, { x = pos.x, y = pos.y, z = pos.z, type = try_field(icon, "IconType") })
        end
    end
    return pins
end

-- Журнал квестов игры: номер и статус каждого квеста (1 — активен, 2 — выполнен, как в сохранении).
-- Меняется редко — читаем раз в 10 секунд.
local QUEST_LOG_INTERVAL = 10.0
local quest_log_cache, quest_log_at = nil, -QUEST_LOG_INTERVAL
-- Названия квестов (RU — как в журнале, EN — по Guid названия): для сбора новых данных (v37); читаем один раз на квест.
local quest_names = {}
local function quest_log()
    local qlm = sdk.get_managed_singleton("app.QuestLogManager")
    local out = {}
    for _, v in ipairs(list_items(try_call(qlm, "getAllOrderedQuestLog"))) do
        local id = try_field(v, "QuestId")
        local st = try_field(v, "<Status>k__BackingField")
        if type(id) == "number" and type(st) == "number" then
            local n = quest_names[id]
            if n == nil then
                local ru = try_field(v, "QuestName")
                local okg, en = pcall(message, try_field(v, "QuestNameId"), LANG_EN)
                n = { ru = type(ru) == "string" and ru ~= "" and ru or nil, en = okg and en or nil }
                if n.ru ~= nil or n.en ~= nil then quest_names[id] = n end
            end
            table.insert(out, { id = id, status = st, name = n.ru, nameEn = n.en })
        end
    end
    return out
end

-- Пешки и драконья чума: персонажи-пешки из PawnManager, у каждого в словаре контекстов (ContextHolder.Contexts)
-- лежат PawnDataContext (_PossessionLv — стадия чумы) и у главной пешки MainPawnDataContext (симпатия) —
-- те же данные, что пишутся в сохранение. Чума меняется медленно — читаем раз в 30 секунд.
local PAWN_INTERVAL = 30.0
local pawns_cache, pawns_at = nil, -PAWN_INTERVAL
local function text_of(v)
    if type(v) == "string" then return v end
    local s = try_call(v, "ToString")
    if type(s) == "string" then return s end
    return nil
end

local function type_name(obj)
    if type(obj) ~= "userdata" then return nil end
    local ok, td = pcall(function() return obj:get_type_definition() end)
    if ok and td ~= nil then return td:get_full_name() end
    return nil
end

-- Контекст персонажа по имени типа. ContextHolder.Contexts — словарь System.Type → ContextInfo<T>: берём
-- обёртку по ключу sdk.typeof(...), а сам контекст ищем в её полях (имя поля не знаем — перебираем).
local function context_of(chara, tname)
    local holder = try_call(chara, "get_Context")
    local dict = try_field(holder, "Contexts")
    local ok, t = pcall(sdk.typeof, tname)
    if dict == nil or not ok or t == nil then return nil end
    local okv, info = pcall(function() return dict:call("get_Item", t) end)
    if not okv or info == nil then
        local okr, restored = pcall(function() return try_field(holder, "RestoredContexts"):call("get_Item", t) end)
        if okr and type_name(restored) == tname then return restored end
        return nil
    end
    if type_name(info) == tname then return info end
    local okt, td = pcall(function() return info:get_type_definition() end)
    local depth = 0
    while okt and td ~= nil and depth < 4 and td:get_full_name() ~= "System.Object" do
        for _, f in ipairs(td:get_fields()) do
            if not f:is_static() then
                local v = try_field(info, f:get_name())
                if type_name(v) == tname then return v end
            end
        end
        td = td:get_parent_type()
        depth = depth + 1
    end
    return nil, info
end

-- Элементы HashSet/Dictionary игры: у них нет get_Item — читаем внутренний массив записей, иначе перечислитель.
local function set_items(obj)
    local out = {}
    if obj == nil then return out end
    for _, fname in ipairs({ "_entries", "_slots" }) do
        local arr = try_field(obj, fname)
        if arr ~= nil then
            for _, e in ipairs(list_items(arr)) do
                local v = try_field(e, "value")
                if v == nil then v = try_field(e, "Value") end
                if v ~= nil then out[#out + 1] = v end
            end
            if #out > 0 then return out end
        end
    end
    local en = try_call(obj, "GetEnumerator")
    if en ~= nil then
        for _ = 1, 100000 do
            local ok, more = pcall(function() return en:call("MoveNext") end)
            if not ok or more ~= true then break end
            local cur = try_call(en, "get_Current")
            if cur ~= nil then out[#out + 1] = cur end
        end
    end
    return out
end

-- Простые поля объекта игры (числа, строки, флаги) с родителями — для разбора контекстов.
local function simple_fields(obj)
    local out = {}
    if obj == nil then return out end
    local okt, td = pcall(function() return obj:get_type_definition() end)
    local depth = 0
    while okt and td ~= nil and depth < 4 and td:get_full_name() ~= "System.Object" do
        for _, f in ipairs(td:get_fields()) do
            if not f:is_static() then
                local fv = try_field(obj, f:get_name())
                local t = type(fv)
                if (t == "string" and fv ~= "") or t == "number" or t == "boolean" then out[f:get_name()] = fv end
            end
        end
        td = td:get_parent_type()
        depth = depth + 1
    end
    return out
end

-- Здоровье, класс, уровень и загрузка персонажа (героя или пешки) — проверено по экрану статуса (v23):
-- JobContext.CurrentJob (2 — лучник, 1 — боец, 3 — маг, 4 — вор), HumanStatusContext._Level/_Exp,
-- HumanWeightRankContext.Rank (1 — легко, 2 — нормально, 3 — тяжело).
local function vitals(chara)
    local status = context_of(chara, "app.HumanStatusContext")
    local job = context_of(chara, "app.JobContext")
    local weight = context_of(chara, "app.HumanWeightRankContext")
    return {
        job = try_field(job, "CurrentJob") or try_field(chara, "WeaponJob"),
        level = try_field(status, "_Level"),
        exp = try_field(status, "_Exp"),
        weightRank = try_field(weight, "Rank"),
        -- Опыт призваний (по номеру призвания − 1) и очки дисциплины (у героя): по ним — ранги (v27, разбор)
        jobExp = (function()
            local out = {}
            for i, v in ipairs(list_items(try_field(job, "CulmativeExp"))) do
                -- элементы Int32[] приходят упакованными (ValueType) — число в поле m_value (v28)
                if type(v) ~= "number" then v = try_field(v, "m_value") or try_field(v, "mValue") end
                if type(v) == "number" then out[i] = v end
            end
            return #out > 0 and out or nil
        end)(),
        discipline = try_field(job, "ConsumableExp"),
        hp = try_call(chara, "get_Hp"),
        maxHp = try_call(chara, "get_OriginalMaxHp"),
        reducedMaxHp = try_call(chara, "get_ReducedMaxHp"),
    }
end

-- Характеристики с экипировкой: калькулятор персонажа (CharacterManager.PlayerStatusCalculatorHolder.Calculators,
-- по CharaID). Итог — calcAttackDefenceWithEquipmentAndBuff(), базовые (в скобках на экране) — calcBasicAttackDefence(),
-- переносимый вес — calcMaxWeightWithBuff(). Поля результатов отдаём как есть — подписи в приложении (v26).
-- Метод объекта по имени и (если задан) типу первого параметра: у перегрузок одно имя, obj:call выбирает наугад.
local function method_of(obj, name, ptype)
    local okt, td = pcall(function() return obj:get_type_definition() end)
    if not okt or td == nil then return nil end
    for _, m in ipairs(td:get_methods()) do
        if m:get_name() == name then
            if ptype == nil then return m end
            local okp, params = pcall(function() return m:get_param_types() end)
            local p = okp and params and params[1]
            if p ~= nil and p:get_full_name() == ptype then return m end
        end
    end
    return nil
end

local function param_type(m)
    local okp, params = pcall(function() return m:get_param_types() end)
    local p = okp and params and params[1]
    return p and p:get_full_name() or nil
end

-- Ранги призваний: опыт — JobContext.getJobExp(JobEnum), ранг — calcJobRank(JobEnum), предел — getMaxJobRank (v28).
-- Порогов рангов игра не отдаёт. Попытка v29 получить их на своём пустом JobContext (sdk.create_instance +
-- setJobExpWithJobRank) роняла игру — pcall такое не ловит: не создаём объекты игры и не зовём на них set*-методы.
-- Таблица рангов — app.JobRankParameter (via.UserData; calcJobExp/calcJobRank/getMaxJobRank). Ни одно поле менеджеров на неё
-- не ссылается (v35), поэтому берём её из перехвата: когда игра (или JobContext.calcJobRank из job_ranks) зовёт её метод,
-- запоминаем объект (this). Перехват только читает аргумент и ничего не меняет (v36).
local rank_param = nil
local rank_param_hooks = 0
do
    local okt, td = pcall(sdk.find_type_definition, "app.JobRankParameter")
    if okt and td ~= nil then
        for _, mname in ipairs({ "calcJobRank", "calcJobExp", "getMaxJobRank", "getJobParam" }) do
            local okm, m = pcall(function() return td:get_method(mname) end)
            if okm and m ~= nil then
                local okh = pcall(sdk.hook, m, function(args)
                    if rank_param == nil then
                        local ok, obj = pcall(sdk.to_managed_object, args[2])
                        if ok and obj ~= nil then rank_param = obj end
                    end
                end, function(retval) return retval end)
                if okh then rank_param_hooks = rank_param_hooks + 1 end
            end
        end
    end
end

-- Пороги рангов призвания j: опыт, с которого начинается ранг r (calcJobExp(j, r)); считаем один раз на призвание.
local rank_exp_cache = {}
local function rank_exp(j, r)
    if rank_param == nil then return nil end
    rank_exp_cache[j] = rank_exp_cache[j] or {}
    local v = rank_exp_cache[j][r]
    if v == nil then
        local ok, e = pcall(function() return rank_param:call("calcJobExp", j, r) end)
        v = ok and type(e) == "number" and e or false
        rank_exp_cache[j][r] = v
    end
    return v or nil
end

local function job_ranks(chara)
    local job = context_of(chara, "app.JobContext")
    if job == nil then return nil end
    local get_exp = method_of(job, "getJobExp", "app.Character.JobEnum")
    local calc = method_of(job, "calcJobRank")
    local max_rank = method_of(job, "getMaxJobRank")
    if get_exp == nil or calc == nil then return nil end
    local out = {}
    for j = 1, 10 do
        local oke, exp = pcall(function() return get_exp:call(job, j) end)
        local okr, rank = pcall(function() return calc:call(job, j) end)
        if oke and type(exp) == "number" then
            local entry = { job = j, exp = exp, rank = okr and type(rank) == "number" and rank or nil }
            local okm, mr = pcall(function() return max_rank:call(job, j) end)
            if okm and type(mr) == "number" then entry.maxRank = mr end
            -- «далее»: порог следующего ранга; берём, только если опыт лежит между порогами текущего и следующего ранга
            if entry.rank ~= nil and entry.maxRank ~= nil and entry.rank < entry.maxRank then
                local lo, hi = rank_exp(j, entry.rank), rank_exp(j, entry.rank + 1)
                if lo ~= nil and hi ~= nil and lo <= exp and exp < hi then entry.next = hi end
            end
            out[#out + 1] = entry
        end
    end
    return #out > 0 and out or nil
end

local function safe_ranks(chara)
    local ok, r = pcall(job_ranks, chara)
    return ok and r or nil
end

-- Золото и кристаллы разлома: в ItemManager они зашифрованы (via.rds.Mandrake), имена геттеров запутаны —
-- сверено с экраном (v28): золото — get_Version (12733), КР — get_Param (480); get_Value — что-то другое (0).
local function money()
    local im = sdk.get_managed_singleton("app.ItemManager")
    return { gold = try_call(im, "get_Version"), rift = try_call(im, "get_Param") }
end

local function call0(obj, name)
    if obj == nil then return nil end
    local okt, td = pcall(function() return obj:get_type_definition() end)
    local m = okt and td and td:get_method(name .. "()") or nil
    if m ~= nil then
        local ok, r = pcall(function() return m:call(obj) end)
        if ok then return r end
    end
    return try_call(obj, name)
end

local function status_calculator(chara)
    local id = try_call(chara, "get_CharaID")
    if type(id) ~= "number" then return nil end
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    local holder = try_call(cm, "get_PlayerStatusCalculatorHolder")
    for _, calc in ipairs(set_items(try_field(holder, "Calculators"))) do
        if try_field(calc, "CharaID") == id then return calc end
    end
    return nil
end

local function character_stats(chara)
    local calc = status_calculator(chara)
    if calc == nil then return nil end
    return {
        total = simple_fields(call0(calc, "calcAttackDefenceWithEquipmentAndBuff")),
        base = simple_fields(call0(calc, "calcBasicAttackDefence")),
        maxWeight = call0(calc, "calcMaxWeightWithBuff"),
    }
end

local function safe_stats(chara)
    local ok, st = pcall(character_stats, chara)
    return ok and st or nil
end

local function pawn_characters()
    local pm = sdk.get_managed_singleton("app.PawnManager")
    local list = list_items(try_call(pm, "get_PawnCharacterList"))
    if #list == 0 then
        for _, pawn in ipairs(list_items(try_call(pm, "getAllPartyPawn"))) do
            local chara = try_call(pawn, "get_Chara") or try_call(pawn, "get_Character")
            if chara ~= nil then table.insert(list, chara) end
        end
    end
    return list
end

local function pawn_state()
    local out = {}
    for _, chara in ipairs(pawn_characters()) do
        local p = context_of(chara, "app.PawnDataContext")
        local main = context_of(chara, "app.MainPawnDataContext")
        local v = vitals(chara)
        if p ~= nil then
            local search = text_of(try_call(p, "get_SearchId") or try_field(p, "_SearchId"))
            table.insert(out, {
                name = text_of(try_call(p, "get_Name") or try_field(p, "_Name")),
                nickname = text_of(try_call(p, "get_Nickname") or try_field(p, "_Nickname")),
                searchId = (search ~= nil and search ~= "") and search or nil,
                main = main ~= nil,
                affinity = main and (try_call(main, "get_FavorabilityRating") or try_field(main, "_FavorabilityRating")) or nil,
                possessionLv = try_call(p, "get_PossessionLv") or try_field(p, "_PossessionLv"),
                possessionPoint = try_call(p, "get_PossessionProgressPoint") or try_field(p, "_PossessionProgressPoint"),
                job = v.job,
                level = v.level,
                weightRank = v.weightRank,
                jobExp = v.jobExp,
                ranks = safe_ranks(chara),
                stats = safe_stats(chara),
            })
        end
    end
    return out
end

-- Туман войны: маска исследованного мира (GuiManager.MapMaskField, тип MapMaskInfo). Её поля нам неизвестны —
-- ищем в ней (и на уровень глубже) массив UInt32: в сохранении это MapMaskSaveData.MaskBit, 512×512 бит.
-- Пишем в base64, как утилита сохранений (u32 little-endian), и только когда маска изменилась.
local FOG_INTERVAL = 30.0
local fog_at, fog_bits = -FOG_INTERVAL, nil
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function to_uint(v)
    if type(v) == "number" then return math.floor(v) & 0xFFFFFFFF end
    for _, f in ipairs({ "m_value", "mValue", "value" }) do
        local x = try_field(v, f)
        if type(x) == "number" then return math.floor(x) & 0xFFFFFFFF end
    end
    local n = tonumber(text_of(v))
    return n and (math.floor(n) & 0xFFFFFFFF) or 0
end

local function base64_words(words)
    local bytes = {}
    for _, w in ipairs(words) do
        bytes[#bytes + 1] = w & 0xFF
        bytes[#bytes + 1] = (w >> 8) & 0xFF
        bytes[#bytes + 1] = (w >> 16) & 0xFF
        bytes[#bytes + 1] = (w >> 24) & 0xFF
    end
    local out = {}
    for i = 1, #bytes, 3 do
        local a, b, c = bytes[i], bytes[i + 1], bytes[i + 2]
        local n = (a << 16) | ((b or 0) << 8) | (c or 0)
        local c1, c2, c3, c4 = (n >> 18) & 63, (n >> 12) & 63, (n >> 6) & 63, n & 63
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end

local function find_mask_array(obj, depth)
    local okt, td = pcall(function() return obj:get_type_definition() end)
    if not okt or td == nil then return nil end
    for _, f in ipairs(td:get_fields()) do
        if not f:is_static() then
            local v = try_field(obj, f:get_name())
            local n = type_name(v)
            if n == "System.UInt32[]" or n == "System.Int32[]" then return v, f:get_name() end
            if depth > 0 and n ~= nil and n:sub(-2) ~= "[]" then
                local a, name = find_mask_array(v, depth - 1)
                if a ~= nil then return a, name end
            end
        end
    end
    return nil
end

-- Int2 игры (BasePos, DispRange, MaskNum) → {x, y}.
local function int2(v)
    local x, y = try_field(v, "x"), try_field(v, "y")
    if type(x) == "number" and type(y) == "number" then return { x, y } end
    return nil
end

-- Маска одной области: угол и размер сетки (м), размер в клетках, биты в base64; пустая — nil.
local function encode_mask(info)
    if info == nil then return nil end
    local arr = try_field(info, "MaskBit") or find_mask_array(info, 1)
    if arr == nil then return nil end
    local words, any = {}, false
    for _, v in ipairs(list_items(arr)) do
        local w = to_uint(v)
        words[#words + 1] = w
        if w ~= 0 then any = true end
    end
    if #words == 0 then return nil end
    return {
        base = int2(try_field(info, "BasePos")) or { -4096, -4096 },
        range = int2(try_field(info, "DispRange")) or { 8192, 8192 },
        size = int2(try_field(info, "MaskNum")),
        bits = base64_words(words),
        any = any,
    }
end

-- Текущая область карты игры (MapMaskCurrentArea): весь мир или пещера/подземелье — угол и размер сетки.
local function fog_area()
    local gui = sdk.get_managed_singleton("app.GuiManager")
    local info = try_field(gui, "MapMaskCurrentArea")
    if info == nil then return nil end
    local base, range = int2(try_field(info, "BasePos")), int2(try_field(info, "DispRange"))
    if base == nil or range == nil then return nil end
    return { base = base, range = range }
end

local function world_fog()
    local gui = sdk.get_managed_singleton("app.GuiManager")
    local world = encode_mask(try_field(gui, "MapMaskField"))
    if world == nil then return nil end
    -- Маски пещер и подземелий: MapMaskLocalArea[номер области]; пустые не пишем.
    local locals = {}
    for i, info in ipairs(list_items(try_field(gui, "MapMaskLocalArea"))) do
        local m = encode_mask(info)
        if m ~= nil and m.any then
            locals[#locals + 1] = { area = i - 1, base = m.base, range = m.range, size = m.size, bits = m.bits }
        end
    end
    return world, locals
end

local function write_fog()
    local world, locals = world_fog()
    if world == nil then return end
    local sig = world.bits
    for _, m in ipairs(locals) do sig = sig .. "|" .. m.area .. ":" .. m.bits end
    if sig == fog_bits then return end
    fog_bits = sig
    json.dump_file(FOG_FILE, {
        version = VERSION, time = os.time(), area = -1,
        base = world.base, range = world.range, size = world.size, bits = world.bits,
        ["local"] = locals,
    })
end

-- Симпатия NPC: в сохранении — NPCSaveSentiment (CharaID, Value 0…300). В игре ищем коллекцию таких записей
-- в NPCManager.SentimentController (запасной путь — NPCManagerSaveData) на глубину до двух уровней.
-- Меняется медленно — раз в 60 секунд.
local SENTIMENT_INTERVAL = 60.0
local sentiments_cache, sentiments_at, sentiments_source = nil, -SENTIMENT_INTERVAL, nil

local function sentiment_entries(coll)
    local items = {}
    local n = type_name(coll) or ""
    if n:find("Dictionary", 1, true) then
        for _, e in ipairs(list_items(try_field(coll, "_entries"))) do
            local v = try_field(e, "value")
            if v ~= nil then items[#items + 1] = { key = try_field(e, "key"), value = v } end
        end
    else
        for _, v in ipairs(list_items(coll)) do items[#items + 1] = { value = v } end
    end
    local out = {}
    for _, it in ipairs(items) do
        local v = it.value
        local id = try_field(v, "CharaID") or try_field(v, "_CharaID")
        if type(id) ~= "number" and type(it.key) == "number" then id = it.key end
        local val = try_field(v, "Value") or try_field(v, "_Value")
        if type(id) == "number" and type(val) == "number" then out[#out + 1] = { id = id, value = val } end
    end
    return out
end

local function is_collection(name)
    return name ~= nil and (name:sub(-2) == "[]" or name:find("Generic.List", 1, true) or name:find("Dictionary", 1, true))
end

local function find_sentiments(obj, depth, path)
    local okt, td = pcall(function() return obj:get_type_definition() end)
    if not okt or td == nil then return nil end
    for _, f in ipairs(td:get_fields()) do
        if not f:is_static() then
            local v = try_field(obj, f:get_name())
            local n = type_name(v)
            local here = path .. "." .. f:get_name()
            if is_collection(n) then
                local entries = sentiment_entries(v)
                if #entries > 0 then return entries, here end
            elseif depth > 0 and n ~= nil then
                local entries, where = find_sentiments(v, depth - 1, here)
                if entries ~= nil then return entries, where end
            end
        end
    end
    return nil
end

-- Поля объекта (вместе с родительскими типами) с «entiment» в имени: путь → значение. Глубина — для вложенных.
local function sentiment_fields(obj, depth, path, out)
    local okt, td = pcall(function() return obj:get_type_definition() end)
    local level = 0
    while okt and td ~= nil and level < 4 and td:get_full_name() ~= "System.Object" do
        for _, f in ipairs(td:get_fields()) do
            if not f:is_static() then
                local name = f:get_name()
                local v = try_field(obj, name)
                if name:lower():find("entiment", 1, true) then
                    out[#out + 1] = { path = path .. "." .. name, value = v }
                elseif depth > 0 and type(v) == "userdata" then
                    local n = type_name(v)
                    if n ~= nil and not is_collection(n) and n:sub(1, 4) == "app." then
                        sentiment_fields(v, depth - 1, path .. "." .. name, out)
                    end
                end
            end
        end
        td = td:get_parent_type()
        level = level + 1
    end
    return out
end

local function npc_chara_id(h)
    for _, f in ipairs({ "CharaID", "_CharaID", "<CharaID>k__BackingField" }) do
        local v = try_field(h, f)
        if type(v) == "number" then return v end
    end
    local v = try_call(h, "get_CharaID")
    if type(v) == "number" then return v end
    return nil
end

-- Симпатия одного NPC: число из поля «…Sentiment…» (или его поля Value). Путь к полю находим один раз —
-- обходить все поля у сотен NPC каждую минуту слишком дорого.
local sentiment_path = nil

local function follow(obj, path)
    local v = obj
    for _, name in ipairs(path) do
        v = try_field(v, name)
        if v == nil then return nil end
    end
    return v
end

local function as_sentiment(v)
    if type(v) == "number" then return v, nil end
    if type(v) == "userdata" then
        for _, f in ipairs({ "Value", "_Value" }) do
            local x = try_field(v, f)
            if type(x) == "number" then return x, f end
        end
    end
    return nil
end

local function holder_sentiment(h)
    if sentiment_path ~= nil then
        local v = follow(h, sentiment_path)
        return type(v) == "number" and v or nil
    end
    for _, e in ipairs(sentiment_fields(h, 1, "", {})) do
        local val, sub = as_sentiment(e.value)
        if val ~= nil then
            local path = {}
            for name in e.path:gmatch("[^%.]+") do path[#path + 1] = name end
            if sub ~= nil then path[#path + 1] = sub end
            sentiment_path = path
            return val
        end
    end
    return nil
end

local function npc_sentiments()
    local npcm = sdk.get_managed_singleton("app.NPCManager")
    -- Основной путь (v11): у каждого NPC в NPCHolder.
    local out = {}
    for _, h in ipairs(list_items(try_call(npcm, "get_NPCHolder_FullList"))) do
        local id, val = npc_chara_id(h), holder_sentiment(h)
        if id ~= nil and val ~= nil then out[#out + 1] = { id = id, value = val } end
    end
    if #out > 0 then return out, "NPCHolder" end
    local roots = {
        { "SentimentController", try_call(npcm, "get_SentimentController") or try_field(npcm, "<SentimentController>k__BackingField") },
        { "NPCManagerSubData", try_field(npcm, "<NPCManagerSubData>k__BackingField") },
    }
    for _, r in ipairs(roots) do
        if r[2] ~= nil then
            local entries, where = find_sentiments(r[2], 2, r[1])
            if entries ~= nil then return entries, where end
        end
    end
    return nil
end

-- Список GimmickManager.getOpenedIt000078List() — массив app.UniqueID, как It000078Array в сохранении. Это НЕ
-- подобранные жетоны искателя (проверено в v17: при подборе не меняется); пишем для дальнейшего разбора. Пишем их строками UniqueID.ToString() (GUID_номер); перевод в формат сохранения —
-- на сервере. Перечитываем, когда меняется число жетонов, и раз в 30 секунд.
local TOKEN_IDS_INTERVAL = 30.0
local token_ids_cache, token_ids_at, token_ids_count = nil, -TOKEN_IDS_INTERVAL, nil

local function token_ids()
    local gm = sdk.get_managed_singleton("app.GimmickManager")
    local out = {}
    for _, uid in ipairs(list_items(try_call(gm, "getOpenedIt000078List"))) do
        local s = text_of(try_call(uid, "ToString"))
        if s ~= nil and s ~= "" then out[#out + 1] = s end
    end
    return out
end

-- Где какой жетон: жетоны искателя — гиммики app.Gm82_036 из GimmickManager.ManagedGimmicksByIDs; игра держит
-- загруженными ближайшие. Номер (UniqueID) → место, копится в файле. Подбор: у жетона поднят флаг IsGetFreeBit,
-- или он пропал из загруженных, пока игрок стоял рядом (подобранный жетон игра убирает, v17) — тогда got = true
-- и событие «seeker-token» с точным местом жетона. Жетон снова лежит в мире неподобранным (загрузили сохранение
-- до подбора) — got снимаем, событие «seeker-token-undo»: приложение снимет отметку. С v20 и без подхода к жетону:
-- при подборе запоминаем часы игры; после загрузки они меньше, чем были при подборе, — значит, в загруженном
-- сохранении жетон не подобран. v20 смотрел только общее время игры (WholePlayTime) — при загрузке оно не
-- откатывается; v21 смотрит ещё игровые часы (день и секунды дня), они хранятся в сохранении.
local TOKEN_SCAN_INTERVAL = 5.0
local TOKEN_SCAN_NEAR_INTERVAL = 1.0 -- рядом с неподобранным жетоном проверяем чаще
local TOKEN_NEAR = 15.0
local TOKEN_PICK_RADIUS = 6.0
local token_scan_at = -TOKEN_SCAN_INTERVAL
-- Файл: items — номер → место (общее для всех персонажей); picked — персонаж → номер → когда подобран (v22).
-- Персонажей в игре может быть несколько (ячейки сохранений): у каждого свои подобранные жетоны.
local LEGACY_CHAR = "?"
local token_places = json.load_file(TOKENS_FILE)
if type(token_places) ~= "table" or type(token_places.items) ~= "table" then token_places = { items = {} } end
if type(token_places.picked) ~= "table" then token_places.picked = {} end
local token_places_count = 0
for uid, p in pairs(token_places.items) do
    token_places_count = token_places_count + 1
    -- v18–v21: got прямо в месте — переносим в подобранные «неизвестного» персонажа (отдадим первому, кого увидим).
    if type(p) == "table" and p.got then
        token_places.picked[LEGACY_CHAR] = token_places.picked[LEGACY_CHAR] or {}
        token_places.picked[LEGACY_CHAR][uid] = { time = p.time, playTime = p.playTime, gameClock = p.gameClock }
        token_places.items[uid] = { x = p.x, y = p.y, z = p.z }
    end
end
local char_key = nil -- кто сейчас в игре (см. character_identity)

local function picks()
    local key = char_key or LEGACY_CHAR
    if type(token_places.picked[key]) ~= "table" then token_places.picked[key] = {} end
    return token_places.picked[key]
end

local function picked_count()
    local n = 0
    for _ in pairs(picks()) do n = n + 1 end
    return n
end
local token_near = false
local token_watch = {} -- номер → место неподобранного жетона, загруженного при прошлой проверке


-- Все гиммики, которые знает GimmickManager: списки сундуков и подбираемого и словарь «тип → гиммики».
-- Возвращает гиммики без повторов и откуда каждый (для диагностики).
local function all_gimmicks()
    local gm = sdk.get_managed_singleton("app.GimmickManager")
    local out, seen, sources = {}, {}, {}
    local function add(src, g)
        if type(g) ~= "userdata" then return end
        sources[src] = (sources[src] or 0) + 1
        local key = tostring(g)
        if not seen[key] then
            seen[key] = src
            out[#out + 1] = { g = g, src = src }
        end
    end
    for _, getter in ipairs({ "get_TreasureBoxGimmicks", "get_PickupGimmicks" }) do
        for _, g in ipairs(list_items(try_call(gm, getter))) do add(getter, g) end
    end
    local dict = try_call(gm, "get_ManagedGimmicksByIDs") or try_field(gm, "<ManagedGimmicksByIDs>k__BackingField")
    for _, set in ipairs(set_items(dict)) do
        for _, g in ipairs(set_items(set)) do add("ManagedGimmicksByIDs", g) end
    end
    return out, sources
end

-- Жетон искателя в мире — гиммик app.Gm82_036 (GimmickID 167; найден диагностикой v16: игрок стоял на жетоне).
-- Флаг _IsIt000078 у сундуков gm80_001 оставляем на случай жетона в сундуке.
local TOKEN_TYPE = "app.Gm82_036"
local function is_token(g)
    return type_name(g) == TOKEN_TYPE or try_call(g, "get__IsIt000078") == true
end

local function token_gimmicks()
    local out = {}
    for _, it in ipairs((all_gimmicks())) do
        if is_token(it.g) then out[#out + 1] = it.g end
    end
    return out
end

local function token_uid(g)
    local uid = try_call(g, "get_UniqId") or try_field(g, "<UniqId>k__BackingField")
    return text_of(try_call(uid, "ToString"))
end

local function horiz(a, b)
    return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
end

local function play_time()
    local t = try_call(sdk.get_managed_singleton("app.TimeManager"), "get_WholePlayTime")
    if type(t) == "number" and t > 0 then return t end
    return nil
end

-- Игровые часы: день и секунды от начала дня одним числом (день < 100000 с), растут, пока не загрузят сохранение.
local function game_clock()
    local tm = sdk.get_managed_singleton("app.TimeManager")
    local day = try_call(tm, "get_InGameDay")
    local sec = try_call(tm, "get_InGameElapsedDaySeconds")
    if type(day) ~= "number" or type(sec) ~= "number" or day <= 0 then return nil end
    return day * 100000 + sec
end

local function token_picked(uid, pos)
    local pk = picks()
    if pk[uid] ~= nil then return end
    pk[uid] = { time = os.time(), playTime = play_time(), gameClock = game_clock() }
    add_event({ type = "seeker-token", time = os.time(), pos = pos, uid = uid, character = char_key })
end

local function token_unpicked(uid, pos)
    picks()[uid] = nil
    add_event({ type = "seeker-token-undo", time = os.time(), pos = pos, uid = uid, character = char_key })
end

-- Загрузили сохранение: часы игры пошли назад (или впервые прочитаны после запуска игры/мода).
-- Жетоны, подобранные позже, в загруженном сохранении не подобраны.
local PLAY_TIME_SLACK = 2.0
local GAME_CLOCK_SLACK = 60.0 -- игровые секунды идут быстрее настоящих
local last_play_time, last_game_clock, last_char = nil, nil, nil
local reidentified = false
local function check_token_rollback()
    if char_key == nil then return end
    local play, clock = play_time(), game_clock()
    if play == nil and clock == nil then return end
    -- Сменился персонаж — это тоже загрузка: сверяем его жетоны с его часами.
    if char_key ~= last_char then
        last_char = char_key
        last_play_time, last_game_clock = nil, nil
    end
    local first = last_play_time == nil and last_game_clock == nil
    local back = (play ~= nil and last_play_time ~= nil and play < last_play_time - PLAY_TIME_SLACK)
        or (clock ~= nil and last_game_clock ~= nil and clock < last_game_clock - GAME_CLOCK_SLACK)
    if back and not reidentified then
        -- Загрузка: могли загрузить другого персонажа — сначала заново узнаём, кто в игре (пешки перечитаются),
        -- и только потом снимаем подборы. Часы не обновляем, чтобы откат был виден и на следующем шаге.
        reidentified = true
        char_key, pawns_cache = nil, nil
        return
    end
    reidentified = false
    last_play_time, last_game_clock = play or last_play_time, clock or last_game_clock
    if not (first or back) then return end
    local changed = false
    for uid, p in pairs(picks()) do
        local place = token_places.items[uid]
        local later = type(p) == "table" and type(place) == "table" and (
            (play ~= nil and type(p.playTime) == "number" and p.playTime > play + PLAY_TIME_SLACK)
            or (clock ~= nil and type(p.gameClock) == "number" and p.gameClock > clock + GAME_CLOCK_SLACK))
        if later then
            token_unpicked(uid, place)
            token_watch[uid] = nil
            changed = true
        end
    end
    if changed then
        token_places.version = VERSION
        json.dump_file(TOKENS_FILE, token_places)
    end
end

-- Возвращает, есть ли неподобранный жетон рядом с игроком (тогда следующая проверка — раньше).
local function scan_tokens(player)
    local changed, seen, near = false, {}, false
    for _, g in ipairs(token_gimmicks()) do
        local uid = token_uid(g)
        local pos = universal_pos(g)
        if uid ~= nil and uid ~= "" and pos ~= nil then
            seen[uid] = true
            if token_places.items[uid] == nil then
                token_places.items[uid] = pos
                token_places_count = token_places_count + 1
                changed = true
            end
            if char_key == nil then
                -- кто в игре, пока неизвестно — подборы не записываем (не отдать их чужому персонажу)
                token_watch[uid] = nil
            elseif try_call(g, "get_IsGetFreeBit") == true then
                if picks()[uid] == nil then
                    token_picked(uid, pos)
                    changed = true
                end
                token_watch[uid] = nil
            else
                if picks()[uid] ~= nil then
                    token_unpicked(uid, pos)
                    changed = true
                end
                token_watch[uid] = pos
                if player ~= nil and horiz(pos, player) <= TOKEN_NEAR then near = true end
            end
        end
    end
    -- Пропал из загруженных, а игрок рядом с его местом — подобран. Далеко — игра просто выгрузила.
    for uid, pos in pairs(token_watch) do
        if not seen[uid] then
            if char_key ~= nil and player ~= nil and horiz(pos, player) <= TOKEN_PICK_RADIUS then
                token_picked(uid, pos)
                changed = true
            end
            token_watch[uid] = nil
        end
    end
    if changed then
        token_places.version = VERSION
        json.dump_file(TOKENS_FILE, token_places)
    end
    return near
end

-- Кто сейчас в игре: имя героя (если найдём в его контекстах), иначе — имя основной пешки (она у каждого
-- персонажа своя). До встречи с пешкой и без имени героя — неизвестно (nil).
-- Имя героя: PlayerPersonalDataContext.Name (проверено в v23).
local function hero_name(chara)
    local v = try_field(context_of(chara, "app.PlayerPersonalDataContext"), "Name")
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

-- Ключ персонажа — по основной пешке (своя у каждого персонажа и есть всегда после пролога); имя героя — для показа.
local function character_identity(chara)
    local pawn = nil
    for _, p in ipairs(pawns_cache or {}) do
        if p.main and type(p.name) == "string" and p.name ~= "" then pawn = p.name end
    end
    if pawn == nil then return nil end
    local okn, name = pcall(hero_name, chara)
    return { key = "pawn:" .. pawn, name = okn and name or nil, pawn = pawn }
end

local hero_stats_cache, hero_stats_at = nil, -10.0
-- Герой для приложения: имя и прозвище, класс, уровень, опыт, загрузка, здоровье, выносливость.
local function hero_state(chara)
    local h = vitals(chara)
    local st = try_call(chara, "get_StaminaManager")
    h.stamina = try_field(st, "<RemainingAmount>k__BackingField")
    h.maxStamina = try_field(st, "<MaxValue>k__BackingField")
    h.reducedMaxStamina = try_field(st, "<ReducedMaxValue>k__BackingField")
    local personal = context_of(chara, "app.PlayerPersonalDataContext")
    h.nickname = text_of(try_field(personal, "NickName"))
    -- характеристики меняются только со снаряжением и усилениями — пересчитываем раз в 10 с
    local now = os.clock()
    if now - hero_stats_at >= 10.0 then
        hero_stats_at = now
        local oks, st2 = pcall(character_stats, chara)
        if oks and st2 ~= nil then hero_stats_cache = st2 end
    end
    h.stats = hero_stats_cache
    h.ranks = safe_ranks(chara)
    local okm, m = pcall(money)
    if okm and m ~= nil then h.gold, h.rift = m.gold, m.rift end
    return h
end

local last_state_text = nil
local function write_state(state)
    local ok, text = pcall(json.dump_string, state)
    if ok and type(text) == "string" then
        if text == last_state_text then return end
        last_state_text = text
    end
    json.dump_file(STATE_FILE, state)
end

local function write_live()
    local live = { version = VERSION, time = os.time() }
    local chara = manual_player()
    if chara == nil then
        status = "waiting for player"
        live.status = "no-player"
        -- нет героя — меню или загрузка: следующего персонажа узнаём заново
        char_key, pawns_cache = nil, nil
    else
        local pos, universal, localpos = player_position(chara)
        if pos == nil then
            status = "player found, no position"
            live.status = "no-position"
        else
            status = "ok"
            live.status = "ok"
            live.player = pos
            live.raw = { universal = universal, ["local"] = localpos }
            live.area = { town = try_field(chara, "<AITownArea>k__BackingField"), ["local"] = try_field(chara, "<AILocalArea>k__BackingField") }
        end
        if pawns_cache == nil then
            -- после загрузки пешки перечитываем сразу: по основной пешке узнаём персонажа
            local okw, pw = pcall(pawn_state)
            if okw and #pw > 0 then pawns_cache, pawns_at = pw, os.clock() end
        end
        local okc, who = pcall(character_identity, chara)
        if okc and who ~= nil then
            live.character = who
            if who.key ~= char_key then
                char_key = who.key
                -- Подобранное до v22 (персонаж неизвестен) — первому, кого увидели, если у него ещё пусто.
                local legacy = token_places.picked[LEGACY_CHAR]
                if legacy ~= nil and next(picks()) == nil then
                    token_places.picked[char_key] = legacy
                    token_places.picked[LEGACY_CHAR] = nil
                    json.dump_file(TOKENS_FILE, token_places)
                end
            end
        end
        live.seekerTokens = picked_count()
        local okh, hero = pcall(hero_state, chara)
        if okh then live.hero = hero end
        pcall(track_chests)
        local ok, q = pcall(quest_state)
        if ok then live.quest = q end
        local okt, t = pcall(game_time)
        if okt then live.gameTime = t end
        local oka, area = pcall(fog_area)
        if oka then live.fogArea = area end
        local okp, pins = pcall(map_pins)
        if okp then live.pins = pins end
        local now = os.clock()
        if now - quest_log_at >= QUEST_LOG_INTERVAL then
            quest_log_at = now
            local okl, log = pcall(quest_log)
            if okl and #log > 0 then quest_log_cache = log end
        end
        live.questLog = quest_log_cache
        if now - pawns_at >= PAWN_INTERVAL then
            pawns_at = now
            local okw, pawns = pcall(pawn_state)
            if okw and #pawns > 0 then pawns_cache = pawns end
        end
        live.pawns = pawns_cache
        if now - sentiments_at >= SENTIMENT_INTERVAL then
            sentiments_at = now
            local oks, entries, where = pcall(npc_sentiments)
            if oks and entries ~= nil then
                sentiments_cache, sentiments_source = entries, where
            end
        end
        live.sentiments = sentiments_cache
        if live.seekerTokens ~= token_ids_count or now - token_ids_at >= TOKEN_IDS_INTERVAL then
            token_ids_at, token_ids_count = now, live.seekerTokens
            local okt, ids = pcall(token_ids)
            if okt and #ids > 0 then token_ids_cache = ids end
        end
        live.seekerTokenIds = token_ids_cache
        -- Тяжёлое и редко меняющееся — в отдельный файл, только при изменении (меньше записей на диск).
        pcall(write_state, {
            version = VERSION, questLog = live.questLog, pawns = live.pawns, sentiments = live.sentiments,
            seekerTokenIds = live.seekerTokenIds,
        })
        live.questLog, live.pawns, live.sentiments, live.seekerTokenIds = nil, nil, nil, nil
        pcall(check_token_rollback)
        live.clock = { play = last_play_time, game = last_game_clock }
        if now - token_scan_at >= (token_near and TOKEN_SCAN_NEAR_INTERVAL or TOKEN_SCAN_INTERVAL) then
            token_scan_at = now
            local okn, near = pcall(scan_tokens, live.player)
            token_near = okn and near == true
        end
        if now - fog_at >= FOG_INTERVAL then
            fog_at = now
            pcall(write_fog)
        end
    end
    last_live = live
    json.dump_file(LIVE_FILE, live)
end

re.on_frame(function()
    local now = os.clock()
    if now - last_write < INTERVAL then return end
    last_write = now
    local ok, err = pcall(write_live)
    if not ok then status = "error: " .. tostring(err) end
end)

-- Диагностика: поля и методы игровых типов (с родителями) и значения простых полей синглтонов.
local DIAG_TYPES = {
    "app.CharacterManager", "app.Character", "app.QuestManager", "app.QuestLogManager",
    "app.GimmickManager", "app.ItemManager", "app.GuiManager", "app.NPCManager",
    "app.TimeManager",
    -- v2: для названий квестов и мест из игры
    "app.QuestLogResource", "app.QuestLogResource.QuestLogTaskData", "app.QuestLogManager.QuestLogViewInfo",
    "app.QuestLogManager.QuestLogInfo", "app.UniqueID", "app.gm80_001", "app.GimmickBase", "via.gui.message",
    "app.GuiManager.MapIconInfo", "app.QuestDefine",
    -- v5: пешки и драконья чума
    "app.ContextDatabaseRecord", "app.PawnDataContext", "app.MainPawnDataContext", "app.ContextHolder", "app.PawnManager",
    "app.Pawn", "app.ContextHolder.ContextInfoBase",
    -- v11: симпатия NPC
    "app.NPCHolder", "app.SentimentController",
    -- v22: характеристики героя и пешек
    "app.Human", "app.Player", "app.StaminaManager",
    -- v17: жетон искателя в мире
    "app.Gm82_036",
}

-- Текст сообщения игры по Guid (через via.gui.message.get) — проверяем, доступны ли названия.
local function message_text(guid)
    local td = sdk.find_type_definition("via.gui.message")
    local m = td and td:get_method("get(System.Guid)")
    if m == nil then return nil end
    local ok, r = pcall(function() return m:call(nil, guid) end)
    if ok then return r end
    return nil
end

-- Объект с вложенными полями (до depth уровней), Guid-поля — вместе с текстом сообщения.
local function explore(obj, depth)
    if obj == nil then return nil end
    local okt, td = pcall(function() return obj:get_type_definition() end)
    if not okt or td == nil then return tostring(obj) end
    local out = { ["$type"] = td:get_full_name() }
    for _, f in ipairs(td:get_fields()) do
        if not f:is_static() then
            local name = f:get_name()
            local ok, v = pcall(function() return obj:get_field(name) end)
            if ok then
                local ft = f:get_type()
                local tname = ft and ft:get_full_name() or "?"
                if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
                    out[name] = v
                elseif tname == "System.Guid" then
                    local text = message_text(v)
                    out[name] = { guid = tostring(v), text = text }
                elseif depth > 0 and v ~= nil then
                    out[name] = explore(v, depth - 1)
                else
                    out[name] = tname
                end
            end
        end
    end
    return out
end

local function diag_quests()
    local qlm = sdk.get_managed_singleton("app.QuestLogManager")
    if qlm == nil then return nil end
    local out = {}
    local tracked = try_field(qlm, "_CurrentDestinationTargetQuestID")
    local ids = { tracked }
    for _, id in ipairs(list_items(try_call(qlm, "getProgressingQuestIds"))) do
        if #ids < 4 then table.insert(ids, id) end
    end
    for _, id in ipairs(ids) do
        if type(id) == "number" and id >= 0 then
            local entry = {}
            local ok, log = pcall(function() return qlm:call("getQuestLog", id) end)
            if ok then entry.log = explore(log, 2) end
            local okt, task = pcall(function() return qlm:call("getCurrentTask", id) end)
            if okt then entry.task = explore(task, 2) end
            out[tostring(id)] = entry
        end
    end
    return out
end

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
        table.insert(out.methods, m:get_name() .. "(" .. tostring(m:get_num_params()) .. "): " .. (r and r:get_full_name() or "?"))
    end
    return out
end

local function simple_values(obj, td)
    local values = {}
    for _, f in ipairs(td:get_fields()) do
        if not f:is_static() then
            local ok, v = pcall(function() return obj:get_field(f:get_name()) end)
            if ok and (type(v) == "number" or type(v) == "boolean" or type(v) == "string") then
                values[f:get_name()] = v
            end
        end
    end
    return values
end

local function dump_diag()
    local diag = { version = VERSION, time = os.time(), status = status, types = {}, singletons = {}, live = last_live }
    for _, name in ipairs(DIAG_TYPES) do
        local td = sdk.find_type_definition(name)
        if td ~= nil then
            diag.types[name] = describe_type(td)
            local s = sdk.get_managed_singleton(name)
            if s ~= nil then diag.singletons[name] = simple_values(s, td) end
        else
            diag.types[name] = "not found"
        end
    end
    local chara = manual_player()
    if chara ~= nil then
        local td = chara:get_type_definition()
        diag.player_type = td:get_full_name()
        diag.player_values = simple_values(chara, td)
    end
    local okq, quests = pcall(diag_quests)
    diag.quests = okq and quests or tostring(quests)
    local gm = sdk.get_managed_singleton("app.GimmickManager")
    local boxes = list_items(try_call(gm, "get_TreasureBoxGimmicks"))
    diag.treasureBoxesLoaded = #boxes
    if boxes[1] ~= nil then diag.treasureBoxSample = explore(boxes[1], 1) end
    -- v15: жетоны искателя среди загруженных гиммиков
    local okk, tokensDiag = pcall(function()
        local list = token_gimmicks()
        local sample = {}
        for i = 1, math.min(3, #list) do
            sample[i] = {
                uid = token_uid(list[i]), pos = universal_pos(list[i]), got = try_call(list[i], "get_IsGetFreeBit"),
                flagGet = try_field(list[i], "GmFlagGet"), flag = try_field(list[i], "GmFlag"),
            }
        end
        return { loaded = #list, known = token_places_count, got = picked_count(), character = char_key, sample = sample }
    end)
    diag.seekerTokenPlaces = okk and tokensDiag or tostring(tokensDiag)
    -- v22: контексты героя и пешек — где игра хранит имя, класс, уровень, характеристики
    local function simple_fields(obj)
        local out = {}
        local okt, td = pcall(function() return obj:get_type_definition() end)
        local depth = 0
        while okt and td ~= nil and depth < 4 and td:get_full_name() ~= "System.Object" do
            for _, f in ipairs(td:get_fields()) do
                if not f:is_static() then
                    local fv = try_field(obj, f:get_name())
                    local t = type(fv)
                    if (t == "string" and fv ~= "") or t == "number" or t == "boolean" then out[f:get_name()] = fv end
                end
            end
            td = td:get_parent_type()
            depth = depth + 1
        end
        return out
    end
    local function contexts_of(c)
        local holder = try_call(c, "get_Context")
        local out = {}
        for _, v in ipairs(set_items(try_field(holder, "Contexts"))) do
            local entry = { type = type_name(v), values = simple_fields(v), inner = {} }
            -- Значение словаря бывает обёрткой: сам контекст — в её поле.
            local okt, td = pcall(function() return v:get_type_definition() end)
            if okt and td ~= nil then
                for _, f in ipairs(td:get_fields()) do
                    local fv = not f:is_static() and try_field(v, f:get_name()) or nil
                    if type(fv) == "userdata" and type_name(fv) ~= nil and type_name(fv):find("Context") then
                        entry.inner[f:get_name()] = { type = type_name(fv), values = simple_fields(fv) }
                    end
                end
            end
            out[#out + 1] = entry
        end
        return out
    end
    local okpc, ctxDiag = pcall(contexts_of, chara)
    diag.playerContexts = okpc and ctxDiag or tostring(ctxDiag)
    local okhs, heroDiag = pcall(function()
        return {
            hp = try_call(chara, "get_Hp"), maxHp = try_call(chara, "get_OriginalMaxHp"),
            reducedMaxHp = try_call(chara, "get_ReducedMaxHp"), weaponJob = try_field(chara, "WeaponJob"),
            human = simple_fields(try_call(sdk.get_managed_singleton("app.CharacterManager"), "get_ManualPlayerHuman")),
            stamina = simple_fields(try_call(chara, "get_StaminaManager")),
        }
    end)
    diag.hero = okhs and heroDiag or tostring(heroDiag)
    -- v23: контексты в обёртке ContextInfo — достаём по типу (context_of) и выгружаем поля, с вложенными объектами
    local NAMED = { "app.HumanStatusContext", "app.JobContext", "app.PlayerPersonalDataContext", "app.StaminaContext",
        "app.HumanWeightRankContext", "app.PawnDataContext", "app.MainPawnDataContext" }
    local function named_contexts(c)
        local out = {}
        for _, t in ipairs(NAMED) do
            local ctx = context_of(c, t)
            if ctx ~= nil then
                local entry = { values = simple_fields(ctx), nested = {} }
                local okt, td = pcall(function() return ctx:get_type_definition() end)
                while okt and td ~= nil and td:get_full_name() ~= "System.Object" do
                    for _, f in ipairs(td:get_fields()) do
                        local fv = not f:is_static() and try_field(ctx, f:get_name()) or nil
                        if type(fv) == "userdata" then
                            entry.nested[f:get_name()] = { type = type_name(fv), values = simple_fields(fv),
                                items = #list_items(fv) > 0 and #list_items(fv) or nil }
                        end
                    end
                    td = td:get_parent_type()
                end
                out[t] = entry
            end
        end
        return out
    end
    local oknc, nc = pcall(named_contexts, chara)
    diag.heroContexts = oknc and nc or tostring(nc)
    local okpn, pnc = pcall(function()
        local out = {}
        for _, c in ipairs(pawn_characters()) do out[#out + 1] = named_contexts(c) end
        return out
    end)
    diag.pawnNamedContexts = okpn and pnc or tostring(pnc)
    -- v24: характеристики (сила, защита…) игра считает с экипировкой — калькулятор статуса героя
    local okcalc, calcDiag = pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local holder = try_call(cm, "get_PlayerStatusCalculatorHolder")
        local out = { holder = explore(holder, 2), types = {} }
        local function add_type(obj)
            local okt, td = pcall(function() return obj:get_type_definition() end)
            if okt and td ~= nil and out.types[td:get_full_name()] == nil then out.types[td:get_full_name()] = describe_type(td) end
        end
        add_type(holder)
        -- v25: сами калькуляторы (словарь CharacterID → PlayerStatusCalculator): поля, вложенные объекты, методы
        out.calculators = {}
        for _, calc in ipairs(set_items(try_field(holder, "Calculators"))) do
            add_type(calc)
            local entry = { type = type_name(calc), values = simple_fields(calc), nested = {} }
            local okc, ctd = pcall(function() return calc:get_type_definition() end)
            while okc and ctd ~= nil and ctd:get_full_name() ~= "System.Object" do
                for _, f in ipairs(ctd:get_fields()) do
                    local fv = not f:is_static() and try_field(calc, f:get_name()) or nil
                    if type(fv) == "userdata" then
                        add_type(fv)
                        entry.nested[f:get_name()] = { type = type_name(fv), values = simple_fields(fv) }
                    end
                end
                ctd = ctd:get_parent_type()
            end
            out.calculators[#out.calculators + 1] = entry
        end
        local okt, td = pcall(function() return holder:get_type_definition() end)
        if okt and td ~= nil then
            for _, f in ipairs(td:get_fields()) do
                local fv = not f:is_static() and try_field(holder, f:get_name()) or nil
                if type(fv) == "userdata" then
                    add_type(fv)
                    for _, item in ipairs(list_items(fv)) do add_type(item) end
                end
            end
        end
        return out
    end)
    diag.statusCalculator = okcalc and calcDiag or tostring(calcDiag)
    -- v26: результаты калькулятора героя — что за поля в итоге и в базовых
    local okst, statsDiag = pcall(function()
        local calc = status_calculator(chara)
        local total = call0(calc, "calcAttackDefenceWithEquipmentAndBuff")
        local base = call0(calc, "calcBasicAttackDefence")
        local out = { found = calc ~= nil, charaId = try_call(chara, "get_CharaID"), stats = character_stats(chara), types = {} }
        for _, v in ipairs({ total, base }) do
            local okt, td = pcall(function() return v:get_type_definition() end)
            if okt and td ~= nil then out.types[td:get_full_name()] = describe_type(td) end
        end
        return out
    end)
    diag.heroStats = okst and statsDiag or tostring(statsDiag)
    -- v27: ранги призваний (таблица опыта призваний) и деньги/кристаллы разлома (зашифрованы в ItemManager)
    local okj, jobDiag = pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local out = { hero = vitals(chara), calculator = explore(try_call(cm, "get_JobPointCalculator"), 2),
            params = explore(try_call(cm, "get_JobStatusParamHolder"), 1), types = {}, ranks = safe_ranks(chara),
            methods = {}, raw = {}, statusParams = {} }
        -- v28: типы параметров методов JobContext и сырые ответы — сверка с экраном призваний
        local jc = context_of(chara, "app.JobContext")
        local okt0, jtd = pcall(function() return jc:get_type_definition() end)
        if okt0 and jtd ~= nil then
            for _, m in ipairs(jtd:get_methods()) do
                local name = m:get_name()
                if name == "getJobExp" or name == "calcJobRank" or name == "getMaxJobRank" or name == "setJobExpWithJobRank" then
                    local types = {}
                    local okp, params = pcall(function() return m:get_param_types() end)
                    for _, p in ipairs(okp and params or {}) do types[#types + 1] = p:get_full_name() end
                    out.methods[#out.methods + 1] = name .. "(" .. table.concat(types, ", ") .. ")"
                    if name ~= "setJobExpWithJobRank" then
                        local row = {}
                        for _, arg in ipairs({ 0, 1, 2, 3, 100, 1000, 3000, 6000, 10000, 20000 }) do
                            local okc, r = pcall(function() return m:call(jc, arg) end)
                            row[tostring(arg)] = okc and r or nil
                        end
                        out.raw[#out.raw + 1] = { method = out.methods[#out.methods], values = row }
                    end
                end
            end
        end
        local holder = try_call(cm, "get_JobStatusParamHolder")
        for j = 1, 4 do
            local okp, sp = pcall(function() return holder:call("getJobStatusParam", j) end)
            if okp and sp ~= nil then out.statusParams[tostring(j)] = explore(sp, 2) end
        end
        for _, obj in ipairs({ context_of(chara, "app.JobContext"), try_call(cm, "get_JobPointCalculator"),
            try_call(cm, "get_JobStatusParamHolder") }) do
            local okt, td = pcall(function() return obj:get_type_definition() end)
            if okt and td ~= nil then out.types[td:get_full_name()] = describe_type(td) end
        end
        return out
    end)
    diag.jobs = okj and jobDiag or tostring(jobDiag)
    -- v31: ищем таблицу порогов рангов в настройках CharacterManager — только чтение полей (get_field/get_element).
    -- Признаки: число 9200 (порог 6-го ранга лучника по экрану: 6201 + «далее 2999») и возрастающие ряды из 8–10 чисел.
    local okr, rankSearch = pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local hits, series, seen, count = {}, {}, {}, 0
        local function number_of(v)
            if type(v) == "number" then return v end
            local x = try_field(v, "m_value")
            if type(x) == "number" then return x end
            return nil
        end
        local walk
        local function visit(v, path, depth)
            local n = number_of(v)
            if n ~= nil then
                if n == 9200 and #hits < 50 then hits[#hits + 1] = path end
            elseif type(v) == "userdata" then
                walk(v, path, depth + 1)
            end
        end
        walk = function(obj, path, depth)
            if obj == nil or depth > 6 or count > 40000 then return end
            local okt, td = pcall(function() return obj:get_type_definition() end)
            if not okt or td == nil then return end
            local oka, addr = pcall(function() return obj:get_address() end)
            if oka and addr ~= nil then
                if seen[addr] then return end
                seen[addr] = true
            end
            count = count + 1
            if is_array(obj) then
                local items = list_items(obj)
                local nums = {}
                for i, v in ipairs(items) do
                    if i > 300 then break end
                    local n = number_of(v)
                    if n ~= nil then nums[#nums + 1] = n end
                    visit(v, path .. "[" .. (i - 1) .. "]", depth)
                end
                if #nums >= 8 and #nums <= 12 and #series < 40 then
                    local up = true
                    for i = 2, #nums do if nums[i] <= nums[i - 1] then up = false end end
                    if up and nums[#nums] >= 1000 then series[#series + 1] = { path = path, values = nums } end
                end
                return
            end
            local t, level = td, 0
            while t ~= nil and level < 3 and t:get_full_name() ~= "System.Object" do
                for _, f in ipairs(t:get_fields()) do
                    if not f:is_static() then
                        local name = f:get_name()
                        local okf, v = pcall(function() return obj:get_field(name) end)
                        if okf and v ~= nil then visit(v, path .. "." .. name, depth) end
                    end
                end
                t = t:get_parent_type()
                level = level + 1
            end
        end
        local okt, td = pcall(function() return cm:get_type_definition() end)
        for _, f in ipairs(okt and td and td:get_fields() or {}) do
            local name = f:get_name()
            if not f:is_static() and (name:find("Param") or name:find("Table") or name:find("Holder") or name:find("Calculator")
                or name:find("Data")) and not name:find("ContextSaveRecords") then
                local okf, v = pcall(function() return cm:get_field(name) end)
                if okf and type(v) == "userdata" then walk(v, name, 0) end
            end
        end
        return { hits = hits, series = series, nodes = count }
    end)
    diag.rankSearch = okr and rankSearch or tostring(rankSearch)
    -- v33: в CharacterManager таблицы порогов нет (v31), а sdk.get_tdb в этой сборке REFramework нет (v32). Перебираем
    -- вероятные имена типов через find_type_definition (только метаданные) и читаем их статические поля.
    local okty, typeSearch = pcall(function()
        local found, tried = {}, 0
        local prefixes = { "app.Job", "app.HumanJob", "app.PlayerJob", "app.JobContext.", "app.Character.Job", "app.CharacterJob" }
        local suffixes = { "RankParam", "RankParameter", "RankData", "RankTable", "RankSetting", "RankSettings", "RankUpParam",
            "RankExpParam", "RankExpTable", "RankExpData", "ExpParam", "ExpParameter", "ExpTable", "ExpData", "ExpSetting",
            "LevelParam", "LevelTable", "LevelData", "Param", "Parameter", "Parameters", "ParamHolder", "Define", "Data", "Setting",
            "Settings", "Util", "Utility", "Utils", "Manager", "PointParam", "PointTable", "Info", "InfoTable", "Table", "Rank",
            "Exp", "RankInfo", "RankDefine", "RankUtil", "RankCalculator", "ExpCalculator", "Helper", "Master", "MasterData",
            "UserData", "ParamTable", "StatusParam", "SkillParam", "SkillTable", "AbilityParam" }
        for _, p0 in ipairs(prefixes) do
            for _, s0 in ipairs(suffixes) do
                local name = p0 .. s0
                tried = tried + 1
                local ok, td = pcall(sdk.find_type_definition, name)
                if ok and td ~= nil then
                    local d = describe_type(td)
                    d.statics = {}
                    for _, f in ipairs(td:get_fields()) do
                        if f:is_static() then
                            local okv, v = pcall(function() return f:get_data(nil) end)
                            if okv and (type(v) == "number" or type(v) == "string" or type(v) == "boolean") then
                                d.statics[f:get_name()] = v
                            elseif okv and v ~= nil then
                                local items = is_array(v) and list_items(v) or nil
                                if items then
                                    local nums = {}
                                    for i, x in ipairs(items) do
                                        if i > 64 then break end
                                        local n = type(x) == "number" and x or try_field(x, "m_value")
                                        nums[#nums + 1] = type(n) == "number" and n or tostring(x)
                                    end
                                    d.statics[f:get_name()] = nums
                                else
                                    d.statics[f:get_name()] = explore(v, 1)
                                end
                            end
                        end
                    end
                    found[#found + 1] = d
                end
            end
        end
        return { tried = tried, found = found }
    end)
    diag.typeSearch = okty and typeSearch or tostring(typeSearch)
    -- v36: таблица рангов из перехвата (см. rank_param): выгружаем её и пробные расчёты для лучника
    local okrp, rankParam = pcall(function()
        local out = { hooks = rank_param_hooks, captured = rank_param ~= nil }
        local first = rank_param
        if first ~= nil then
            out.dump = explore(first, 3)
            out.jobParams = {}
            for i, jp in ipairs(list_items(try_field(first, "JobParams"))) do
                if i > 12 then break end
                local e = explore(jp, 2)
                for fname, v in pairs(e or {}) do
                    if type(v) == "table" and v["$type"] and tostring(v["$type"]):sub(-2) == "[]" then
                        local vals = {}
                        for k, x in ipairs(list_items(try_field(jp, fname))) do
                            if k > 20 then break end
                            local n = type(x) == "number" and x or try_field(x, "m_value")
                            vals[#vals + 1] = type(n) == "number" and n or explore(x, 1)
                        end
                        e[fname] = vals
                    end
                end
                out.jobParams[#out.jobParams + 1] = e
            end
            local exp, rank = {}, {}
            for r = 1, 9 do exp[tostring(r)] = rank_exp(2, r) end
            for _, e in ipairs({ 6201, 9199, 9200 }) do
                local ok, v = pcall(function() return first:call("calcJobRank", 2, e) end)
                rank[tostring(e)] = ok and v or nil
            end
            out.archerExp, out.archerRank = exp, rank
        end
        return out
    end)
    diag.rankParam = okrp and rankParam or tostring(rankParam)
    local okm, moneyDiag = pcall(function()
        local im = sdk.get_managed_singleton("app.ItemManager")
        local out = {}
        local okt, td = pcall(function() return im:get_type_definition() end)
        if okt and td ~= nil then
            for _, m in ipairs(td:get_methods()) do
                local name = m:get_name()
                if name:sub(1, 5) == "get__" and m:get_num_params() == 0 then
                    local okc, v = pcall(function() return m:call(im) end)
                    if okc and type(v) == "number" then out[name] = v end
                end
            end
        end
        local gui = sdk.get_managed_singleton("app.GuiManager")
        return { itemManager = out, money2 = explore(try_field(gui, "Money2"), 1), value = try_call(im, "get_Value"),
            param = try_call(im, "get_Param"), version = try_call(im, "get_Version"), money = money() }
    end)
    diag.money = okm and moneyDiag or tostring(moneyDiag)
    local okpp, pawnCtx = pcall(function()
        local out = {}
        for _, c in ipairs(pawn_characters()) do
            out[#out + 1] = {
                hp = try_call(c, "get_Hp"), maxHp = try_call(c, "get_OriginalMaxHp"), weaponJob = try_field(c, "WeaponJob"),
                contexts = contexts_of(c),
            }
        end
        return out
    end)
    diag.pawnContexts = okpp and pawnCtx or tostring(pawnCtx)
    -- v16: все гиммики рядом с игроком — каким типом и с каким флагом игра держит жетон, который рядом
    local okg, nearDiag = pcall(function()
        local list, sources = all_gimmicks()
        local me = chara and player_position(chara)
        local near = {}
        for _, it in ipairs(list) do
            local pos = universal_pos(it.g)
            local d = (me and pos) and math.sqrt((pos.x - me.x) ^ 2 + (pos.z - me.z) ^ 2) or nil
            if d ~= nil and d <= 40 then
                local raw = nil
                local okr, r = pcall(function() return it.g:call("get__IsIt000078") end)
                raw = okr and (type(r) .. ":" .. tostring(r)) or ("error: " .. tostring(r))
                local gid = try_field(it.g, "GimmickId")
                near[#near + 1] = {
                    type = type_name(it.g), src = it.src, dist = math.floor(d * 10) / 10, pos = pos,
                    isToken = raw, uid = token_uid(it.g),
                    gimmickId = type(gid) == "userdata" and text_of(gid) or gid,
                    state = try_field(it.g, "<NowState>k__BackingField"),
                    items = explore(list_items(try_field(it.g, "ItemList"))[1], 1),
                }
            end
        end
        table.sort(near, function(a, b) return a.dist < b.dist end)
        while #near > 25 do table.remove(near) end
        return { total = #list, sources = sources, player = me, near = near }
    end)
    diag.gimmicksNear = okg and nearDiag or tostring(nearDiag)
    -- v5: метки игрока — что лежит в MapPinList
    local okp, pinsDiag = pcall(function()
        local gui = sdk.get_managed_singleton("app.GuiManager")
        local arr = try_call(gui, "get_MapPinList") or try_field(gui, "<MapPinList>k__BackingField")
        local items = list_items(arr)
        local function probe(f)
            local ok, v = pcall(f)
            if not ok then return "error: " .. tostring(v) end
            if type(v) == "table" then return "table #" .. tostring(#v) end
            return type(v) == "userdata" and type_name(v) or v
        end
        local out = {
            enableCount = try_call(gui, "getEnableMapPinCount"), arrayType = type_name(arr), size = #items, sample = {},
            probes = {
                get_size = probe(function() return arr:get_size() end),
                get_Count = probe(function() return arr:call("get_Count") end),
                get_Length = probe(function() return arr:call("get_Length") end),
                get_elements = probe(function() return arr:get_elements() end),
                element0 = probe(function() return arr:get_element(0) end),
            },
        }
        for i, icon in ipairs(items) do
            if i <= 6 then table.insert(out.sample, explore(icon, 1)) end
        end
        return out
    end)
    diag.mapPins = okp and pinsDiag or tostring(pinsDiag)
    -- v5: пешки — какие контексты нашлись у персонажей-пешек
    local okw, pawnsDiag = pcall(function()
        local out = {}
        for _, chara in ipairs(pawn_characters()) do
            local holder = try_call(chara, "get_Context")
            local p, wrapper = context_of(chara, "app.PawnDataContext")
            table.insert(out, {
                type = type_name(chara),
                holder = type_name(holder),
                contextsCount = try_call(try_field(holder, "Contexts"), "get_Count"),
                pawnData = type_name(p),
                -- контекст не нашёлся в обёртке — покажем её устройство
                wrapper = wrapper and explore(wrapper, 1) or nil,
            })
        end
        return out
    end)
    diag.pawns = okw and pawnsDiag or tostring(pawnsDiag)
    -- v9: туман войны — устройство MapMaskInfo и найденный массив маски
    local okf, fogDiag = pcall(function()
        local gui = sdk.get_managed_singleton("app.GuiManager")
        local info = try_field(gui, "MapMaskField")
        local arr, name = find_mask_array(info, 1)
        local items = list_items(arr)
        return {
            infoType = type_name(info),
            info = explore(info, 1),
            arrayField = name,
            arrayType = type_name(arr),
            size = #items,
            first = items[1] ~= nil and to_uint(items[1]) or nil,
            nonZero = (function() local c = 0; for _, v in ipairs(items) do if to_uint(v) ~= 0 then c = c + 1 end end; return c end)(),
            current = explore(try_field(gui, "MapMaskCurrentArea"), 0),
            localCount = try_field(gui, "MapMaskLocalAreaNum"),
            locals = (function()
                local out = {}
                for i, li in ipairs(list_items(try_field(gui, "MapMaskLocalArea"))) do
                    local m = encode_mask(li)
                    if m ~= nil and m.any and #out < 20 then
                        out[#out + 1] = { area = i - 1, base = m.base, range = m.range, size = m.size, bytes = #m.bits * 3 // 4 }
                    end
                end
                return out
            end)(),
        }
    end)
    diag.fog = okf and fogDiag or tostring(fogDiag)
    -- v10: симпатия NPC — где нашлась и устройство SentimentController
    local okn, npcDiag = pcall(function()
        local npcm = sdk.get_managed_singleton("app.NPCManager")
        local ctrl = try_call(npcm, "get_SentimentController") or try_field(npcm, "<SentimentController>k__BackingField")
        local entries, where = npc_sentiments()
        local holders = list_items(try_call(npcm, "get_NPCHolder_FullList"))
        local first = holders[1]
        local fields = {}
        if first ~= nil then
            for _, e in ipairs(sentiment_fields(first, 2, "NPCHolder", {})) do
                fields[#fields + 1] = { path = e.path, type = type(e.value) == "userdata" and type_name(e.value) or e.value }
            end
        end
        return {
            controllerType = type_name(ctrl),
            holders = #holders,
            holderType = type_name(first),
            holderCharaId = first and npc_chara_id(first) or nil,
            holderSentimentFields = fields,
            holder = explore(first, 1),
            foundAt = where,
            sentimentPath = sentiment_path and table.concat(sentiment_path, ".") or nil,
            count = entries and #entries or 0,
            sample = entries and { entries[1], entries[2], entries[3] } or nil,
        }
    end)
    diag.sentiments = okn and npcDiag or tostring(npcDiag)
    local okv, pawnState = pcall(pawn_state)
    diag.pawnState = okv and pawnState or tostring(pawnState)
    json.dump_file(DIAG_FILE, diag)
    status = "diagnostics saved to reframework/data/" .. DIAG_FILE
end

-- Названия всех квестов: из каталога журнала квестов (QuestLogResource._Title → текст на RU и EN).
local function dump_names()
    local qlm = sdk.get_managed_singleton("app.QuestLogManager")
    if qlm == nil then error("QuestLogManager not ready") end
    local catalogs = {}
    for _, fname in ipairs({ "_Catalog", "_Contents0014Catalog" }) do
        local cat = try_field(qlm, fname)
        if cat ~= nil then
            table.insert(catalogs, cat)
            local td = cat:get_type_definition()
            for _, f in ipairs(td:get_fields()) do
                local ft = f:get_type()
                if ft and ft:get_full_name():find("Dictionary") then
                    local d = try_field(cat, f:get_name())
                    if d ~= nil then table.insert(catalogs, d) end
                end
            end
        end
    end
    local function resource(id)
        for _, d in ipairs(catalogs) do
            local okc, has = pcall(function() return d:call("ContainsKey", id) end)
            if okc and has then
                local ok, r = pcall(function() return d:call("get_Item", id) end)
                if ok and r ~= nil then return r end
            end
        end
        return nil
    end
    local out = { version = VERSION, time = os.time(), quests = {} }
    local count = 0
    for id = 10000, 99990, 10 do
        local res = resource(id)
        local title = res and try_call(res, "get_Title")
        local ru, en = message(title, LANG_RU), message(title, LANG_EN)
        if ru == nil and en == nil then
            -- запасной путь: журнал игры (только для квестов, которые уже были в журнале)
            ru = quest_name(qlm, id)
        end
        if ru ~= nil or en ~= nil then
            out.quests[tostring(id)] = { ru = ru, en = en }
            count = count + 1
        end
    end
    json.dump_file(NAMES_FILE, out)
    status = "names: " .. count .. " quests saved to reframework/data/" .. NAMES_FILE
end

-- Иконки карты игры (камни разлома, порткристаллы, станции, гостиницы…): тип и мировые координаты.
local function dump_map_icons()
    local gui = sdk.get_managed_singleton("app.GuiManager")
    if gui == nil then error("GuiManager not ready") end
    local sources = {
        { "minimap", try_call(gui, "getMiniMapIconList") },
        { "dynamic", try_call(gui, "getDynamicMapIconList") },
        { "warp", try_call(gui, "getWarpPointList") },
        { "wakestone", try_call(gui, "getWakeStoneIconList") },
        { "pin", try_call(gui, "get_MapPinList") },
        { "disp", try_field(gui, "MapIconDispList") },
        { "hide", try_field(gui, "MapIconHideList") },
    }
    local out = { version = VERSION, time = os.time(), player = last_live and last_live.player, icons = {} }
    local count = 0
    for _, src in ipairs(sources) do
        for _, icon in ipairs(list_items(src[2])) do
            local pos = vec3(try_field(icon, "Pos"))
            if pos ~= nil and (pos.x ~= 0 or pos.z ~= 0) then
                local uid = try_field(icon, "UniqId")
                table.insert(out.icons, {
                    src = src[1],
                    type = try_field(icon, "IconType"),
                    id = try_field(icon, "IconId"),
                    enabled = try_field(icon, "IsEnable"),
                    uid = uid and tostring(try_call(uid, "ToString")) or nil,
                    pos = pos,
                })
                count = count + 1
            end
        end
    end
    json.dump_file(ICONS_FILE, out)
    status = "map icons: " .. count .. " saved to reframework/data/" .. ICONS_FILE
end

re.on_draw_ui(function()
    if imgui.tree_node("GuidForGames") then
        imgui.text("Bridge v" .. VERSION .. ": " .. status)
        if last_live ~= nil and last_live.player ~= nil then
            local p = last_live.player
            imgui.text(string.format("Player: x %.1f, y %.1f, z %.1f", p.x, p.y, p.z))
            if last_live.quest ~= nil and last_live.quest.tracked ~= nil then
                imgui.text("Tracked quest: " .. tostring(last_live.quest.tracked) .. " " .. tostring(last_live.quest.trackedName or ""))
            end
            if last_live.seekerTokens ~= nil then
                imgui.text("Seeker tokens picked (with mod): " .. tostring(last_live.seekerTokens) .. ", places known: "
                    .. tostring(token_places_count) .. ", events: " .. tostring(#events.items))
                if last_live.character ~= nil then
                    imgui.text("Character: " .. tostring(last_live.character.key))
                end
                if last_live.clock ~= nil then
                    imgui.text(string.format("Play time: %.0f s, game clock: %.0f", last_live.clock.play or -1, last_live.clock.game or -1))
                end
            end
        end
        if imgui.button("Dump names") then
            local ok, err = pcall(dump_names)
            if not ok then status = "names error: " .. tostring(err) end
        end
        if imgui.button("Dump map icons") then
            local ok, err = pcall(dump_map_icons)
            if not ok then status = "map icons error: " .. tostring(err) end
        end
        if imgui.button("Dump diagnostics") then
            local ok, err = pcall(dump_diag)
            if not ok then status = "diagnostics error: " .. tostring(err) end
        end
        imgui.tree_pop()
    end
end)
